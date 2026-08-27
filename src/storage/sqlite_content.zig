const std = @import("std");
const content = @import("../content.zig");
const sqlite = @import("sqlite.zig");
const c = sqlite.c;

const schema_sql =
    \\CREATE TABLE IF NOT EXISTS note_types (
    \\    id INTEGER PRIMARY KEY,
    \\    slug TEXT NOT NULL UNIQUE,
    \\    name TEXT NOT NULL,
    \\    kind TEXT NOT NULL,
    \\    css TEXT NOT NULL,
    \\    created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS note_type_fields (
    \\    note_type_id INTEGER NOT NULL REFERENCES note_types(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    name TEXT NOT NULL,
    \\    PRIMARY KEY(note_type_id, ordinal),
    \\    UNIQUE(note_type_id, name)
    \\);
    \\CREATE TABLE IF NOT EXISTS card_templates (
    \\    note_type_id INTEGER NOT NULL REFERENCES note_types(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    name TEXT NOT NULL,
    \\    front TEXT NOT NULL,
    \\    back TEXT NOT NULL,
    \\    PRIMARY KEY(note_type_id, ordinal)
    \\);
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id INTEGER PRIMARY KEY,
    \\    note_type_id INTEGER NOT NULL REFERENCES note_types(id),
    \\    tags_json TEXT NOT NULL DEFAULT '[]',
    \\    created_at_ms INTEGER NOT NULL,
    \\    updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS notes_note_type_idx ON notes(note_type_id);
    \\CREATE TABLE IF NOT EXISTS note_fields (
    \\    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    \\    ordinal INTEGER NOT NULL,
    \\    value TEXT NOT NULL,
    \\    PRIMARY KEY(note_id, ordinal)
    \\);
    \\CREATE TABLE IF NOT EXISTS generated_cards (
    \\    card_id INTEGER PRIMARY KEY REFERENCES cards(id) ON DELETE CASCADE,
    \\    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    \\    template_ordinal INTEGER NOT NULL,
    \\    generation_key TEXT NOT NULL UNIQUE
    \\);
    \\CREATE INDEX IF NOT EXISTS generated_cards_note_idx ON generated_cards(note_id, template_ordinal);
;

fn exec(db: *sqlite.Db, sql: [:0]const u8) !void {
    var error_message: [*c]u8 = null;
    const result = c.sqlite3_exec(db.handle, sql.ptr, null, null, &error_message);
    if (error_message != null) c.sqlite3_free(error_message);
    if (result != c.SQLITE_OK) return error.SqliteContentSchemaFailed;
}

fn prepare(db: *sqlite.Db, sql: [:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
        return error.SqlitePrepareFailed;
    }
    return stmt.?;
}

fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindId(stmt: *c.sqlite3_stmt, index: c_int, value: u64) !void {
    try bindInt64(stmt, index, std.math.cast(i64, value) orelse return error.IdOutOfRange);
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn columnTextOwned(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return error.UnexpectedNull;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return allocator.dupe(u8, ptr[0..len]);
}

pub fn ensureSchema(db: *sqlite.Db) !void {
    try exec(db, schema_sql);
}

pub fn ensureBuiltInBasic(db: *sqlite.Db, created_at_ms: i64) !content.NoteTypeId {
    try ensureSchema(db);

    const insert_type = try prepare(
        db,
        "INSERT OR IGNORE INTO note_types(id, slug, name, kind, css, created_at_ms) VALUES (1, 'basic', 'Basic', 'basic', ?1, ?2);",
    );
    defer _ = c.sqlite3_finalize(insert_type);
    try bindText(insert_type, 1, content.basic_note_type.css);
    try bindInt64(insert_type, 2, created_at_ms);
    try stepDone(insert_type);

    for (content.basic_note_type.fields) |field| {
        const stmt = try prepare(
            db,
            "INSERT OR IGNORE INTO note_type_fields(note_type_id, ordinal, name) VALUES (1, ?1, ?2);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, field.ordinal);
        try bindText(stmt, 2, field.name);
        try stepDone(stmt);
    }

    for (content.basic_note_type.templates) |template| {
        const stmt = try prepare(
            db,
            "INSERT OR IGNORE INTO card_templates(note_type_id, ordinal, name, front, back) VALUES (1, ?1, ?2, ?3, ?4);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, template.ordinal);
        try bindText(stmt, 2, template.name);
        try bindText(stmt, 3, template.front);
        try bindText(stmt, 4, template.back);
        try stepDone(stmt);
    }
    return content.basic_note_type.id;
}

fn insertNote(
    db: *sqlite.Db,
    note_type_id: content.NoteTypeId,
    fields: []const content.FieldValue,
    tags_json: []const u8,
    created_at_ms: i64,
) !content.NoteId {
    const stmt = try prepare(
        db,
        "INSERT INTO notes(note_type_id, tags_json, created_at_ms, updated_at_ms) VALUES (?1, ?2, ?3, ?3);",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, note_type_id);
    try bindText(stmt, 2, tags_json);
    try bindInt64(stmt, 3, created_at_ms);
    try stepDone(stmt);
    const note_id: content.NoteId = @intCast(c.sqlite3_last_insert_rowid(db.handle));

    for (fields) |field| {
        const field_stmt = try prepare(
            db,
            "INSERT INTO note_fields(note_id, ordinal, value) VALUES (?1, ?2, ?3);",
        );
        defer _ = c.sqlite3_finalize(field_stmt);
        try bindId(field_stmt, 1, note_id);
        try bindInt64(field_stmt, 2, field.ordinal);
        try bindText(field_stmt, 3, field.value);
        try stepDone(field_stmt);
    }
    return note_id;
}

pub fn createNote(
    db: *sqlite.Db,
    note_type_id: content.NoteTypeId,
    fields: []const content.FieldValue,
    tags_json: []const u8,
    created_at_ms: i64,
) !content.NoteId {
    try ensureSchema(db);
    return insertNote(db, note_type_id, fields, tags_json, created_at_ms);
}

fn linkGeneratedCard(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    card_id: u64,
    note_id: content.NoteId,
    template_ordinal: content.TemplateOrdinal,
) !void {
    const key = try content.generationKey(allocator, note_id, template_ordinal);
    defer allocator.free(key);
    const stmt = try prepare(
        db,
        "INSERT INTO generated_cards(card_id, note_id, template_ordinal, generation_key) VALUES (?1, ?2, ?3, ?4);",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, card_id);
    try bindId(stmt, 2, note_id);
    try bindInt64(stmt, 3, template_ordinal);
    try bindText(stmt, 4, key);
    try stepDone(stmt);
}

pub fn createBasicNote(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    deck_id: u64,
    front: []const u8,
    back: []const u8,
    tags_json: []const u8,
    created_at_ms: i64,
) !content.CreatedNote {
    try content.requireText(front);
    try content.requireText(back);
    _ = try ensureBuiltInBasic(db, created_at_ms);

    try db.beginImmediate();
    errdefer db.rollback();
    const values = [_]content.FieldValue{
        .{ .ordinal = 0, .value = front },
        .{ .ordinal = 1, .value = back },
    };
    const note_id = try insertNote(db, content.basic_note_type.id, &values, tags_json, created_at_ms);
    const card_id = try db.createCard(deck_id, front, back, created_at_ms);
    try linkGeneratedCard(allocator, db, card_id, note_id, 0);
    try db.commit();

    const ids = try allocator.alloc(u64, 1);
    ids[0] = card_id;
    return .{ .note_id = note_id, .card_ids = ids };
}

fn existingNoteForCard(db: *sqlite.Db, card_id: u64) !?content.NoteId {
    const stmt = try prepare(db, "SELECT note_id FROM generated_cards WHERE card_id = ?1;");
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, card_id);
    const result = c.sqlite3_step(stmt);
    if (result == c.SQLITE_DONE) return null;
    if (result != c.SQLITE_ROW) return error.SqliteStepFailed;
    return @intCast(c.sqlite3_column_int64(stmt, 0));
}

/// Adopt a v0.1.x question/answer card into Content Model v2 without replacing
/// its card ID. Review history therefore keeps pointing at the same card.
pub fn adoptLegacyCard(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    card_id: u64,
    adopted_at_ms: i64,
) !content.NoteId {
    _ = try ensureBuiltInBasic(db, adopted_at_ms);
    if (try existingNoteForCard(db, card_id)) |note_id| return note_id;

    const card = (try db.getCard(allocator, card_id)) orelse return error.CardNotFound;
    defer card.deinit(allocator);

    try db.beginImmediate();
    errdefer db.rollback();
    const values = [_]content.FieldValue{
        .{ .ordinal = 0, .value = card.question },
        .{ .ordinal = 1, .value = card.answer },
    };
    const note_id = try insertNote(db, content.basic_note_type.id, &values, "[]", adopted_at_ms);
    try linkGeneratedCard(allocator, db, card_id, note_id, 0);
    try db.commit();
    return note_id;
}

pub fn getNote(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    note_id: content.NoteId,
) !?content.OwnedNote {
    try ensureSchema(db);
    const stmt = try prepare(
        db,
        "SELECT note_type_id, tags_json, created_at_ms, updated_at_ms FROM notes WHERE id = ?1;",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, note_id);
    const result = c.sqlite3_step(stmt);
    if (result == c.SQLITE_DONE) return null;
    if (result != c.SQLITE_ROW) return error.SqliteStepFailed;

    const tags_json = try columnTextOwned(allocator, stmt, 1);
    errdefer allocator.free(tags_json);

    const field_stmt = try prepare(
        db,
        "SELECT ordinal, value FROM note_fields WHERE note_id = ?1 ORDER BY ordinal;",
    );
    defer _ = c.sqlite3_finalize(field_stmt);
    try bindId(field_stmt, 1, note_id);

    var fields: std.ArrayList(content.OwnedFieldValue) = .empty;
    errdefer {
        for (fields.items) |field| field.deinit(allocator);
        fields.deinit(allocator);
    }
    while (true) {
        const field_result = c.sqlite3_step(field_stmt);
        if (field_result == c.SQLITE_DONE) break;
        if (field_result != c.SQLITE_ROW) return error.SqliteStepFailed;
        try fields.append(allocator, .{
            .ordinal = @intCast(c.sqlite3_column_int64(field_stmt, 0)),
            .value = try columnTextOwned(allocator, field_stmt, 1),
        });
    }

    return .{
        .id = note_id,
        .note_type_id = @intCast(c.sqlite3_column_int64(stmt, 0)),
        .tags_json = tags_json,
        .fields = try fields.toOwnedSlice(allocator),
        .created_at_ms = c.sqlite3_column_int64(stmt, 2),
        .updated_at_ms = c.sqlite3_column_int64(stmt, 3),
    };
}

pub fn cardSource(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    card_id: u64,
) !?content.GeneratedCardSource {
    try ensureSchema(db);
    const stmt = try prepare(
        db,
        "SELECT note_id, template_ordinal, generation_key FROM generated_cards WHERE card_id = ?1;",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, card_id);
    const result = c.sqlite3_step(stmt);
    if (result == c.SQLITE_DONE) return null;
    if (result != c.SQLITE_ROW) return error.SqliteStepFailed;
    return .{
        .note_id = @intCast(c.sqlite3_column_int64(stmt, 0)),
        .template_ordinal = @intCast(c.sqlite3_column_int64(stmt, 1)),
        .generation_key = try columnTextOwned(allocator, stmt, 2),
    };
}

test "legacy card adoption preserves the card identity" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const deck_id = try db.createDeck("legacy", 0);
    const card_id = try db.createCard(deck_id, "front", "back", 0);

    const note_id = try adoptLegacyCard(std.testing.allocator, &db, card_id, 10);
    const source = (try cardSource(std.testing.allocator, &db, card_id)).?;
    defer source.deinit(std.testing.allocator);
    try std.testing.expectEqual(note_id, source.note_id);
    try std.testing.expectEqualStrings("note:1:template:0", source.generation_key);

    const card = (try db.getCard(std.testing.allocator, card_id)).?;
    defer card.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("front", card.question);
    try std.testing.expectEqualStrings("back", card.answer);
}

test "Basic note creates a linked generated card" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const deck_id = try db.createDeck("basic", 0);

    const created = try createBasicNote(std.testing.allocator, &db, deck_id, "Q", "A", "[]", 0);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), created.card_ids.len);

    const note = (try getNote(std.testing.allocator, &db, created.note_id)).?;
    defer note.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), note.fields.len);
    try std.testing.expectEqualStrings("Q", note.fields[0].value);
}
