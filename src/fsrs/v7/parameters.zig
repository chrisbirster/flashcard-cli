const std = @import("std");

pub const weight_count = 35;
pub const one_second_days = 1.0 / 86_400.0;
pub const max_supported_interval_days = 36_500.0;

pub const default_weights: [weight_count]f64 = .{
    0.041,
    2.4175,
    4.1283,
    11.9709,
    5.6385,
    0.4468,
    3.262,
    2.3054,
    0.1688,
    1.3325,
    0.3524,
    0.0049,
    0.7503,
    0.0896,
    0.6625,
    1.3,
    0.882,
    0.3072,
    3.5875,
    0.303,
    0.0107,
    0.2279,
    2.6413,
    0.5594,
    1.3,
    2.5,
    1.0,
    0.0723,
    0.1634,
    0.5,
    0.9555,
    0.2245,
    0.6232,
    0.1362,
    0.3862,
};

pub const Parameters = struct {
    weights: [weight_count]f64 = default_weights,
    desired_retention: f64 = 0.9,
    minimum_interval_days: f64 = one_second_days,
    maximum_interval_days: f64 = max_supported_interval_days,

    pub fn validate(self: Parameters) !void {
        if (!std.math.isFinite(self.desired_retention) or self.desired_retention <= 0 or self.desired_retention >= 1) {
            return error.InvalidDesiredRetention;
        }
        if (!std.math.isFinite(self.minimum_interval_days) or self.minimum_interval_days <= 0) {
            return error.InvalidMinimumInterval;
        }
        if (!std.math.isFinite(self.maximum_interval_days) or self.maximum_interval_days < self.minimum_interval_days or self.maximum_interval_days > max_supported_interval_days) {
            return error.InvalidMaximumInterval;
        }

        const ranges = [_][2]f64{
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

        for (self.weights, ranges) |weight, range| {
            if (!std.math.isFinite(weight) or weight < range[0] or weight > range[1]) return error.InvalidWeight;
        }

        if (!(self.weights[0] <= self.weights[1] and self.weights[1] <= self.weights[2] and self.weights[2] <= self.weights[3])) {
            return error.InvalidInitialStabilityOrder;
        }
        if (self.weights[28] < self.weights[27]) return error.InvalidForgettingCurve;
        if (self.weights[30] < self.weights[29]) return error.InvalidForgettingCurve;
    }
};

test "default FSRS-7 parameters validate" {
    const parameters: Parameters = .{};
    try parameters.validate();
    try std.testing.expectEqual(@as(usize, 35), parameters.weights.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.041), parameters.weights[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3862), parameters.weights[34], 1e-12);
}

test "parameter validation rejects incompatible forgetting curve ordering" {
    var parameters: Parameters = .{};
    parameters.weights[28] = 0.02;
    parameters.weights[27] = 0.03;
    try std.testing.expectError(error.InvalidForgettingCurve, parameters.validate());
}
