const std = @import("std");
const Io = std.Io;
const c = @cImport({
    @cInclude("sqlite3.h");
});

const storage = @import("storage/root.zig");

pub const version: u16 = 1;
const hex = "0123456789abcdef";

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

fn writeHex(writer: *Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| {
        var pair = [2]u8{ hex[byte >> 4], hex[byte & 0x0f] };
        try writer.writeAll(&pair);
    }
}

fn columnBytes(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return &.{};
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return ptr[0..len];
}

fn columnBlob(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_blob(stmt, column) orelse return &.{};
    const bytes: [*]const u8 = @ptrCast(ptr);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return bytes[0..len];
}

fn writeNullableText(writer: *Io.Writer, stmt: *c.sqlite3_stmt, column: c_int) !void {
    if (c.sqlite3_column_type(stmt, column) == c.SQLITE_NULL) {
        try writer.writeAll("-");
    } else {
        try writer.writeAll(columnBytes(stmt, column));
    }
}

fn writeNullableHexText(writer: *Io.Writer, stmt: *c.sqlite3_stmt, column: c_int) !void {
    if (c.sqlite3_column_type(stmt, column) == c.SQLITE_NULL) {
        try writer.writeAll("-");
    } else {
        try writeHex(writer, columnBytes(stmt, column));
    }
}

fn writeNullableBlob(writer: *Io.Writer, stmt: *c.sqlite3_stmt, column: c_int) !void {
    if (c.sqlite3_column_type(stmt, column) == c.SQLITE_NULL) {
        try writer.writeAll("-");
    } else {
        try writeHex(writer, columnBlob(stmt, column));
    }
}

fn writeNullableInt(writer: *Io.Writer, stmt: *c.sqlite3_stmt, column: c_int) !void {
    if (c.sqlite3_column_type(stmt, column) == c.SQLITE_NULL) {
        try writer.writeAll("-");
    } else {
        try writer.print("{d}", .{c.sqlite3_column_int64(stmt, column)});
    }
}

fn exportParameters(db: *storage.Db, writer: *Io.Writer) !void {
    const stmt = try prepare(db, "SELECT id, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, source, desired_retention, minimum_interval_days, maximum_interval_days, created_at_ms FROM parameter_sets ORDER BY id;");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                try writer.writeAll("PARAM\t");
                try writeHex(writer, columnBlob(stmt, 0));
                try writer.print("\t{s}\t{d}\t{d}\t{d}\t{d}\t", .{
                    columnBytes(stmt, 1),
                    c.sqlite3_column_int64(stmt, 2),
                    c.sqlite3_column_int64(stmt, 3),
                    c.sqlite3_column_int64(stmt, 4),
                    c.sqlite3_column_int64(stmt, 5),
                });
                try writeHex(writer, columnBytes(stmt, 6));
                try writer.print("\t{d:.17}\t{d:.17}\t{d:.17}\t{d}\n", .{
                    c.sqlite3_column_double(stmt, 7),
                    c.sqlite3_column_double(stmt, 8),
                    c.sqlite3_column_double(stmt, 9),
                    c.sqlite3_column_int64(stmt, 10),
                });
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStepFailed,
        }
    }
}

fn exportWeights(db: *storage.Db, writer: *Io.Writer) !void {
    const stmt = try prepare(db, "SELECT parameter_set_id, position, value FROM parameter_weights ORDER BY parameter_set_id, position;");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                try writer.writeAll("WEIGHT\t");
                try writeHex(writer, columnBlob(stmt, 0));
                try writer.print("\t{d}\t{d:.17}\n", .{
                    c.sqlite3_column_int64(stmt, 1),
                    c.sqlite3_column_double(stmt, 2),
                });
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStepFailed,
        }
    }
}

fn exportDefault(db: *storage.Db, writer: *Io.Writer) !void {
    const stmt = try prepare(db, "SELECT algorithm_family, algorithm_major, parameter_set_id FROM scheduler_defaults WHERE id = 1;");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.MissingSchedulerDefault;
    try writer.print("DEFAULT\t{s}\t{d}\t", .{
        columnBytes(stmt, 0),
        c.sqlite3_column_int64(stmt, 1),
    });
    try writeNullableBlob(writer, stmt, 2);
    try writer.writeAll("\n");
}

