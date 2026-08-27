const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";

test "built-in note types preserve generated identities through MongoDB" {
    const allocator = std.testing.allocator;
    const mongo = try deez.storage.MongoStore.connect(std.testing.io, allocator, replica_uri);
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    const deck_id = try store.createDeck("rc2-card-types-mongo", 200);
    defer store.deleteDeck(deck_id) catch {};

    const fields = [_][]const u8{ "France", "Paris" };
    const created = try deez.card_types.create(allocator, &store, deck_id, .basic_reverse, &fields, "[]", 200);
    defer created.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);

    const edited_fields = [_][]const u8{ "Capital of France", "Paris" };
    const updated = try deez.card_types.update(allocator, &store, deck_id, created.note_id, &edited_fields, "[]", 201);
    defer allocator.free(updated);
    try std.testing.expectEqualSlices(u64, created.card_ids, updated);

    const first = (try store.getCard(allocator, updated[0])).?;
    defer first.deinit(allocator);
    try std.testing.expectEqualStrings("Capital of France", first.question);

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    try deez.deck_json.exportDeck(allocator, &store, deck_id, &json_out.writer);
    try std.testing.expect(std.mem.indexOf(u8, json_out.written(), "basic-reverse") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_out.written(), "reviews") == null);

    var nut_out: std.Io.Writer.Allocating = .init(allocator);
    defer nut_out.deinit();
    try deez.nut.exportDeck(allocator, &store, deck_id, &nut_out.writer);
    try std.testing.expect(std.mem.indexOf(u8, nut_out.written(), "\"kind\":\"note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nut_out.written(), "basic-reverse") != null);
}

test "cloze creates one MongoDB card per distinct ordinal" {
    const allocator = std.testing.allocator;
    const mongo = try deez.storage.MongoStore.connect(std.testing.io, allocator, replica_uri);
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    const deck_id = try store.createDeck("rc2-cloze-mongo", 300);
    defer store.deleteDeck(deck_id) catch {};
    const fields = [_][]const u8{ "{{c1::Paris}} is in {{c2::France}} and {{c1::Paris}} is a city", "geo" };
    const created = try deez.card_types.create(allocator, &store, deck_id, .cloze, &fields, "[]", 300);
    defer created.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);
}

test "interaction note types round trip through MongoDB" {
    const allocator = std.testing.allocator;
    const mongo = try deez.storage.MongoStore.connect(std.testing.io, allocator, replica_uri);
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    const deck_id = try store.createDeck("rc4-1-interactions-mongo", 400);
    defer store.deleteDeck(deck_id) catch {};

    const choices = "[{\"id\":\"array\",\"text\":\"Array\"},{\"id\":\"hash\",\"text\":\"Hash table\"},{\"id\":\"list\",\"text\":\"Linked list\"}]";
    const mc_fields = [_][]const u8{ "Average O(1) lookup?", choices, "hash", "Uses hashing." };
    const mc = try deez.card_types.create(allocator, &store, deck_id, .multiple_choice, &mc_fields, "[]", 400);
    defer mc.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), mc.card_ids.len);

    const image = "deez-media://sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const masks_a = "[{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"right\"},{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left\"}]";
    const occlusion_fields_a = [_][]const u8{ image, masks_a, "tree" };
    const occlusion = try deez.card_types.create(allocator, &store, deck_id, .image_occlusion, &occlusion_fields_a, "[]", 400);
    defer occlusion.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), occlusion.card_ids.len);

    const masks_b = "[{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left node\"},{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"right node\"}]";
    const occlusion_fields_b = [_][]const u8{ image, masks_b, "tree" };
    const updated = try deez.card_types.update(allocator, &store, deck_id, occlusion.note_id, &occlusion_fields_b, "[]", 401);
    defer allocator.free(updated);
    try std.testing.expectEqualSlices(u64, occlusion.card_ids, updated);

    var nut_out: std.Io.Writer.Allocating = .init(allocator);
    defer nut_out.deinit();
    try deez.nut.exportDeck(allocator, &store, deck_id, &nut_out.writer);
    try std.testing.expect(std.mem.indexOf(u8, nut_out.written(), "multiple-choice") != null);
    try std.testing.expect(std.mem.indexOf(u8, nut_out.written(), "image-occlusion") != null);
}
