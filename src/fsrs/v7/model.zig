const std = @import("std");
const Rating = @import("../rating.zig").Rating;
const parameters_mod = @import("parameters.zig");
const Parameters = parameters_mod.Parameters;

pub const MemoryState = struct {
    stability_days: f64,
    difficulty: f64,
};

const Curve = struct {
    retention: f64,
    derivative: f64,
};

fn clamp(value: f64, min_value: f64, max_value: f64) f64 {
    return @max(min_value, @min(value, max_value));
}

fn ratingValue(rating: Rating) f64 {
    return @as(f64, @floatFromInt(rating.value()));
}

pub fn initialDifficulty(rating: Rating, parameters: Parameters) f64 {
    const w = parameters.weights;
    const value = w[4] - @exp(w[5] * (ratingValue(rating) - 1.0)) + 1.0;
    return clamp(value, 1.0, 10.0);
}

pub fn initialMemoryState(rating: Rating, parameters: Parameters) MemoryState {
    return .{
        .stability_days = parameters.weights[@as(usize, rating.value() - 1)],
        .difficulty = initialDifficulty(rating, parameters),
    };
}

fn forgettingCurveAndDerivative(elapsed_days: f64, stability_days: f64, parameters: Parameters) Curve {
    const w = parameters.weights;
    const decay1 = -w[27];
    const decay2 = -w[28];
    const base1 = w[29];
    const base2 = w[30];

    const c1 = std.math.pow(f64, base1, 1.0 / decay1) - 1.0;
    const c2 = std.math.pow(f64, base2, 1.0 / decay2) - 1.0;
    const t_over_s = elapsed_days / stability_days;
    const inner1 = @max(1.0 + c1 * t_over_s, 1e-12);
    const inner2 = @max(1.0 + c2 * t_over_s, 1e-12);
    const r1 = std.math.pow(f64, inner1, decay1);
    const r2 = std.math.pow(f64, inner2, decay2);

    const weight1 = w[31] * std.math.pow(f64, stability_days, -w[33]);
    const weight2 = w[32] * std.math.pow(f64, stability_days, w[34]);
    const weight_sum = @max(weight1 + weight2, 1e-12);

    const retention = clamp((weight1 * r1 + weight2 * r2) / weight_sum, 0.0, 1.0);
    const dr1_dt = decay1 * std.math.pow(f64, inner1, decay1 - 1.0) * (c1 / stability_days);
    const dr2_dt = decay2 * std.math.pow(f64, inner2, decay2 - 1.0) * (c2 / stability_days);
    const derivative = @min((weight1 * dr1_dt + weight2 * dr2_dt) / weight_sum, 0.0);

    return .{ .retention = retention, .derivative = derivative };
}

pub fn retrievability(elapsed_days: f64, state: MemoryState, parameters: Parameters) !f64 {
    if (!std.math.isFinite(elapsed_days) or elapsed_days < 0) return error.InvalidElapsedTime;
    if (!std.math.isFinite(state.stability_days) or state.stability_days <= 0) return error.InvalidStability;
    return forgettingCurveAndDerivative(elapsed_days, state.stability_days, parameters).retention;
}

pub fn nextDifficulty(state: MemoryState, rating: Rating, parameters: Parameters) f64 {
    const w = parameters.weights;
    const delta_d = -w[6] * (ratingValue(rating) - 3.0);
    const damped = delta_d * (10.0 - state.difficulty) / 9.0;
    const current = state.difficulty + damped;
    return clamp(0.01 * initialDifficulty(.easy, parameters) + 0.99 * current, 1.0, 10.0);
}

