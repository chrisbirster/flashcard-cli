const std = @import("std");
const HistoryEntry = @import("../history.zig").Entry;
const model = @import("model.zig");
const parameters_mod = @import("parameters.zig");
const time = @import("../../time.zig");
const Parameters = parameters_mod.Parameters;

/// Matches the current srs-benchmark FSRS-7 training defaults: eight epochs,
/// Adam betas 0.8/0.85, learning rate 0.02, and optional positional recency
/// weighting. Deez uses deterministic finite-difference gradients instead of
/// PyTorch autograd, but optimizes the same BCE + L2 objective.
pub const Config = struct {
    epochs: usize = 8,
    learning_rate: f64 = 0.02,
    beta1: f64 = 0.8,
    beta2: f64 = 0.85,
    epsilon: f64 = 1e-8,
    finite_difference_step: f64 = 1e-4,
    gradient_clip: f64 = 10.0,
    l2_weight: f64 = 0.5,
    minimum_examples: usize = 20,
    recency_weighting: bool = false,
    // Temporary source-compatibility bridge for the existing CLI. Any value
    // enables the upstream positional weighting; the numeric half-life is not
    // used by FSRS-7 training and will be removed from the CLI before release.
    recency_half_life_days: ?f64 = null,
    seed: u64 = 0x4445455a,
};

pub const Result = struct {
    parameters: Parameters,
    initial_log_loss: f64,
    final_log_loss: f64,
    objective_before: f64,
    objective_after: f64,
    examples: usize,
    epochs: usize,
    recency_weighting: bool,
    seed: u64,
};

pub const TrainingLoss = struct {
    examples: usize,
    log_loss: f64,
};

const l2_sigma: [parameters_mod.weight_count]f64 = .{
    9999.0, 9999.0, 9999.0, 9999.0,
    0.523,  0.2528, 0.4329, 0.2966,
    0.2139, 0.2889, 0.1862, 0.0829,
    0.175,  0.3812, 0.3013, 0.9104,
    0.3234, 0.2448, 0.3273, 0.1842,
    0.1542, 0.1735, 0.4608, 0.311,
    0.864,  0.4053, 0.162,  0.0418,
    0.2596, 0.0798, 0.0682, 0.1282,
    0.1397, 0.1407, 0.1489,
};

const ranges: [parameters_mod.weight_count][2]f64 = .{
    .{ 0.0001, 50.0 }, .{ 0.0001, 100.0 }, .{ 0.0001, 100.0 }, .{ 0.0001, 100.0 },
    .{ 1.0, 10.0 },    .{ 0.001, 4.0 },    .{ 0.1, 4.0 },      .{ 0.0, 4.0 },
    .{ 0.0, 1.2 },     .{ 0.3, 3.0 },      .{ 0.01, 1.5 },     .{ 0.001, 0.9 },
    .{ 0.1, 1.0 },     .{ 0.0, 3.5 },      .{ 0.0, 1.0 },      .{ 1.0, 7.0 },
    .{ 0.0, 4.0 },     .{ 0.0, 2.0 },      .{ 0.5, 6.0 },      .{ 0.001, 1.5 },
    .{ 0.001, 2.0 },   .{ 0.001, 1.0 },    .{ 0.0, 5.0 },      .{ 0.0, 1.0 },
    .{ 1.0, 7.0 },     .{ 2.5, 15.0 },     .{ 0.0, 1.0 },      .{ 0.01, 0.25 },
    .{ 0.01, 0.95 },   .{ 0.5, 0.85 },     .{ 0.5, 0.99 },     .{ 0.01, 1.0 },
    .{ 0.1, 1.0 },     .{ 0.0, 0.9 },      .{ 0.1, 1.1 },
};

const OrderedExample = struct {
    reviewed_at_ms: i64,
    ordinal: usize,
    flat_index: usize,
};

fn lessExample(_: void, a: OrderedExample, b: OrderedExample) bool {
    if (a.reviewed_at_ms != b.reviewed_at_ms) return a.reviewed_at_ms < b.reviewed_at_ms;
    return a.ordinal < b.ordinal;
}

fn clamp(value: f64, low: f64, high: f64) f64 {
    return @max(low, @min(value, high));
}

fn probability(value: f64) f64 {
    return clamp(value, 0.0001, 0.9999);
}

fn sanitize(parameters: *Parameters) void {
    for (&parameters.weights, ranges) |*weight, range| {
        weight.* = clamp(weight.*, range[0], range[1]);
    }
    parameters.weights[1] = @max(parameters.weights[1], parameters.weights[0]);
    parameters.weights[2] = @max(parameters.weights[2], parameters.weights[1]);
    parameters.weights[3] = @max(parameters.weights[3], parameters.weights[2]);
    parameters.weights[28] = @max(parameters.weights[28], parameters.weights[27]);
    parameters.weights[30] = @max(parameters.weights[30], parameters.weights[29]);
}

