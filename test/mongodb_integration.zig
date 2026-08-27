const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";
const standalone_uri = "mongodb://admin:secretpassword@localhost:27017/deez_standalone?authSource=admin";

fn connectStore(uri: []const u8) !deez.storage.Store {
    const mongo = try deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        uri,
    );
    return .{ .mongodb = mongo };
}

fn expectConnectFailure(uri: []const u8) !void {
    if (deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        uri,
    )) |mongo| {
        var unexpected = mongo;
        unexpected.deinit();
        return error.ExpectedMongoConnectFailure;
    } else |_| {}
}

fn containsCard(cards: []const deez.storage.OwnedDueCard, card_id: u64) bool {
    for (cards) |card| {
        if (card.id == card_id) return true;
    }
    return false;
}

test "MongoStore supports Deez transaction workflow and reconnect" {
    const allocator = std.testing.allocator;

    var deck_id: u64 = undefined;
    var card_id: u64 = undefined;
    var second_card_id: u64 = undefined;
    var due_at_ms: i64 = undefined;
    var expected_stability: f64 = undefined;

    {
        var store = try connectStore(replica_uri);
        defer store.deinit();

        try std.testing.expect(store.mongodb.client.supports_sessions);
        try std.testing.expect(store.mongodb.client.supports_transactions);

        deck_id = try store.createDeck("mongo-integration", 0);
        _ = try store.ensureDefaultFsrs7(0);
        card_id = try store.createCard(
            deck_id,
            "What is BSON?",
            "Binary JSON",
            0,
        );
        second_card_id = try store.createCard(
            deck_id,
            "What is Zig?",
            "A systems programming language",
            1,
        );

        const loaded_deck = (try store.getDeck(allocator, deck_id)) orelse
            return error.MissingDeck;
        defer loaded_deck.deinit(allocator);
        try std.testing.expectEqualStrings("mongo-integration", loaded_deck.name);

        const loaded_card = (try store.getCard(allocator, card_id)) orelse
            return error.MissingCard;
        defer loaded_card.deinit(allocator);
        try std.testing.expectEqual(deck_id, loaded_card.deck_id);
        try std.testing.expectEqualStrings("What is BSON?", loaded_card.question);

        const listed_cards = try store.cards(allocator, deck_id);
        defer {
            for (listed_cards) |card| card.deinit(allocator);
            allocator.free(listed_cards);
        }
        try std.testing.expectEqual(@as(usize, 2), listed_cards.len);
        try std.testing.expectEqual(card_id, listed_cards[0].id);
        try std.testing.expectEqual(second_card_id, listed_cards[1].id);
        try std.testing.expectEqualStrings("What is BSON?", listed_cards[0].question);
        try std.testing.expectEqualStrings("What is Zig?", listed_cards[1].question);

        const initially_due = try store.dueCards(allocator, deck_id, 1, 10);
        defer {
            for (initially_due) |card| card.deinit(allocator);
            allocator.free(initially_due);
        }
        try std.testing.expectEqual(@as(usize, 2), initially_due.len);
        try std.testing.expect(containsCard(initially_due, card_id));
        try std.testing.expect(containsCard(initially_due, second_card_id));

        const study = deez.Study.init(&store);
        const result = try study.recordReview(
            allocator,
            card_id,
            .good,
            deez.time.milliseconds_per_day,
        );
        due_at_ms = result.state.due_at_ms;
        expected_stability = result.state.stability_days.?;

        const history = try store.loadHistory(allocator, card_id);
        defer allocator.free(history);
        try std.testing.expectEqual(@as(usize, 1), history.len);
        try std.testing.expectEqual(deez.fsrs.Rating.good, history[0].rating);

        const state = (try store.getSchedulerState(card_id)) orelse
            return error.MissingSchedulerState;
        try std.testing.expectEqual(result.state.due_at_ms, state.due_at_ms);
        try std.testing.expectApproxEqAbs(
            result.state.stability_days.?,
            state.stability_days.?,
            1e-12,
        );

        const due = try store.dueCards(allocator, deck_id, due_at_ms, 10);
        defer {
            for (due) |card| card.deinit(allocator);
            allocator.free(due);
        }
        try std.testing.expect(containsCard(due, card_id));

        const stats = try store.stats(due_at_ms, deck_id);
        try std.testing.expectEqual(@as(usize, 2), stats.card_count);
        try std.testing.expectEqual(@as(usize, 1), stats.review_count);
        try std.testing.expectEqual(@as(usize, 2), stats.due_count);
    }

    {
        var store = try connectStore(replica_uri);
        defer store.deinit();
        defer store.deleteDeck(deck_id) catch {};

        const loaded_deck = (try store.getDeck(allocator, deck_id)) orelse
            return error.MissingDeckAfterReconnect;
        defer loaded_deck.deinit(allocator);
        try std.testing.expectEqualStrings("mongo-integration", loaded_deck.name);

        const loaded_card = (try store.getCard(allocator, card_id)) orelse
            return error.MissingCardAfterReconnect;
        defer loaded_card.deinit(allocator);
        try std.testing.expectEqualStrings("Binary JSON", loaded_card.answer);

        const listed_cards = try store.cards(allocator, deck_id);
        defer {
            for (listed_cards) |card| card.deinit(allocator);
            allocator.free(listed_cards);
        }
        try std.testing.expectEqual(@as(usize, 2), listed_cards.len);
        try std.testing.expectEqual(card_id, listed_cards[0].id);
        try std.testing.expectEqual(second_card_id, listed_cards[1].id);

        const history = try store.loadHistory(allocator, card_id);
        defer allocator.free(history);
        try std.testing.expectEqual(@as(usize, 1), history.len);
        try std.testing.expectEqual(deez.fsrs.Rating.good, history[0].rating);

        const state = (try store.getSchedulerState(card_id)) orelse
            return error.MissingStateAfterReconnect;
        try std.testing.expectEqual(due_at_ms, state.due_at_ms);
        try std.testing.expectApproxEqAbs(
            expected_stability,
            state.stability_days.?,
            1e-12,
        );
    }
}

