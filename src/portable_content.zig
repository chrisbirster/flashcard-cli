const std = @import("std");

const card_types = @import("card_types.zig");
const content = @import("content.zig");
const storage = @import("storage/root.zig");

pub const OwnedNote = struct {
    note_type: []u8,
    fields: [][]u8,
    tags_json: []u8,

    pub fn deinit(self: OwnedNote, allocator: std.mem.Allocator) void {
        allocator.free(self.note_type);
        for (self.fields) |field| allocator.free(field);
        allocator.free(self.fields);
        allocator.free(self.tags_json);
    }
};

pub const NoteInput = struct {
    note_type: []const u8,
    fields: []const []const u8,
    tags_json: []const u8 = "[]",
};

pub fn slugForNoteType(note_type_id: content.NoteTypeId) ![]const u8 {
    const kind = content.BuiltInNoteType.fromId(note_type_id) catch return error.UnsupportedPortableNoteType;
    return kind.definition().slug;
}

fn contains(ids: []const content.NoteId, id: content.NoteId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn copyFields(
    allocator: std.mem.Allocator,
    fields: []const content.OwnedFieldValue,
) ![][]u8 {
    const result = try allocator.alloc([]u8, fields.len);
    var completed: usize = 0;
    errdefer {
        for (result[0..completed]) |field| allocator.free(field);
        allocator.free(result);
    }
    for (fields, 0..) |field, index| {
        result[index] = try allocator.dupe(u8, field.value);
        completed += 1;
    }
    return result;
}

fn legacyNote(
    allocator: std.mem.Allocator,
    question: []const u8,
    answer: []const u8,
) !OwnedNote {
    const fields = try allocator.alloc([]u8, 2);
    errdefer allocator.free(fields);
    fields[0] = try allocator.dupe(u8, question);
    errdefer allocator.free(fields[0]);
    fields[1] = try allocator.dupe(u8, answer);
    errdefer allocator.free(fields[1]);
    return .{
        .note_type = try allocator.dupe(u8, "basic"),
        .fields = fields,
        .tags_json = try allocator.dupe(u8, "[]"),
    };
}

pub fn collectDeckNotes(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
) ![]OwnedNote {
    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }

    var seen: std.ArrayList(content.NoteId) = .empty;
    defer seen.deinit(allocator);
    var notes: std.ArrayList(OwnedNote) = .empty;
    errdefer {
        for (notes.items) |note| note.deinit(allocator);
        notes.deinit(allocator);
    }

    const content_store = storage.ContentStore.init(store);
    for (cards) |card| {
        const maybe_source = try content_store.cardSource(allocator, card.id);
        if (maybe_source) |source| {
            defer source.deinit(allocator);
            if (contains(seen.items, source.note_id)) continue;
            try seen.append(allocator, source.note_id);

            const note = (try content_store.getNote(allocator, source.note_id)) orelse return error.NoteNotFound;
            defer note.deinit(allocator);
            const slug = try slugForNoteType(note.note_type_id);
            const copied_fields = try copyFields(allocator, note.fields);
            errdefer {
                for (copied_fields) |field| allocator.free(field);
                allocator.free(copied_fields);
            }
            const copied_slug = try allocator.dupe(u8, slug);
            errdefer allocator.free(copied_slug);
            const copied_tags = try allocator.dupe(u8, note.tags_json);
            errdefer allocator.free(copied_tags);
            try notes.append(allocator, .{
                .note_type = copied_slug,
                .fields = copied_fields,
                .tags_json = copied_tags,
            });
        } else {
            try notes.append(allocator, try legacyNote(allocator, card.question, card.answer));
        }
    }

    return notes.toOwnedSlice(allocator);
}

pub fn importNotes(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    notes: []const NoteInput,
    created_at_ms: i64,
) !usize {
    var card_count: usize = 0;
    for (notes) |note| {
        const kind = try content.BuiltInNoteType.parse(note.note_type);
        const generated = try card_types.create(
            allocator,
            store,
            deck_id,
            kind,
            note.fields,
            note.tags_json,
            created_at_ms,
        );
        card_count += generated.card_ids.len;
        generated.deinit(allocator);
    }
    return card_count;
}

test "portable deck collection deduplicates reverse generated cards" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("geo", 0);
    const values = [_][]const u8{ "France", "Paris" };
    const created = try card_types.create(std.testing.allocator, &store, deck_id, .basic_reverse, &values, "[]", 0);
    defer created.deinit(std.testing.allocator);

    const notes = try collectDeckNotes(std.testing.allocator, &store, deck_id);
    defer {
        for (notes) |note| note.deinit(std.testing.allocator);
        std.testing.allocator.free(notes);
    }
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("basic-reverse", notes[0].note_type);
    try std.testing.expectEqual(@as(usize, 2), notes[0].fields.len);
}

test "portable note type slugs include interaction types" {
    try std.testing.expectEqualStrings("multiple-choice", try slugForNoteType(6));
    try std.testing.expectEqualStrings("multiple-select", try slugForNoteType(7));
    try std.testing.expectEqualStrings("ordering", try slugForNoteType(8));
    try std.testing.expectEqualStrings("image-occlusion", try slugForNoteType(9));
}