fn regularization(parameters: Parameters) f64 {
    var penalty: f64 = 0;
    for (parameters.weights, parameters_mod.default_weights, l2_sigma) |weight, default, sigma| {
        const normalized = (weight - default) / sigma;
        penalty += normalized * normalized;
    }
    return penalty;
}

fn exampleCount(histories: []const []const HistoryEntry) usize {
    var count: usize = 0;
    for (histories) |history| {
        if (history.len > 1) count += history.len - 1;
    }
    return count;
}

/// Exact positional weighting used by current srs-benchmark --recency:
/// x = linspace(0, 1, N); weight = 0.25 + 0.75*x^3.
pub fn benchmarkRecencyWeight(index: usize, count: usize) f64 {
    if (count == 0) return 0;
    const x = if (count == 1)
        0.0
    else
        @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count - 1));
    return 0.25 + 0.75 * x * x * x;
}

fn prepareWeights(
    allocator: std.mem.Allocator,
    histories: []const []const HistoryEntry,
    recency_weighting: bool,
) ![]f64 {
    const count = exampleCount(histories);
    const weights = try allocator.alloc(f64, count);
    @memset(weights, 1.0);
    if (!recency_weighting or count == 0) return weights;

    const ordered = try allocator.alloc(OrderedExample, count);
    defer allocator.free(ordered);
    var flat_index: usize = 0;
    var ordinal: usize = 0;
    for (histories) |history| {
        if (history.len < 2) continue;
        for (history[1..]) |entry| {
            ordered[flat_index] = .{
                .reviewed_at_ms = entry.reviewed_at_ms,
                .ordinal = ordinal,
                .flat_index = flat_index,
            };
            flat_index += 1;
            ordinal += 1;
        }
    }
    std.sort.heap(OrderedExample, ordered, {}, lessExample);
    for (ordered, 0..) |entry, index| {
        weights[entry.flat_index] = benchmarkRecencyWeight(index, count);
    }
    return weights;
}

fn trainingLossWithWeights(
    histories: []const []const HistoryEntry,
    parameters: Parameters,
    weights: []const f64,
) !TrainingLoss {
    try parameters.validate();
    if (weights.len != exampleCount(histories)) return error.InvalidTrainingWeights;

    var total_loss: f64 = 0;
    var flat_index: usize = 0;
    for (histories) |history| {
        if (history.len < 2) continue;
        var state = model.initialMemoryState(history[0].rating, parameters);
        var previous_ms = history[0].reviewed_at_ms;
        for (history[1..]) |entry| {
            if (entry.reviewed_at_ms < previous_ms) return error.NonMonotonicHistory;
            const elapsed_days = time.millisecondsToDays(entry.reviewed_at_ms - previous_ms);
            const predicted = probability(try model.retrievability(elapsed_days, state, parameters));
            const observed: f64 = if (entry.rating == .again) 0.0 else 1.0;
            const bce = -(observed * @log(predicted) + (1.0 - observed) * @log(1.0 - predicted));
            total_loss += bce * weights[flat_index];
            flat_index += 1;
            state = try model.nextMemoryState(state, elapsed_days, entry.rating, parameters);
            previous_ms = entry.reviewed_at_ms;
        }
    }

    return .{
        .examples = weights.len,
        // Upstream divides weighted BCE by row count, not by sum(weights).
        .log_loss = if (weights.len == 0) 0 else total_loss / @as(f64, @floatFromInt(weights.len)),
    };
}

pub fn benchmarkTrainingLoss(
    allocator: std.mem.Allocator,
    histories: []const []const HistoryEntry,
    parameters: Parameters,
    recency_weighting: bool,
) !TrainingLoss {
    const weights = try prepareWeights(allocator, histories, recency_weighting);
    defer allocator.free(weights);
    return trainingLossWithWeights(histories, parameters, weights);
}

fn objective(
    histories: []const []const HistoryEntry,
    parameters: Parameters,
    weights: []const f64,
    config: Config,
) !f64 {
    const loss = try trainingLossWithWeights(histories, parameters, weights);
    if (loss.examples < config.minimum_examples) return error.NotEnoughReviewHistory;
    return loss.log_loss + config.l2_weight * regularization(parameters) /
        @as(f64, @floatFromInt(@max(loss.examples, 1)));
}

