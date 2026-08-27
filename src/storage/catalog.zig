const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const card_mod = @import("../card.zig");
const fsrs = @import("../fsrs/root.zig");
const time = @import("../time.zig");
const sqlite = @import("sqlite.zig");

pub const ResolvedScheduler = struct {
    algorithm: fsrs.AlgorithmId,
    parameter_set_id: fsrs.ParameterSetId,
};

pub const OwnedDueCard = struct {
    id: card_mod.CardId,
    deck_id: card_mod.DeckId,
    question: []u8,
    answer: []u8,
    due_at_ms: ?time.TimestampMs,

    pub fn deinit(self: OwnedDueCard, allocator: std.mem.Allocator) void {
        allocator.free(self.question);
        allocator.free(self.answer);
    }
};

pub const SchedulerState = struct {
    card_id: card_mod.CardId,
    stamp: fsrs.SchedulerStamp,
    stability_days: ?f64,
    difficulty: ?f64,
    due_at_ms: time.TimestampMs,
    last_reviewed_at_ms: ?time.TimestampMs,
};

pub const Catalog = struct {
    db: *sqlite.Db,

    fn dbHandle(self: Catalog) ?*c.sqlite3 {
        return @ptrCast(self.db.handle);
    }

    fn prepare(self: Catalog, sql: [:0]const u8) !*c.sqlite3_stmt {
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

    fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
        if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    fn bindBlob32(stmt: *c.sqlite3_stmt, index: c_int, id: *const fsrs.ParameterSetId) !void {
        if (c.sqlite3_bind_blob(stmt, index, @ptrCast(id), 32, null) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    fn bindOptionalBlob32(stmt: *c.sqlite3_stmt, index: c_int, id: ?fsrs.ParameterSetId) !void {
        if (id) |value| {
            var stable = value;
            try bindBlob32(stmt, index, &stable);
        } else if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) {
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

    fn columnBlob32(stmt: *c.sqlite3_stmt, column: c_int) !fsrs.ParameterSetId {
        if (c.sqlite3_column_type(stmt, column) == c.SQLITE_NULL or c.sqlite3_column_bytes(stmt, column) != 32) {
            return error.InvalidParameterSetId;
        }
        const blob_ptr = c.sqlite3_column_blob(stmt, column) orelse return error.InvalidParameterSetId;
        const bytes: [*]const u8 = @ptrCast(blob_ptr);
        var id: fsrs.ParameterSetId = undefined;
        @memcpy(id[0..], bytes[0..32]);
        return id;
    }

    fn mix(lane: *u64, value: u64) void {
        lane.* ^= value +% 0x9e3779b97f4a7c15;
        lane.* *%= 0x100000001b3;
        lane.* ^= lane.* >> 29;
        lane.* *%= 0xbf58476d1ce4e5b9;
        lane.* ^= lane.* >> 31;
    }

    pub fn parameterSetId(parameters: fsrs.v7.Parameters) fsrs.ParameterSetId {
        var lanes = [4]u64{
            0xcbf29ce484222325,
            0x84222325cbf29ce4,
            0x6a09e667f3bcc909,
            0xbb67ae8584caa73b,
        };

        for (parameters.weights, 0..) |weight, index| {
            const bits: u64 = @bitCast(weight);
            for (&lanes, 0..) |*lane, lane_index| {
                const position: u64 = @intCast(index + 1);
                const lane_number: u64 = @intCast(lane_index + 1);
                mix(lane, bits ^ (position *% (lane_number *% 0x517cc1b727220a95)));
            }
        }

        const config_bits = [_]u64{
            @bitCast(parameters.desired_retention),
            @bitCast(parameters.minimum_interval_days),
            @bitCast(parameters.maximum_interval_days),
            7,
        };
        for (config_bits, 0..) |value, index| mix(&lanes[index], value);

        var id: fsrs.ParameterSetId = undefined;
        for (lanes, 0..) |lane, lane_index| {
            for (0..8) |byte_index| {
                const shift: u6 = @intCast(byte_index * 8);
                id[lane_index * 8 + byte_index] = @truncate(lane >> shift);
            }
        }
        return id;
    }

    fn parameterSetExists(self: Catalog, id: fsrs.ParameterSetId) !bool {
        const stmt = try self.prepare("SELECT 1 FROM parameter_sets WHERE id = ?1;");
        defer _ = c.sqlite3_finalize(stmt);
        var stable_id = id;
        try bindBlob32(stmt, 1, &stable_id);
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.SqliteStepFailed,
        };
    }

    pub fn putFsrs7Parameters(
        self: Catalog,
        parameters: fsrs.v7.Parameters,
        source: []const u8,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        try parameters.validate();
        var id = parameterSetId(parameters);
        if (try self.parameterSetExists(id)) return id;

        try self.db.beginImmediate();
        errdefer self.db.rollback();

        const set_stmt = try self.prepare(
            "INSERT INTO parameter_sets(id, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, source, parameters_json, desired_retention, minimum_interval_days, maximum_interval_days, created_at_ms) VALUES (?1, 'fsrs', 7, ?2, ?3, ?4, ?5, '[]', ?6, ?7, ?8, ?9);",
        );
        defer _ = c.sqlite3_finalize(set_stmt);
        try bindBlob32(set_stmt, 1, &id);
        try bindInt64(set_stmt, 2, fsrs.ImplementationVersion.current.major);
        try bindInt64(set_stmt, 3, fsrs.ImplementationVersion.current.minor);
        try bindInt64(set_stmt, 4, fsrs.ImplementationVersion.current.patch);
        try bindText(set_stmt, 5, source);
        if (c.sqlite3_bind_double(set_stmt, 6, parameters.desired_retention) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_double(set_stmt, 7, parameters.minimum_interval_days) != c.SQLITE_OK) return error.SqliteBindFailed;
        if (c.sqlite3_bind_double(set_stmt, 8, parameters.maximum_interval_days) != c.SQLITE_OK) return error.SqliteBindFailed;
        try bindInt64(set_stmt, 9, created_at_ms);
        try stepDone(set_stmt);

        const weight_stmt = try self.prepare(
            "INSERT INTO parameter_weights(parameter_set_id, position, value) VALUES (?1, ?2, ?3);",
        );
        defer _ = c.sqlite3_finalize(weight_stmt);
        for (parameters.weights, 0..) |weight, index| {
            _ = c.sqlite3_reset(weight_stmt);
            _ = c.sqlite3_clear_bindings(weight_stmt);
            try bindBlob32(weight_stmt, 1, &id);
            try bindInt64(weight_stmt, 2, @intCast(index));
            if (c.sqlite3_bind_double(weight_stmt, 3, weight) != c.SQLITE_OK) return error.SqliteBindFailed;
            try stepDone(weight_stmt);
        }

        try self.db.commit();
        return id;
    }

    pub fn loadFsrs7Parameters(self: Catalog, id: fsrs.ParameterSetId) !fsrs.v7.Parameters {
        const set_stmt = try self.prepare(
            "SELECT algorithm_family, algorithm_major, desired_retention, minimum_interval_days, maximum_interval_days FROM parameter_sets WHERE id = ?1;",
        );
        defer _ = c.sqlite3_finalize(set_stmt);
        var stable_id = id;
        try bindBlob32(set_stmt, 1, &stable_id);
        if (c.sqlite3_step(set_stmt) != c.SQLITE_ROW) return error.ParameterSetNotFound;

        const family_ptr = c.sqlite3_column_text(set_stmt, 0) orelse return error.InvalidParameterSet;
        const family_len: usize = @intCast(c.sqlite3_column_bytes(set_stmt, 0));
        if (!std.mem.eql(u8, family_ptr[0..family_len], "fsrs") or c.sqlite3_column_int(set_stmt, 1) != 7) {
            return error.IncompatibleParameterSet;
        }

        var parameters: fsrs.v7.Parameters = .{};
        parameters.desired_retention = c.sqlite3_column_double(set_stmt, 2);
        parameters.minimum_interval_days = c.sqlite3_column_double(set_stmt, 3);
        parameters.maximum_interval_days = c.sqlite3_column_double(set_stmt, 4);

        const weight_stmt = try self.prepare(
            "SELECT position, value FROM parameter_weights WHERE parameter_set_id = ?1 ORDER BY position;",
        );
        defer _ = c.sqlite3_finalize(weight_stmt);
        try bindBlob32(weight_stmt, 1, &stable_id);
        var count: usize = 0;
        while (true) {
            switch (c.sqlite3_step(weight_stmt)) {
                c.SQLITE_ROW => {
                    const position: usize = @intCast(c.sqlite3_column_int(weight_stmt, 0));
                    if (position >= parameters.weights.len or position != count) return error.InvalidParameterWeights;
                    parameters.weights[position] = c.sqlite3_column_double(weight_stmt, 1);
                    count += 1;
                },
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
        }
        if (count != parameters.weights.len) return error.InvalidParameterWeights;
        try parameters.validate();
        return parameters;
    }

    pub fn ensureDefaultFsrs7(self: Catalog, created_at_ms: time.TimestampMs) !fsrs.ParameterSetId {
        const id = try self.putFsrs7Parameters(.{}, "default", created_at_ms);
        const stmt = try self.prepare(
            "UPDATE scheduler_defaults SET algorithm_family = 'fsrs', algorithm_major = 7, parameter_set_id = ?1 WHERE id = 1 AND parameter_set_id IS NULL;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        var stable_id = id;
        try bindBlob32(stmt, 1, &stable_id);
        try stepDone(stmt);
        return id;
    }

    pub fn resolveDeckScheduler(
        self: Catalog,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
    ) !ResolvedScheduler {
        _ = try self.ensureDefaultFsrs7(now_ms);
        const stmt = try self.prepare(
            "SELECT COALESCE(d.algorithm_family, g.algorithm_family, s.algorithm_family), COALESCE(d.algorithm_major, g.algorithm_major, s.algorithm_major), COALESCE(d.parameter_set_id, g.parameter_set_id, s.parameter_set_id) FROM decks d LEFT JOIN deck_groups g ON g.id = d.group_id CROSS JOIN scheduler_defaults s WHERE d.id = ?1 AND s.id = 1;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, deck_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DeckNotFound;

        const family_ptr = c.sqlite3_column_text(stmt, 0) orelse return error.InvalidSchedulerConfiguration;
        const family_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (!std.mem.eql(u8, family_ptr[0..family_len], "fsrs")) return error.UnsupportedAlgorithmFamily;

        return .{
            .algorithm = .{
                .family = .fsrs,
                .major = @intCast(c.sqlite3_column_int(stmt, 1)),
            },
            .parameter_set_id = try columnBlob32(stmt, 2),
        };
    }

    pub fn setGlobalFsrs7(self: Catalog, parameter_set_id: fsrs.ParameterSetId) !void {
        _ = try self.loadFsrs7Parameters(parameter_set_id);
        const stmt = try self.prepare(
            "UPDATE scheduler_defaults SET algorithm_family = 'fsrs', algorithm_major = 7, parameter_set_id = ?1 WHERE id = 1;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        var stable_id = parameter_set_id;
        try bindBlob32(stmt, 1, &stable_id);
        try stepDone(stmt);
    }

    pub fn createGroup(self: Catalog, name: []const u8, created_at_ms: time.TimestampMs) !u64 {
        const stmt = try self.prepare("INSERT INTO deck_groups(name, created_at_ms) VALUES (?1, ?2);");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, name);
        try bindInt64(stmt, 2, created_at_ms);
        try stepDone(stmt);
        return @intCast(c.sqlite3_last_insert_rowid(self.dbHandle()));
    }

    pub fn assignDeckGroup(self: Catalog, deck_id: card_mod.DeckId, group_id: ?u64) !void {
        const stmt = try self.prepare("UPDATE decks SET group_id = ?1 WHERE id = ?2;");
        defer _ = c.sqlite3_finalize(stmt);
        if (group_id) |id| {
            try bindId(stmt, 1, id);
        } else if (c.sqlite3_bind_null(stmt, 1) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
        try bindId(stmt, 2, deck_id);
        try stepDone(stmt);
    }

    pub fn inheritDeckScheduler(self: Catalog, deck_id: card_mod.DeckId) !void {
        const stmt = try self.prepare(
            "UPDATE decks SET algorithm_family = NULL, algorithm_major = NULL, parameter_set_id = NULL WHERE id = ?1;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, deck_id);
        try stepDone(stmt);
    }

    pub fn setGroupFsrs7(self: Catalog, group_id: u64, parameter_set_id: fsrs.ParameterSetId) !void {
        _ = try self.loadFsrs7Parameters(parameter_set_id);
        const stmt = try self.prepare(
            "UPDATE deck_groups SET algorithm_family = 'fsrs', algorithm_major = 7, parameter_set_id = ?1 WHERE id = ?2;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        var stable_id = parameter_set_id;
        try bindBlob32(stmt, 1, &stable_id);
        try bindId(stmt, 2, group_id);
        try stepDone(stmt);
    }

    pub fn setDeckFsrs7(self: Catalog, deck_id: card_mod.DeckId, parameter_set_id: fsrs.ParameterSetId) !void {
        _ = try self.loadFsrs7Parameters(parameter_set_id);
        const stmt = try self.prepare(
            "UPDATE decks SET algorithm_family = 'fsrs', algorithm_major = 7, parameter_set_id = ?1 WHERE id = ?2;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        var stable_id = parameter_set_id;
        try bindBlob32(stmt, 1, &stable_id);
        try bindId(stmt, 2, deck_id);
        try stepDone(stmt);
    }

    pub fn dueCards(
        self: Catalog,
        allocator: std.mem.Allocator,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
        limit: usize,
    ) ![]OwnedDueCard {
        const stmt = try self.prepare(
            "SELECT c.id, c.deck_id, c.question, c.answer, s.due_at_ms FROM cards c LEFT JOIN scheduler_state s ON s.card_id = c.id WHERE c.deck_id = ?1 AND (s.card_id IS NULL OR s.due_at_ms <= ?2) ORDER BY COALESCE(s.due_at_ms, c.created_at_ms), c.id LIMIT ?3;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, deck_id);
        try bindInt64(stmt, 2, now_ms);
        try bindInt64(stmt, 3, @intCast(limit));

        var cards: std.ArrayList(OwnedDueCard) = .empty;
        errdefer {
            for (cards.items) |card| card.deinit(allocator);
            cards.deinit(allocator);
        }

        while (true) {
            switch (c.sqlite3_step(stmt)) {
                c.SQLITE_ROW => {
                    const question = try columnTextOwned(allocator, stmt, 2);
                    errdefer allocator.free(question);
                    const answer = try columnTextOwned(allocator, stmt, 3);
                    errdefer allocator.free(answer);
                    try cards.append(allocator, .{
                        .id = @intCast(c.sqlite3_column_int64(stmt, 0)),
                        .deck_id = @intCast(c.sqlite3_column_int64(stmt, 1)),
                        .question = question,
                        .answer = answer,
                        .due_at_ms = if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL)
                            null
                        else
                            c.sqlite3_column_int64(stmt, 4),
                    });
                },
                c.SQLITE_DONE => break,
                else => return error.SqliteStepFailed,
            }
        }
        return cards.toOwnedSlice(allocator);
    }

    pub fn appendReview(
        self: Catalog,
        card_id: card_mod.CardId,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
        stamp: fsrs.SchedulerStamp,
        scheduled_at_ms: time.TimestampMs,
    ) !u64 {
        if (stamp.algorithm.family != .fsrs) return error.UnsupportedAlgorithmFamily;
        const stmt = try self.prepare(
            "INSERT INTO reviews(card_id, rating, reviewed_at_ms, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, parameter_set_id, scheduled_at_ms) VALUES (?1, ?2, ?3, 'fsrs', ?4, ?5, ?6, ?7, ?8, ?9);",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, card_id);
        try bindInt64(stmt, 2, rating.value());
        try bindInt64(stmt, 3, reviewed_at_ms);
        try bindInt64(stmt, 4, stamp.algorithm.major);
        try bindInt64(stmt, 5, stamp.implementation.major);
        try bindInt64(stmt, 6, stamp.implementation.minor);
        try bindInt64(stmt, 7, stamp.implementation.patch);
        var stable_id = stamp.parameter_set_id;
        try bindBlob32(stmt, 8, &stable_id);
        try bindInt64(stmt, 9, scheduled_at_ms);
        try stepDone(stmt);
        return @intCast(c.sqlite3_last_insert_rowid(self.dbHandle()));
    }

    pub fn upsertSchedulerState(self: Catalog, state: SchedulerState) !void {
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
        var stable_id = state.stamp.parameter_set_id;
        try bindBlob32(stmt, 6, &stable_id);

        if (state.stability_days) |value| {
            if (c.sqlite3_bind_double(stmt, 7, value) != c.SQLITE_OK) return error.SqliteBindFailed;
        } else if (c.sqlite3_bind_null(stmt, 7) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
        if (state.difficulty) |value| {
            if (c.sqlite3_bind_double(stmt, 8, value) != c.SQLITE_OK) return error.SqliteBindFailed;
        } else if (c.sqlite3_bind_null(stmt, 8) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
        try bindInt64(stmt, 9, state.due_at_ms);
        if (state.last_reviewed_at_ms) |value| {
            try bindInt64(stmt, 10, value);
        } else if (c.sqlite3_bind_null(stmt, 10) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
        try stepDone(stmt);
    }

    pub fn getSchedulerState(self: Catalog, card_id: card_mod.CardId) !?SchedulerState {
        const stmt = try self.prepare(
            "SELECT algorithm_major, implementation_major, implementation_minor, implementation_patch, parameter_set_id, stability_days, difficulty, due_at_ms, last_reviewed_at_ms FROM scheduler_state WHERE card_id = ?1;",
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindId(stmt, 1, card_id);
        const result = c.sqlite3_step(stmt);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.SqliteStepFailed;

        return .{
            .card_id = card_id,
            .stamp = .{
                .algorithm = .{
                    .family = .fsrs,
                    .major = @intCast(c.sqlite3_column_int(stmt, 0)),
                },
                .implementation = .{
                    .major = @intCast(c.sqlite3_column_int(stmt, 1)),
                    .minor = @intCast(c.sqlite3_column_int(stmt, 2)),
                    .patch = @intCast(c.sqlite3_column_int(stmt, 3)),
                },
                .parameter_set_id = try columnBlob32(stmt, 4),
            },
            .stability_days = if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_double(stmt, 5),
            .difficulty = if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_double(stmt, 6),
            .due_at_ms = c.sqlite3_column_int64(stmt, 7),
            .last_reviewed_at_ms = if (c.sqlite3_column_type(stmt, 8) == c.SQLITE_NULL)
                null
            else
                c.sqlite3_column_int64(stmt, 8),
        };
    }
};

test "parameter sets round trip and resolve globally" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const catalog: Catalog = .{ .db = &db };

    const id = try catalog.ensureDefaultFsrs7(0);
    const loaded = try catalog.loadFsrs7Parameters(id);
    try std.testing.expectEqual(id, Catalog.parameterSetId(loaded));
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), loaded.desired_retention, 1e-12);

    const deck_id = try db.createDeck("bson", 0);
    try catalog.inheritDeckScheduler(deck_id);
    const resolved = try catalog.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(resolved.algorithm.eql(.fsrs7));
    try std.testing.expectEqual(id, resolved.parameter_set_id);
}

test "deck parameter scope overrides group and global" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const catalog: Catalog = .{ .db = &db };
    _ = try catalog.ensureDefaultFsrs7(0);

    var group_parameters: fsrs.v7.Parameters = .{};
    group_parameters.desired_retention = 0.92;
    const group_parameter_id = try catalog.putFsrs7Parameters(group_parameters, "group", 1);

    var deck_parameters: fsrs.v7.Parameters = .{};
    deck_parameters.desired_retention = 0.95;
    const deck_parameter_id = try catalog.putFsrs7Parameters(deck_parameters, "deck", 2);

    const group_id = try catalog.createGroup("developer", 0);
    try catalog.setGroupFsrs7(group_id, group_parameter_id);
    const deck_id = try db.createDeck("zig", 0);
    try catalog.assignDeckGroup(deck_id, group_id);
    try catalog.inheritDeckScheduler(deck_id);

    var resolved = try catalog.resolveDeckScheduler(deck_id, 0);
    try std.testing.expectEqual(group_parameter_id, resolved.parameter_set_id);
    try catalog.setDeckFsrs7(deck_id, deck_parameter_id);
    resolved = try catalog.resolveDeckScheduler(deck_id, 0);
    try std.testing.expectEqual(deck_parameter_id, resolved.parameter_set_id);
}

test "due queue includes unscheduled and due cards" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    const catalog: Catalog = .{ .db = &db };
    const parameter_id = try catalog.ensureDefaultFsrs7(0);
    const deck_id = try db.createDeck("bson", 0);
    const first = try db.createCard(deck_id, "q1", "a1", 0);
    _ = try db.createCard(deck_id, "q2", "a2", 1);

    try catalog.upsertSchedulerState(.{
        .card_id = first,
        .stamp = .{
            .algorithm = .fsrs7,
            .implementation = .current,
            .parameter_set_id = parameter_id,
        },
        .stability_days = 2,
        .difficulty = 4,
        .due_at_ms = 100,
        .last_reviewed_at_ms = 0,
    });

    const due = try catalog.dueCards(std.testing.allocator, deck_id, 50, 10);
    defer {
        for (due) |card| card.deinit(std.testing.allocator);
        std.testing.allocator.free(due);
    }
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqualStrings("q2", due[0].question);
}
