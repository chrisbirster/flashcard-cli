const std = @import("std");
const scheduler = @import("scheduler.zig");
const HistoryEntry = @import("../history.zig").Entry;
const time = @import("../../time.zig");

const tolerance = 1e-10;

fn expectClose(expected: f64, actual: f64) !void {
    try std.testing.expectApproxEqAbs(expected, actual, tolerance);
}

test "upstream-derived new-card scheduling intervals cover four ratings" {
    const scheduled = try (scheduler.Engine{}).schedule(&.{}, 0);
    try expectClose(0.000024841463049591768, scheduled.again.interval_days);
    try expectClose(0.874447994323948, scheduled.hard.interval_days);
    try expectClose(2.966927162372145, scheduled.good.interval_days);
    try expectClose(16.936615525786898, scheduled.easy.interval_days);
}

test "upstream-derived review scheduling covers lapse and remembered paths" {
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .hard, .reviewed_at_ms = day / 4 },
        .{ .rating = .good, .reviewed_at_ms = day / 4 + 2 * day },
        .{ .rating = .again, .reviewed_at_ms = day / 4 + 9 * day },
        .{ .rating = .easy, .reviewed_at_ms = day / 4 + 9 * day + day / 10 },
    };
    const now = history[history.len - 1].reviewed_at_ms + day;
    const scheduled = try (scheduler.Engine{}).schedule(&history, now);
    try expectClose(0.005620196041399007, scheduled.again.interval_days);
    try expectClose(2.628243829660618, scheduled.hard.interval_days);
    try expectClose(3.4798740617946793, scheduled.good.interval_days);
    try expectClose(4.269782379990243, scheduled.easy.interval_days);
    try std.testing.expect(scheduled.again.interval_days < scheduled.hard.interval_days);
    try std.testing.expect(scheduled.hard.interval_days < scheduled.good.interval_days);
    try std.testing.expect(scheduled.good.interval_days < scheduled.easy.interval_days);
}