test "MongoStore standalone fallback preserves review history and derived state" {
    const allocator = std.testing.allocator;
    var store = try connectStore(standalone_uri);
    defer store.deinit();

    try std.testing.expect(!store.mongodb.client.supports_transactions);

    const deck_id = try store.createDeck("mongo-standalone", 0);
    defer store.deleteDeck(deck_id) catch {};
    _ = try store.ensureDefaultFsrs7(0);
    const card_id = try store.createCard(deck_id, "Fallback?", "Review first", 0);

    const study = deez.Study.init(&store);
    const result = try study.recordReview(
        allocator,
        card_id,
        .hard,
        deez.time.milliseconds_per_day,
    );

    const history = try store.loadHistory(allocator, card_id);
    defer allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(deez.fsrs.Rating.hard, history[0].rating);

    const stored = (try store.getSchedulerState(card_id)) orelse
        return error.MissingStandaloneSchedulerState;
    try std.testing.expectEqual(result.state.due_at_ms, stored.due_at_ms);

    try store.clearSchedulerState(card_id);
    try std.testing.expect((try store.getSchedulerState(card_id)) == null);
    const rebuilt = (try study.rebuildCardState(
        allocator,
        card_id,
        deez.time.milliseconds_per_day,
    )) orelse return error.MissingRebuiltStandaloneState;
    try std.testing.expectApproxEqAbs(
        result.state.stability_days.?,
        rebuilt.stability_days.?,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        result.state.difficulty.?,
        rebuilt.difficulty.?,
        1e-12,
    );
}

test "MongoStore propagates startup authentication and TLS failures" {
    try expectConnectFailure("mongodb://localhost:27099/deez_unreachable");
    try expectConnectFailure(
        "mongodb://admin:wrong-password@localhost:27017/deez_auth_failure?authSource=admin",
    );
    try expectConnectFailure(
        "mongodb://admin:secretpassword@localhost:27018/deez_tls_failure?authSource=admin&tls=true",
    );
}

test "storage.Store propagates a rejected MongoDB write" {
    const allocator = std.testing.allocator;
    var store = try connectStore(replica_uri);
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-write-error", 0);
    defer store.deleteDeck(deck_id) catch {};

    const oversized_question = try allocator.alloc(u8, 17 * 1024 * 1024);
    defer allocator.free(oversized_question);
    @memset(oversized_question, 'x');

    if (store.createCard(deck_id, oversized_question, "answer", 0)) |card_id| {
        store.deleteCard(card_id) catch {};
        return error.ExpectedMongoWriteFailure;
    } else |_| {}

    const stats = try store.stats(0, deck_id);
    try std.testing.expectEqual(@as(usize, 0), stats.card_count);
}

test "MongoStore study session enforces new limit and relearning due time" {
    const allocator = std.testing.allocator;
    var store = try connectStore(replica_uri);
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-session-policy", 0);
    defer store.deleteDeck(deck_id) catch {};
    _ = try store.ensureDefaultFsrs7(0);
    const first_id = try store.createCard(deck_id, "first", "1", 0);
    _ = try store.createCard(deck_id, "second", "2", 0);

    const study = deez.Study.init(&store);
    var session = deez.study.Session.init(study, deck_id, .{
        .new_limit = 1,
        .review_order = .new_first,
    });

    const first = (try session.next(allocator, 0)).?;
    try std.testing.expectEqual(first_id, first.id);
    first.deinit(allocator);

    const learned = try study.recordReview(allocator, first_id, .good, 0);
    try std.testing.expect((try session.next(allocator, 0)) == null);

    var review_session = deez.study.Session.init(study, deck_id, .{
        .new_limit = 0,
        .review_order = .reviews_first,
    });
    const due_review = (try review_session.next(allocator, learned.candidate.due_at_ms)).?;
    try std.testing.expectEqual(first_id, due_review.id);
    due_review.deinit(allocator);

    const lapse = try study.recordReview(
        allocator,
        first_id,
        .again,
        learned.candidate.due_at_ms,
    );
    if (lapse.candidate.due_at_ms > learned.candidate.due_at_ms) {
        try std.testing.expect(
            (try review_session.next(allocator, lapse.candidate.due_at_ms - 1)) == null,
        );
    }

    const relearning = (try review_session.next(allocator, lapse.candidate.due_at_ms)).?;
    try std.testing.expectEqual(first_id, relearning.id);
    relearning.deinit(allocator);
}
