const std = @import("std");
const bongo = @import("bongo");

const content = @import("../content.zig");
const store_mod = @import("store.zig");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;
const q = bongo.query;

fn prepare(db: *sqlite.Db, sql: [:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) return error.SqlitePrepareFailed;
    return stmt.?;
}

fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn requiredI64(document: []const u8, field: []const u8) !i64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| v,
        else => error.InvalidField,
    };
}

pub fn link(
    store: *store_mod.Store,
    card_id: u64,
    note_id: content.NoteId,
    template_ordinal: content.TemplateOrdinal,
    generation_key: []const u8,
) !void {
    switch (store.*) {
        .sqlite => |db| {
            const stmt = try prepare(
                db,
                "INSERT INTO generated_cards(card_id, note_id, template_ordinal, generation_key) VALUES (?1, ?2, ?3, ?4);",
            );
            defer _ = c.sqlite3_finalize(stmt);
            try bindInt64(stmt, 1, @intCast(card_id));
            try bindInt64(stmt, 2, @intCast(note_id));
            try bindInt64(stmt, 3, @intCast(template_ordinal));
            try bindText(stmt, 4, generation_key);
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
        },
        .mongodb => |*mongo| {
            _ = try mongo.client.insertOne(mongo.client.databaseName(), "generated_cards", .{
                ._id = @as(i64, @intCast(card_id)),
                .note_id = @as(i64, @intCast(note_id)),
                .template_ordinal = @as(i32, @intCast(template_ordinal)),
                .generation_key = generation_key,
            });
        },
    }
}

pub fn unlink(store: *store_mod.Store, card_id: u64) !void {
    switch (store.*) {
        .sqlite => |db| {
            const stmt = try prepare(db, "DELETE FROM generated_cards WHERE card_id = ?1;");
            defer _ = c.sqlite3_finalize(stmt);
            try bindInt64(stmt, 1, @intCast(card_id));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
        },
        .mongodb => |*mongo| {
            _ = try mongo.client.deleteOne(
                mongo.client.databaseName(),
                "generated_cards",
                .{ ._id = @as(i64, @intCast(card_id)) },
            );
        },
    }
}

pub fn cardIdForKey(store: *store_mod.Store, generation_key: []const u8) !?u64 {
    return switch (store.*) {
        .sqlite => |db| blk: {
            const stmt = try prepare(db, "SELECT card_id FROM generated_cards WHERE generation_key = ?1;");
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, generation_key);
            const result = c.sqlite3_step(stmt);
            if (result == c.SQLITE_DONE) break :blk null;
            if (result != c.SQLITE_ROW) return error.SqliteStepFailed;
            break :blk @intCast(c.sqlite3_column_int64(stmt, 0));
        },
        .mongodb => |*mongo| blk: {
            var owned = (try mongo.client.findOne(
                mongo.client.databaseName(),
                "generated_cards",
                .{ .generation_key = generation_key },
            )) orelse break :blk null;
            defer owned.deinit();
            const value = (try bongo.bson.Reader.get(owned.bytes, "_id")) orelse return error.MissingField;
            break :blk switch (value) {
                .int32 => |v| @intCast(v),
                .int64 => |v| @intCast(v),
                else => error.InvalidField,
            };
        },
    };
}

pub fn cardIdsForNote(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    note_id: content.NoteId,
) ![]u64 {
    switch (store.*) {
        .sqlite => |db| {
            const stmt = try prepare(db, "SELECT card_id FROM generated_cards WHERE note_id = ?1 ORDER BY card_id;");
            defer _ = c.sqlite3_finalize(stmt);
            try bindInt64(stmt, 1, @intCast(note_id));

            var ids: std.ArrayList(u64) = .empty;
            errdefer ids.deinit(allocator);
            while (true) {
                const result = c.sqlite3_step(stmt);
                if (result == c.SQLITE_DONE) break;
                if (result != c.SQLITE_ROW) return error.SqliteStepFailed;
                try ids.append(allocator, @intCast(c.sqlite3_column_int64(stmt, 0)));
            }
            return ids.toOwnedSlice(allocator);
        },
        .mongodb => |*mongo| {
            var cursor = try mongo.client.find(
                mongo.client.databaseName(),
                "generated_cards",
                .{ .note_id = @as(i64, @intCast(note_id)) },
                .{ .sort = .{ ._id = @as(i32, 1) } },
            );
            defer cursor.deinit();

            var ids: std.ArrayList(u64) = .empty;
            errdefer ids.deinit(allocator);
            while (try cursor.next()) |document| {
                try ids.append(allocator, @intCast(try requiredI64(document, "_id")));
            }
            return ids.toOwnedSlice(allocator);
        },
    }
}

