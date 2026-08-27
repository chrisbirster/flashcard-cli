const std = @import("std");
const model = @import("model.zig");
const parameters_mod = @import("parameters.zig");
const scheduler = @import("scheduler.zig");
const Rating = @import("../rating.zig").Rating;
const HistoryEntry = @import("../history.zig").Entry;
const time = @import("../../time.zig");

/// Authoritative fixture source:
/// open-spaced-repetition/srs-benchmark
/// commit 1053082bd2d6dbedbbd9674c4c9683c203f6818a
/// models/fsrs_v7.py
///
/// Expected values were evaluated from the upstream FSRS7 equations using the
/// default 35-parameter vector at that commit. Keep this commit pinned when
/// changing fixtures so an upstream change cannot silently redefine Deez's
/// FSRS-7 behavior.
const tolerance = 1e-10;

fn expectClose(expected: f64, actual: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "upstream FSRS-7 default parameter vector remains pinned" {
    const expected = [_]f64{
        0.041,  2.4175, 4.1283, 11.9709,
        5.6385, 0.4468, 3.262,  2.3054,
        0.1688, 1.3325, 0.3524, 0.0049,
        0.7503, 0.0896, 0.6625, 1.3,
        0.882,  0.3072, 3.5875, 0.303,
        0.0107, 0.2279, 2.6413, 0.5594,
        1.3,    2.5,    1.0,    0.0723,
        0.1634, 0.5,    0.9555, 0.2245,
        0.6232, 0.1362, 0.3862,
    };
    const parameters: parameters_mod.Parameters = .{};
    try std.testing.expectEqualSlices(f64, &expected, &parameters.weights);
}

test "upstream FSRS-7 initial states cover all ratings" {
    const parameters: parameters_mod.Parameters = .{};
    const ratings = [_]Rating{ .again, .hard, .good, .easy };
    const stability = [_]f64{ 0.041, 2.4175, 4.1283, 11.9709 };
    const difficulty = [_]f64{ 5.6385, 5.075198392303237, 4.194588083372719, 2.817928571667297 };
    for (ratings, stability, difficulty) |rating, expected_s, expected_d| {
        const state = model.initialMemoryState(rating, parameters);
        try expectClose(expected_s, state.stability_days);
        try expectClose(expected_d, state.difficulty);
    }
}

test "upstream FSRS-7 forgetting curve covers same-day and long intervals" {
    const parameters: parameters_mod.Parameters = .{};
    const state = model.initialMemoryState(.good, parameters);
    const elapsed = [_]f64{ 0.0, 1.0 / 144.0, 0.25, 1.0, 2.0, 10.0 };
    const expected = [_]f64{ 1.0, 0.9693189917294772, 0.9404929608601553, 0.9242342483541028, 0.9107175041978118, 0.8455626424668119 };
    for (elapsed, expected) |days, value| try expectClose(value, try model.retrievability(days, state, parameters));
}

test "upstream FSRS-7 same-day transitions cover Again Hard Good Easy" {
    const parameters: parameters_mod.Parameters = .{};
    const state = model.initialMemoryState(.good, parameters);
    const ratings = [_]Rating{ .again, .hard, .good, .easy };
    const expected_s = [_]f64{ 0.15811635416498357, 4.778504242699423, 5.284074098785149, 5.630806328420692 };
    const expected_d = [_]f64{ 8.347017296104067, 6.263919392179866, 4.180821488255665, 2.097723584331464 };
    for (ratings, expected_s, expected_d) |rating, stability, difficulty| {
        const next = try model.nextMemoryState(state, 1.0 / 144.0, rating, parameters);
        try expectClose(stability, next.stability_days);
        try expectClose(difficulty, next.difficulty);
    }
}

test "upstream FSRS-7 normal transitions cover Again Hard Good Easy" {
    const parameters: parameters_mod.Parameters = .{};
    const state = model.initialMemoryState(.good, parameters);
    const ratings = [_]Rating{ .again, .hard, .good, .easy };
    const expected_s = [_]f64{ 0.8453640589005196, 8.255985782255209, 10.362647327728341, 12.232951526046847 };
    const expected_d = [_]f64{ 8.347017296104067, 6.263919392179866, 4.180821488255665, 2.097723584331464 };
    for (ratings, expected_s, expected_d) |rating, stability, difficulty| {
        const next = try model.nextMemoryState(state, 2.0, rating, parameters);
        try expectClose(stability, next.stability_days);
        try expectClose(difficulty, next.difficulty);
    }
}

test "upstream FSRS-7 replay matches mixed same-day success and lapse history" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .hard, .reviewed_at_ms = day / 4 },
        .{ .rating = .good, .reviewed_at_ms = day / 4 + 2 * day },
        .{ .rating = .again, .reviewed_at_ms = day / 4 + 9 * day },
        .{ .rating = .easy, .reviewed_at_ms = day / 4 + 9 * day + day / 10 },
    };
    const replayed = (try (scheduler.Engine{}).replay(&history)).?;
    try expectClose(2.738262934528915, replayed.memory.stability_days);
    try expectClose(8.446142904111408, replayed.memory.difficulty);
}
