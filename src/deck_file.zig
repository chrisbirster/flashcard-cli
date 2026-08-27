const std = @import("std");
const Io = std.Io;
const portable = @import("portable_content.zig");
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const format_name = "plandalf.deck";
pub const format_version: u32 = 2;

const deck_kind = "deck";
const card_kind = "card";
const note_kind = "note";

const Envelope = struct { kind: []const u8 };
const DeckRecord = struct {
    kind: []const u8,
    format: []const u8,
    version: u32,
    name: []const u8,
};
const CardRecord = struct {
    kind: []const u8,
    question: []const u8,
    answer: []const u8,
};
const NoteRecordInput = struct {
    kind: []const u8,
    note_type: []const u8,
    fields: []const []const u8,
    tags_json: []const u8 = "[]",
};
const NoteRecordOutput = struct {
    kind: []const u8,
    note_type: []const u8,
    fields: [][]u8,
    tags_json: []const u8,
};

pub const ImportResult = struct {
    deck_id: u64,
    card_count: usize,
};

fn requireText(text: []const u8) !void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
}

fn validateDeck(record: DeckRecord) !void {
    if (!std.mem.eql(u8, record.kind, deck_kind)) return error.InvalidDeckRecord;
    if (!std.mem.eql(u8, record.format, format_name)) return error.UnsupportedDeckFormat;
    if (record.version != 1 and record.version != format_version) return error.UnsupportedDeckVersion;
    try requireText(record.name);
}

fn validateCard(record: CardRecord) !void {
    if (!std.mem.eql(u8, record.kind, card_kind)) return error.InvalidDeckRecord;
    try requireText(record.question);
    try requireText(record.answer);
}

fn validateNote(record: NoteRecordInput) !void {
    if (!std.mem.eql(u8, record.kind, note_kind)) return error.InvalidDeckRecord;
    _ = try @import("content.zig").BuiltInNoteType.parse(record.note_type);
    if (record.fields.len == 0) return error.InvalidFieldCount;
}

/// Export Plandalf's native logical `.deck` format. v2 is NDJSON containing
/// one deck header and one record per logical note. Generated cards are rebuilt
/// on import, while review/scheduler state is intentionally excluded.
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

    const header: DeckRecord = .{
        .kind = deck_kind,
        .format = format_name,
        .version = format_version,
        .name = deck.name,
    };
    try std.json.Stringify.value(header, .{}, writer);
    try writer.writeAll("\n");

    for (notes) |note| {
        const record: NoteRecordOutput = .{
            .kind = note_kind,
            .note_type = note.note_type,
            .fields = note.fields,
            .tags_json = note.tags_json,
        };
        try std.json.Stringify.value(record, .{}, writer);
        try writer.writeAll("\n");
    }
}

fn importV1Line(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    line: []const u8,
    created_at_ms: time.TimestampMs,
) !usize {
    var parsed = try std.json.parseFromSlice(CardRecord, allocator, line, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateCard(parsed.value);
    _ = try store.createCard(deck_id, parsed.value.question, parsed.value.answer, created_at_ms);
    return 1;
}

fn importV2Line(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    line: []const u8,
    created_at_ms: time.TimestampMs,
) !usize {
    var parsed = try std.json.parseFromSlice(NoteRecordInput, allocator, line, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateNote(parsed.value);
    const input = [_]portable.NoteInput{.{
        .note_type = parsed.value.note_type,
        .fields = parsed.value.fields,
        .tags_json = parsed.value.tags_json,
    }};
    return portable.importNotes(allocator, store, deck_id, &input, created_at_ms);
}

pub fn importSlice(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    bytes: []const u8,
    created_at_ms: time.TimestampMs,
) !ImportResult {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var deck_id: ?u64 = null;
    var version: ?u32 = null;
    var card_count: usize = 0;

    errdefer if (deck_id) |id| store.deleteDeck(id) catch {};

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var envelope = try std.json.parseFromSlice(Envelope, allocator, line, .{ .ignore_unknown_fields = true });
        const kind = try allocator.dupe(u8, envelope.value.kind);
        envelope.deinit();
        defer allocator.free(kind);

        if (std.mem.eql(u8, kind, deck_kind)) {
            if (deck_id != null) return error.DuplicateDeckHeader;
            var parsed = try std.json.parseFromSlice(DeckRecord, allocator, line, .{ .ignore_unknown_fields = false });
            defer parsed.deinit();
            try validateDeck(parsed.value);
            const id = try store.createDeck(parsed.value.name, created_at_ms);
            deck_id = id;
            version = parsed.value.version;
            _ = try store.ensureDefaultFsrs7(created_at_ms);
            continue;
        }

        const id = deck_id orelse return error.MissingDeckHeader;
        const file_version = version orelse return error.MissingDeckHeader;
        switch (file_version) {
            1 => {
                if (!std.mem.eql(u8, kind, card_kind)) return error.UnsupportedDeckRecordKind;
                card_count += try importV1Line(allocator, store, id, line, created_at_ms);
            },
            2 => {
                if (!std.mem.eql(u8, kind, note_kind)) return error.UnsupportedDeckRecordKind;
                card_count += try importV2Line(allocator, store, id, line, created_at_ms);
            },
            else => return error.UnsupportedDeckVersion,
        }
    }

    return .{
        .deck_id = deck_id orelse return error.MissingDeckHeader,
        .card_count = card_count,
    };
}

test ".deck v1 import works" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const source =
        \\{"kind":"deck","format":"plandalf.deck","version":1,"name":"Legacy"}
        \\{"kind":"card","question":"q","answer":"a"}
    ;
    const result = try importSlice(std.testing.allocator, &store, source, 0);
    try std.testing.expectEqual(@as(usize, 1), result.card_count);
}

test ".deck v2 cloze round trip preserves logical note" {
    var source_db = try storage.Db.open(":memory:");
    defer source_db.close();
    try source_db.migrate();
    var source_store: storage.Store = .{ .sqlite = &source_db };
    const source_deck = try source_store.createDeck("Cloze", 0);
    const fields = [_][]const u8{ "{{c1::Paris}} is in {{c2::France}}", "geo" };
    const created = try @import("card_types.zig").create(std.testing.allocator, &source_store, source_deck, .cloze, &fields, "[]", 0);
    defer created.deinit(std.testing.allocator);

    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try exportDeck(std.testing.allocator, &source_store, source_deck, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"format\":\"plandalf.deck\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"kind\":\"note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"note_type\":\"cloze\"") != null);
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
    try std.testing.expectEqualStrings("cloze", notes[0].note_type);
}
