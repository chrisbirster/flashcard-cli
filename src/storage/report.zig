const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const card_mod = @import("../card.zig");
const fsrs = @import("../fsrs/root.zig");
const sqlite = @import("sqlite.zig");
const time = @import("../time.zig");

pub const DeckSummary = struct {
    id: card_mod.DeckId,
    name: []u8,
    card_count: usize,
    due_count: usize,

    pub fn deinit(self: DeckSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Stats = struct {
    deck_count: usize,
    card_count: usize,
    due_count: usize,
    review_count: usize,
};

pub const OwnedHistories = struct {
    histories: [][]fsrs.HistoryEntry,

    pub fn deinit(self: OwnedHistories, allocator: std.mem.Allocator) void {
        for (self.histories) |history| allocator.free(history);
        allocator.free(self.histories);
    }
};

pub const Report = struct {
    db: *sqlite.Db,

    fn prepare(self: Report, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const db_handle: ?*c.sqlite3 = @ptrCast(self.db.handle);
        if (c.sqlite3_prepare_v2(db_handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
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

    fn columnTextOwned(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]u8 {
        const ptr = c.sqlite3_column_text(stmt, column) orelse return error.UnexpectedNull;
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
        return allocator.dupe(u8, ptr[0..len]);
    }

    pub fn decks(self: Report, allocator: std.mem.Allocator, now_ms: time.TimestampMs) ![]DeckSummary {
        const stmt = try self.prepare(
            "SELECT d.id, d.name, COUNT(c.id), SUM(CASE WHEN c.id IS NOT NULL AND (s.card_id IS NULL OR s.due_at_ms <= ?1) THEN 1 ELSE 0 END) FROM decks d LEFT JOIN cards c ON c.deck_id = d.id LEFT JOIN scheduler_state s ON s.card_id = c.id GROUP BY d.id, d.name ORDER BY d.name, d.id;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, now_ms);

        var result: std.ArrayList(DeckSummary) = .empty;
        errdefer {
            for (result.items) |deck| deck.deinit(allocator);
            result.deinit(allocator);
        }
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => {
                    const name = try columnTextOwned(allocator, stmt, 1);
                    errdefer allocator.free(name);
                    try result.append(allocator, .{
                        .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
                        .name = name,
                        .card_count = @intCast(c.sqlite3_column_int64(stmt, 2)),
                        .due_count = @intCast(c.sqlite3_column_int64(stmt, 3)),
                    });
                },
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn stats(self: Report, now_ms: time.TimestampMs, deck_id: ?card_mod.DeckId) !Stats {
        const sql = if (deck_id == null)
            "SELECT (SELECT COUNT(*) FROM decks), (SELECT COUNT(*) FROM cards), (SELECT COUNT(*) FROM cards c LEFT JOIN scheduler_state s ON s.card_id = c.id WHERE s.card_id IS NULL OR s.due_at_ms <= ?1), (SELECT COUNT(*) FROM reviews);"
        else
            "SELECT 1, (SELECT COUNT(*) FROM cards WHERE deck_id = ?2), (SELECT COUNT(*) FROM cards c LEFT JOIN scheduler_state s ON s.card_id = c.id WHERE c.deck_id = ?2 AND (s.card_id IS NULL OR s.due_at_ms <= ?1)), (SELECT COUNT(*) FROM reviews r JOIN cards c ON c.id = r.card_id WHERE c.deck_id = ?2);";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, now_ms);
        if (deck_id) |id| try bindId(stmt, 2, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteStepFailed;
        return .{
            .deck_count = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .card_count = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .due_count = @intCast(c.sqlite3_column_int64(stmt, 2)),
            .review_count = @intCast(c.sqlite3_column_int64(stmt, 3)),
        };
    }

    pub fn histories(self: Report, allocator: std.mem.Allocator, deck_id: ?card_mod.DeckId) !OwnedHistories {
        const sql = if (deck_id == null)
            "SELECT id FROM cards ORDER BY id;"
        else
            "SELECT id FROM cards WHERE deck_id = ?1 ORDER BY id;";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        if (deck_id) |id| try bindId(stmt, 1, id);

        var result: std.ArrayList([]fsrs.HistoryEntry) = .empty;
        errdefer {
            for (result.items) |history| allocator.free(history);
            result.deinit(allocator);
        }
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => {
                    const card_id: card_mod.CardId = @intCast(c.sqlite3_column_int64(stmt, 0));
                    const history = try self.db.loadHistory(allocator, card_id);
                    errdefer allocator.free(history);
                    if (history.len > 0) {
                        try result.append(allocator, history);
                    } else allocator.free(history);
                },
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
        }
        return .{ .histories = try result.toOwnedSlice(allocator) };
    }
};

test "report exposes deck counts and due counts" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const deck_id = try db.createDeck("bson", 0);
    _ = try db.createCard(deck_id, "q", "a", 0);
    const report: Report = .{ .db = &db };
    const decks = try report.decks(std.testing.allocator, 0);
    defer {
        for (decks) |deck| deck.deinit(std.testing.allocator);
        std.testing.allocator.free(decks);
    }
    try std.testing.expectEqual(@as(usize, 1), decks.len);
    try std.testing.expectEqual(@as(usize, 1), decks[0].due_count);
    const counts = try report.stats(0, null);
    try std.testing.expectEqual(@as(usize, 1), counts.deck_count);
    try std.testing.expectEqual(@as(usize, 1), counts.card_count);
}
