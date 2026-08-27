const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const fsrs = @import("../fsrs/root.zig");
const storage = @import("../storage/root.zig");
const Study = @import("../study.zig").Study;

pub const Inspection = struct {
    deck_count: usize,
    card_count: usize,
    eligible_review_count: usize,
    excluded_review_count: usize,
    legacy_learning_three_count: usize,
};

pub const Result = struct {
    decks_created: usize = 0,
    cards_created: usize = 0,
    reviews_imported: usize = 0,
    legacy_learning_three_count: usize = 0,
    cards_without_second_field: usize = 0,
};

fn openReadOnly(path: [:0]const u8) !*c.sqlite3 {
    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK or handle == null) {
        if (handle) |opened| _ = c.sqlite3_close(opened);
        return error.AnkiOpenFailed;
    }
    return handle.?;
}

fn prepare(db: *c.sqlite3, sql: [:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK or stmt == null) {
        return error.UnsupportedAnkiSchema;
    }
    return stmt.?;
}

fn scalarCount(db: *c.sqlite3, sql: [:0]const u8) !usize {
    const stmt = try prepare(db, sql);
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.AnkiReadFailed;
    const value = c.sqlite3_column_int64(stmt, 0);
    if (value < 0) return error.InvalidAnkiCount;
    return @intCast(value);
}

pub fn inspect(path: [:0]const u8) !Inspection {
    const source = try openReadOnly(path);
    defer _ = c.sqlite3_close(source);

    const decks = try scalarCount(source, "SELECT COUNT(DISTINCT did) FROM cards;");
    const cards = try scalarCount(source, "SELECT COUNT(*) FROM cards;");
    const reviews = try scalarCount(source, "SELECT COUNT(*) FROM revlog WHERE ease BETWEEN 1 AND 4 AND NOT(type = 3 AND factor = 0);");
    const excluded = try scalarCount(source, "SELECT COUNT(*) FROM revlog WHERE NOT(ease BETWEEN 1 AND 4 AND NOT(type = 3 AND factor = 0));");
    const ambiguous = try scalarCount(source, "SELECT COUNT(*) FROM revlog WHERE type = 0 AND ease = 3;");

    // Confirm the note join used by the importer is available before a write is attempted.
    const probe = try prepare(source, "SELECT c.id, c.did, n.flds FROM cards c JOIN notes n ON n.id = c.nid LIMIT 1;");
    defer _ = c.sqlite3_finalize(probe);
    const probe_result = c.sqlite3_step(probe);
    if (probe_result != c.SQLITE_ROW and probe_result != c.SQLITE_DONE) return error.UnsupportedAnkiSchema;

    return .{
        .deck_count = decks,
        .card_count = cards,
        .eligible_review_count = reviews,
        .excluded_review_count = excluded,
        .legacy_learning_three_count = ambiguous,
    };
}

fn textColumn(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return &.{};
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return ptr[0..len];
}

fn firstTwoFields(fields: []const u8) struct { question: []const u8, answer: []const u8, has_answer: bool } {
    var split = std.mem.splitScalar(u8, fields, 0x1f);
    const question = split.next() orelse &.{};
    const maybe_answer = split.next();
    return .{
        .question = question,
        .answer = maybe_answer orelse &.{},
        .has_answer = maybe_answer != null,
    };
}

pub fn importCollection(
    allocator: std.mem.Allocator,
    destination: *storage.Db,
    path: [:0]const u8,
    deck_prefix: []const u8,
    imported_at_ms: i64,
) !Result {
    _ = try inspect(path);
    const source = try openReadOnly(path);
    defer _ = c.sqlite3_close(source);

    const deck_stmt = try prepare(source, "SELECT DISTINCT did FROM cards ORDER BY did;");
    defer _ = c.sqlite3_finalize(deck_stmt);
    const card_stmt = try prepare(source, "SELECT c.id, n.flds FROM cards c JOIN notes n ON n.id = c.nid WHERE c.did = ?1 ORDER BY c.id;");
    defer _ = c.sqlite3_finalize(card_stmt);
    const review_stmt = try prepare(source, "SELECT id, ease, type, factor FROM revlog WHERE cid = ?1 AND ease BETWEEN 1 AND 4 AND NOT(type = 3 AND factor = 0) ORDER BY id;");
    defer _ = c.sqlite3_finalize(review_stmt);

    var result: Result = .{};
    const study = Study.init(destination);

    while (true) {
        const deck_step = c.sqlite3_step(deck_stmt);
        if (deck_step == c.SQLITE_DONE) break;
        if (deck_step != c.SQLITE_ROW) return error.AnkiReadFailed;
        const source_deck_id = c.sqlite3_column_int64(deck_stmt, 0);
        if (source_deck_id < 0) return error.InvalidAnkiDeckId;

        const deck_name = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ deck_prefix, source_deck_id });
        defer allocator.free(deck_name);
        const destination_deck_id = try destination.createDeck(deck_name, imported_at_ms);
        result.decks_created += 1;

        _ = c.sqlite3_reset(card_stmt);
        _ = c.sqlite3_clear_bindings(card_stmt);
        if (c.sqlite3_bind_int64(card_stmt, 1, source_deck_id) != c.SQLITE_OK) return error.AnkiBindFailed;

        while (true) {
            const card_step = c.sqlite3_step(card_stmt);
            if (card_step == c.SQLITE_DONE) break;
            if (card_step != c.SQLITE_ROW) return error.AnkiReadFailed;
            const source_card_id = c.sqlite3_column_int64(card_stmt, 0);
            if (source_card_id < 0) return error.InvalidAnkiCardId;
            const fields = firstTwoFields(textColumn(card_stmt, 1));
            if (!fields.has_answer) result.cards_without_second_field += 1;

            const destination_card_id = try destination.createCard(
                destination_deck_id,
                fields.question,
                fields.answer,
                source_card_id,
            );
            result.cards_created += 1;

            _ = c.sqlite3_reset(review_stmt);
            _ = c.sqlite3_clear_bindings(review_stmt);
            if (c.sqlite3_bind_int64(review_stmt, 1, source_card_id) != c.SQLITE_OK) return error.AnkiBindFailed;

            var last_review_ms: ?i64 = null;
            while (true) {
                const review_step = c.sqlite3_step(review_stmt);
                if (review_step == c.SQLITE_DONE) break;
                if (review_step != c.SQLITE_ROW) return error.AnkiReadFailed;

                const reviewed_at_ms = c.sqlite3_column_int64(review_stmt, 0);
                const ease: u8 = @intCast(c.sqlite3_column_int(review_stmt, 1));
                const review_kind = c.sqlite3_column_int(review_stmt, 2);
                if (review_kind == 0 and ease == 3) result.legacy_learning_three_count += 1;

                const rating = try fsrs.Rating.fromValue(ease);
                _ = try destination.appendReview(destination_card_id, rating, reviewed_at_ms, null, null);
                result.reviews_imported += 1;
                last_review_ms = reviewed_at_ms;
            }

            if (last_review_ms) |timestamp| {
                _ = try study.rebuildCardState(allocator, destination_card_id, timestamp);
            }
        }
    }

    return result;
}

test "Anki note fields use the first two fields without template guessing" {
    const parsed = firstTwoFields("front\x1fback\x1fextra");
    try std.testing.expectEqualStrings("front", parsed.question);
    try std.testing.expectEqualStrings("back", parsed.answer);
    try std.testing.expect(parsed.has_answer);
}
