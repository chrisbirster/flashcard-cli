const std = @import("std");
const HistoryEntry = @import("../history.zig").Entry;
const evaluator = @import("evaluator.zig");
const Parameters = @import("parameters.zig").Parameters;
const time = @import("../../time.zig");

pub const default_splits: usize = 5;

pub const Fold = struct {
    train_end_ms_exclusive: time.TimestampMs,
    test_start_ms: time.TimestampMs,
    test_end_ms_exclusive: ?time.TimestampMs,
};

pub const FoldMetrics = struct {
    fold: Fold,
    train: evaluator.Metrics,
    evaluation: evaluator.Metrics,
};

pub const Result = struct {
    folds: []FoldMetrics,
    weighted_test_log_loss: f64,
    weighted_test_rmse: f64,
    test_examples: usize,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.folds);
    }
};

fn lessThan(_: void, lhs: time.TimestampMs, rhs: time.TimestampMs) bool {
    return lhs < rhs;
}

fn scoreableTimestamps(
    allocator: std.mem.Allocator,
    histories: []const []const HistoryEntry,
) ![]time.TimestampMs {
    var timestamps: std.ArrayList(time.TimestampMs) = .empty;
    errdefer timestamps.deinit(allocator);
    for (histories) |history| {
        if (history.len < 2) continue;
        for (history[1..]) |entry| try timestamps.append(allocator, entry.reviewed_at_ms);
    }
    std.sort.heap(time.TimestampMs, timestamps.items, {}, lessThan);
    return timestamps.toOwnedSlice(allocator);
}

/// Mirror sklearn TimeSeriesSplit's default sample sizing while converting the
/// boundaries to timestamps. Equal timestamps stay on the newer/test side of
/// a boundary, which can enlarge a fold but never leaks future state backward.
pub fn folds(
    allocator: std.mem.Allocator,
    histories: []const []const HistoryEntry,
    n_splits: usize,
) ![]Fold {
    if (n_splits < 2) return error.InvalidSplitCount;
    const timestamps = try scoreableTimestamps(allocator, histories);
    defer allocator.free(timestamps);
    if (timestamps.len <= n_splits) return error.NotEnoughReviewHistory;

    const test_size = timestamps.len / (n_splits + 1);
    if (test_size == 0) return error.NotEnoughReviewHistory;
    const remainder = timestamps.len % (n_splits + 1);

    const result = try allocator.alloc(Fold, n_splits);
    errdefer allocator.free(result);
    for (result, 0..) |*fold, index| {
        const test_start_index = remainder + test_size * (index + 1);
        const test_end_index = test_start_index + test_size;
        const test_start = timestamps[test_start_index];
        fold.* = .{
            .train_end_ms_exclusive = test_start,
            .test_start_ms = test_start,
            .test_end_ms_exclusive = if (test_end_index < timestamps.len)
                timestamps[test_end_index]
            else
                null,
        };
    }
    return result;
}

pub fn evaluate(
    allocator: std.mem.Allocator,
    histories: []const []const HistoryEntry,
    parameters: Parameters,
    n_splits: usize,
    options: evaluator.Options,
) !Result {
    const split_folds = try folds(allocator, histories, n_splits);
    defer allocator.free(split_folds);
    const metrics = try allocator.alloc(FoldMetrics, split_folds.len);
    errdefer allocator.free(metrics);

    var test_examples: usize = 0;
    var weighted_log_loss: f64 = 0;
    var weighted_squared_error: f64 = 0;
    var total_weight: f64 = 0;

    for (split_folds, 0..) |fold, index| {
        const train_options: evaluator.Options = .{
            .recency_half_life_days = options.recency_half_life_days,
            .evaluation_start_ms = options.evaluation_start_ms,
            .evaluation_end_ms_exclusive = fold.train_end_ms_exclusive,
        };
        const evaluation_options: evaluator.Options = .{
            .recency_half_life_days = options.recency_half_life_days,
            .evaluation_start_ms = @max(options.evaluation_start_ms orelse fold.test_start_ms, fold.test_start_ms),
            .evaluation_end_ms_exclusive = if (options.evaluation_end_ms_exclusive) |configured|
                if (fold.test_end_ms_exclusive) |fold_end| @min(configured, fold_end) else configured
            else
                fold.test_end_ms_exclusive,
        };
        const train_metrics = try evaluator.evaluate(histories, parameters, train_options);
        const test_metrics = try evaluator.evaluate(histories, parameters, evaluation_options);
        metrics[index] = .{ .fold = fold, .train = train_metrics, .evaluation = test_metrics };
        test_examples += test_metrics.examples;
        weighted_log_loss += test_metrics.log_loss * test_metrics.effective_weight;
        weighted_squared_error += test_metrics.brier_score * test_metrics.effective_weight;
        total_weight += test_metrics.effective_weight;
    }

    return .{
        .folds = metrics,
        .weighted_test_log_loss = if (total_weight > 0) weighted_log_loss / total_weight else 0,
        .weighted_test_rmse = if (total_weight > 0) @sqrt(weighted_squared_error / total_weight) else 0,
        .test_examples = test_examples,
    };
}

test "five-way split mirrors sklearn default sample sizing" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 1 * day },
        .{ .rating = .good, .reviewed_at_ms = 2 * day },
        .{ .rating = .good, .reviewed_at_ms = 3 * day },
        .{ .rating = .good, .reviewed_at_ms = 4 * day },
        .{ .rating = .good, .reviewed_at_ms = 5 * day },
        .{ .rating = .good, .reviewed_at_ms = 6 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const split = try folds(std.testing.allocator, &histories, 5);
    defer std.testing.allocator.free(split);
    try std.testing.expectEqual(@as(usize, 5), split.len);
    try std.testing.expectEqual(2 * day, split[0].test_start_ms);
    try std.testing.expectEqual(6 * day, split[4].test_start_ms);
}

test "cross validation scores only chronological test windows" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 1 * day },
        .{ .rating = .hard, .reviewed_at_ms = 2 * day },
        .{ .rating = .good, .reviewed_at_ms = 3 * day },
        .{ .rating = .again, .reviewed_at_ms = 4 * day },
        .{ .rating = .good, .reviewed_at_ms = 5 * day },
        .{ .rating = .easy, .reviewed_at_ms = 6 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const result = try evaluate(std.testing.allocator, &histories, .{}, 5, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), result.folds.len);
    try std.testing.expect(result.test_examples >= 5);
    try std.testing.expect(std.math.isFinite(result.weighted_test_log_loss));
}
