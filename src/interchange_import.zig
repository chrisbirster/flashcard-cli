const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const storage = @import("storage/root.zig");

fn handle(db: *storage.Db) ?*c.sqlite3 {
    return @ptrCast(db.handle);
}

fn prepare(db: *storage.Db, sql: [:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(handle(db), sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
        return error.SqlitePrepareFailed;
    }
    return stmt.?;
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

fn bindBlob(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_blob(stmt, index, value.ptr, @intCast(value.len), null) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn parseI64(text: []const u8) !i64 {
    return std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger;
}

fn parseF64(text: []const u8) !f64 {
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidFloat;
    if (!std.math.isFinite(value)) return error.InvalidFloat;
    return value;
}

fn nibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn validateHex(text: []const u8) !void {
    if (text.len % 2 != 0) return error.InvalidHex;
    for (text) |byte| _ = try nibble(byte);
}

fn decodeHex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    try validateHex(text);
    const result = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(result);
    for (result, 0..) |*byte, index| {
        byte.* = (try nibble(text[index * 2])) << 4 | try nibble(text[index * 2 + 1]);
    }
    return result;
}

fn decodeId(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidParameterSetId;
    var id: [32]u8 = undefined;
    for (&id, 0..) |*byte, index| {
        byte.* = (try nibble(text[index * 2])) << 4 | try nibble(text[index * 2 + 1]);
    }
    return id;
}

fn optionalInt(text: []const u8) !?i64 {
    if (std.mem.eql(u8, text, "-")) return null;
    return try parseI64(text);
}

fn optionalId(text: []const u8) !?([32]u8) {
    if (std.mem.eql(u8, text, "-")) return null;
    return try decodeId(text);
}

fn fieldCount(line: []const u8) usize {
    if (line.len == 0) return 0;
    var count: usize = 1;
    for (line) |byte| {
        if (byte == '\t') count += 1;
    }
    return count;
}

fn rank(kind: []const u8) !u8 {
    if (std.mem.eql(u8, kind, "PARAM")) return 1;
    if (std.mem.eql(u8, kind, "WEIGHT")) return 2;
    if (std.mem.eql(u8, kind, "DEFAULT")) return 3;
    if (std.mem.eql(u8, kind, "GROUP")) return 4;
    if (std.mem.eql(u8, kind, "DECK")) return 5;
    if (std.mem.eql(u8, kind, "CARD")) return 6;
    if (std.mem.eql(u8, kind, "REVIEW")) return 7;
    return error.UnknownRecordType;
}

fn expectedFields(kind: []const u8) !usize {
    if (std.mem.eql(u8, kind, "PARAM")) return 12;
    if (std.mem.eql(u8, kind, "WEIGHT")) return 4;
    if (std.mem.eql(u8, kind, "DEFAULT")) return 4;
    if (std.mem.eql(u8, kind, "GROUP")) return 7;
    if (std.mem.eql(u8, kind, "DECK")) return 8;
    if (std.mem.eql(u8, kind, "CARD")) return 6;
    if (std.mem.eql(u8, kind, "REVIEW")) return 12;
    return error.UnknownRecordType;
}

fn validateFamily(text: []const u8) !void {
    if (!std.mem.eql(u8, text, "-") and !std.mem.eql(u8, text, "fsrs")) {
        return error.UnsupportedAlgorithmFamily;
    }
}

fn validateRecord(line: []const u8, previous_rank: *u8) !void {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const kind = fields.next() orelse return error.EmptyRecord;
    const current_rank = try rank(kind);
    if (current_rank < previous_rank.*) return error.InvalidRecordOrder;
    previous_rank.* = current_rank;
    if (fieldCount(line) != try expectedFields(kind)) return error.InvalidFieldCount;

    if (std.mem.eql(u8, kind, "PARAM")) {
        _ = try decodeId(fields.next().?);
        try validateFamily(fields.next().?);
        _ = try parseI64(fields.next().?);
        _ = try parseI64(fields.next().?);
        _ = try parseI64(fields.next().?);
        _ = try parseI64(fields.next().?);
        try validateHex(fields.next().?);
        _ = try parseF64(fields.next().?);
        _ = try parseF64(fields.next().?);
        _ = try parseF64(fields.next().?);
        _ = try parseI64(fields.next().?);
        return;
    }
    if (std.mem.eql(u8, kind, "WEIGHT")) {
        _ = try decodeId(fields.next().?);
        const position = try parseI64(fields.next().?);
        if (position < 0 or position >= 35) return error.InvalidWeightPosition;
        _ = try parseF64(fields.next().?);
        return;
    }
    if (std.mem.eql(u8, kind, "DEFAULT")) {
        try validateFamily(fields.next().?);
        _ = try parseI64(fields.next().?);
        _ = try optionalId(fields.next().?);
        return;
    }
    if (std.mem.eql(u8, kind, "GROUP")) {
        _ = try parseI64(fields.next().?);
        try validateHex(fields.next().?);
        try validateFamily(fields.next().?);
        _ = try optionalInt(fields.next().?);
        _ = try optionalId(fields.next().?);
        _ = try parseI64(fields.next().?);
        return;
    }
    if (std.mem.eql(u8, kind, "DECK")) {
        _ = try parseI64(fields.next().?);
        try validateHex(fields.next().?);
        _ = try optionalInt(fields.next().?);
        try validateFamily(fields.next().?);
        _ = try optionalInt(fields.next().?);
        _ = try optionalId(fields.next().?);
        _ = try parseI64(fields.next().?);
        return;
    }
    if (std.mem.eql(u8, kind, "CARD")) {
        _ = try parseI64(fields.next().?);
        _ = try parseI64(fields.next().?);
        try validateHex(fields.next().?);
        try validateHex(fields.next().?);
        _ = try parseI64(fields.next().?);
        return;
    }

    _ = try parseI64(fields.next().?);
    _ = try parseI64(fields.next().?);
    const rating = try parseI64(fields.next().?);
    if (rating < 1 or rating > 4) return error.InvalidRating;
    _ = try parseI64(fields.next().?);
    try validateFamily(fields.next().?);
    inline for (0..4) |_| _ = try optionalInt(fields.next().?);
    _ = try optionalId(fields.next().?);
    _ = try optionalInt(fields.next().?);
}

pub fn validateArchive(bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header = stripCr(lines.next() orelse return error.MissingHeader);
    if (!std.mem.eql(u8, header, "DEEZ\t1")) return error.UnsupportedArchiveVersion;

    var previous_rank: u8 = 0;
    while (lines.next()) |raw_line| {
        const line = stripCr(raw_line);
        if (line.len == 0) continue;
        try validateRecord(line, &previous_rank);
    }
}

fn destinationIsEmpty(db: *storage.Db) !bool {
    const stmt = try prepare(
        db,
        "SELECT (SELECT COUNT(*) FROM parameter_sets) + (SELECT COUNT(*) FROM deck_groups) + (SELECT COUNT(*) FROM decks) + (SELECT COUNT(*) FROM cards) + (SELECT COUNT(*) FROM reviews);",
    );
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteStepFailed;
    return c.sqlite3_column_int64(stmt, 0) == 0;
}

fn bindOptionalInt(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (try optionalInt(text)) |value| {
        try bindInt(stmt, index, value);
    } else if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

fn bindOptionalText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
    if (std.mem.eql(u8, text, "-")) {
        if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) return error.SqliteBindFailed;
    } else {
        try bindText(stmt, index, text);
    }
}

fn bindOptionalId(
    stmt: *c.sqlite3_stmt,
    index: c_int,
    text: []const u8,
    storage_slot: *?[32]u8,
) !void {
    storage_slot.* = try optionalId(text);
    if (storage_slot.*) |*id| {
        try bindBlob(stmt, index, id);
    } else if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
}

fn importParameter(allocator: std.mem.Allocator, db: *storage.Db, fields: anytype) !void {
    var id = try decodeId(fields.next().?);
    const family = fields.next().?;
    const algorithm_major = try parseI64(fields.next().?);
    const implementation_major = try parseI64(fields.next().?);
    const implementation_minor = try parseI64(fields.next().?);
    const implementation_patch = try parseI64(fields.next().?);
    const source = try decodeHex(allocator, fields.next().?);
    defer allocator.free(source);
    const retention = try parseF64(fields.next().?);
    const minimum = try parseF64(fields.next().?);
    const maximum = try parseF64(fields.next().?);
    const created = try parseI64(fields.next().?);

    const stmt = try prepare(
        db,
        "INSERT INTO parameter_sets(id, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, source, parameters_json, desired_retention, minimum_interval_days, maximum_interval_days, created_at_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, '[]', ?8, ?9, ?10, ?11);",
    );
    defer _ = c.sqlite3_finalize(stmt);
    try bindBlob(stmt, 1, &id);
    try bindText(stmt, 2, family);
    try bindInt(stmt, 3, algorithm_major);
    try bindInt(stmt, 4, implementation_major);
    try bindInt(stmt, 5, implementation_minor);
    try bindInt(stmt, 6, implementation_patch);
    try bindText(stmt, 7, source);
    if (c.sqlite3_bind_double(stmt, 8, retention) != c.SQLITE_OK or
        c.sqlite3_bind_double(stmt, 9, minimum) != c.SQLITE_OK or
        c.sqlite3_bind_double(stmt, 10, maximum) != c.SQLITE_OK)
    {
        return error.SqliteBindFailed;
    }
    try bindInt(stmt, 11, created);
    try stepDone(stmt);
}

fn importRecord(allocator: std.mem.Allocator, db: *storage.Db, line: []const u8) !void {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const kind = fields.next().?;

    if (std.mem.eql(u8, kind, "PARAM")) return importParameter(allocator, db, &fields);

    if (std.mem.eql(u8, kind, "WEIGHT")) {
        var id = try decodeId(fields.next().?);
        const stmt = try prepare(db, "INSERT INTO parameter_weights(parameter_set_id, position, value) VALUES (?1, ?2, ?3);");
        defer _ = c.sqlite3_finalize(stmt);
        try bindBlob(stmt, 1, &id);
        try bindInt(stmt, 2, try parseI64(fields.next().?));
        if (c.sqlite3_bind_double(stmt, 3, try parseF64(fields.next().?)) != c.SQLITE_OK) return error.SqliteBindFailed;
        return stepDone(stmt);
    }

    if (std.mem.eql(u8, kind, "DEFAULT")) {
        const stmt = try prepare(db, "UPDATE scheduler_defaults SET algorithm_family = ?1, algorithm_major = ?2, parameter_set_id = ?3 WHERE id = 1;");
        defer _ = c.sqlite3_finalize(stmt);
        var parameter_id: ?[32]u8 = null;
        try bindText(stmt, 1, fields.next().?);
        try bindInt(stmt, 2, try parseI64(fields.next().?));
        try bindOptionalId(stmt, 3, fields.next().?, &parameter_id);
        return stepDone(stmt);
    }

    if (std.mem.eql(u8, kind, "GROUP")) {
        const id = try parseI64(fields.next().?);
        const name = try decodeHex(allocator, fields.next().?);
        defer allocator.free(name);
        const stmt = try prepare(db, "INSERT INTO deck_groups(id, name, algorithm_family, algorithm_major, parameter_set_id, created_at_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6);");
        defer _ = c.sqlite3_finalize(stmt);
        var parameter_id: ?[32]u8 = null;
        try bindInt(stmt, 1, id);
        try bindText(stmt, 2, name);
        try bindOptionalText(stmt, 3, fields.next().?);
        try bindOptionalInt(stmt, 4, fields.next().?);
        try bindOptionalId(stmt, 5, fields.next().?, &parameter_id);
        try bindInt(stmt, 6, try parseI64(fields.next().?));
        return stepDone(stmt);
    }

    if (std.mem.eql(u8, kind, "DECK")) {
        const id = try parseI64(fields.next().?);
        const name = try decodeHex(allocator, fields.next().?);
        defer allocator.free(name);
        const stmt = try prepare(db, "INSERT INTO decks(id, name, group_id, algorithm_family, algorithm_major, parameter_set_id, created_at_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);");
        defer _ = c.sqlite3_finalize(stmt);
        var parameter_id: ?[32]u8 = null;
        try bindInt(stmt, 1, id);
        try bindText(stmt, 2, name);
        try bindOptionalInt(stmt, 3, fields.next().?);
        try bindOptionalText(stmt, 4, fields.next().?);
        try bindOptionalInt(stmt, 5, fields.next().?);
        try bindOptionalId(stmt, 6, fields.next().?, &parameter_id);
        try bindInt(stmt, 7, try parseI64(fields.next().?));
        return stepDone(stmt);
    }

    if (std.mem.eql(u8, kind, "CARD")) {
        const id = try parseI64(fields.next().?);
        const deck_id = try parseI64(fields.next().?);
        const question = try decodeHex(allocator, fields.next().?);
        defer allocator.free(question);
        const answer = try decodeHex(allocator, fields.next().?);
        defer allocator.free(answer);
        const stmt = try prepare(db, "INSERT INTO cards(id, deck_id, question, answer, created_at_ms) VALUES (?1, ?2, ?3, ?4, ?5);");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt(stmt, 1, id);
        try bindInt(stmt, 2, deck_id);
        try bindText(stmt, 3, question);
        try bindText(stmt, 4, answer);
        try bindInt(stmt, 5, try parseI64(fields.next().?));
        return stepDone(stmt);
    }

    const stmt = try prepare(db, "INSERT INTO reviews(id, card_id, rating, reviewed_at_ms, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, parameter_set_id, scheduled_at_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);");
    defer _ = c.sqlite3_finalize(stmt);
    var parameter_id: ?[32]u8 = null;
    inline for (1..5) |index| try bindInt(stmt, index, try parseI64(fields.next().?));
    try bindOptionalText(stmt, 5, fields.next().?);
    try bindOptionalInt(stmt, 6, fields.next().?);
    try bindOptionalInt(stmt, 7, fields.next().?);
    try bindOptionalInt(stmt, 8, fields.next().?);
    try bindOptionalInt(stmt, 9, fields.next().?);
    try bindOptionalId(stmt, 10, fields.next().?, &parameter_id);
    try bindOptionalInt(stmt, 11, fields.next().?);
    try stepDone(stmt);
}

pub fn importArchive(allocator: std.mem.Allocator, db: *storage.Db, bytes: []const u8) !void {
    try validateArchive(bytes);
    if (!try destinationIsEmpty(db)) return error.DestinationNotEmpty;

    try db.beginImmediate();
    errdefer db.rollback();

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next();
    while (lines.next()) |raw_line| {
        const line = stripCr(raw_line);
        if (line.len == 0) continue;
        try importRecord(allocator, db, line);
    }
    try db.commit();
}

test "archive validation accepts CRLF and rejects unknown records" {
    try validateArchive("DEEZ\t1\r\n");
    try std.testing.expectError(error.UnknownRecordType, validateArchive("DEEZ\t1\nNOPE\t1\n"));
}

test "archive validation rejects unsupported versions" {
    try std.testing.expectError(error.UnsupportedArchiveVersion, validateArchive("DEEZ\t2\n"));
}
