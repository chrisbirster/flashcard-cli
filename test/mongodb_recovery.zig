const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_recovery?replicaSet=rs0";

fn connectStore() !deez.storage.Store {
    const mongo = try deez.storage.MongoStore.connect(std.testing.io, std.testing.allocator, replica_uri);
    return .{ .mongodb = mongo };
}

test "Mongo recovery rebuilds derived state without discarding immutable reviews" {
    const allocator = std.testing.allocator;
    var store = try connectStore();
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-recovery", 0);
    defer store.deleteDeck(deck_id) catch {};
    const card_id = try store.createCard(deck_id, "recover?", "from history", 0);
    const study = deez.Study.init(&store);
    _ = try study.recordReview(allocator, card_id, .good, 0);
    _ = try study.recordReview(allocator, card_id, .hard, 2 * deez.time.milliseconds_per_day);

    const before = try store.loadHistory(allocator, card_id);
    defer allocator.free(before);
    try store.clearSchedulerState(card_id);
    try std.testing.expect((try store.getSchedulerState(card_id)) == null);

    const report = try deez.recovery.repairDeck(allocator, &store, deck_id, 3 * deez.time.milliseconds_per_day);
    try std.testing.expectEqual(@as(usize, 1), report.cards_checked);
    try std.testing.expectEqual(@as(usize, 1), report.states_rebuilt);
    try std.testing.expectEqual(@as(usize, 2), report.reviews_verified);
    try std.testing.expect((try store.getSchedulerState(card_id)) != null);

    const after = try store.loadHistory(allocator, card_id);
    defer allocator.free(after);
    try std.testing.expectEqual(before.len, after.len);
    for (before, after) |left, right| {
        try std.testing.expectEqual(left.rating, right.rating);
        try std.testing.expectEqual(left.reviewed_at_ms, right.reviewed_at_ms);
    }
}
