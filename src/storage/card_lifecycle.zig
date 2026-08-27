const std = @import("std");
const bongo = @import("bongo");

const card_mod = @import("../card.zig");
const sqlite = @import("sqlite.zig");
const mongodb = @import("mongodb.zig");

const c = sqlite.c;
const q = bongo.query;

fn ensureSqliteSchema(db: *sqlite.Db) !void {
    const sql =
        "CREATE TABLE IF NOT EXISTS retired_cards (" ++
        "card_id INTEGER PRIMARY KEY REFERENCES cards(id) ON DELETE CASCADE," ++
        "retired_at_ms INTEGER NOT NULL" ++
        ");";
    var error_message: [*c]u8 = null;
    const result = c.sqlite3_exec(db.handle, sql.ptr, null, null, &error_message);
    if (error_message != null) c.sqlite3_free(error_message);
    if (result != c.SQLITE_OK) return error.SqliteCardLifecycleSchemaFailed;
}

fn prepare(db: *sqlite.Db, sql: [:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
        return error.SqlitePrepareFailed;
    }
    return stmt.?;
}

fn bindId(stmt: *c.sqlite3_stmt, index: c_int, id: card_mod.CardId) !void {
    const signed = std.math.cast(i64, id) orelse return error.IdOutOfRange;
    if (c.sqlite3_bind_int64(stmt, index, signed) != c.SQLITE_OK) return error.SqliteBindFailed;
}

pub fn sqliteRetire(db: *sqlite.Db, card_id: card_mod.CardId, retired_at_ms: i64) !void {
    try ensureSqliteSchema(db);
    const stmt = try prepare(
        db,
        "INSERT INTO retired_cards(card_id, retired_at_ms) VALUES (?1, ?2) ON CONFLICT(card_id) DO UPDATE SET retired_at_ms = excluded.retired_at_ms;",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, card_id);
    if (c.sqlite3_bind_int64(stmt, 2, retired_at_ms) != c.SQLITE_OK) return error.SqliteBindFailed;
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

pub fn sqliteRestore(db: *sqlite.Db, card_id: card_mod.CardId) !void {
    try ensureSqliteSchema(db);
    const stmt = try prepare(db, "DELETE FROM retired_cards WHERE card_id = ?1;");
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, card_id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

pub fn sqliteIsRetired(db: *sqlite.Db, card_id: card_mod.CardId) !bool {
    try ensureSqliteSchema(db);
    const stmt = try prepare(db, "SELECT 1 FROM retired_cards WHERE card_id = ?1 LIMIT 1;");
    defer _ = c.sqlite3_finalize(stmt);
    try bindId(stmt, 1, card_id);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.SqliteStepFailed,
    };
}

fn mongoId(card_id: card_mod.CardId) !i64 {
    return std.math.cast(i64, card_id) orelse error.IdOutOfRange;
}

pub fn mongoRetire(store: *mongodb.Store, card_id: card_mod.CardId, retired_at_ms: i64) !void {
    const id = try mongoId(card_id);
    var result = try store.client.updateOne(
        store.client.databaseName(),
        "retired_cards",
        .{ ._id = id },
        q.set(.{ .retired_at_ms = retired_at_ms }),
        true,
    );
    defer result.deinit();
}

pub fn mongoRestore(store: *mongodb.Store, card_id: card_mod.CardId) !void {
    _ = try store.client.deleteOne(
        store.client.databaseName(),
        "retired_cards",
        .{ ._id = try mongoId(card_id) },
    );
}

pub fn mongoIsRetired(store: *mongodb.Store, card_id: card_mod.CardId) !bool {
    var owned = (try store.client.findOne(
        store.client.databaseName(),
        "retired_cards",
        .{ ._id = try mongoId(card_id) },
    )) orelse return false;
    defer owned.deinit();
    return true;
}

test "SQLite retirement is reversible without deleting the card" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const deck_id = try db.createDeck("retirement", 0);
    const card_id = try db.createCard(deck_id, "q", "a", 0);

    try std.testing.expect(!try sqliteIsRetired(&db, card_id));
    try sqliteRetire(&db, card_id, 10);
    try std.testing.expect(try sqliteIsRetired(&db, card_id));
    const card = (try db.getCard(std.testing.allocator, card_id)).?;
    defer card.deinit(std.testing.allocator);
    try std.testing.expectEqual(card_id, card.id);
    try sqliteRestore(&db, card_id);
    try std.testing.expect(!try sqliteIsRetired(&db, card_id));
}
