const std = @import("std");
pub const c = @cImport({
    @cInclude("sqlite3.h");
});

const card_mod = @import("../card.zig");
const fsrs = @import("../fsrs/root.zig");
const schema = @import("schema.zig");
const time = @import("../time.zig");

pub const OwnedDeck = struct {
    id: card_mod.DeckId,
    name: []u8,
    algorithm: fsrs.AlgorithmId,
    parameter_set_id: ?fsrs.ParameterSetId,

    pub fn deinit(self: OwnedDeck, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const OwnedCard = struct {
    id: card_mod.CardId,
    deck_id: card_mod.DeckId,
    question: []u8,
    answer: []u8,

    pub fn deinit(self: OwnedCard, allocator: std.mem.Allocator) void {
        allocator.free(self.question);
        allocator.free(self.answer);
    }
};

pub const ParameterSetRecord = struct {
    identity: fsrs.ParameterSetIdentity,
    implementation: fsrs.ImplementationVersion,
    source: []const u8,
    parameters_json: []const u8,
    desired_retention: f64,
    minimum_interval_days: f64,
    maximum_interval_days: f64,
    created_at_ms: time.TimestampMs,
};

pub const SchedulerStateRecord = struct {
    card_id: card_mod.CardId,
    stamp: fsrs.SchedulerStamp,
    stability_days: ?f64,
    difficulty: ?f64,
    due_at_ms: time.TimestampMs,
    last_reviewed_at_ms: ?time.TimestampMs,
};

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path.ptr, &handle, flags, null) != c.SQLITE_OK or handle == null) {
            if (handle) |opened| _ = c.sqlite3_close(opened);
            return error.SqliteOpenFailed;
        }

        var db: Db = .{ .handle = handle.? };
        errdefer db.close();
        try db.exec("PRAGMA foreign_keys = ON;");
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn migrate(self: *Db) !void {
        const version = try self.userVersion();
        if (version > schema.current_version) return error.DatabaseTooNew;
        if (version < 1) try self.exec(schema.migration_v1);
        if (version < 2) try self.exec(schema.migration_v2);
    }

    pub fn userVersion(self: *Db) !i32 {
        const stmt = try self.prepare("PRAGMA user_version;");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteStepFailed;
        return c.sqlite3_column_int(stmt, 0);
    }

    pub fn beginImmediate(self: *Db) !void {
        try self.exec("BEGIN IMMEDIATE;");
    }

    pub fn commit(self: *Db) !void {
        try self.exec("COMMIT;");
    }

    pub fn rollback(self: *Db) void {
        self.exec("ROLLBACK;") catch {};
    }

    fn exec(self: *Db, sql: [:0]const u8) !void {
        var error_message: [*c]u8 = null;
        const result = c.sqlite3_exec(self.handle, sql.ptr, null, null, &error_message);
        if (error_message != null) c.sqlite3_free(error_message);
        if (result != c.SQLITE_OK) return error.SqliteExecFailed;
    }

    fn prepare(self: *Db, sql: [:0]const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
            return error.SqlitePrepareFailed;
        }
        return stmt.?;
    }

    fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
        if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    fn bindId(stmt: *c.sqlite3_stmt, index: c_int, value: u64) !void {
        const signed = std.math.cast(i64, value) orelse return error.IdOutOfRange;
        try bindInt64(stmt, index, signed);
    }

    fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    fn bindParameterSetId(stmt: *c.sqlite3_stmt, index: c_int, value: ?fsrs.ParameterSetId) !void {
        if (value) |id| {
            if (c.sqlite3_bind_blob(stmt, index, &id, id.len, null) != c.SQLITE_OK) return error.SqliteBindFailed;
        } else if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    fn stepDone(stmt: *c.sqlite3_stmt) !void {
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    fn columnTextOwned(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]u8 {
        const ptr = c.sqlite3_column_text(stmt, column);
        if (ptr == null) return error.UnexpectedNull;
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
        return allocator.dupe(u8, ptr[0..len]);
    }

    fn columnParameterSetId(stmt: *c.sqlite3_stmt, column: c_int) !?fsrs.ParameterSetId {
        if (c.sqlite3_column_type(stmt, column) == c.SQLITE_NULL) return null;
        if (c.sqlite3_column_bytes(stmt, column) != 32) return error.InvalidParameterSetId;
        const ptr = c.sqlite3_column_blob(stmt, column) orelse return error.InvalidParameterSetId;
        const bytes: [*]const u8 = @ptrCast(ptr);
        var id: fsrs.ParameterSetId = undefined;
        @memcpy(id[0..], bytes[0..32]);
        return id;
    }

    pub fn createDeck(self: *Db, name: []const u8, created_at_ms: time.TimestampMs) !card_mod.DeckId {
        const stmt = try self.prepare("INSERT INTO decks(name, created_at_ms) VALUES (?1, ?2);");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, name);
        try bindInt64(stmt, 2, created_at_ms);
        try stepDone(stmt);
        return @intCast(c.sqlite3_last_insert_rowid(self.handle));
    }

    pub fn getDeck(self: *Db, allocator: std.mem.Allocator, id: card_mod.DeckId) !?OwnedDeck {
        const stmt = try self.prepare("SELECT id, name, algorithm_major, parameter_set_id FROM decks WHERE id = ?1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);

        const result = c.sqlite3_step(stmt);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.SqliteStepFailed;

        return .{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .name = try columnTextOwned(allocator, stmt, 1),
            .algorithm = .{ .family = .fsrs, .major = @intCast(c.sqlite3_column_int(stmt, 2)) },
            .parameter_set_id = try columnParameterSetId(stmt, 3),
        };
    }

    pub fn renameDeck(self: *Db, id: card_mod.DeckId, name: []const u8) !void {
        const stmt = try self.prepare("UPDATE decks SET name = ?1 WHERE id = ?2;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, name);
        try bindId(stmt, 2, id);
        try stepDone(stmt);
    }

    pub fn deleteDeck(self: *Db, id: card_mod.DeckId) !void {
        const stmt = try self.prepare("DELETE FROM decks WHERE id = ?1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);
        try stepDone(stmt);
    }

    pub fn setDeckScheduler(
        self: *Db,
        id: card_mod.DeckId,
        algorithm: fsrs.AlgorithmId,
        parameter_set_id: ?fsrs.ParameterSetId,
    ) !void {
        if (algorithm.family != .fsrs) return error.UnsupportedAlgorithmFamily;
        const stmt = try self.prepare("UPDATE decks SET algorithm_family = 'fsrs', algorithm_major = ?1, parameter_set_id = ?2 WHERE id = ?3;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, algorithm.major);
        try bindParameterSetId(stmt, 2, parameter_set_id);
        try bindId(stmt, 3, id);
        try stepDone(stmt);
    }

    pub fn createCard(
        self: *Db,
        deck_id: card_mod.DeckId,
        question: []const u8,
        answer: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.CardId {
        const stmt = try self.prepare("INSERT INTO cards(deck_id, question, answer, created_at_ms) VALUES (?1, ?2, ?3, ?4);");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, deck_id);
        try bindText(stmt, 2, question);
        try bindText(stmt, 3, answer);
        try bindInt64(stmt, 4, created_at_ms);
        try stepDone(stmt);
        return @intCast(c.sqlite3_last_insert_rowid(self.handle));
    }

    pub fn getCard(self: *Db, allocator: std.mem.Allocator, id: card_mod.CardId) !?OwnedCard {
        const stmt = try self.prepare("SELECT id, deck_id, question, answer FROM cards WHERE id = ?1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);

        const result = c.sqlite3_step(stmt);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.SqliteStepFailed;

        const question = try columnTextOwned(allocator, stmt, 2);
        errdefer allocator.free(question);
        const answer = try columnTextOwned(allocator, stmt, 3);

        return .{
            .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .deck_id = @intCast(c.sqlite3_column_int64(stmt, 1)),
            .question = question,
            .answer = answer,
        };
    }

    pub fn updateCard(self: *Db, id: card_mod.CardId, question: []const u8, answer: []const u8) !void {
        const stmt = try self.prepare("UPDATE cards SET question = ?1, answer = ?2 WHERE id = ?3;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, question);
        try bindText(stmt, 2, answer);
        try bindId(stmt, 3, id);
        try stepDone(stmt);
    }

    pub fn deleteCard(self: *Db, id: card_mod.CardId) !void {
        const stmt = try self.prepare("DELETE FROM cards WHERE id = ?1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, id);
        try stepDone(stmt);
    }

    pub fn insertParameterSet(self: *Db, record: ParameterSetRecord) !void {
        try record.identity.validateFor(record.identity.algorithm);
        const stmt = try self.prepare(
            "INSERT INTO parameter_sets(id, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, source, parameters_json, desired_retention, minimum_interval_days, maximum_interval_days, created_at_ms) VALUES (?1, 'fsrs', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindParameterSetId(stmt, 1, record.identity.id);
        try bindInt64(stmt, 2, record.identity.algorithm.major);
        try bindInt64(stmt, 3, record.implementation.major);
        try bindInt64(stmt, 4, record.implementation.minor);
        try bindInt64(stmt, 5, record.implementation.patch);
        try bindText(stmt, 6, record.source);
        try bindText(stmt, 7, record.parameters_json);
        if (c.sqlite3_bind_double(stmt, 8, record.desired_retention) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_double(stmt, 9, record.minimum_interval_days) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_double(stmt, 10, record.maximum_interval_days) != c.SQLITE_OK) return error.SqliteBindFailed;
        try bindInt64(stmt, 11, record.created_at_ms);
        try stepDone(stmt);
    }

    pub fn appendReview(
        self: *Db,
        card_id: card_mod.CardId,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
        stamp: ?fsrs.SchedulerStamp,
        scheduled_at_ms: ?time.TimestampMs,
    ) !u64 {
        const stmt = try self.prepare(
            "INSERT INTO reviews(card_id, rating, reviewed_at_ms, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, parameter_set_id, scheduled_at_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, card_id);
        try bindInt64(stmt, 2, rating.value());
        try bindInt64(stmt, 3, reviewed_at_ms);

        if (stamp) |value| {
            if (value.algorithm.family != .fsrs) return error.UnsupportedAlgorithmFamily;
            try bindText(stmt, 4, "fsrs");
            try bindInt64(stmt, 5, value.algorithm.major);
            try bindInt64(stmt, 6, value.implementation.major);
            try bindInt64(stmt, 7, value.implementation.minor);
            try bindInt64(stmt, 8, value.implementation.patch);
            try bindParameterSetId(stmt, 9, value.parameter_set_id);
        } else {
            for (4..10) |index| {
                if (c.sqlite3_bind_null(stmt, @intCast(index)) != c.SQLITE_OK) return error.SqliteBindFailed;
            }
        }

        if (scheduled_at_ms) |scheduled| {
            try bindInt64(stmt, 10, scheduled);
        } else if (c.sqlite3_bind_null(stmt, 10) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }

        try stepDone(stmt);
        return @intCast(c.sqlite3_last_insert_rowid(self.handle));
    }

    pub fn loadHistory(self: *Db, allocator: std.mem.Allocator, card_id: card_mod.CardId) ![]fsrs.HistoryEntry {
        const stmt = try self.prepare("SELECT rating, reviewed_at_ms FROM reviews WHERE card_id = ?1 ORDER BY reviewed_at_ms, id;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, card_id);

        var history: std.ArrayList(fsrs.HistoryEntry) = .empty;
        errdefer history.deinit(allocator);

        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => {
                    const rating_value: u8 = @intCast(c.sqlite3_column_int(stmt, 0));
                    try history.append(allocator, .{
                        .rating = try fsrs.Rating.fromValue(rating_value),
                        .reviewed_at_ms = c.sqlite3_column_int64(stmt, 1),
                    });
                },
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
        }

        return history.toOwnedSlice(allocator);
    }

    pub fn upsertSchedulerState(self: *Db, state: SchedulerStateRecord) !void {
        if (state.stamp.algorithm.family != .fsrs) return error.UnsupportedAlgorithmFamily;
        const stmt = try self.prepare(
            "INSERT INTO scheduler_state(card_id, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, parameter_set_id, stability_days, difficulty, due_at_ms, last_reviewed_at_ms) VALUES (?1, 'fsrs', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10) ON CONFLICT(card_id) DO UPDATE SET algorithm_family=excluded.algorithm_family, algorithm_major=excluded.algorithm_major, implementation_major=excluded.implementation_major, implementation_minor=excluded.implementation_minor, implementation_patch=excluded.implementation_patch, parameter_set_id=excluded.parameter_set_id, stability_days=excluded.stability_days, difficulty=excluded.difficulty, due_at_ms=excluded.due_at_ms, last_reviewed_at_ms=excluded.last_reviewed_at_ms;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, state.card_id);
        try bindInt64(stmt, 2, state.stamp.algorithm.major);
        try bindInt64(stmt, 3, state.stamp.implementation.major);
        try bindInt64(stmt, 4, state.stamp.implementation.minor);
        try bindInt64(stmt, 5, state.stamp.implementation.patch);
        try bindParameterSetId(stmt, 6, state.stamp.parameter_set_id);
        if (state.stability_days) |value| {
            if (c.sqlite3_bind_double(stmt, 7, value) != c.SQLITE_OK) return error.SqliteBindFailed;
        } else if (c.sqlite3_bind_null(stmt, 7) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (state.difficulty) |value| {
            if (c.sqlite3_bind_double(stmt, 8, value) != c.SQLITE_OK) return error.SqliteBindFailed;
        } else if (c.sqlite3_bind_null(stmt, 8) != c.SQLITE_OK) return error.SqliteBindFailed;
        try bindInt64(stmt, 9, state.due_at_ms);
        if (state.last_reviewed_at_ms) |value| {
            try bindInt64(stmt, 10, value);
        } else if (c.sqlite3_bind_null(stmt, 10) != c.SQLITE_OK) return error.SqliteBindFailed;
        try stepDone(stmt);
    }

    pub fn clearSchedulerState(self: *Db, card_id: card_mod.CardId) !void {
        const stmt = try self.prepare("DELETE FROM scheduler_state WHERE card_id = ?1;");
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, card_id);
        try stepDone(stmt);
    }
};

test "SQLite migration and core persistence" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.migrate();
    try std.testing.expectEqual(schema.current_version, try db.userVersion());

    const deck_id = try db.createDeck("bson", 1);
    var deck = (try db.getDeck(std.testing.allocator, deck_id)).?;
    defer deck.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bson", deck.name);
    try std.testing.expect(deck.algorithm.eql(.fsrs7));

    const card_id = try db.createCard(deck_id, "What does i32 mean?", "A signed 32-bit integer.", 2);
    var card = (try db.getCard(std.testing.allocator, card_id)).?;
    defer card.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("What does i32 mean?", card.question);

    _ = try db.appendReview(card_id, .good, 3, null, null);
    const history = try db.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(fsrs.Rating.good, history[0].rating);
}
