const std = @import("std");
const Io = std.Io;
const portable = @import("portable_content.zig");
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const format_name = "deez.deck";
pub const format_version: u32 = 2;

const Header = struct {
    format: []const u8,
    version: u32,
};

pub const CardFile = struct {
    question: []const u8,
    answer: []const u8,
};

const DeckContentsV1 = struct {
    name: []const u8,
    cards: []const CardFile,
};

const FileV1 = struct {
    format: []const u8,
    version: u32,
    deck: DeckContentsV1,
};

const NoteFileInput = struct {
    note_type: []const u8,
    fields: []const []const u8,
    tags_json: []const u8 = "[]",
};

const NoteFileOutput = struct {
    note_type: []const u8,
    fields: [][]u8,
    tags_json: []const u8,
};

const DeckContentsV2Input = struct {
    name: []const u8,
    notes: []const NoteFileInput,
};

const DeckContentsV2Output = struct {
    name: []const u8,
    notes: []const NoteFileOutput,
};

const FileV2Input = struct {
    format: []const u8,
    version: u32,
    deck: DeckContentsV2Input,
};

const FileV2Output = struct {
    format: []const u8,
    version: u32,
    deck: DeckContentsV2Output,
};

pub const ImportResult = struct {
    deck_id: u64,
    card_count: usize,
};

fn requireText(text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
}

fn validateHeader(header: Header) !void {
    if (!std.mem.eql(u8, header.format, format_name)) return error.UnsupportedDeckFormat;
    if (header.version != 1 and header.version != format_version) return error.UnsupportedDeckVersion;
}

fn validateV1(file: FileV1) !void {
    try validateHeader(.{ .format = file.format, .version = file.version });
    try requireText(file.deck.name);
    for (file.deck.cards) |card| {
        try requireText(card.question);
        try requireText(card.answer);
    }
}

fn validateV2(file: FileV2Input) !void {
    try validateHeader(.{ .format = file.format, .version = file.version });
    if (file.version != format_version) return error.UnsupportedDeckVersion;
    try requireText(file.deck.name);
    for (file.deck.notes) |note| {
        _ = try @import("content.zig").BuiltInNoteType.parse(note.note_type);
        if (note.fields.len == 0) return error.InvalidFieldCount;
    }
}

/// Export a shareable logical-content file. Version 2 stores notes and fields,
/// not generated card fronts/backs, so reverse/cloze identity survives a
/// round trip. Personal review history and scheduler state are excluded.
pub fn exportDeck(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    writer: *Io.Writer,
) !void {
    const deck = (try store.getDeck(allocator, deck_id)) orelse return error.DeckNotFound;
    defer deck.deinit(allocator);

    const notes = try portable.collectDeckNotes(allocator, store, deck_id);
    defer {
        for (notes) |note| note.deinit(allocator);
        allocator.free(notes);
    }

    const output_notes = try allocator.alloc(NoteFileOutput, notes.len);
    defer allocator.free(output_notes);
    for (notes, 0..) |note, index| {
        output_notes[index] = .{
            .note_type = note.note_type,
            .fields = note.fields,
            .tags_json = note.tags_json,
        };
    }

    const file: FileV2Output = .{
        .format = format_name,
        .version = format_version,
        .deck = .{ .name = deck.name, .notes = output_notes },
    };
    try std.json.Stringify.value(file, .{ .whitespace = .indent_2 }, writer);
    try writer.writeAll("\n");
}

fn importV1(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    bytes: []const u8,
    created_at_ms: time.TimestampMs,
) !ImportResult {
    var parsed = try std.json.parseFromSlice(FileV1, allocator, bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateV1(parsed.value);

    const deck_id = try store.createDeck(parsed.value.deck.name, created_at_ms);
    errdefer store.deleteDeck(deck_id) catch {};
    _ = try store.ensureDefaultFsrs7(created_at_ms);
    for (parsed.value.deck.cards) |card| {
        _ = try store.createCard(deck_id, card.question, card.answer, created_at_ms);
    }
    return .{ .deck_id = deck_id, .card_count = parsed.value.deck.cards.len };
}

fn importV2(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    bytes: []const u8,
    created_at_ms: time.TimestampMs,
) !ImportResult {
    var parsed = try std.json.parseFromSlice(FileV2Input, allocator, bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateV2(parsed.value);

    const deck_id = try store.createDeck(parsed.value.deck.name, created_at_ms);
    errdefer store.deleteDeck(deck_id) catch {};
    const inputs = try allocator.alloc(portable.NoteInput, parsed.value.deck.notes.len);
    defer allocator.free(inputs);
    for (parsed.value.deck.notes, 0..) |note, index| {
        inputs[index] = .{
            .note_type = note.note_type,
            .fields = note.fields,
            .tags_json = note.tags_json,
        };
    }
    const card_count = try portable.importNotes(allocator, store, deck_id, inputs, created_at_ms);
    return .{ .deck_id = deck_id, .card_count = card_count };
}

pub fn importSlice(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    bytes: []const u8,
    created_at_ms: time.TimestampMs,
) !ImportResult {
    var header = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    try validateHeader(header.value);
    return switch (header.value.version) {
        1 => importV1(allocator, store, bytes, created_at_ms),
        2 => importV2(allocator, store, bytes, created_at_ms),
        else => error.UnsupportedDeckVersion,
    };
}

test "JSON v1 deck import remains compatible" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };

    const json =
        \\{"format":"deez.deck","version":1,"deck":{"name":"Legacy","cards":[{"question":"q","answer":"a"}]}}
    ;
    const result = try importSlice(std.testing.allocator, &store, json, 1234);
    try std.testing.expectEqual(@as(usize, 1), result.card_count);
}

test "JSON v2 reverse note round trips as one logical note" {
    var source_db = try storage.Db.open(":memory:");
    defer source_db.close();
    try source_db.migrate();
    var source_store: storage.Store = .{ .sqlite = &source_db };
    const source_deck = try source_store.createDeck("Geography", 0);
    const fields = [_][]const u8{ "France", "Paris" };
    const created = try @import("card_types.zig").create(std.testing.allocator, &source_store, source_deck, .basic_reverse, &fields, "[]", 0);
    defer created.deinit(std.testing.allocator);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try exportDeck(std.testing.allocator, &source_store, source_deck, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "basic-reverse") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "reviews") == null);

    var dest_db = try storage.Db.open(":memory:");
    defer dest_db.close();
    try dest_db.migrate();
    var dest_store: storage.Store = .{ .sqlite = &dest_db };
    const imported = try importSlice(std.testing.allocator, &dest_store, out.written(), 1);
    try std.testing.expectEqual(@as(usize, 2), imported.card_count);
    const notes = try portable.collectDeckNotes(std.testing.allocator, &dest_store, imported.deck_id);
    defer {
        for (notes) |note| note.deinit(std.testing.allocator);
        std.testing.allocator.free(notes);
    }
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("basic-reverse", notes[0].note_type);
}
