const std = @import("std");

const content = @import("../content.zig");
const sqlite = @import("sqlite.zig");
const store_mod = @import("store.zig");

pub const ContentMembership = struct {
    store: *store_mod.Store,

    pub fn init(store: *store_mod.Store) ContentMembership {
        return .{ .store = store };
    }

    /// Resolve the deck that owns a logical note through its generated cards.
    ///
    /// Notes deliberately do not duplicate deck ownership. If persisted data
    /// ever links one note's generated cards to more than one deck, surface an
    /// invariant error instead of choosing an arbitrary deck.
    pub fn deckIdForNote(
        self: ContentMembership,
        allocator: std.mem.Allocator,
        note_id: content.NoteId,
    ) !?u64 {
        _ = allocator;
        return switch (self.store.*) {
            .sqlite => |db| sqliteDeckIdForNote(db, note_id),
        };
    }
};

fn sqliteDeckIdForNote(db: *sqlite.Db, note_id: content.NoteId) !?u64 {
    const sql =
        "SELECT DISTINCT c.deck_id " ++
        "FROM generated_cards g " ++
        "JOIN cards c ON c.id = g.card_id " ++
        "WHERE g.note_id = ?1 " ++
        "ORDER BY c.deck_id LIMIT 2;";

    var stmt: ?*sqlite.c.sqlite3_stmt = null;
    if (sqlite.c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null) != sqlite.c.SQLITE_OK or stmt == null) {
        return error.SqlitePrepareFailed;
    }
    defer _ = sqlite.c.sqlite3_finalize(stmt.?);

    const signed_id = std.math.cast(i64, note_id) orelse return error.IdOutOfRange;
    if (sqlite.c.sqlite3_bind_int64(stmt.?, 1, signed_id) != sqlite.c.SQLITE_OK) return error.SqliteBindFailed;

    const first = sqlite.c.sqlite3_step(stmt.?);
    if (first == sqlite.c.SQLITE_DONE) return null;
    if (first != sqlite.c.SQLITE_ROW) return error.SqliteStepFailed;
    const deck_id: u64 = @intCast(sqlite.c.sqlite3_column_int64(stmt.?, 0));

    const second = sqlite.c.sqlite3_step(stmt.?);
    if (second == sqlite.c.SQLITE_ROW) return error.NoteSpansDecks;
    if (second != sqlite.c.SQLITE_DONE) return error.SqliteStepFailed;
    return deck_id;
}

test "content membership resolves a note through generated cards" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();

    var store: store_mod.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("membership", 0);
    const content_store = @import("content_store.zig").ContentStore.init(&store);
    const created = try content_store.createBasicNote(
        std.testing.allocator,
        deck_id,
        "front",
        "back",
        "[]",
        0,
    );
    defer created.deinit(std.testing.allocator);

    const membership = ContentMembership.init(&store);
    try std.testing.expectEqual(deck_id, (try membership.deckIdForNote(std.testing.allocator, created.note_id)).?);
    try std.testing.expectEqual(@as(?u64, null), try membership.deckIdForNote(std.testing.allocator, created.note_id + 1000));
}
