const std = @import("std");
const Rating = @import("../rating.zig").Rating;
const model = @import("model.zig");
const Parameters = @import("parameters.zig").Parameters;

const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545f4914f6cdd1d;
    }

    fn unit(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }
};

fn ratingFromIndex(index: usize) Rating {
    return switch (index % 4) {
        0 => .again,
        1 => .hard,
        2 => .good,
        else => .easy,
    };
}

test "FSRS-7 randomized invariants remain finite and bounded" {
    const parameters: Parameters = .{};
    var rng: Rng = .{ .state = 0x4445455a7f5a1337 };

    for (0..2_000) |index| {
        const stability = 0.001 + rng.unit() * 10_000.0;
        const difficulty = 1.0 + rng.unit() * 9.0;
        const elapsed = rng.unit() * 5_000.0;
        const state: model.MemoryState = .{
            .stability_days = stability,
            .difficulty = difficulty,
        };

        const now_retrievability = try model.retrievability(elapsed, state, parameters);
        const later_retrievability = try model.retrievability(elapsed + 1.0, state, parameters);
        try std.testing.expect(std.math.isFinite(now_retrievability));
        try std.testing.expect(now_retrievability >= 0 and now_retrievability <= 1);
        try std.testing.expect(later_retrievability <= now_retrievability + 1e-12);

        const next = try model.nextMemoryState(state, elapsed, ratingFromIndex(index), parameters);
        try std.testing.expect(std.math.isFinite(next.stability_days));
        try std.testing.expect(std.math.isFinite(next.difficulty));
        try std.testing.expect(next.stability_days > 0);
        try std.testing.expect(next.difficulty >= 1 and next.difficulty <= 10);

        const interval = try model.intervalForRetention(next.stability_days, parameters.desired_retention, parameters);
        try std.testing.expect(std.math.isFinite(interval));
        try std.testing.expect(interval >= parameters.minimum_interval_days);
        try std.testing.expect(interval <= parameters.maximum_interval_days);
    }
}

test "invalid numerical scheduler inputs are rejected" {
    const parameters: Parameters = .{};
    const state: model.MemoryState = .{ .stability_days = 1, .difficulty = 5 };
    try std.testing.expectError(error.InvalidElapsedTime, model.retrievability(-1, state, parameters));
    try std.testing.expectError(
        error.InvalidStability,
        model.retrievability(1, .{ .stability_days = 0, .difficulty = 5 }, parameters),
    );
    try std.testing.expectError(error.InvalidDesiredRetention, model.intervalForRetention(1, 1.0, parameters));
}
