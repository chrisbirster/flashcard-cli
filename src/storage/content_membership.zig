const std = @import("std");
const bongo = @import("bongo");

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
        return switch (self.store.*) {
            .sqlite => |db| sqliteDeckIdForNote(db, note_id),
            .mongodb => |*mongo| mongoDeckIdForNote(allocator, mongo, note_id),
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

fn mongoDeckIdForNote(
    allocator: std.mem.Allocator,
    store: *@import("mongodb.zig").Store,
    note_id: content.NoteId,
) !?u64 {
    const signed_id = std.math.cast(i64, note_id) orelse return error.IdOutOfRange;
    var cursor = try store.client.find(
        store.client.databaseName(),
        "generated_cards",
        .{ .note_id = signed_id },
        .{ .sort = .{ ._id = @as(i32, 1) } },
    );
    defer cursor.deinit();

    var deck_id: ?u64 = null;
    while (try cursor.next()) |document| {
        const value = (try bongo.bson.Reader.get(document, "_id")) orelse return error.MissingField;
        const signed_card_id = switch (value) {
            .int32 => |v| @as(i64, v),
            .int64 => |v| v,
            else => return error.InvalidField,
        };
        const card_id: u64 = @intCast(signed_card_id);
        const card = (try store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);

        if (deck_id) |existing| {
            if (existing != card.deck_id) return error.NoteSpansDecks;
        } else {
            deck_id = card.deck_id;
        }
    }
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
