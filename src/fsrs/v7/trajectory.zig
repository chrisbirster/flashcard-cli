const std = @import("std");
const Parameters = @import("parameters.zig").Parameters;
const simulator = @import("simulator.zig");

pub const Point = struct {
    day: usize,
    cumulative_reviews: usize,
    cumulative_lapses: usize,
    average_daily_reviews: f64,
    estimated_study_seconds: f64,
    average_retrievability: f64,
    average_stability_days: f64,
    average_difficulty: f64,
};

/// Return deterministic memory/workload progression over time without exposing
/// simulator internals. Each point is the result of the same seeded simulation
/// truncated at that horizon, so callers can compare progression reproducibly.
pub fn project(
    allocator: std.mem.Allocator,
    parameters: Parameters,
    base_config: simulator.Config,
    sample_every_days: usize,
) ![]Point {
    if (sample_every_days == 0) return error.InvalidSampleInterval;
    if (base_config.horizon_days == 0) return error.InvalidHorizon;

    const count = (base_config.horizon_days + sample_every_days - 1) / sample_every_days;
    const points = try allocator.alloc(Point, count);
    errdefer allocator.free(points);

    var index: usize = 0;
    var day = sample_every_days;
    while (day < base_config.horizon_days) : (day += sample_every_days) {
        var config = base_config;
        config.horizon_days = day;
        const result = try simulator.simulate(allocator, parameters, config);
        points[index] = pointFromResult(day, result);
        index += 1;
    }

    const final_result = try simulator.simulate(allocator, parameters, base_config);
    points[index] = pointFromResult(base_config.horizon_days, final_result);
    return points;
}

fn pointFromResult(day: usize, result: simulator.Result) Point {
    return .{
        .day = day,
        .cumulative_reviews = result.reviews,
        .cumulative_lapses = result.lapses,
        .average_daily_reviews = result.average_daily_reviews,
        .estimated_study_seconds = result.estimated_study_seconds,
        .average_retrievability = result.average_retrievability_at_horizon,
        .average_stability_days = result.average_stability_days_at_horizon,
        .average_difficulty = result.average_difficulty_at_horizon,
    };
}

test "trajectory returns deterministic memory and workload progression" {
    const config: simulator.Config = .{
        .card_count = 10,
        .horizon_days = 30,
        .new_cards_per_day = 5,
        .seed = 42,
    };
    const points = try project(std.testing.allocator, .{}, config, 7);
    defer std.testing.allocator.free(points);

    try std.testing.expectEqual(@as(usize, 5), points.len);
    try std.testing.expectEqual(@as(usize, 7), points[0].day);
    try std.testing.expectEqual(@as(usize, 30), points[4].day);
    for (points) |point| {
        try std.testing.expect(std.math.isFinite(point.average_retrievability));
        try std.testing.expect(point.average_retrievability >= 0 and point.average_retrievability <= 1);
        try std.testing.expect(point.average_stability_days > 0);
        try std.testing.expect(point.average_difficulty >= 1 and point.average_difficulty <= 10);
    }
    for (points[1..], points[0 .. points.len - 1]) |current, previous| {
        try std.testing.expect(current.cumulative_reviews >= previous.cumulative_reviews);
    }
}
