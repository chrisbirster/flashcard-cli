const std = @import("std");
const AlgorithmId = @import("algorithm.zig").AlgorithmId;
const Engine = @import("engine.zig").Engine;
const HistoryEntry = @import("history.zig").Entry;
const Comparison = @import("compare.zig").Comparison;
const compare = @import("compare.zig").compare;
const TimestampMs = @import("../time.zig").TimestampMs;

pub const Preview = struct {
    source_algorithm: AlgorithmId,
    target_algorithm: AlgorithmId,
    review_count: usize,
    comparison: Comparison,
};

pub fn preview(
    source_engine: Engine,
    target_engine: Engine,
    history: []const HistoryEntry,
    now_ms: TimestampMs,
) !Preview {
    return .{
        .source_algorithm = source_engine.algorithm(),
        .target_algorithm = target_engine.algorithm(),
        .review_count = history.len,
        .comparison = try compare(source_engine, target_engine, history, now_ms),
    };
}

pub fn requirePublishedTarget(target: AlgorithmId) !void {
    const registry = @import("registry.zig");
    _ = registry.lookup(target) orelse return error.UnsupportedAlgorithm;
}

test "unpublished FSRS-8 cannot be migrated into" {
    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        requirePublishedTarget(.{ .family = .fsrs, .major = 8 }),
    );
}

test "migration preview does not require state translation" {
    const source = Engine.defaultFsrs7();
    const target = Engine.defaultFsrs7();
    const result = try preview(source, target, &.{}, 0);
    try std.testing.expectEqual(@as(usize, 0), result.review_count);
    try std.testing.expect(result.source_algorithm.eql(.fsrs7));
}
