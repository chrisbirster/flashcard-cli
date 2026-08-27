const std = @import("std");
const builtin = @import("builtin");
const AlgorithmId = @import("algorithm.zig").AlgorithmId;
const HistoryEntry = @import("history.zig").Entry;
const schedule_mod = @import("schedule.zig");
const Schedule = schedule_mod.Schedule;
const TimestampMs = @import("../time.zig").TimestampMs;
const time = @import("../time.zig");
const v7 = @import("v7/root.zig");

pub const fixture_algorithm: AlgorithmId = .{ .family = .fsrs, .major = 65535 };

const FixtureEngine = struct {
    fn schedule(_: FixtureEngine, _: []const HistoryEntry, now_ms: TimestampMs) !Schedule {
        return .{
            .again = candidate(.again, now_ms, 1),
            .hard = candidate(.hard, now_ms, 2),
            .good = candidate(.good, now_ms, 4),
            .easy = candidate(.easy, now_ms, 8),
        };
    }

    fn candidate(rating: @import("rating.zig").Rating, now_ms: TimestampMs, days: f64) schedule_mod.Candidate {
        return .{
            .rating = rating,
            .interval_days = days,
            .due_at_ms = now_ms + time.daysToMilliseconds(days),
        };
    }
};

pub const Engine = union(enum) {
    fsrs7: v7.Engine,
    fixture: FixtureEngine,

    pub fn defaultFsrs7() Engine {
        return .{ .fsrs7 = .{} };
    }

    pub fn fsrs7With(parameters: v7.Parameters) !Engine {
        return .{ .fsrs7 = try v7.Engine.init(parameters) };
    }

    pub fn fixtureForTesting() !Engine {
        if (!builtin.is_test) return error.UnsupportedAlgorithm;
        return .{ .fixture = .{} };
    }

    pub fn forAlgorithm(algorithm_id: AlgorithmId) !Engine {
        if (algorithm_id.eql(.fsrs7)) return defaultFsrs7();
        if (builtin.is_test and algorithm_id.eql(fixture_algorithm)) return fixtureForTesting();
        return error.UnsupportedAlgorithm;
    }

    pub fn algorithm(self: Engine) AlgorithmId {
        return switch (self) {
            .fsrs7 => .fsrs7,
            .fixture => fixture_algorithm,
        };
    }

    pub fn schedule(self: Engine, history: []const HistoryEntry, now_ms: TimestampMs) !Schedule {
        return switch (self) {
            .fsrs7 => |engine| engine.schedule(history, now_ms),
            .fixture => |engine| engine.schedule(history, now_ms),
        };
    }
};

test "engine dispatch is versioned" {
    const engine = try Engine.forAlgorithm(.fsrs7);
    try std.testing.expect(engine.algorithm().eql(.fsrs7));
    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        Engine.forAlgorithm(.{ .family = .fsrs, .major = 8 }),
    );
}

test "test fixture proves two scheduler majors dispatch independently" {
    const source = try Engine.forAlgorithm(.fsrs7);
    const fixture = try Engine.forAlgorithm(fixture_algorithm);
    try std.testing.expect(source.algorithm().eql(.fsrs7));
    try std.testing.expect(fixture.algorithm().eql(fixture_algorithm));
    const fixture_schedule = try fixture.schedule(&.{}, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 4), fixture_schedule.good.interval_days, 1e-12);
    const fsrs_schedule = try source.schedule(&.{}, 0);
    try std.testing.expect(@abs(fsrs_schedule.good.interval_days - fixture_schedule.good.interval_days) > 1e-6);
}

test "engine accepts versioned custom parameters" {
    var parameters: v7.Parameters = .{};
    parameters.desired_retention = 0.95;
    const engine = try Engine.fsrs7With(parameters);
    const schedule = try engine.schedule(&.{}, 0);
    const default_schedule = try Engine.defaultFsrs7().schedule(&.{}, 0);
    try std.testing.expect(schedule.good.interval_days < default_schedule.good.interval_days);
}

test "engine returns version-independent schedule results" {
    const engine = Engine.defaultFsrs7();
    const schedule = try engine.schedule(&.{}, 0);
    try std.testing.expect(schedule.good.interval_days > 0);
}
