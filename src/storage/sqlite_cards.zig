const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const card_mod = @import("../card.zig");
const sqlite = @import("sqlite.zig");

pub fn list(
    db: *sqlite.Db,
    allocator: std.mem.Allocator,
    deck_id: card_mod.DeckId,
) ![]sqlite.OwnedCard {
    var stmt: ?*c.sqlite3_stmt = null;
    const handle: ?*c.sqlite3 = @ptrCast(db.handle);
    if (c.sqlite3_prepare_v2(
        handle,
        "SELECT id, deck_id, question, answer FROM cards WHERE deck_id = ?1 ORDER BY id;",
        -1,
        &stmt,
        null,
    ) != c.SQLITE_OK or stmt == null) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt.?);

    const signed_id = std.math.cast(i64, deck_id) orelse return error.IdOutOfRange;
    if (c.sqlite3_bind_int64(stmt.?, 1, signed_id) != c.SQLITE_OK) return error.SqliteBindFailed;

    var cards: std.ArrayList(sqlite.OwnedCard) = .empty;
    errdefer {
        for (cards.items) |card| card.deinit(allocator);
        cards.deinit(allocator);
    }

    while (true) {
        switch (c.sqlite3_step(stmt.?)) {
            c.SQLITE_ROW => {
                const question_ptr = c.sqlite3_column_text(stmt.?, 2) orelse return error.UnexpectedNull;
                const question_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 2));
                const question = try allocator.dupe(u8, question_ptr[0..question_len]);
                errdefer allocator.free(question);

                const answer_ptr = c.sqlite3_column_text(stmt.?, 3) orelse return error.UnexpectedNull;
                const answer_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 3));
                const answer = try allocator.dupe(u8, answer_ptr[0..answer_len]);
                errdefer allocator.free(answer);

                try cards.append(allocator, .{
                    .id = @intCast(c.sqlite3_column_int64(stmt.?, 0)),
                    .deck_id = @intCast(c.sqlite3_column_int64(stmt.?, 1)),
                    .question = question,
                    .answer = answer,
                });
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStepFailed,
        }
    }

    return cards.toOwnedSlice(allocator);
}
