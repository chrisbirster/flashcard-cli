const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const sqlite = @import("sqlite.zig");

fn handle(db: *sqlite.Db) ?*c.sqlite3 {
    return @ptrCast(db.handle);
}

pub fn copy(source: *sqlite.Db, destination: *sqlite.Db) !void {
    const backup = c.sqlite3_backup_init(handle(destination), "main", handle(source), "main") orelse return error.SqliteBackupInitFailed;
    defer _ = c.sqlite3_backup_finish(backup);

    const result = c.sqlite3_backup_step(backup, -1);
    if (result != c.SQLITE_DONE) return error.SqliteBackupFailed;
}

pub fn backupTo(source: *sqlite.Db, path: [:0]const u8) !void {
    var destination = try sqlite.Db.open(path);
    defer destination.close();
    try copy(source, &destination);
}

pub fn restoreFrom(destination: *sqlite.Db, path: [:0]const u8) !void {
    var source = try sqlite.Db.open(path);
    defer source.close();
    try copy(&source, destination);
}

test "SQLite backup preserves study data" {
    var source = try sqlite.Db.open(":memory:");
    defer source.close();
    try source.migrate();
    const deck_id = try source.createDeck("bson", 1);
    _ = try source.createCard(deck_id, "What is BSON?", "Binary JSON", 2);

    var destination = try sqlite.Db.open(":memory:");
    defer destination.close();
    try copy(&source, &destination);

    const copied = (try destination.getDeck(std.testing.allocator, deck_id)).?;
    defer copied.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bson", copied.name);
}
