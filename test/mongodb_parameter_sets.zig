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

test "MongoStore preserves immutable versioned FSRS parameter sets" {
    var store = try connectStore();
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-parameter-sets", 0);
    defer store.deleteDeck(deck_id) catch {};

    const default_id = try store.ensureDefaultFsrs7(0);

    var first: deez.fsrs.v7.Parameters = .{};
    first.desired_retention = 0.93;
    const first_id = try store.putFsrs7Parameters(first, "optimized-a", 1);

    var second: deez.fsrs.v7.Parameters = .{};
    second.desired_retention = 0.96;
    const second_id = try store.putFsrs7Parameters(second, "optimized-b", 2);

    try std.testing.expect(!std.mem.eql(u8, default_id[0..], first_id[0..]));
    try std.testing.expect(!std.mem.eql(u8, first_id[0..], second_id[0..]));

    const reloaded_first = try store.loadFsrs7Parameters(first_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.93), reloaded_first.desired_retention, 1e-12);
    const reloaded_second = try store.loadFsrs7Parameters(second_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.96), reloaded_second.desired_retention, 1e-12);

    try store.setDeckFsrs7(deck_id, first_id);
    const resolved = try store.resolveDeckScheduler(deck_id, 3);
    try std.testing.expect(resolved.algorithm.eql(.fsrs7));
    try std.testing.expect(std.mem.eql(u8, resolved.parameter_set_id[0..], first_id[0..]));

    const card_id = try store.createCard(deck_id, "parameter identity?", "exact", 0);
    const study = deez.Study.init(&store);
    _ = try study.recordReview(std.testing.allocator, card_id, .good, 0);
    const state = (try store.getSchedulerState(card_id)) orelse return error.MissingSchedulerState;
    try std.testing.expect(std.mem.eql(u8, state.stamp.parameter_set_id[0..], first_id[0..]));

    try store.mongodb.setDeckScheduler(
        deck_id,
        .{ .family = .fsrs, .major = 8 },
        first_id,
    );
    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        store.resolveDeckScheduler(deck_id, 4),
    );

    const missing: deez.fsrs.ParameterSetId = [_]u8{0xff} ** 32;
    try std.testing.expectError(
        error.ParameterSetNotFound,
        store.setDeckFsrs7(deck_id, missing),
    );
}
