const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_scheduler_migration?replicaSet=rs0";
const standalone_uri = "mongodb://admin:secretpassword@localhost:27017/deez_scheduler_migration_standalone?authSource=admin";

fn connectStore(uri: []const u8) !deez.storage.Store {
    const mongo = try deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        uri,
    );
    return .{ .mongodb = mongo };
}

fn targetParameters() deez.fsrs.v7.Parameters {
    var parameters: deez.fsrs.v7.Parameters = .{};
    parameters.desired_retention = 0.95;
    return parameters;
}

test "Mongo scheduler migration commits target pin and rebuilt states atomically" {
    const allocator = std.testing.allocator;
    var store = try connectStore(replica_uri);
    defer store.deinit();
    try std.testing.expect(store.mongodb.client.supports_transactions);

    const deck_id = try store.createDeck("migration", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);
    const source_id = try store.ensureDefaultFsrs7(0);
    try store.setDeckFsrs7(deck_id, source_id);

    const study = deez.Study.init(&store);
    _ = try study.recordReview(allocator, card_id, .good, 0);
    const history_before = try store.loadHistory(allocator, card_id);
    defer allocator.free(history_before);

    const target_id = try store.putFsrs7Parameters(targetParameters(), "migration-target", 1);
    const preview = try deez.scheduler_migration.dryRunFsrs7(
        allocator,
        &store,
        deck_id,
        target_id,
        deez.time.milliseconds_per_day,
    );
    preview.deinit(allocator);

    const still_source = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, still_source.parameter_set_id[0..], source_id[0..]));

    const activation = try deez.scheduler_migration.activateFsrs7(
        allocator,
        &store,
        deck_id,
        target_id,
        deez.time.milliseconds_per_day,
    );
    try std.testing.expectEqual(@as(usize, 1), activation.rebuilt_cards);

    const active = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, active.parameter_set_id[0..], target_id[0..]));
    const state = (try store.getSchedulerState(card_id)) orelse return error.MissingMigratedState;
    try std.testing.expect(std.mem.eql(u8, state.stamp.parameter_set_id[0..], target_id[0..]));

    const history_after = try store.loadHistory(allocator, card_id);
    defer allocator.free(history_after);
    try std.testing.expectEqual(history_before.len, history_after.len);
    for (history_before, history_after) |before, after| {
        try std.testing.expectEqual(before.rating, after.rating);
        try std.testing.expectEqual(before.reviewed_at_ms, after.reviewed_at_ms);
    }
}

test "standalone Mongo refuses scheduler migration before mutating the deck" {
    const allocator = std.testing.allocator;
    var store = try connectStore(standalone_uri);
    defer store.deinit();
    try std.testing.expect(!store.mongodb.client.supports_transactions);

    const deck_id = try store.createDeck("migration-standalone", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);
    const source_id = try store.ensureDefaultFsrs7(0);
    try store.setDeckFsrs7(deck_id, source_id);
    const study = deez.Study.init(&store);
    _ = try study.recordReview(allocator, card_id, .good, 0);
    const state_before = (try store.getSchedulerState(card_id)) orelse return error.MissingSourceState;

    const target_id = try store.putFsrs7Parameters(targetParameters(), "migration-target", 1);
    try std.testing.expectError(
        error.TransactionsRequired,
        deez.scheduler_migration.activateFsrs7(
            allocator,
            &store,
            deck_id,
            target_id,
            deez.time.milliseconds_per_day,
        ),
    );

    const still_source = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, still_source.parameter_set_id[0..], source_id[0..]));
    const state_after = (try store.getSchedulerState(card_id)) orelse return error.MissingSourceStateAfterFailure;
    try std.testing.expect(std.mem.eql(
        u8,
        state_after.stamp.parameter_set_id[0..],
        state_before.stamp.parameter_set_id[0..],
    ));
}
