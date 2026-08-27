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

test "MongoStore rejects an explicitly unsupported deck scheduler instead of falling back" {
    var store = try connectStore();
    defer store.deinit();

    const deck_id = try store.createDeck("mongo-unsupported-scheduler", 0);
    defer store.deleteDeck(deck_id) catch {};
    _ = try store.ensureDefaultFsrs7(0);

    try store.mongodb.setDeckScheduler(
        deck_id,
        .{ .family = .fsrs, .major = 8 },
        null,
    );

    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        store.resolveDeckScheduler(deck_id, 0),
    );
}
