const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const card_mod = @import("../card.zig");
const sqlite = @import("sqlite.zig");
const time = @import("../time.zig");

pub const HistoricalStats = struct {
    review_count: usize = 0,
    unique_cards: usize = 0,
    new_cards: usize = 0,
    again: usize = 0,
    hard: usize = 0,
    good: usize = 0,
    easy: usize = 0,
    days_studied: usize = 0,
    current_streak_days: usize = 0,
    longest_streak_days: usize = 0,

    pub fn recalled(self: HistoricalStats) usize {
        return self.hard + self.good + self.easy;
    }

    pub fn observedRetention(self: HistoricalStats) f64 {
        if (self.review_count == 0) return 0;
        return @as(f64, @floatFromInt(self.recalled())) / @as(f64, @floatFromInt(self.review_count));
    }
};

pub const HistoryReport = struct {
    db: *sqlite.Db,

    fn dbHandle(self: HistoryReport) ?*c.sqlite3 {
        return @ptrCast(self.db.handle);
    }

    fn prepare(self: HistoryReport, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.dbHandle(), sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
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

    fn collectDays(
        self: HistoryReport,
        allocator: std.mem.Allocator,
        deck_id: ?card_mod.DeckId,
        start_ms: ?time.TimestampMs,
        end_ms_exclusive: time.TimestampMs,
    ) ![]i64 {
        const sql = if (deck_id == null)
            "SELECT DISTINCT CAST(reviewed_at_ms / 86400000 AS INTEGER) FROM reviews WHERE reviewed_at_ms >= ?1 AND reviewed_at_ms < ?2 ORDER BY 1;"
        else
            "SELECT DISTINCT CAST(r.reviewed_at_ms / 86400000 AS INTEGER) FROM reviews r JOIN cards c ON c.id = r.card_id WHERE c.deck_id = ?3 AND r.reviewed_at_ms >= ?1 AND r.reviewed_at_ms < ?2 ORDER BY 1;";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, start_ms orelse std.math.minInt(i64));
        try bindInt64(stmt, 2, end_ms_exclusive);
        if (deck_id) |id| try bindId(stmt, 3, id);

        var days: std.ArrayList(i64) = .empty;
        errdefer days.deinit(allocator);
        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => try days.append(allocator, c.sqlite3_column_int64(stmt, 0)),
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
        }
        return days.toOwnedSlice(allocator);
    }

    fn streaks(days: []const i64, today: i64) struct { current: usize, longest: usize } {
        if (days.len == 0) return .{ .current = 0, .longest = 0 };

        var longest: usize = 1;
        var run: usize = 1;
        var index: usize = 1;
        while (index < days.len) : (index += 1) {
            if (days[index] == days[index - 1] + 1) {
                run += 1;
                longest = @max(longest, run);
            } else {
                run = 1;
            }
        }

        var current: usize = 0;
        const last = days[days.len - 1];
        if (last == today or last == today - 1) {
            current = 1;
            var cursor = days.len - 1;
            while (cursor > 0 and days[cursor - 1] == days[cursor] - 1) {
                current += 1;
                cursor -= 1;
            }
        }
        return .{ .current = current, .longest = longest };
    }

    pub fn historical(
        self: HistoryReport,
        allocator: std.mem.Allocator,
        deck_id: ?card_mod.DeckId,
        start_ms: ?time.TimestampMs,
        end_ms_exclusive: time.TimestampMs,
    ) !HistoricalStats {
        const sql = if (deck_id == null)
            "SELECT COUNT(*), COUNT(DISTINCT r.card_id), SUM(CASE WHEN r.rating=1 THEN 1 ELSE 0 END), SUM(CASE WHEN r.rating=2 THEN 1 ELSE 0 END), SUM(CASE WHEN r.rating=3 THEN 1 ELSE 0 END), SUM(CASE WHEN r.rating=4 THEN 1 ELSE 0 END), SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM reviews prior WHERE prior.card_id=r.card_id AND (prior.reviewed_at_ms < r.reviewed_at_ms OR (prior.reviewed_at_ms = r.reviewed_at_ms AND prior.id < r.id))) THEN 1 ELSE 0 END) FROM reviews r WHERE r.reviewed_at_ms >= ?1 AND r.reviewed_at_ms < ?2;"
        else
            "SELECT COUNT(*), COUNT(DISTINCT r.card_id), SUM(CASE WHEN r.rating=1 THEN 1 ELSE 0 END), SUM(CASE WHEN r.rating=2 THEN 1 ELSE 0 END), SUM(CASE WHEN r.rating=3 THEN 1 ELSE 0 END), SUM(CASE WHEN r.rating=4 THEN 1 ELSE 0 END), SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM reviews prior WHERE prior.card_id=r.card_id AND (prior.reviewed_at_ms < r.reviewed_at_ms OR (prior.reviewed_at_ms = r.reviewed_at_ms AND prior.id < r.id))) THEN 1 ELSE 0 END) FROM reviews r JOIN cards c ON c.id=r.card_id WHERE c.deck_id=?3 AND r.reviewed_at_ms >= ?1 AND r.reviewed_at_ms < ?2;";
        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, start_ms orelse std.math.minInt(i64));
        try bindInt64(stmt, 2, end_ms_exclusive);
        if (deck_id) |id| try bindId(stmt, 3, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteStepFailed;

        var result: HistoricalStats = .{
            .review_count = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .unique_cards = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .again = @intCast(c.sqlite3_column_int64(stmt, 2)),
            .hard = @intCast(c.sqlite3_column_int64(stmt, 3)),
            .good = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .easy = @intCast(c.sqlite3_column_int64(stmt, 5)),
            .new_cards = @intCast(c.sqlite3_column_int64(stmt, 6)),
        };

        const days = try self.collectDays(allocator, deck_id, start_ms, end_ms_exclusive);
        defer allocator.free(days);
        result.days_studied = days.len;
        const today = @divFloor(end_ms_exclusive - 1, time.milliseconds_per_day);
        const calculated = streaks(days, today);
        result.current_streak_days = calculated.current;
        result.longest_streak_days = calculated.longest;
        return result;
    }
};