fn componentStability(
    state: MemoryState,
    retention: f64,
    rating: Rating,
    parameters: Parameters,
    comptime base: usize,
) f64 {
    const w = parameters.weights;
    const stability = state.stability_days;
    const difficulty = state.difficulty;

    const failed = w[base + 3] *
        std.math.pow(f64, difficulty, -w[base + 4]) *
        (std.math.pow(f64, stability + 1.0, w[base + 5]) - 1.0) *
        @exp((1.0 - retention) * w[base + 6]);
    const post_lapse = @min(stability, failed);

    if (rating == .again) return post_lapse;

    const hard_penalty = if (rating == .hard) w[base + 7] else 1.0;
    const easy_bonus = if (rating == .easy) w[base + 8] else 1.0;
    const stability_increase = 1.0 +
        @exp(w[base] - 1.5) *
            (11.0 - difficulty) *
            std.math.pow(f64, stability, -w[base + 1]) *
            (@exp(@min((1.0 - retention) * w[base + 2], 30.0)) - 1.0) *
            hard_penalty *
            easy_bonus;

    return @max(post_lapse, stability * stability_increase);
}

pub fn nextMemoryState(
    state: MemoryState,
    elapsed_days: f64,
    rating: Rating,
    parameters: Parameters,
) !MemoryState {
    if (!std.math.isFinite(elapsed_days) or elapsed_days < 0) return error.InvalidElapsedTime;
    if (!std.math.isFinite(state.stability_days) or state.stability_days <= 0) return error.InvalidStability;

    const retention = forgettingCurveAndDerivative(elapsed_days, state.stability_days, parameters).retention;
    const long_term = componentStability(state, retention, rating, parameters, 7);
    const short_term = componentStability(state, retention, rating, parameters, 16);
    const coefficient = clamp(1.0 - parameters.weights[26] * @exp(-parameters.weights[25] * elapsed_days), 0.0, 1.0);
    const stability = clamp(
        coefficient * long_term + (1.0 - coefficient) * short_term,
        0.0001,
        parameters_mod.max_supported_interval_days,
    );

    return .{
        .stability_days = stability,
        .difficulty = nextDifficulty(state, rating, parameters),
    };
}

pub fn intervalForRetention(stability_days: f64, target: f64, parameters: Parameters) !f64 {
    if (!std.math.isFinite(stability_days) or stability_days <= 0) return error.InvalidStability;
    if (!std.math.isFinite(target) or target <= 0 or target >= 1) return error.InvalidDesiredRetention;

    const min_interval = parameters.minimum_interval_days;
    const max_interval = parameters.maximum_interval_days;
    var u = @log(@max(stability_days, 1e-10));
    const min_u = @log(min_interval);
    const max_u = @log(max_interval);

    for (0..12) |_| {
        u = clamp(u, min_u, max_u);
        const interval = clamp(@exp(u), min_interval, max_interval);
        const curve = forgettingCurveAndDerivative(interval, stability_days, parameters);
        const df_du = @min(curve.derivative * interval, -1e-12);
        u -= (curve.retention - target) / df_du;
    }

    return clamp(@exp(clamp(u, min_u, max_u)), min_interval, max_interval);
}

test "FSRS-7 forgetting curve reference value" {
    const parameters: Parameters = .{};
    const state: MemoryState = .{ .stability_days = 4.1283, .difficulty = 4.194588083372719 };
    const actual = try retrievability(1.0, state, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9242342483541028), actual, 1e-12);
}

test "FSRS-7 next state supports fractional intervals" {
    const parameters: Parameters = .{};
    const initial = initialMemoryState(.good, parameters);
    const next = try nextMemoryState(initial, 2.0, .good, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 10.362647327728341), next.stability_days, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 4.180821488255665), next.difficulty, 1e-10);

    const same_day = try nextMemoryState(next, 0.25, .hard, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 12.626362639611436), same_day.stability_days, 1e-10);
}

test "FSRS-7 inverts the forgetting curve for desired retention" {
    const parameters: Parameters = .{};
    const interval = try intervalForRetention(4.1283, 0.9, parameters);
    try std.testing.expectApproxEqAbs(@as(f64, 2.966927162372141), interval, 1e-10);
    const state: MemoryState = .{ .stability_days = 4.1283, .difficulty = 4.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), try retrievability(interval, state, parameters), 1e-10);
}
