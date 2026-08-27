const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";

test "Content Model v2 creates and adopts cards through MongoDB" {
    const allocator = std.testing.allocator;
    const mongo = try deez.storage.MongoStore.connect(std.testing.io, allocator, replica_uri);
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    const deck_id = try store.createDeck("content-v2-mongo", 100);
    defer store.deleteDeck(deck_id) catch {};

    const content_store = deez.storage.ContentStore.init(&store);
    const created = try content_store.createBasicNote(
        allocator,
        deck_id,
        "Mongo front",
        "Mongo back",
        "[]",
        100,
    );
    defer created.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), created.card_ids.len);

    const note = (try content_store.getNote(allocator, created.note_id)).?;
    defer note.deinit(allocator);
    try std.testing.expectEqualStrings("Mongo front", note.fields[0].value);
    try std.testing.expectEqualStrings("Mongo back", note.fields[1].value);

    const generated = (try content_store.cardSource(allocator, created.card_ids[0])).?;
    defer generated.deinit(allocator);
    try std.testing.expectEqual(created.note_id, generated.note_id);

    const legacy_card_id = try store.createCard(deck_id, "legacy q", "legacy a", 101);
    const adopted_note_id = try content_store.adoptLegacyCard(allocator, legacy_card_id, 102);
    const adopted = (try content_store.cardSource(allocator, legacy_card_id)).?;
    defer adopted.deinit(allocator);
    try std.testing.expectEqual(adopted_note_id, adopted.note_id);

    const legacy = (try store.getCard(allocator, legacy_card_id)).?;
    defer legacy.deinit(allocator);
    try std.testing.expectEqualStrings("legacy q", legacy.question);
    try std.testing.expectEqualStrings("legacy a", legacy.answer);
}
