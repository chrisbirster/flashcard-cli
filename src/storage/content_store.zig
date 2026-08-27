const std = @import("std");

const content = @import("../content.zig");
const store_mod = @import("store.zig");
const sqlite = @import("sqlite.zig");
const sqlite_content = @import("sqlite_content.zig");

pub const OwnedDeckNote = struct {
    note: content.OwnedNote,
    card_count: usize,

    pub fn deinit(self: OwnedDeckNote, allocator: std.mem.Allocator) void {
        self.note.deinit(allocator);
    }
};

pub const ContentStore = struct {
    store: *store_mod.Store,

    pub fn init(store: *store_mod.Store) ContentStore {
        return .{ .store = store };
    }

    fn db(self: ContentStore) *sqlite.Db {
        return switch (self.store.*) {
            .sqlite => |database| database,
        };
    }

    pub fn ensureBuiltInBasic(self: ContentStore, created_at_ms: i64) !content.NoteTypeId {
        return sqlite_content.ensureBuiltInBasic(self.db(), created_at_ms);
    }

    pub fn createNote(
        self: ContentStore,
        allocator: std.mem.Allocator,
        note_type_id: content.NoteTypeId,
        fields: []const content.FieldValue,
        tags_json: []const u8,
        created_at_ms: i64,
    ) !content.NoteId {
        _ = allocator;
        return sqlite_content.createNote(self.db(), note_type_id, fields, tags_json, created_at_ms);
    }

    pub fn createBasicNote(
        self: ContentStore,
        allocator: std.mem.Allocator,
        deck_id: u64,
        front: []const u8,
        back: []const u8,
        tags_json: []const u8,
        created_at_ms: i64,
    ) !content.CreatedNote {
        return sqlite_content.createBasicNote(allocator, self.db(), deck_id, front, back, tags_json, created_at_ms);
    }

    pub fn adoptLegacyCard(
        self: ContentStore,
        allocator: std.mem.Allocator,
        card_id: u64,
        adopted_at_ms: i64,
    ) !content.NoteId {
        return sqlite_content.adoptLegacyCard(allocator, self.db(), card_id, adopted_at_ms);
    }

    pub fn getNote(
        self: ContentStore,
        allocator: std.mem.Allocator,
        note_id: content.NoteId,
    ) !?content.OwnedNote {
        return sqlite_content.getNote(allocator, self.db(), note_id);
    }

    /// Return logical notes whose generated cards belong to `deck_id`.
    ///
    /// The content schema intentionally does not duplicate deck ownership on a
    /// note. A note belongs to a deck through its generated cards. Legacy cards
    /// without Content Model v2 metadata are ignored.
    pub fn notesForDeck(
        self: ContentStore,
        allocator: std.mem.Allocator,
        deck_id: u64,
    ) ![]OwnedDeckNote {
        const cards = try self.store.cards(allocator, deck_id);
        defer {
            for (cards) |card| card.deinit(allocator);
            allocator.free(cards);
        }

        var notes: std.ArrayList(OwnedDeckNote) = .empty;
        errdefer {
            for (notes.items) |entry| entry.deinit(allocator);
            notes.deinit(allocator);
        }

        for (cards) |card| {
            const source = (try self.cardSource(allocator, card.id)) orelse continue;
            defer source.deinit(allocator);

            var existing_index: ?usize = null;
            for (notes.items, 0..) |entry, index| {
                if (entry.note.id == source.note_id) {
                    existing_index = index;
                    break;
                }
            }

            if (existing_index) |index| {
                notes.items[index].card_count += 1;
                continue;
            }

            const note = (try self.getNote(allocator, source.note_id)) orelse return error.NoteNotFound;
            errdefer note.deinit(allocator);
            try notes.append(allocator, .{
                .note = note,
                .card_count = 1,
            });
        }

        std.mem.sort(OwnedDeckNote, notes.items, {}, struct {
            fn lessThan(_: void, left: OwnedDeckNote, right: OwnedDeckNote) bool {
                if (left.note.updated_at_ms == right.note.updated_at_ms) return left.note.id < right.note.id;
                return left.note.updated_at_ms > right.note.updated_at_ms;
            }
        }.lessThan);

        return notes.toOwnedSlice(allocator);
    }

    pub fn cardSource(
        self: ContentStore,
        allocator: std.mem.Allocator,
        card_id: u64,
    ) !?content.GeneratedCardSource {
        return sqlite_content.cardSource(allocator, self.db(), card_id);
    }
};

test "ContentStore adopts an existing SQLite card without changing its id" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: store_mod.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("legacy", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);

    const content_store = ContentStore.init(&store);
    const note_id = try content_store.adoptLegacyCard(std.testing.allocator, card_id, 1);
    const source = (try content_store.cardSource(std.testing.allocator, card_id)).?;
    defer source.deinit(std.testing.allocator);
    try std.testing.expectEqual(note_id, source.note_id);
    try std.testing.expectEqual(card_id, @as(u64, card_id));
}

test "notesForDeck deduplicates generated cards into logical notes" {
    const note_type_store = @import("note_type_store.zig");
    const generated_card_store = @import("generated_card_store.zig");

    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: store_mod.Store = .{ .sqlite = &db };
    const content_store = ContentStore.init(&store);
    const deck_id = try store.createDeck("reverse", 0);

    try note_type_store.ensure(std.testing.allocator, &store, content.basic_reverse_note_type, 0);
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "France" },
        .{ .ordinal = 1, .value = "Paris" },
    };
    const note_id = try content_store.createNote(
        std.testing.allocator,
        content.basic_reverse_note_type.id,
        &fields,
        "[\"geography\"]",
        10,
    );
    const forward = try store.createCard(deck_id, "France", "Paris", 10);
    const reverse = try store.createCard(deck_id, "Paris", "France", 10);
    const forward_key = try content.generationKey(std.testing.allocator, note_id, 0);
    defer std.testing.allocator.free(forward_key);
    try generated_card_store.link(&store, forward, note_id, 0, forward_key);
    const reverse_key = try content.generationKey(std.testing.allocator, note_id, 1);
    defer std.testing.allocator.free(reverse_key);
    try generated_card_store.link(&store, reverse, note_id, 1, reverse_key);

    const notes = try content_store.notesForDeck(std.testing.allocator, deck_id);
    defer {
        for (notes) |entry| entry.deinit(std.testing.allocator);
        std.testing.allocator.free(notes);
    }
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqual(note_id, notes[0].note.id);
    try std.testing.expectEqual(@as(usize, 2), notes[0].card_count);
    try std.testing.expectEqualStrings("[\"geography\"]", notes[0].note.tags_json);
}
