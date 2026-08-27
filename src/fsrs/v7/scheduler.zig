const std = @import("std");
const Rating = @import("../rating.zig").Rating;
const HistoryEntry = @import("../history.zig").Entry;
const schedule_types = @import("../schedule.zig");
const time = @import("../../time.zig");
const model = @import("model.zig");
const Parameters = @import("parameters.zig").Parameters;

pub const ReplayState = struct {
    memory: model.MemoryState,
    last_reviewed_at_ms: time.TimestampMs,
};

pub const Engine = struct {
    parameters: Parameters = .{},

    pub fn init(parameters: Parameters) !Engine {
        try parameters.validate();
        return .{ .parameters = parameters };
    }

    pub fn replay(self: Engine, history: []const HistoryEntry) !?ReplayState {
        try self.parameters.validate();
        if (history.len == 0) return null;

        var state = model.initialMemoryState(history[0].rating, self.parameters);
        var previous_time = history[0].reviewed_at_ms;

        for (history[1..]) |entry| {
            if (entry.reviewed_at_ms < previous_time) return error.NonMonotonicHistory;
            const elapsed_ms = entry.reviewed_at_ms - previous_time;
            const elapsed_days = time.millisecondsToDays(elapsed_ms);
            state = try model.nextMemoryState(state, elapsed_days, entry.rating, self.parameters);
            previous_time = entry.reviewed_at_ms;
        }

        return .{ .memory = state, .last_reviewed_at_ms = previous_time };
    }

    fn dueTimestamp(now_ms: time.TimestampMs, interval_days: f64) !time.TimestampMs {
        const delta = time.daysToMilliseconds(interval_days);
        if (delta > 0 and now_ms > std.math.maxInt(i64) - delta) return error.TimestampOverflow;
        return now_ms + delta;
    }

    fn candidate(
        self: Engine,
        replayed: ?ReplayState,
        now_ms: time.TimestampMs,
        rating: Rating,
    ) !schedule_types.Candidate {
        const next_state = if (replayed) |current| blk: {
            if (now_ms < current.last_reviewed_at_ms) return error.NowBeforeLastReview;
            const elapsed_days = time.millisecondsToDays(now_ms - current.last_reviewed_at_ms);
            break :blk try model.nextMemoryState(current.memory, elapsed_days, rating, self.parameters);
        } else model.initialMemoryState(rating, self.parameters);

        const interval_days = try model.intervalForRetention(
            next_state.stability_days,
            self.parameters.desired_retention,
            self.parameters,
        );

        return .{
            .rating = rating,
            .due_at_ms = try dueTimestamp(now_ms, interval_days),
            .interval_days = interval_days,
        };
    }

    pub fn schedule(
        self: Engine,
        history: []const HistoryEntry,
        now_ms: time.TimestampMs,
    ) !schedule_types.Schedule {
        const replayed = try self.replay(history);
        return .{
            .again = try self.candidate(replayed, now_ms, .again),
            .hard = try self.candidate(replayed, now_ms, .hard),
            .good = try self.candidate(replayed, now_ms, .good),
            .easy = try self.candidate(replayed, now_ms, .easy),
        };
    }
};

test "new card returns four FSRS-7 candidates" {
    const engine: Engine = .{};
    const scheduled = try engine.schedule(&.{}, 0);
    try std.testing.expectEqual(Rating.again, scheduled.again.rating);
    try std.testing.expectEqual(Rating.easy, scheduled.easy.rating);
    try std.testing.expect(scheduled.good.interval_days > scheduled.hard.interval_days);
    try std.testing.expect(scheduled.easy.interval_days > scheduled.good.interval_days);
}

test "history replay preserves same-day reviews and lapses" {
    const engine: Engine = .{};
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 2 * day },
        .{ .rating = .hard, .reviewed_at_ms = 2 * day + 6 * time.milliseconds_per_hour },
        .{ .rating = .again, .reviewed_at_ms = 12 * day + 6 * time.milliseconds_per_hour },
    };

    const replayed = (try engine.replay(&history)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2.1442345281745427), replayed.memory.stability_days, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 8.908253780993332), replayed.memory.difficulty, 1e-10);
}

test "scheduler rejects non-monotonic history" {
    const engine: Engine = .{};
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 10 },
        .{ .rating = .good, .reviewed_at_ms = 9 },
    };
    try std.testing.expectError(error.NonMonotonicHistory, engine.replay(&history));
}