fn fieldsJson(allocator: std.mem.Allocator, fields: []const content.FieldValue) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(fields, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn updateNote(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    note_id: content.NoteId,
    fields: []const content.FieldValue,
    tags_json: []const u8,
    updated_at_ms: i64,
) !void {
    switch (store.*) {
        .sqlite => |db| {
            try db.beginImmediate();
            errdefer db.rollback();
            const delete_stmt = try prepare(db, "DELETE FROM note_fields WHERE note_id = ?1;");
            defer _ = c.sqlite3_finalize(delete_stmt);
            try bindInt64(delete_stmt, 1, @intCast(note_id));
            if (c.sqlite3_step(delete_stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
            for (fields) |field| {
                const stmt = try prepare(
                    db,
                    "INSERT INTO note_fields(note_id, ordinal, value) VALUES (?1, ?2, ?3);",
                );
                defer _ = c.sqlite3_finalize(stmt);
                try bindInt64(stmt, 1, @intCast(note_id));
                try bindInt64(stmt, 2, @intCast(field.ordinal));
                try bindText(stmt, 3, field.value);
                if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
            }
            const update_stmt = try prepare(db, "UPDATE notes SET tags_json = ?1, updated_at_ms = ?2 WHERE id = ?3;");
            defer _ = c.sqlite3_finalize(update_stmt);
            try bindText(update_stmt, 1, tags_json);
            try bindInt64(update_stmt, 2, updated_at_ms);
            try bindInt64(update_stmt, 3, @intCast(note_id));
            if (c.sqlite3_step(update_stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
            try db.commit();
        },
        .mongodb => |*mongo| {
            const fields_json = try fieldsJson(allocator, fields);
            defer allocator.free(fields_json);
            var result = try mongo.client.updateOne(
                mongo.client.databaseName(),
                "notes",
                .{ ._id = @as(i64, @intCast(note_id)) },
                q.set(.{
                    .fields_json = fields_json,
                    .tags_json = tags_json,
                    .updated_at_ms = updated_at_ms,
                }),
                false,
            );
            defer result.deinit();
        },
    }
}

/// Remove logical-note and generated-card metadata without deleting physical
/// cards. Callers must retire the note's cards first so immutable review and
/// scheduler history remain preserved but the cards disappear from study.
pub fn deleteNote(store: *store_mod.Store, note_id: content.NoteId) !void {
    switch (store.*) {
        .sqlite => |db| {
            const stmt = try prepare(db, "DELETE FROM notes WHERE id = ?1;");
            defer _ = c.sqlite3_finalize(stmt);
            try bindInt64(stmt, 1, @intCast(note_id));
            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
        },
        .mongodb => |*mongo| {
            var cursor = try mongo.client.find(
                mongo.client.databaseName(),
                "generated_cards",
                .{ .note_id = @as(i64, @intCast(note_id)) },
                .{ .sort = .{ ._id = @as(i32, 1) } },
            );
            defer cursor.deinit();
            while (try cursor.next()) |document| {
                const card_id = try requiredI64(document, "_id");
                _ = try mongo.client.deleteOne(
                    mongo.client.databaseName(),
                    "generated_cards",
                    .{ ._id = card_id },
                );
            }
            _ = try mongo.client.deleteOne(
                mongo.client.databaseName(),
                "notes",
                .{ ._id = @as(i64, @intCast(note_id)) },
            );
        },
    }
}
