const std = @import("std");
const fsrs = @import("fsrs/root.zig");
const interchange_import = @import("interchange_import.zig");
const time = @import("time.zig");

fn fuzzScheduler(_: void, smith: *std.testing.Smith) !void {
    const raw_stability = smith.value(u32);
    const raw_difficulty = smith.value(u32);
    const raw_elapsed = smith.value(u32);
    const stability = 0.001 + @as(f64, @floatFromInt(raw_stability % 10_000_000)) / 1_000.0;
    const difficulty = 1.0 + @as(f64, @floatFromInt(raw_difficulty % 9_000_001)) / 1_000_000.0;
    const elapsed = @as(f64, @floatFromInt(raw_elapsed % 5_000_000)) / 1_000.0;
    const state: fsrs.v7.model.MemoryState = .{
        .stability_days = stability,
        .difficulty = @min(difficulty, 10.0),
    };
    const parameters: fsrs.v7.Parameters = .{};

    const retrievability = try fsrs.v7.model.retrievability(elapsed, state, parameters);
    try std.testing.expect(std.math.isFinite(retrievability));
    try std.testing.expect(retrievability >= 0 and retrievability <= 1);

    const rating = try fsrs.Rating.fromValue(@as(u8, @intCast(smith.value(u8) % 4 + 1)));
    const next = try fsrs.v7.model.nextMemoryState(state, elapsed, rating, parameters);
    try std.testing.expect(std.math.isFinite(next.stability_days));
    try std.testing.expect(std.math.isFinite(next.difficulty));
    try std.testing.expect(next.stability_days > 0);
    try std.testing.expect(next.difficulty >= 1 and next.difficulty <= 10);
    const interval = try fsrs.v7.model.intervalForRetention(next.stability_days, parameters.desired_retention, parameters);
    try std.testing.expect(std.math.isFinite(interval));
    try std.testing.expect(interval > 0);
}

fn fuzzReplay(_: void, smith: *std.testing.Smith) !void {
    var history: [64]fsrs.HistoryEntry = undefined;
    var len: usize = 0;
    var timestamp: i64 = 0;
    while (len < history.len and !smith.eos()) {
        const rating = try fsrs.Rating.fromValue(@as(u8, @intCast(smith.value(u8) % 4 + 1)));
        const increment: i64 = @intCast(smith.value(u32) % @as(u32, @intCast(7 * time.milliseconds_per_day)));
        timestamp += increment;
        history[len] = .{ .rating = rating, .reviewed_at_ms = timestamp };
        len += 1;
    }
    const engine: fsrs.v7.Engine = .{};
    const replayed = try engine.replay(history[0..len]);
    if (replayed) |state| {
        try std.testing.expect(state.memory.stability_days > 0);
        try std.testing.expect(state.memory.difficulty >= 1 and state.memory.difficulty <= 10);
        const schedule = try engine.schedule(history[0..len], timestamp);
        try std.testing.expect(schedule.again.interval_days > 0);
        try std.testing.expect(schedule.easy.interval_days > 0);
    }
}

fn fuzzInterchange(_: void, smith: *std.testing.Smith) !void {
    var bytes: [512]u8 = undefined;
    var len: usize = 0;
    while (len < bytes.len and !smith.eos()) {
        bytes[len] = smith.value(u8);
        len += 1;
    }
    interchange_import.validateArchive(bytes[0..len]) catch {};
}

test "fuzz FSRS numeric invariants" {
    try std.testing.fuzz({}, fuzzScheduler, .{});
}

test "fuzz chronological FSRS replay" {
    try std.testing.fuzz({}, fuzzReplay, .{});
}

test "fuzz Deez interchange parser" {
    try std.testing.fuzz({}, fuzzInterchange, .{});
}
