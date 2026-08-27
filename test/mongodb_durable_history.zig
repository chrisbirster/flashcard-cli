const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";

fn connectStore() !deez.storage.Store {
    const mongo = try deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        replica_uri,
    );
    return .{ .mongodb = mongo };
}

test "MongoStore rejects invalid review targets without appending orphan history" {
    var store = try connectStore();
    defer store.deinit();

    const parameter_set_id = try store.ensureDefaultFsrs7(0);
    const missing_card_id: deez.CardId = 9_223_372_036;
    const state: deez.storage.SchedulerState = .{
        .card_id = missing_card_id,
        .stamp = .{
            .algorithm = .fsrs7,
            .implementation = .current,
            .parameter_set_id = parameter_set_id,
        },
        .stability_days = 1.0,
        .difficulty = 5.0,
        .due_at_ms = 1_000,
        .last_reviewed_at_ms = 0,
    };

    try std.testing.expectError(
        error.CardNotFound,
        store.recordReviewAndState(
            missing_card_id,
            .good,
            0,
            state,
            1_000,
        ),
    );

    const history = try store.loadHistory(std.testing.allocator, missing_card_id);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 0), history.len);
}

test "MongoStore rejects scheduler state for a different card" {
    var store = try connectStore();
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-state-card-match", 0);
    defer store.deleteDeck(deck_id) catch {};
    const first = try store.createCard(deck_id, "first", "1", 0);
    const second = try store.createCard(deck_id, "second", "2", 0);
    const parameter_set_id = try store.ensureDefaultFsrs7(0);

    const wrong_state: deez.storage.SchedulerState = .{
        .card_id = second,
        .stamp = .{
            .algorithm = .fsrs7,
            .implementation = .current,
            .parameter_set_id = parameter_set_id,
        },
        .stability_days = 1.0,
        .difficulty = 5.0,
        .due_at_ms = 1_000,
        .last_reviewed_at_ms = 0,
    };

    try std.testing.expectError(
        error.InvalidSchedulerState,
        store.recordReviewAndState(first, .good, 0, wrong_state, 1_000),
    );

    const history = try store.loadHistory(std.testing.allocator, first);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 0), history.len);
}

test "Store deletion cannot discard Mongo immutable review history" {
    const allocator = std.testing.allocator;
    var store = try connectStore();
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-immutable-delete", 0);
    const reviewed_card = try store.createCard(deck_id, "reviewed", "keep", 0);
    const untouched_card = try store.createCard(deck_id, "untouched", "keep", 1);

    // Cleanup intentionally bypasses the Deez Store deletion invariant. This is
    // integration-fixture teardown only; production callers use Store.
    defer {
        const db = store.mongodb.client.databaseName();
        _ = store.mongodb.client.deleteOne(db, "reviews", .{ .card_id = @as(i64, @intCast(reviewed_card)) }) catch {};
        _ = store.mongodb.client.deleteOne(db, "cards", .{ ._id = @as(i64, @intCast(reviewed_card)) }) catch {};
        _ = store.mongodb.client.deleteOne(db, "cards", .{ ._id = @as(i64, @intCast(untouched_card)) }) catch {};
        _ = store.mongodb.client.deleteOne(db, "decks", .{ ._id = @as(i64, @intCast(deck_id)) }) catch {};
    }

    _ = try store.ensureDefaultFsrs7(0);
    const study = deez.Study.init(&store);
    _ = try study.recordReview(allocator, reviewed_card, .good, 0);

    try std.testing.expectError(error.ReviewHistoryExists, store.deleteCard(reviewed_card));
    const history = try store.loadHistory(allocator, reviewed_card);
    defer allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);

    try std.testing.expectError(error.ReviewHistoryExists, store.deleteDeck(deck_id));
    const reviewed_after = (try store.getCard(allocator, reviewed_card)) orelse return error.ReviewedCardWasDeleted;
    reviewed_after.deinit(allocator);
    const untouched_after = (try store.getCard(allocator, untouched_card)) orelse return error.DeckDeleteWasPartial;
    untouched_after.deinit(allocator);
}
