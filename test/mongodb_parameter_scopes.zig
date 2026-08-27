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

fn makeParameters(retention: f64) deez.fsrs.v7.Parameters {
    var parameters: deez.fsrs.v7.Parameters = .{};
    parameters.desired_retention = retention;
    return parameters;
}

test "MongoStore resolves deck group and global parameter scopes deterministically" {
    var store = try connectStore();
    defer store.deinit();

    const global_id = try store.putFsrs7Parameters(makeParameters(0.90), "global", 0);
    const group_id_param = try store.putFsrs7Parameters(makeParameters(0.93), "group", 1);
    const deck_id_param = try store.putFsrs7Parameters(makeParameters(0.96), "deck", 2);
    try store.setGlobalFsrs7(global_id);

    const group_id = try store.createGroup("shared", 0);
    try store.setGroupFsrs7(group_id, group_id_param);

    const deck_id = try store.createDeck("scoped", 0);
    defer store.deleteDeck(deck_id) catch {};

    var resolved = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, resolved.parameter_set_id[0..], global_id[0..]));

    try store.assignDeckGroup(deck_id, group_id);
    resolved = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, resolved.parameter_set_id[0..], group_id_param[0..]));

    try store.setDeckFsrs7(deck_id, deck_id_param);
    resolved = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, resolved.parameter_set_id[0..], deck_id_param[0..]));

    try store.inheritDeckScheduler(deck_id);
    resolved = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, resolved.parameter_set_id[0..], group_id_param[0..]));

    try store.assignDeckGroup(deck_id, null);
    resolved = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, resolved.parameter_set_id[0..], global_id[0..]));
}
