const std = @import("std");
const Parameters = @import("parameters.zig").Parameters;
const simulator = @import("simulator.zig");

pub const Config = struct {
    minimum_retention: f64 = 0.80,
    maximum_retention: f64 = 0.99,
    step: f64 = 0.01,
    /// Additional explicit relearning cost. Zero models equal review costs.
    lapse_penalty_seconds: f64 = 0.0,
    simulation: simulator.Config = .{},
};

pub const Point = struct {
    desired_retention: f64,
    reviews: usize,
    lapses: usize,
    average_daily_reviews: f64,
    estimated_study_seconds: f64,
    average_retrievability_at_horizon: f64,
    estimated_knowledge: f64,
    total_cost_seconds: f64,
    workload_per_knowledge: f64,
};

pub const Analysis = struct {
    points: []Point,
    optimal_retention: f64,
    minimum_workload_per_knowledge: f64,

    pub fn deinit(self: Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
    }
};

/// Compute minimum recommended retention using the current reference objective:
/// minimize study workload divided by acquired knowledge. Acquired knowledge is
/// represented by the sum of horizon recall probabilities; for a homogeneous
/// simulated population this is cards_introduced * average retrievability.
pub fn analyze(
    allocator: std.mem.Allocator,
    base_parameters: Parameters,
    config: Config,
) !Analysis {
    if (!std.math.isFinite(config.minimum_retention) or !std.math.isFinite(config.maximum_retention) or
        config.minimum_retention <= 0 or config.maximum_retention >= 1 or
        config.minimum_retention > config.maximum_retention)
    {
        return error.InvalidRetentionRange;
    }
    if (!std.math.isFinite(config.step) or config.step <= 0) return error.InvalidRetentionStep;
    if (!std.math.isFinite(config.lapse_penalty_seconds) or config.lapse_penalty_seconds < 0) return error.InvalidLapsePenalty;

    var points: std.ArrayList(Point) = .empty;
    errdefer points.deinit(allocator);

    var retention = config.minimum_retention;
    var best_retention = retention;
    var best_ratio = std.math.inf(f64);
    while (retention <= config.maximum_retention + 1e-12) : (retention += config.step) {
        var parameters = base_parameters;
        parameters.desired_retention = @min(retention, config.maximum_retention);
        try parameters.validate();

        const simulation = try simulator.simulate(allocator, parameters, config.simulation);
        const total_cost = simulation.estimated_study_seconds +
            @as(f64, @floatFromInt(simulation.lapses)) * config.lapse_penalty_seconds;
        const knowledge = @as(f64, @floatFromInt(simulation.cards_introduced)) *
            simulation.average_retrievability_at_horizon;
        const ratio = if (knowledge > 0) total_cost / knowledge else std.math.inf(f64);

        try points.append(allocator, .{
            .desired_retention = parameters.desired_retention,
            .reviews = simulation.reviews,
            .lapses = simulation.lapses,
            .average_daily_reviews = simulation.average_daily_reviews,
            .estimated_study_seconds = simulation.estimated_study_seconds,
            .average_retrievability_at_horizon = simulation.average_retrievability_at_horizon,
            .estimated_knowledge = knowledge,
            .total_cost_seconds = total_cost,
            .workload_per_knowledge = ratio,
        });

        if (ratio < best_ratio) {
            best_ratio = ratio;
            best_retention = parameters.desired_retention;
        }
    }

    return .{
        .points = try points.toOwnedSlice(allocator),
        .optimal_retention = best_retention,
        .minimum_workload_per_knowledge = best_ratio,
    };
}

test "retention analysis returns workload knowledge curve and optimum" {
    const analysis = try analyze(std.testing.allocator, .{}, .{
        .minimum_retention = 0.85,
        .maximum_retention = 0.95,
        .step = 0.05,
        .simulation = .{ .card_count = 10, .horizon_days = 30, .new_cards_per_day = 5, .seed = 42 },
    });
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), analysis.points.len);
    try std.testing.expect(analysis.optimal_retention >= 0.85 and analysis.optimal_retention <= 0.95);
    try std.testing.expect(std.math.isFinite(analysis.minimum_workload_per_knowledge));
    for (analysis.points) |point| {
        try std.testing.expect(point.estimated_knowledge > 0);
        try std.testing.expect(point.workload_per_knowledge > 0);
    }
}

test "higher retention increases review workload in the high-retention range" {
    const analysis = try analyze(std.testing.allocator, .{}, .{
        .minimum_retention = 0.90,
        .maximum_retention = 0.96,
        .step = 0.03,
        .simulation = .{ .card_count = 30, .horizon_days = 120, .new_cards_per_day = 5, .seed = 7 },
    });
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expect(analysis.points[1].reviews >= analysis.points[0].reviews);
    try std.testing.expect(analysis.points[2].reviews >= analysis.points[1].reviews);
}
