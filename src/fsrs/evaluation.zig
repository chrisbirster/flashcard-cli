const std = @import("std");

pub const calibration_bin_count = 10;

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

/// Algorithm-neutral prediction metrics. Scheduler implementations should
/// return this shape so different major versions can be compared against the
/// same immutable review history without changing the history contract.
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

    pub fn brierImprovement(self: Comparison) f64 {
        return self.baseline.brier_score - self.candidate.brier_score;
    }

    pub fn calibrationImprovement(self: Comparison) f64 {
        return self.baseline.calibration_error - self.candidate.calibration_error;
    }
};

test "neutral comparison reports lower loss as improvement" {
    const comparison: Comparison = .{
        .baseline = .{ .log_loss = 0.4, .brier_score = 0.2, .calibration_error = 0.1 },
        .candidate = .{ .log_loss = 0.3, .brier_score = 0.15, .calibration_error = 0.05 },
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), comparison.logLossImprovement(), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), comparison.brierImprovement(), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), comparison.calibrationImprovement(), 1e-12);
}