fn exportGroups(db: *storage.Db, writer: *Io.Writer) !void {
    const stmt = try prepare(db, "SELECT id, name, algorithm_family, algorithm_major, parameter_set_id, created_at_ms FROM deck_groups ORDER BY id;");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                try writer.print("GROUP\t{d}\t", .{c.sqlite3_column_int64(stmt, 0)});
                try writeHex(writer, columnBytes(stmt, 1));
                try writer.writeAll("\t");
                try writeNullableText(writer, stmt, 2);
                try writer.writeAll("\t");
                try writeNullableInt(writer, stmt, 3);
                try writer.writeAll("\t");
                try writeNullableBlob(writer, stmt, 4);
                try writer.print("\t{d}\n", .{c.sqlite3_column_int64(stmt, 5)});
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStepFailed,
        }
    }
}

fn exportDecks(db: *storage.Db, writer: *Io.Writer) !void {
    const stmt = try prepare(db, "SELECT id, name, group_id, algorithm_family, algorithm_major, parameter_set_id, created_at_ms FROM decks ORDER BY id;");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                try writer.print("DECK\t{d}\t", .{c.sqlite3_column_int64(stmt, 0)});
                try writeHex(writer, columnBytes(stmt, 1));
                try writer.writeAll("\t");
                try writeNullableInt(writer, stmt, 2);
                try writer.writeAll("\t");
                try writeNullableText(writer, stmt, 3);
                try writer.writeAll("\t");
                try writeNullableInt(writer, stmt, 4);
                try writer.writeAll("\t");
                try writeNullableBlob(writer, stmt, 5);
                try writer.print("\t{d}\n", .{c.sqlite3_column_int64(stmt, 6)});
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStepFailed,
        }
    }
}

fn exportCards(db: *storage.Db, writer: *Io.Writer) !void {
    const stmt = try prepare(db, "SELECT id, deck_id, question, answer, created_at_ms FROM cards ORDER BY id;");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                try writer.print("CARD\t{d}\t{d}\t", .{
                    c.sqlite3_column_int64(stmt, 0),
                    c.sqlite3_column_int64(stmt, 1),
                });
                try writeHex(writer, columnBytes(stmt, 2));
                try writer.writeAll("\t");
                try writeHex(writer, columnBytes(stmt, 3));
                try writer.print("\t{d}\n", .{c.sqlite3_column_int64(stmt, 4)});
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStepFailed,
        }
    }
}

fn exportReviews(db: *storage.Db, writer: *Io.Writer) !void {
    const stmt = try prepare(db, "SELECT id, card_id, rating, reviewed_at_ms, algorithm_family, algorithm_major, implementation_major, implementation_minor, implementation_patch, parameter_set_id, scheduled_at_ms FROM reviews ORDER BY id;");
    defer _ = c.sqlite3_finalize(stmt);
    while (true) {
        switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                try writer.print("REVIEW\t{d}\t{d}\t{d}\t{d}\t", .{
                    c.sqlite3_column_int64(stmt, 0),
                    c.sqlite3_column_int64(stmt, 1),
                    c.sqlite3_column_int64(stmt, 2),
                    c.sqlite3_column_int64(stmt, 3),
                });
                try writeNullableText(writer, stmt, 4);
                inline for (5..9) |column| {
                    try writer.writeAll("\t");
                    try writeNullableInt(writer, stmt, column);
                }
                try writer.writeAll("\t");
                try writeNullableBlob(writer, stmt, 9);
                try writer.writeAll("\t");
                try writeNullableInt(writer, stmt, 10);
                try writer.writeAll("\n");
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStepFailed,
        }
    }
}

pub fn exportAll(db: *storage.Db, writer: *Io.Writer) !void {
    try writer.print("DEEZ\t{d}\n", .{version});
    try exportParameters(db, writer);
    try exportWeights(db, writer);
    try exportDefault(db, writer);
    try exportGroups(db, writer);
    try exportDecks(db, writer);
    try exportCards(db, writer);
    try exportReviews(db, writer);
}

// Import is intentionally separate from export so malformed input can be fully
// validated before any database mutation occurs.
