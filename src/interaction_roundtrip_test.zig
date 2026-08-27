const std = @import("std");
const card_types = @import("card_types.zig");
const deck_file = @import("deck_file.zig");
const portable = @import("portable_content.zig");
const storage = @import("storage/root.zig");

test "interaction note types round trip through .deck v2" {
    const allocator = std.testing.allocator;
    var source_db = try storage.Db.open(":memory:");
    defer source_db.close();
    try source_db.migrate();
    var source_store: storage.Store = .{ .sqlite = &source_db };
    const deck_id = try source_store.createDeck("Interactions", 0);

    const choices = "[{\"id\":\"stack\",\"text\":\"Stack\"},{\"id\":\"queue\",\"text\":\"Queue\"},{\"id\":\"hash\",\"text\":\"Hash table\"}]";
    const mc_fields = [_][]const u8{ "Average O(1) lookup?", choices, "hash", "Uses hashing." };
    const mc = try card_types.create(allocator, &source_store, deck_id, .multiple_choice, &mc_fields, "[]", 0);
    defer mc.deinit(allocator);

    const image = "deez-media://sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const masks = "[{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"root\"},{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"child\"}]";
    const occlusion_fields = [_][]const u8{ image, masks, "Binary tree anatomy" };
    const occlusion = try card_types.create(allocator, &source_store, deck_id, .image_occlusion, &occlusion_fields, "[]", 0);
    defer occlusion.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), occlusion.card_ids.len);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try deck_file.exportDeck(allocator, &source_store, deck_id, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "multiple-choice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "image-occlusion") != null);

    var dest_db = try storage.Db.open(":memory:");
    defer dest_db.close();
    try dest_db.migrate();
    var dest_store: storage.Store = .{ .sqlite = &dest_db };
    const imported = try deck_file.importSlice(allocator, &dest_store, out.written(), 1);
    try std.testing.expectEqual(@as(usize, 3), imported.card_count);

    const notes = try portable.collectDeckNotes(allocator, &dest_store, imported.deck_id);
    defer {
        for (notes) |note| note.deinit(allocator);
        allocator.free(notes);
    }
    try std.testing.expectEqual(@as(usize, 2), notes.len);
    try std.testing.expectEqualStrings("multiple-choice", notes[0].note_type);
    try std.testing.expectEqualStrings("image-occlusion", notes[1].note_type);
}