test "historical stats preserve rating counts and streaks" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const deck_id = try db.createDeck("history", 0);
    const card_a = try db.createCard(deck_id, "a", "a", 0);
    const card_b = try db.createCard(deck_id, "b", "b", 0);
    const day = time.milliseconds_per_day;

    try db.appendReview(card_a, .good, day, .{ .algorithm = .fsrs7, .implementation = .current, .parameter_set_id = [_]u8{0} ** 32 }, day * 2);
    try db.appendReview(card_b, .again, day * 2, .{ .algorithm = .fsrs7, .implementation = .current, .parameter_set_id = [_]u8{0} ** 32 }, day * 3);
    try db.appendReview(card_a, .easy, day * 2, .{ .algorithm = .fsrs7, .implementation = .current, .parameter_set_id = [_]u8{0} ** 32 }, day * 4);

    const report: HistoryReport = .{ .db = &db };
    const result = try report.historical(std.testing.allocator, deck_id, null, day * 3);
    try std.testing.expectEqual(@as(usize, 3), result.review_count);
    try std.testing.expectEqual(@as(usize, 2), result.unique_cards);
    try std.testing.expectEqual(@as(usize, 2), result.new_cards);
    try std.testing.expectEqual(@as(usize, 1), result.again);
    try std.testing.expectEqual(@as(usize, 1), result.good);
    try std.testing.expectEqual(@as(usize, 1), result.easy);
    try std.testing.expectEqual(@as(usize, 2), result.days_studied);
    try std.testing.expectEqual(@as(usize, 2), result.longest_streak_days);
}
