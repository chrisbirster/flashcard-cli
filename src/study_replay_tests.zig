const std = @import("std");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const Study = @import("study.zig").Study;
const time = @import("time.zig");

test "empty history rebuild clears derived scheduler state" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("empty", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);

    try std.testing.expect((try study.rebuildCardState(std.testing.allocator, card_id, 0)) == null);
    try std.testing.expect((try store.getSchedulerState(card_id)) == null);
}

test "long mixed history rebuild matches incrementally maintained state" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("long-history", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);

    const ratings = [_]fsrs.Rating{ .good, .hard, .easy, .again, .good, .good, .hard };
    var reviewed_at_ms: i64 = 0;
    for (0..120) |index| {
        if (index != 0) {
            // Every fifth review is same-day; the rest advance by one day.
            reviewed_at_ms += if (index % 5 == 0)
                2 * time.milliseconds_per_hour
            else
                time.milliseconds_per_day;
        }
        _ = try study.recordReview(
            std.testing.allocator,
            card_id,
            ratings[index % ratings.len],
            reviewed_at_ms,
        );
    }

    const before = (try store.getSchedulerState(card_id)) orelse return error.MissingSchedulerState;
    const history_before = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history_before);
    try std.testing.expectEqual(@as(usize, 120), history_before.len);

    try store.clearSchedulerState(card_id);
    const rebuilt = (try study.rebuildCardState(
        std.testing.allocator,
        card_id,
        reviewed_at_ms,
    )) orelse return error.MissingRebuiltState;

    try std.testing.expectApproxEqAbs(before.stability_days.?, rebuilt.stability_days.?, 1e-10);
    try std.testing.expectApproxEqAbs(before.difficulty.?, rebuilt.difficulty.?, 1e-10);
    try std.testing.expectEqual(before.due_at_ms, rebuilt.due_at_ms);
    try std.testing.expectEqual(before.last_reviewed_at_ms, rebuilt.last_reviewed_at_ms);

    const history_after = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history_after);
    try std.testing.expectEqual(history_before.len, history_after.len);
    for (history_before, history_after) |expected, actual| {
        try std.testing.expectEqual(expected.rating, actual.rating);
        try std.testing.expectEqual(expected.reviewed_at_ms, actual.reviewed_at_ms);
    }
}
