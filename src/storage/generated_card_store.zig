const std = @import("std");

const content = @import("../content.zig");
const store_mod = @import("store.zig");
const sqlite = @import("sqlite.zig");

const c = sqlite.c;

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
    }
}

pub fn updateNote(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    note_id: content.NoteId,
    fields: []const content.FieldValue,
    tags_json: []const u8,
    updated_at_ms: i64,
) !void {
    _ = allocator;
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
    }
}
