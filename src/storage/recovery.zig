const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const sqlite = @import("sqlite.zig");

pub const IntegrityResult = struct {
    ok: bool,
    message: []u8,

    pub fn deinit(self: IntegrityResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// Run SQLite's full integrity check without mutating the database.
pub fn check(
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
) !IntegrityResult {
    var stmt: ?*c.sqlite3_stmt = null;
    const handle: ?*c.sqlite3 = @ptrCast(db.handle);
    const sql = "PRAGMA integrity_check;";
    if (c.sqlite3_prepare_v2(handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK or stmt == null) {
        return error.SqlitePrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt.?);

    if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return error.SqliteStepFailed;
    const text = c.sqlite3_column_text(stmt.?, 0) orelse return error.UnexpectedNull;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 0));
    const message = try allocator.dupe(u8, text[0..len]);
    return .{
        .ok = std.mem.eql(u8, message, "ok"),
        .message = message,
    };
}

test "fresh migrated SQLite database passes integrity check" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();

    const result = try check(std.testing.allocator, &db);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.ok);
    try std.testing.expectEqualStrings("ok", result.message);
}
