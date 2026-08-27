const std = @import("std");
const Parameters = @import("parameters.zig").Parameters;
const simulator = @import("simulator.zig");

pub const Bucket = struct {
    start_day: usize,
    end_day_exclusive: usize,
    reviews: usize,
    estimated_study_seconds: f64,
};

pub const Forecast = struct {
    daily: []Bucket,
    weekly: []Bucket,
    monthly: []Bucket,

    pub fn deinit(self: Forecast, allocator: std.mem.Allocator) void {
        allocator.free(self.daily);
        allocator.free(self.weekly);
        allocator.free(self.monthly);
    }
};

pub const Selection = struct {
    parameters: Parameters = .{},
    config: simulator.Config = .{},
};

fn cumulativeReviews(
    allocator: std.mem.Allocator,
    parameters: Parameters,
    base: simulator.Config,
    horizon_days: usize,
) !usize {
    var config = base;
    config.horizon_days = horizon_days;
    return (try simulator.simulate(allocator, parameters, config)).reviews;
}

fn aggregate(
    allocator: std.mem.Allocator,
    daily: []const Bucket,
    width_days: usize,
) ![]Bucket {
    const count = (daily.len + width_days - 1) / width_days;
    const result = try allocator.alloc(Bucket, count);
    errdefer allocator.free(result);

    for (result, 0..) |*bucket, index| {
        const start = index * width_days;
        const end = @min(start + width_days, daily.len);
        var reviews: usize = 0;
        var seconds: f64 = 0;
        for (daily[start..end]) |day| {
            reviews += day.reviews;
            seconds += day.estimated_study_seconds;
        }
        bucket.* = .{
            .start_day = start,
            .end_day_exclusive = end,
            .reviews = reviews,
            .estimated_study_seconds = seconds,
        };
    }
    return result;
}

pub fn forecast(
    allocator: std.mem.Allocator,
    parameters: Parameters,
    config: simulator.Config,
) !Forecast {
    try parameters.validate();
    if (config.horizon_days == 0) return error.InvalidHorizon;

    const daily = try allocator.alloc(Bucket, config.horizon_days);
    errdefer allocator.free(daily);

    var previous_total: usize = 0;
    for (daily, 0..) |*bucket, index| {
        const total = try cumulativeReviews(allocator, parameters, config, index + 1);
        if (total < previous_total) return error.NonMonotonicSimulation;
        const reviews = total - previous_total;
        bucket.* = .{
            .start_day = index,
            .end_day_exclusive = index + 1,
            .reviews = reviews,
            .estimated_study_seconds = @as(f64, @floatFromInt(reviews)) * config.seconds_per_review,
        };
        previous_total = total;
    }

    const weekly = try aggregate(allocator, daily, 7);
    errdefer allocator.free(weekly);
    const monthly = try aggregate(allocator, daily, 30);

    return .{ .daily = daily, .weekly = weekly, .monthly = monthly };
}

/// Combine independent deck/population forecasts. Each selection may use its
/// own FSRS parameter set, new-card rate, seed, and per-review timing assumption.
pub fn forecastSelections(
    allocator: std.mem.Allocator,
    selections: []const Selection,
    horizon_days: usize,
) !Forecast {
    if (selections.len == 0) return error.EmptySelection;
    if (horizon_days == 0) return error.InvalidHorizon;

    const daily = try allocator.alloc(Bucket, horizon_days);
    errdefer allocator.free(daily);
    for (daily, 0..) |*bucket, index| bucket.* = .{
        .start_day = index,
        .end_day_exclusive = index + 1,
        .reviews = 0,
        .estimated_study_seconds = 0,
    };

    for (selections) |selection| {
        var config = selection.config;
        config.horizon_days = horizon_days;
        const one = try forecast(allocator, selection.parameters, config);
        defer one.deinit(allocator);
        for (daily, one.daily) |*target, source| {
            target.reviews += source.reviews;
            target.estimated_study_seconds += source.estimated_study_seconds;
        }
    }

    const weekly = try aggregate(allocator, daily, 7);
    errdefer allocator.free(weekly);
    const monthly = try aggregate(allocator, daily, 30);
    return .{ .daily = daily, .weekly = weekly, .monthly = monthly };
}

test "forecast returns daily weekly and monthly buckets" {
    const config: simulator.Config = .{
        .card_count = 20,
        .horizon_days = 31,
        .new_cards_per_day = 5,
        .seed = 123,
    };
    const result = try forecast(std.testing.allocator, .{}, config);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 31), result.daily.len);
    try std.testing.expectEqual(@as(usize, 5), result.weekly.len);
    try std.testing.expectEqual(@as(usize, 2), result.monthly.len);

    var daily_total: usize = 0;
    for (result.daily) |bucket| daily_total += bucket.reviews;
    var weekly_total: usize = 0;
    for (result.weekly) |bucket| weekly_total += bucket.reviews;
    var monthly_total: usize = 0;
    for (result.monthly) |bucket| monthly_total += bucket.reviews;

    try std.testing.expectEqual(daily_total, weekly_total);
    try std.testing.expectEqual(daily_total, monthly_total);
}

test "aggregate forecast equals the sum of independent deck forecasts" {
    const selections = [_]Selection{
        .{ .config = .{ .card_count = 10, .horizon_days = 14, .new_cards_per_day = 5, .seconds_per_review = 10, .seed = 1 } },
        .{ .config = .{ .card_count = 7, .horizon_days = 14, .new_cards_per_day = 2, .seconds_per_review = 20, .seed = 2 } },
    };
    const combined = try forecastSelections(std.testing.allocator, &selections, 14);
    defer combined.deinit(std.testing.allocator);
    const first = try forecast(std.testing.allocator, selections[0].parameters, selections[0].config);
    defer first.deinit(std.testing.allocator);
    const second = try forecast(std.testing.allocator, selections[1].parameters, selections[1].config);
    defer second.deinit(std.testing.allocator);

    for (combined.daily, first.daily, second.daily) |total, a, b| {
        try std.testing.expectEqual(a.reviews + b.reviews, total.reviews);
        try std.testing.expectApproxEqAbs(a.estimated_study_seconds + b.estimated_study_seconds, total.estimated_study_seconds, 1e-12);
    }
}
