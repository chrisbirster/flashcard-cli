const std = @import("std");
const card_mod = @import("../card.zig");
const fsrs = @import("../fsrs/root.zig");
const time = @import("../time.zig");
const sqlite = @import("sqlite.zig");
const sqlite_cards = @import("sqlite_cards.zig");
const catalog_mod = @import("catalog.zig");
const report_mod = @import("report.zig");
const card_lifecycle = @import("card_lifecycle.zig");

const Allocator = std.mem.Allocator;
const all_due_limit: usize = @intCast(std.math.maxInt(i64));

/// Plandalf persistence boundary.
///
/// Plandalf intentionally has one storage backend: SQLite. The tagged union is
/// retained so existing call sites can continue constructing `.{ .sqlite = &db }`
/// while the legacy multi-backend implementation is removed.
pub const Store = union(enum) {
    sqlite: *sqlite.Db,

    fn db(self: *Store) *sqlite.Db {
        return switch (self.*) {
            .sqlite => |db| db,
        };
    }

    pub fn deinit(self: *Store) void {
        self.* = undefined;
    }

    pub fn createDeck(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.DeckId {
        return self.db().createDeck(name, created_at_ms);
    }

    pub fn getDeck(
        self: *Store,
        allocator: Allocator,
        id: card_mod.DeckId,
    ) !?sqlite.OwnedDeck {
        return self.db().getDeck(allocator, id);
    }

    pub fn renameDeck(self: *Store, id: card_mod.DeckId, name: []const u8) !void {
        try self.db().renameDeck(id, name);
    }

    fn ensureCardHasNoReviewHistory(self: *Store, id: card_mod.CardId) !void {
        const history = try self.loadHistory(std.heap.page_allocator, id);
        defer std.heap.page_allocator.free(history);
        if (history.len != 0) return error.ReviewHistoryExists;
    }

    pub fn deleteDeck(self: *Store, id: card_mod.DeckId) !void {
        const deck_cards = try self.allCards(std.heap.page_allocator, id);
        defer {
            for (deck_cards) |card| card.deinit(std.heap.page_allocator);
            std.heap.page_allocator.free(deck_cards);
        }
        for (deck_cards) |card| try self.ensureCardHasNoReviewHistory(card.id);
        for (deck_cards) |card| try self.restoreCard(card.id);
        try self.db().deleteDeck(id);
    }

    pub fn createCard(
        self: *Store,
        deck_id: card_mod.DeckId,
        question: []const u8,
        answer: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.CardId {
        return self.db().createCard(deck_id, question, answer, created_at_ms);
    }

    pub fn getCard(
        self: *Store,
        allocator: Allocator,
        id: card_mod.CardId,
    ) !?sqlite.OwnedCard {
        return self.db().getCard(allocator, id);
    }

    pub fn allCards(
        self: *Store,
        allocator: Allocator,
        deck_id: card_mod.DeckId,
    ) ![]sqlite.OwnedCard {
        return sqlite_cards.list(self.db(), allocator, deck_id);
    }

    fn activeCardsFromOwned(
        self: *Store,
        allocator: Allocator,
        owned: []sqlite.OwnedCard,
    ) ![]sqlite.OwnedCard {
        var active: std.ArrayList(sqlite.OwnedCard) = .empty;
        errdefer {
            for (active.items) |card| card.deinit(allocator);
            active.deinit(allocator);
        }

        var index: usize = 0;
        errdefer {
            for (owned[index..]) |card| card.deinit(allocator);
            allocator.free(owned);
        }
        while (index < owned.len) {
            const card = owned[index];
            if (try self.isCardRetired(card.id)) {
                card.deinit(allocator);
            } else {
                active.append(allocator, card) catch |err| {
                    card.deinit(allocator);
                    return err;
                };
            }
            index += 1;
        }
        allocator.free(owned);
        return active.toOwnedSlice(allocator);
    }

    pub fn cards(
        self: *Store,
        allocator: Allocator,
        deck_id: card_mod.DeckId,
    ) ![]sqlite.OwnedCard {
        return self.activeCardsFromOwned(allocator, try self.allCards(allocator, deck_id));
    }

    pub fn updateCard(
        self: *Store,
        id: card_mod.CardId,
        question: []const u8,
        answer: []const u8,
    ) !void {
        try self.db().updateCard(id, question, answer);
    }

    pub fn retireCard(self: *Store, id: card_mod.CardId, retired_at_ms: time.TimestampMs) !void {
        try card_lifecycle.sqliteRetire(self.db(), id, retired_at_ms);
    }

    pub fn restoreCard(self: *Store, id: card_mod.CardId) !void {
        try card_lifecycle.sqliteRestore(self.db(), id);
    }

    pub fn isCardRetired(self: *Store, id: card_mod.CardId) !bool {
        return card_lifecycle.sqliteIsRetired(self.db(), id);
    }

    pub fn deleteCard(self: *Store, id: card_mod.CardId) !void {
        try self.ensureCardHasNoReviewHistory(id);
        try self.restoreCard(id);
        try self.db().deleteCard(id);
    }

    pub fn loadHistory(
        self: *Store,
        allocator: Allocator,
        card_id: card_mod.CardId,
    ) ![]fsrs.HistoryEntry {
        return self.db().loadHistory(allocator, card_id);
    }

    pub fn putFsrs7Parameters(
        self: *Store,
        parameters: fsrs.v7.Parameters,
        source: []const u8,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        return (catalog_mod.Catalog{ .db = self.db() }).putFsrs7Parameters(
            parameters,
            source,
            created_at_ms,
        );
    }

    pub fn loadFsrs7Parameters(
        self: *Store,
        id: fsrs.ParameterSetId,
    ) !fsrs.v7.Parameters {
        return (catalog_mod.Catalog{ .db = self.db() }).loadFsrs7Parameters(id);
    }

    pub fn ensureDefaultFsrs7(
        self: *Store,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        return (catalog_mod.Catalog{ .db = self.db() }).ensureDefaultFsrs7(created_at_ms);
    }

    pub fn resolveDeckScheduler(
        self: *Store,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
    ) !catalog_mod.ResolvedScheduler {
        return (catalog_mod.Catalog{ .db = self.db() }).resolveDeckScheduler(deck_id, now_ms);
    }

    pub fn setGlobalFsrs7(self: *Store, parameter_set_id: fsrs.ParameterSetId) !void {
        try (catalog_mod.Catalog{ .db = self.db() }).setGlobalFsrs7(parameter_set_id);
    }

    pub fn setDeckFsrs7(
        self: *Store,
        deck_id: card_mod.DeckId,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        _ = try self.loadFsrs7Parameters(parameter_set_id);
        try (catalog_mod.Catalog{ .db = self.db() }).setDeckFsrs7(deck_id, parameter_set_id);
    }

    pub fn createGroup(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !u64 {
        return (catalog_mod.Catalog{ .db = self.db() }).createGroup(name, created_at_ms);
    }

    pub fn assignDeckGroup(
        self: *Store,
        deck_id: card_mod.DeckId,
        group_id: ?u64,
    ) !void {
        try (catalog_mod.Catalog{ .db = self.db() }).assignDeckGroup(deck_id, group_id);
    }

    pub fn inheritDeckScheduler(self: *Store, deck_id: card_mod.DeckId) !void {
        try (catalog_mod.Catalog{ .db = self.db() }).inheritDeckScheduler(deck_id);
    }

    pub fn setGroupFsrs7(
        self: *Store,
        group_id: u64,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        try (catalog_mod.Catalog{ .db = self.db() }).setGroupFsrs7(group_id, parameter_set_id);
    }

    pub fn recordReviewAndState(
        self: *Store,
        card_id: card_mod.CardId,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
        state: catalog_mod.SchedulerState,
        scheduled_at_ms: time.TimestampMs,
    ) !u64 {
        if (state.card_id != card_id) return error.InvalidSchedulerState;
        const db_value = self.db();
        const catalog: catalog_mod.Catalog = .{ .db = db_value };
        try db_value.beginImmediate();
        errdefer db_value.rollback();
        const review_id = try catalog.appendReview(
            card_id,
            rating,
            reviewed_at_ms,
            state.stamp,
            scheduled_at_ms,
        );
        try catalog.upsertSchedulerState(state);
        try db_value.commit();
        return review_id;
    }

    pub fn upsertSchedulerState(self: *Store, state: catalog_mod.SchedulerState) !void {
        try (catalog_mod.Catalog{ .db = self.db() }).upsertSchedulerState(state);
    }

    pub fn clearSchedulerState(self: *Store, card_id: card_mod.CardId) !void {
        try self.db().clearSchedulerState(card_id);
    }

    pub fn getSchedulerState(
        self: *Store,
        card_id: card_mod.CardId,
    ) !?catalog_mod.SchedulerState {
        return (catalog_mod.Catalog{ .db = self.db() }).getSchedulerState(card_id);
    }

    fn activeDueCardsFromOwned(
        self: *Store,
        allocator: Allocator,
        owned: []catalog_mod.OwnedDueCard,
        limit: usize,
    ) ![]catalog_mod.OwnedDueCard {
        var active: std.ArrayList(catalog_mod.OwnedDueCard) = .empty;
        errdefer {
            for (active.items) |card| card.deinit(allocator);
            active.deinit(allocator);
        }

        var index: usize = 0;
        errdefer {
            for (owned[index..]) |card| card.deinit(allocator);
            allocator.free(owned);
        }
        while (index < owned.len) {
            const card = owned[index];
            if (try self.isCardRetired(card.id)) {
                card.deinit(allocator);
            } else if (active.items.len < limit) {
                active.append(allocator, card) catch |err| {
                    card.deinit(allocator);
                    return err;
                };
            } else {
                card.deinit(allocator);
            }
            index += 1;
        }
        allocator.free(owned);
        return active.toOwnedSlice(allocator);
    }

    pub fn dueCards(
        self: *Store,
        allocator: Allocator,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
        limit: usize,
    ) ![]catalog_mod.OwnedDueCard {
        const backend_limit = if (limit == 0) 0 else all_due_limit;
        const owned = try (catalog_mod.Catalog{ .db = self.db() }).dueCards(
            allocator,
            deck_id,
            now_ms,
            backend_limit,
        );
        return self.activeDueCardsFromOwned(allocator, owned, limit);
    }

    pub fn decks(
        self: *Store,
        allocator: Allocator,
        now_ms: time.TimestampMs,
    ) ![]report_mod.DeckSummary {
        const summaries = try (report_mod.Report{ .db = self.db() }).decks(allocator, now_ms);
        errdefer {
            for (summaries) |summary| summary.deinit(allocator);
            allocator.free(summaries);
        }

        for (summaries) |*summary| {
            const deck_cards = try self.cards(allocator, summary.id);
            defer {
                for (deck_cards) |card| card.deinit(allocator);
                allocator.free(deck_cards);
            }
            const due = try self.dueCards(allocator, summary.id, now_ms, all_due_limit);
            defer {
                for (due) |card| card.deinit(allocator);
                allocator.free(due);
            }
            summary.card_count = deck_cards.len;
            summary.due_count = due.len;
        }
        return summaries;
    }

    pub fn stats(
        self: *Store,
        now_ms: time.TimestampMs,
        deck_id: ?card_mod.DeckId,
    ) !report_mod.Stats {
        var result = try (report_mod.Report{ .db = self.db() }).stats(now_ms, deck_id);

        if (deck_id) |id| {
            const deck_cards = try self.cards(std.heap.page_allocator, id);
            defer {
                for (deck_cards) |card| card.deinit(std.heap.page_allocator);
                std.heap.page_allocator.free(deck_cards);
            }
            const due = try self.dueCards(std.heap.page_allocator, id, now_ms, all_due_limit);
            defer {
                for (due) |card| card.deinit(std.heap.page_allocator);
                std.heap.page_allocator.free(due);
            }
            result.card_count = deck_cards.len;
            result.due_count = due.len;
            return result;
        }

        const summaries = try self.decks(std.heap.page_allocator, now_ms);
        defer {
            for (summaries) |summary| summary.deinit(std.heap.page_allocator);
            std.heap.page_allocator.free(summaries);
        }
        result.card_count = 0;
        result.due_count = 0;
        for (summaries) |summary| {
            result.card_count += summary.card_count;
            result.due_count += summary.due_count;
        }
        return result;
    }

    pub fn histories(
        self: *Store,
        allocator: Allocator,
        deck_id: ?card_mod.DeckId,
    ) !report_mod.OwnedHistories {
        return (report_mod.Report{ .db = self.db() }).histories(allocator, deck_id);
    }
};

test "SQLite remains usable through Store" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("zig", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);
    const card = (try store.getCard(std.testing.allocator, card_id)).?;
    defer card.deinit(std.testing.allocator);
    try std.testing.expectEqual(deck_id, card.deck_id);
}

test "retired cards are hidden from active list due queue and counts" {
    var db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("retired", 0);
    const retired_id = try store.createCard(deck_id, "retired", "r", 0);
    const active_id = try store.createCard(deck_id, "active", "a", 0);
    try store.retireCard(retired_id, 10);

    const active = try store.cards(std.testing.allocator, deck_id);
    defer {
        for (active) |card| card.deinit(std.testing.allocator);
        std.testing.allocator.free(active);
    }
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(active_id, active[0].id);

    const all = try store.allCards(std.testing.allocator, deck_id);
    defer {
        for (all) |card| card.deinit(std.testing.allocator);
        std.testing.allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const due = try store.dueCards(std.testing.allocator, deck_id, 0, 1);
    defer {
        for (due) |card| card.deinit(std.testing.allocator);
        std.testing.allocator.free(due);
    }
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(active_id, due[0].id);

    const counts = try store.stats(0, deck_id);
    try std.testing.expectEqual(@as(usize, 1), counts.card_count);
    try std.testing.expectEqual(@as(usize, 1), counts.due_count);

    try store.restoreCard(retired_id);
    try std.testing.expect(!try store.isCardRetired(retired_id));
}
