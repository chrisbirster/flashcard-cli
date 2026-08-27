const std = @import("std");
const HistoryEntry = @import("../history.zig").Entry;
const time = @import("../../time.zig");
const model = @import("model.zig");
const Parameters = @import("parameters.zig").Parameters;

pub const calibration_bin_count = 10;

pub const Options = struct {
    recency_half_life_days: ?f64 = null,
    evaluation_start_ms: ?time.TimestampMs = null,
    evaluation_end_ms_exclusive: ?time.TimestampMs = null,
};

pub const CalibrationBin = struct {
    count: usize = 0,
    weight: f64 = 0,
    predicted_sum: f64 = 0,
    observed_sum: f64 = 0,

    pub fn meanPredicted(self: CalibrationBin) f64 {
        return if (self.weight > 0) self.predicted_sum / self.weight else 0;
    }

    pub fn meanObserved(self: CalibrationBin) f64 {
        return if (self.weight > 0) self.observed_sum / self.weight else 0;
    }
};

pub const Metrics = struct {
    examples: usize = 0,
    effective_weight: f64 = 0,
    log_loss: f64 = 0,
    brier_score: f64 = 0,
    rmse: f64 = 0,
    mean_predicted: f64 = 0,
    mean_observed: f64 = 0,
    calibration_error: f64 = 0,
    bins: [calibration_bin_count]CalibrationBin = [_]CalibrationBin{.{}} ** calibration_bin_count,
};

pub const Comparison = struct {
    baseline: Metrics,
    candidate: Metrics,

    pub fn logLossImprovement(self: Comparison) f64 {
        return self.baseline.log_loss - self.candidate.log_loss;
    }
};

fn probability(value: f64) f64 {
    return @max(0.0001, @min(value, 0.9999));
}

fn inEvaluationWindow(reviewed_at_ms: time.TimestampMs, options: Options) bool {
    if (options.evaluation_start_ms) |start| {
        if (reviewed_at_ms < start) return false;
    }
    if (options.evaluation_end_ms_exclusive) |end| {
        if (reviewed_at_ms >= end) return false;
    }
    return true;
}

fn newestTimestamp(histories: []const []const HistoryEntry, options: Options) ?time.TimestampMs {
    var newest: ?time.TimestampMs = null;
    for (histories) |history| {
        for (history) |entry| {
            if (!inEvaluationWindow(entry.reviewed_at_ms, options)) continue;
            if (newest == null or entry.reviewed_at_ms > newest.?) newest = entry.reviewed_at_ms;
        }
    }
    return newest;
}

fn sampleWeight(reviewed_at_ms: time.TimestampMs, newest_ms: time.TimestampMs, options: Options) f64 {
    const half_life = options.recency_half_life_days orelse return 1.0;
    if (half_life <= 0 or !std.math.isFinite(half_life)) return 1.0;
    const age_days = time.millisecondsToDays(@max(@as(i64, 0), newest_ms - reviewed_at_ms));
    return @exp(-std.math.ln2 * age_days / half_life);
}

