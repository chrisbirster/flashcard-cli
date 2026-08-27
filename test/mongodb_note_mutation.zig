const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";

test "MongoDB note mutation retires restores and deletes generated cards" {
    const allocator = std.testing.allocator;
    const mongo = try deez.storage.MongoStore.connect(std.testing.io, allocator, replica_uri);
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    const deck_id = try store.createDeck("web-note-mutation-mongo", 900);
    defer store.deleteDeck(deck_id) catch {};

    const initial = [_][]const u8{ "front", "back", "reverse please" };
    const created = try deez.note_mutation.create(
        allocator,
        &store,
        deck_id,
        .optional_reverse,
        &initial,
        "[]",
        900,
    );
    defer created.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);
    const reverse_id = created.card_ids[1];

    const forward_only = [_][]const u8{ "front", "back", "" };
    const one = try deez.note_mutation.update(
        allocator,
        &store,
        deck_id,
        created.note_id,
        &forward_only,
        "[]",
        901,
    );
    defer allocator.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expect(try store.isCardRetired(reverse_id));

    const active = try store.cards(allocator, deck_id);
    defer {
        for (active) |card| card.deinit(allocator);
        allocator.free(active);
    }
    try std.testing.expectEqual(@as(usize, 1), active.len);

    const restored_values = [_][]const u8{ "front", "back", "reverse again" };
    const two = try deez.note_mutation.update(
        allocator,
        &store,
        deck_id,
        created.note_id,
        &restored_values,
        "[]",
        902,
    );
    defer allocator.free(two);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqual(reverse_id, two[1]);
    try std.testing.expect(!try store.isCardRetired(reverse_id));

    try deez.note_mutation.delete(allocator, &store, deck_id, created.note_id, 903);
    try std.testing.expect(try store.isCardRetired(created.card_ids[0]));
    try std.testing.expect(try store.isCardRetired(reverse_id));
    try std.testing.expect((try deez.storage.ContentStore.init(&store).getNote(allocator, created.note_id)) == null);

    const after_delete = try store.cards(allocator, deck_id);
    defer {
        for (after_delete) |card| card.deinit(allocator);
        allocator.free(after_delete);
    }
    try std.testing.expectEqual(@as(usize, 0), after_delete.len);
}
