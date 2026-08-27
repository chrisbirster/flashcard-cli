const std = @import("std");
const HistoryEntry = @import("../history.zig").Entry;
const optimizer = @import("optimizer.zig");
const time = @import("../../time.zig");

// Reference: current srs-benchmark FSRS-7 default parameters give
// retrievability 0.9242342483541028 one day after an initial Good review.
// BCE for a recalled review is therefore -ln(R). With one scoreable sample,
// upstream --recency assigns x=0 and weight 0.25.
test "FSRS-7 training loss matches upstream one-day reference" {
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = time.milliseconds_per_day },
    };
    const histories = [_][]const HistoryEntry{&history};

    const standard = try optimizer.benchmarkTrainingLoss(
        std.testing.allocator,
        &histories,
        .{},
        false,
    );
    try std.testing.expectEqual(@as(usize, 1), standard.examples);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.07878972393534261),
        standard.log_loss,
        1e-12,
    );

    const recency = try optimizer.benchmarkTrainingLoss(
        std.testing.allocator,
        &histories,
        .{},
        true,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.019697430983835654),
        recency.log_loss,
        1e-12,
    );
}