pub fn evaluate(
    histories: []const []const HistoryEntry,
    parameters: Parameters,
    options: Options,
) !Metrics {
    try parameters.validate();
    if (options.evaluation_start_ms != null and options.evaluation_end_ms_exclusive != null and
        options.evaluation_start_ms.? >= options.evaluation_end_ms_exclusive.?)
    {
        return error.InvalidEvaluationWindow;
    }
    const newest_ms = newestTimestamp(histories, options) orelse return .{};

    var result: Metrics = .{};
    var log_loss_sum: f64 = 0;
    var squared_error_sum: f64 = 0;
    var predicted_sum: f64 = 0;
    var observed_sum: f64 = 0;

    for (histories) |history| {
        if (history.len < 2) continue;
        var state = model.initialMemoryState(history[0].rating, parameters);
        var previous_ms = history[0].reviewed_at_ms;

        for (history[1..]) |entry| {
            if (entry.reviewed_at_ms < previous_ms) return error.NonMonotonicHistory;
            const elapsed_days = time.millisecondsToDays(entry.reviewed_at_ms - previous_ms);
            const predicted = probability(try model.retrievability(elapsed_days, state, parameters));

            if (inEvaluationWindow(entry.reviewed_at_ms, options)) {
                const observed: f64 = if (entry.rating == .again) 0.0 else 1.0;
                const weight = sampleWeight(entry.reviewed_at_ms, newest_ms, options);
                const error_value = predicted - observed;

                result.examples += 1;
                result.effective_weight += weight;
                log_loss_sum += weight * (-(observed * @log(predicted) + (1.0 - observed) * @log(1.0 - predicted)));
                squared_error_sum += weight * error_value * error_value;
                predicted_sum += weight * predicted;
                observed_sum += weight * observed;

                const raw_bin: usize = @intFromFloat(@floor(predicted * @as(f64, @floatFromInt(calibration_bin_count))));
                const bin_index = @min(raw_bin, calibration_bin_count - 1);
                result.bins[bin_index].count += 1;
                result.bins[bin_index].weight += weight;
                result.bins[bin_index].predicted_sum += weight * predicted;
                result.bins[bin_index].observed_sum += weight * observed;
            }

            state = try model.nextMemoryState(state, elapsed_days, entry.rating, parameters);
            previous_ms = entry.reviewed_at_ms;
        }
    }

    if (result.effective_weight == 0) return result;
    result.log_loss = log_loss_sum / result.effective_weight;
    result.brier_score = squared_error_sum / result.effective_weight;
    result.rmse = @sqrt(result.brier_score);
    result.mean_predicted = predicted_sum / result.effective_weight;
    result.mean_observed = observed_sum / result.effective_weight;

    var calibration_sum: f64 = 0;
    for (result.bins) |bin| {
        if (bin.weight == 0) continue;
        calibration_sum += bin.weight * @abs(bin.meanPredicted() - bin.meanObserved());
    }
    result.calibration_error = calibration_sum / result.effective_weight;
    return result;
}

pub fn compareParameterSets(
    histories: []const []const HistoryEntry,
    baseline: Parameters,
    candidate: Parameters,
    options: Options,
) !Comparison {
    return .{
        .baseline = try evaluate(histories, baseline, options),
        .candidate = try evaluate(histories, candidate, options),
    };
}

pub fn logLoss(histories: []const []const HistoryEntry, parameters: Parameters, options: Options) !f64 {
    return (try evaluate(histories, parameters, options)).log_loss;
}

test "evaluation predicts review history" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 3 * day },
        .{ .rating = .again, .reviewed_at_ms = 20 * day },
        .{ .rating = .hard, .reviewed_at_ms = 21 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const metrics = try evaluate(&histories, .{}, .{});
    try std.testing.expectEqual(@as(usize, 3), metrics.examples);
    try std.testing.expect(metrics.log_loss > 0 and metrics.log_loss < 10);
    try std.testing.expect(metrics.rmse >= 0 and metrics.rmse <= 1);
}

test "recency weighting reduces effective sample weight" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = day },
        .{ .rating = .good, .reviewed_at_ms = 100 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const plain = try evaluate(&histories, .{}, .{});
    const recent = try evaluate(&histories, .{}, .{ .recency_half_life_days = 30 });
    try std.testing.expect(recent.effective_weight < plain.effective_weight);
}

test "chronological evaluation window replays prior state without scoring it" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = day },
        .{ .rating = .hard, .reviewed_at_ms = 2 * day },
        .{ .rating = .again, .reviewed_at_ms = 10 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const metrics = try evaluate(&histories, .{}, .{
        .evaluation_start_ms = 2 * day,
        .evaluation_end_ms_exclusive = 11 * day,
    });
    try std.testing.expectEqual(@as(usize, 2), metrics.examples);
}

test "parameter comparison uses the same chronological history" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 2 * day },
        .{ .rating = .again, .reviewed_at_ms = 20 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    var candidate: Parameters = .{};
    candidate.weights[0] *= 1.01;
    const comparison = try compareParameterSets(&histories, .{}, candidate, .{});
    try std.testing.expectEqual(comparison.baseline.examples, comparison.candidate.examples);
    try std.testing.expect(std.math.isFinite(comparison.logLossImprovement()));
}