pub fn optimize(
    histories: []const []const HistoryEntry,
    initial_parameters: Parameters,
    config: Config,
) !Result {
    if (config.epochs == 0) return error.InvalidEpochCount;
    if (config.learning_rate <= 0 or !std.math.isFinite(config.learning_rate)) return error.InvalidLearningRate;
    if (config.finite_difference_step <= 0 or !std.math.isFinite(config.finite_difference_step)) return error.InvalidFiniteDifferenceStep;

    const use_recency = config.recency_weighting or config.recency_half_life_days != null;
    const allocator = std.heap.c_allocator;
    const weights = try prepareWeights(allocator, histories, use_recency);
    defer allocator.free(weights);
    if (weights.len < config.minimum_examples) return error.NotEnoughReviewHistory;

    var parameters = initial_parameters;
    sanitize(&parameters);
    try parameters.validate();

    const initial_loss = try trainingLossWithWeights(histories, parameters, weights);
    const before = try objective(histories, parameters, weights, config);
    var first_moment = [_]f64{0} ** parameters_mod.weight_count;
    var second_moment = [_]f64{0} ** parameters_mod.weight_count;

    for (0..config.epochs) |epoch_index| {
        var gradient = [_]f64{0} ** parameters_mod.weight_count;
        for (0..parameters_mod.weight_count) |index| {
            const base = parameters.weights[index];
            const step = config.finite_difference_step * @max(@abs(base), 1.0);
            var plus = parameters;
            plus.weights[index] = base + step;
            sanitize(&plus);
            var minus = parameters;
            minus.weights[index] = base - step;
            sanitize(&minus);
            const denominator = plus.weights[index] - minus.weights[index];
            if (@abs(denominator) < 1e-15) continue;
            const plus_loss = try objective(histories, plus, weights, config);
            const minus_loss = try objective(histories, minus, weights, config);
            gradient[index] = clamp((plus_loss - minus_loss) / denominator, -config.gradient_clip, config.gradient_clip);
        }

        const step_number: f64 = @floatFromInt(epoch_index + 1);
        const beta1_power = std.math.pow(f64, config.beta1, step_number);
        const beta2_power = std.math.pow(f64, config.beta2, step_number);
        for (0..parameters_mod.weight_count) |index| {
            const grad = gradient[index];
            first_moment[index] = config.beta1 * first_moment[index] + (1.0 - config.beta1) * grad;
            second_moment[index] = config.beta2 * second_moment[index] + (1.0 - config.beta2) * grad * grad;
            const corrected_m = first_moment[index] / (1.0 - beta1_power);
            const corrected_v = second_moment[index] / (1.0 - beta2_power);
            parameters.weights[index] -= config.learning_rate * corrected_m / (@sqrt(corrected_v) + config.epsilon);
        }
        sanitize(&parameters);
    }

    try parameters.validate();
    const final_loss = try trainingLossWithWeights(histories, parameters, weights);
    return .{
        .parameters = parameters,
        .initial_log_loss = initial_loss.log_loss,
        .final_log_loss = final_loss.log_loss,
        .objective_before = before,
        .objective_after = try objective(histories, parameters, weights, config),
        .examples = final_loss.examples,
        .epochs = config.epochs,
        .recency_weighting = use_recency,
        .seed = config.seed,
    };
}

test "upstream recency weighting matches cubic benchmark formula" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), benchmarkRecencyWeight(0, 5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.26171875), benchmarkRecencyWeight(1, 5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.34375), benchmarkRecencyWeight(2, 5), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), benchmarkRecencyWeight(4, 5), 1e-12);
}

test "recency weighting changes benchmark training loss reproducibly" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .again, .reviewed_at_ms = day },
        .{ .rating = .good, .reviewed_at_ms = 2 * day },
        .{ .rating = .good, .reviewed_at_ms = 3 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const plain = try benchmarkTrainingLoss(std.testing.allocator, &histories, .{}, false);
    const recent = try benchmarkTrainingLoss(std.testing.allocator, &histories, .{}, true);
    try std.testing.expectEqual(plain.examples, recent.examples);
    try std.testing.expect(@abs(plain.log_loss - recent.log_loss) > 1e-12);
}

test "optimizer produces valid deterministic parameters" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 2 * day },
        .{ .rating = .hard, .reviewed_at_ms = 5 * day },
        .{ .rating = .good, .reviewed_at_ms = 9 * day },
        .{ .rating = .again, .reviewed_at_ms = 30 * day },
        .{ .rating = .good, .reviewed_at_ms = 31 * day },
    };
    const histories = [_][]const HistoryEntry{&history};
    const config: Config = .{ .epochs = 1, .minimum_examples = 1, .learning_rate = 0.001, .recency_weighting = true, .seed = 123 };
    const first = try optimize(&histories, .{}, config);
    const second = try optimize(&histories, .{}, config);
    try first.parameters.validate();
    try std.testing.expectEqual(@as(usize, 5), first.examples);
    try std.testing.expectEqual(first.parameters.weights, second.parameters.weights);
    try std.testing.expectApproxEqAbs(first.final_log_loss, second.final_log_loss, 1e-15);
    try std.testing.expect(first.recency_weighting);
    try std.testing.expectEqual(@as(u64, 123), first.seed);
}
