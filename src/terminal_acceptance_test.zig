const std = @import("std");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const study_mod = @import("study.zig");
const time = @import("time.zig");

test "completed review survives an interrupted study session" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();

    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("interrupt", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);

    {
        const study = study_mod.Study.init(&store);
        _ = try study.recordReview(std.testing.allocator, card_id, .good, 0);
    }

    const history = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(fsrs.Rating.good, history[0].rating);
    try std.testing.expect((try store.getSchedulerState(card_id)) != null);

    const resumed = study_mod.Study.init(&store);
    const preview = try resumed.preview(std.testing.allocator, card_id, time.milliseconds_per_day);
    try std.testing.expect(preview.algorithm.eql(.fsrs7));
}

test "study preview respects a deck-pinned FSRS-7 parameter set" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();

    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("pinned", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);

    var parameters: fsrs.v7.Parameters = .{};
    parameters.desired_retention = 0.95;
    const parameter_set_id = try store.putFsrs7Parameters(parameters, "test-pinned", 0);
    try store.setDeckFsrs7(deck_id, parameter_set_id);

    const study = study_mod.Study.init(&store);
    const preview = try study.preview(std.testing.allocator, card_id, 0);
    try std.testing.expect(preview.algorithm.eql(.fsrs7));
    try std.testing.expect(std.mem.eql(u8, preview.parameter_set_id[0..], parameter_set_id[0..]));

    const default_schedule = try fsrs.v7.Engine.init(.{});
    const default_preview = try default_schedule.schedule(&.{}, 0);
    try std.testing.expect(preview.schedule.good.interval_days < default_preview.good.interval_days);
}

test "card listing includes new and scheduled cards deterministically" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();

    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("cards", 0);
    const first = try store.createCard(deck_id, "first", "a", 0);
    const second = try store.createCard(deck_id, "second", "b", 1);

    const study = study_mod.Study.init(&store);
    _ = try study.recordReview(std.testing.allocator, first, .easy, 0);

    const cards = try store.cards(std.testing.allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(std.testing.allocator);
        std.testing.allocator.free(cards);
    }

    try std.testing.expectEqual(@as(usize, 2), cards.len);
    try std.testing.expectEqual(first, cards[0].id);
    try std.testing.expectEqual(second, cards[1].id);
    try std.testing.expectEqualStrings("first", cards[0].question);
    try std.testing.expectEqualStrings("second", cards[1].question);
}

test "stats and scheduler inspection data cover empty and populated stores" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();

    var store: storage.Store = .{ .sqlite = &db };
    const empty = try store.stats(0, null);
    try std.testing.expectEqual(@as(usize, 0), empty.deck_count);
    try std.testing.expectEqual(@as(usize, 0), empty.card_count);
    try std.testing.expectEqual(@as(usize, 0), empty.review_count);

    const deck_id = try store.createDeck("inspect", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);
    var parameters: fsrs.v7.Parameters = .{};
    parameters.desired_retention = 0.93;
    const parameter_set_id = try store.putFsrs7Parameters(parameters, "inspect-test", 0);
    try store.setDeckFsrs7(deck_id, parameter_set_id);

    const populated = try store.stats(0, null);
    try std.testing.expectEqual(@as(usize, 1), populated.deck_count);
    try std.testing.expectEqual(@as(usize, 1), populated.card_count);

    const study = study_mod.Study.init(&store);
    const preview = try study.preview(std.testing.allocator, card_id, 0);
    const active = try store.loadFsrs7Parameters(preview.parameter_set_id);
    try std.testing.expect(preview.algorithm.eql(.fsrs7));
    try std.testing.expectApproxEqAbs(@as(f64, 0.93), active.desired_retention, 1e-12);
    try std.testing.expect(fsrs.ImplementationVersion.current.eql(.{ .major = 0, .minor = 1, .patch = 0 }));
}
