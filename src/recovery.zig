const std = @import("std");
const storage = @import("storage/root.zig");
const Study = @import("study.zig").Study;
const time = @import("time.zig");

pub const Report = struct {
    cards_checked: usize = 0,
    states_rebuilt: usize = 0,
    reviews_verified: usize = 0,
};

fn historiesEqual(a: []const @import("fsrs/root.zig").HistoryEntry, b: []const @import("fsrs/root.zig").HistoryEntry) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.rating != right.rating or left.reviewed_at_ms != right.reviewed_at_ms) return false;
    }
    return true;
}

/// Reconstruct disposable scheduler state from immutable review history and
/// verify that the repair did not mutate or discard any review events.
pub fn repairDeck(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    now_ms: time.TimestampMs,
) !Report {
    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }
    const study = Study.init(store);
    var report: Report = .{};

    for (cards) |card| {
        const before = try store.loadHistory(allocator, card.id);
        defer allocator.free(before);
        const rebuilt = try study.rebuildCardState(allocator, card.id, now_ms);
        const after = try store.loadHistory(allocator, card.id);
        defer allocator.free(after);
        if (!historiesEqual(before, after)) return error.ImmutableHistoryChanged;
        report.cards_checked += 1;
        report.reviews_verified += before.len;
        if (rebuilt != null) report.states_rebuilt += 1;
    }
    return report;
}

test "repair rebuilds derived state without changing immutable history" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("repair", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);
    const study = Study.init(&store);
    _ = try study.recordReview(std.testing.allocator, card_id, .good, 0);
    try store.clearSchedulerState(card_id);

    const report = try repairDeck(std.testing.allocator, &store, deck_id, time.milliseconds_per_day);
    try std.testing.expectEqual(@as(usize, 1), report.cards_checked);
    try std.testing.expectEqual(@as(usize, 1), report.states_rebuilt);
    try std.testing.expectEqual(@as(usize, 1), report.reviews_verified);
    try std.testing.expect((try store.getSchedulerState(card_id)) != null);
}
