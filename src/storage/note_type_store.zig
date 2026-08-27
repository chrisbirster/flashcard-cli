const std = @import("std");
const bongo = @import("bongo");

const content = @import("../content.zig");
const store_mod = @import("store.zig");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;

fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn prepare(db: *sqlite.Db, sql: [:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) return error.SqlitePrepareFailed;
    return stmt.?;
}

fn noteKindText(kind: content.NoteKind) []const u8 {
    return switch (kind) {
        .basic => "basic",
        .custom => "custom",
        .cloze => "cloze",
    };
}

fn ensureSqlite(db: *sqlite.Db, definition: content.NoteTypeDefinition, created_at_ms: i64) !void {
    try content.validateNoteType(definition);
    const type_stmt = try prepare(
        db,
        "INSERT OR IGNORE INTO note_types(id, slug, name, kind, css, created_at_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
    );
    defer _ = c.sqlite3_finalize(type_stmt);
    try bindInt64(type_stmt, 1, @intCast(definition.id));
    try bindText(type_stmt, 2, definition.slug);
    try bindText(type_stmt, 3, definition.name);
    try bindText(type_stmt, 4, noteKindText(definition.kind));
    try bindText(type_stmt, 5, definition.css);
    try bindInt64(type_stmt, 6, created_at_ms);
    if (c.sqlite3_step(type_stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;

    for (definition.fields) |field| {
        const stmt = try prepare(
            db,
            "INSERT OR REPLACE INTO note_type_fields(note_type_id, ordinal, name) VALUES (?1, ?2, ?3);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, @intCast(definition.id));
        try bindInt64(stmt, 2, @intCast(field.ordinal));
        try bindText(stmt, 3, field.name);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    }
    for (definition.templates) |template| {
        const stmt = try prepare(
            db,
            "INSERT OR REPLACE INTO card_templates(note_type_id, ordinal, name, front, back) VALUES (?1, ?2, ?3, ?4, ?5);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, @intCast(definition.id));
        try bindInt64(stmt, 2, @intCast(template.ordinal));
        try bindText(stmt, 3, template.name);
        try bindText(stmt, 4, template.front);
        try bindText(stmt, 5, template.back);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    }
}

fn fieldsJson(allocator: std.mem.Allocator, fields: []const content.FieldDefinition) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(fields, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn templatesJson(allocator: std.mem.Allocator, templates: []const content.CardTemplate) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(templates, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn ensureMongo(
    allocator: std.mem.Allocator,
    mongo: anytype,
    definition: content.NoteTypeDefinition,
    created_at_ms: i64,
) !void {
    try content.validateNoteType(definition);
    const db_name = mongo.client.databaseName();
    var existing = try mongo.client.findOne(db_name, "note_types", .{ ._id = @as(i64, @intCast(definition.id)) });
    if (existing) |*document| {
        document.deinit();
        return;
    }
    const fields_json = try fieldsJson(allocator, definition.fields);
    defer allocator.free(fields_json);
    const templates_json = try templatesJson(allocator, definition.templates);
    defer allocator.free(templates_json);
    _ = try mongo.client.insertOne(db_name, "note_types", .{
        ._id = @as(i64, @intCast(definition.id)),
        .slug = definition.slug,
        .name = definition.name,
        .kind = noteKindText(definition.kind),
        .css = definition.css,
        .fields_json = fields_json,
        .templates_json = templates_json,
        .created_at_ms = created_at_ms,
    });
}

pub fn ensure(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    definition: content.NoteTypeDefinition,
    created_at_ms: i64,
) !void {
    switch (store.*) {
        .sqlite => |db| try ensureSqlite(db, definition, created_at_ms),
        .mongodb => |*mongo| try ensureMongo(allocator, mongo, definition, created_at_ms),
    }
}

pub fn ensureBuiltIns(allocator: std.mem.Allocator, store: *store_mod.Store, created_at_ms: i64) !void {
    for (content.built_in_note_types) |definition| try ensure(allocator, store, definition, created_at_ms);
}
