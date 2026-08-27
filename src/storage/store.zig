const std = @import("std");
const card_mod = @import("../card.zig");
const fsrs = @import("../fsrs/root.zig");
const time = @import("../time.zig");
const sqlite = @import("sqlite.zig");
const sqlite_cards = @import("sqlite_cards.zig");
const catalog_mod = @import("catalog.zig");
const report_mod = @import("report.zig");
const mongodb = @import("mongodb.zig");
const mongodb_cards = @import("mongodb_cards.zig");
const card_lifecycle = @import("card_lifecycle.zig");

const Allocator = std.mem.Allocator;
const all_due_limit: usize = @intCast(std.math.maxInt(i64));

/// Deez persistence boundary.
///
/// This is deliberately an operation-oriented tagged union rather than a
/// generic database/query API. SQLite is free to use normalized tables and SQL;
/// MongoDB is free to use Mongo-native embedded documents and indexes.
pub const Store = union(enum) {
    sqlite: *sqlite.Db,
    mongodb: mongodb.Store,

    pub fn deinit(self: *Store) void {
        switch (self.*) {
            .sqlite => {}, // the caller owns the SQLite Db lifetime
            .mongodb => |*store| store.deinit(),
        }
        self.* = undefined;
    }

    pub fn createDeck(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.DeckId {
        return switch (self.*) {
            .sqlite => |db| db.createDeck(name, created_at_ms),
            .mongodb => |*store| store.createDeck(name, created_at_ms),
        };
    }

    pub fn getDeck(
        self: *Store,
        allocator: Allocator,
        id: card_mod.DeckId,
    ) !?sqlite.OwnedDeck {
        return switch (self.*) {
            .sqlite => |db| db.getDeck(allocator, id),
            .mongodb => |*store| store.getDeck(allocator, id),
        };
    }

    pub fn renameDeck(self: *Store, id: card_mod.DeckId, name: []const u8) !void {
        switch (self.*) {
            .sqlite => |db| try db.renameDeck(id, name),
            .mongodb => |*store| try store.renameDeck(id, name),
        }
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

        switch (self.*) {
            .sqlite => |db| try db.deleteDeck(id),
            .mongodb => |*store| try store.deleteDeck(id),
        }
    }

    pub fn createCard(
        self: *Store,
        deck_id: card_mod.DeckId,
        question: []const u8,
        answer: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.CardId {
        return switch (self.*) {
            .sqlite => |db| db.createCard(deck_id, question, answer, created_at_ms),
            .mongodb => |*store| store.createCard(deck_id, question, answer, created_at_ms),
        };
    }

    pub fn getCard(
        self: *Store,
        allocator: Allocator,
        id: card_mod.CardId,
    ) !?sqlite.OwnedCard {
        return switch (self.*) {
            .sqlite => |db| db.getCard(allocator, id),
            .mongodb => |*store| store.getCard(allocator, id),
        };
    }

    pub fn allCards(
        self: *Store,
        allocator: Allocator,
        deck_id: card_mod.DeckId,
    ) ![]sqlite.OwnedCard {
        return switch (self.*) {
            .sqlite => |db| sqlite_cards.list(db, allocator, deck_id),
            .mongodb => |*store| mongodb_cards.list(store, allocator, deck_id),
        };
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
        switch (self.*) {
            .sqlite => |db| try db.updateCard(id, question, answer),
            .mongodb => |*store| try store.updateCard(id, question, answer),
        }
    }

    pub fn retireCard(self: *Store, id: card_mod.CardId, retired_at_ms: time.TimestampMs) !void {
        switch (self.*) {
            .sqlite => |db| try card_lifecycle.sqliteRetire(db, id, retired_at_ms),
            .mongodb => |*store| try card_lifecycle.mongoRetire(store, id, retired_at_ms),
        }
    }

    pub fn restoreCard(self: *Store, id: card_mod.CardId) !void {
        switch (self.*) {
            .sqlite => |db| try card_lifecycle.sqliteRestore(db, id),
            .mongodb => |*store| try card_lifecycle.mongoRestore(store, id),
        }
    }

    pub fn isCardRetired(self: *Store, id: card_mod.CardId) !bool {
        return switch (self.*) {
            .sqlite => |db| card_lifecycle.sqliteIsRetired(db, id),
            .mongodb => |*store| card_lifecycle.mongoIsRetired(store, id),
        };
    }

    pub fn deleteCard(self: *Store, id: card_mod.CardId) !void {
        try self.ensureCardHasNoReviewHistory(id);
        try self.restoreCard(id);
        switch (self.*) {
            .sqlite => |db| try db.deleteCard(id),
            .mongodb => |*store| try store.deleteCard(id),
        }
    }

    pub fn loadHistory(
        self: *Store,
        allocator: Allocator,
        card_id: card_mod.CardId,
    ) ![]fsrs.HistoryEntry {
        return switch (self.*) {
            .sqlite => |db| db.loadHistory(allocator, card_id),
            .mongodb => |*store| store.loadHistory(allocator, card_id),
        };
    }

    pub fn putFsrs7Parameters(
        self: *Store,
        parameters: fsrs.v7.Parameters,
        source: []const u8,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).putFsrs7Parameters(
                parameters,
                source,
                created_at_ms,
            ),
            .mongodb => |*store| store.putFsrs7Parameters(parameters, source, created_at_ms),
        };
    }

    pub fn loadFsrs7Parameters(
        self: *Store,
        id: fsrs.ParameterSetId,
    ) !fsrs.v7.Parameters {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).loadFsrs7Parameters(id),
            .mongodb => |*store| store.loadFsrs7Parameters(id),
        };
    }

    pub fn ensureDefaultFsrs7(
        self: *Store,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).ensureDefaultFsrs7(created_at_ms),
            .mongodb => |*store| store.ensureDefaultFsrs7(created_at_ms),
        };
    }

    pub fn resolveDeckScheduler(
        self: *Store,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
    ) !catalog_mod.ResolvedScheduler {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).resolveDeckScheduler(deck_id, now_ms),
            .mongodb => |*store| blk: {
                const deck = (try store.getDeck(store.allocator, deck_id)) orelse
                    return error.DeckNotFound;
                defer deck.deinit(store.allocator);
                if (!deck.algorithm.eql(.fsrs7)) return error.UnsupportedAlgorithm;
                break :blk try store.resolveDeckScheduler(deck_id, now_ms);
            },
        };
    }

    pub fn setGlobalFsrs7(self: *Store, parameter_set_id: fsrs.ParameterSetId) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).setGlobalFsrs7(parameter_set_id),
            .mongodb => |*store| try store.setGlobalFsrs7(parameter_set_id),
        }
    }

    pub fn setDeckFsrs7(
        self: *Store,
        deck_id: card_mod.DeckId,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        _ = try self.loadFsrs7Parameters(parameter_set_id);
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).setDeckFsrs7(deck_id, parameter_set_id),
            .mongodb => |*store| try store.setDeckFsrs7(deck_id, parameter_set_id),
        }
    }

    pub fn createGroup(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !u64 {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).createGroup(name, created_at_ms),
            .mongodb => |*store| store.createGroup(name, created_at_ms),
        };
    }

    pub fn assignDeckGroup(
        self: *Store,
        deck_id: card_mod.DeckId,
        group_id: ?u64,
    ) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).assignDeckGroup(deck_id, group_id),
            .mongodb => |*store| try store.assignDeckGroup(deck_id, group_id),
        }
    }

    pub fn inheritDeckScheduler(self: *Store, deck_id: card_mod.DeckId) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).inheritDeckScheduler(deck_id),
            .mongodb => |*store| try store.inheritDeckScheduler(deck_id),
        }
    }

    pub fn setGroupFsrs7(
        self: *Store,
        group_id: u64,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).setGroupFsrs7(group_id, parameter_set_id),
            .mongodb => |*store| try store.setGroupFsrs7(group_id, parameter_set_id),
        }
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
        return switch (self.*) {
            .sqlite => |db| blk: {
                const catalog: catalog_mod.Catalog = .{ .db = db };
                try db.beginImmediate();
                errdefer db.rollback();
                const review_id = try catalog.appendReview(
                    card_id,
                    rating,
                    reviewed_at_ms,
                    state.stamp,
                    scheduled_at_ms,
                );
                try catalog.upsertSchedulerState(state);
                try db.commit();
                break :blk review_id;
            },
            .mongodb => |*store| blk: {
                const card = (try store.getCard(store.allocator, card_id)) orelse
                    return error.CardNotFound;
                defer card.deinit(store.allocator);
                break :blk try store.recordReviewAndState(
                    card_id,
                    rating,
                    reviewed_at_ms,
                    state,
                    scheduled_at_ms,
                );
            },
        };
    }

    pub fn upsertSchedulerState(self: *Store, state: catalog_mod.SchedulerState) !void {
        switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).upsertSchedulerState(state),
            .mongodb => |*store| try store.upsertSchedulerState(state),
        }
    }

    pub fn clearSchedulerState(self: *Store, card_id: card_mod.CardId) !void {
        switch (self.*) {
            .sqlite => |db| try db.clearSchedulerState(card_id),
            .mongodb => |*store| try store.clearSchedulerState(card_id),
        }
    }

    pub fn getSchedulerState(
        self: *Store,
        card_id: card_mod.CardId,
    ) !?catalog_mod.SchedulerState {
        return switch (self.*) {
            .sqlite => |db| (catalog_mod.Catalog{ .db = db }).getSchedulerState(card_id),
            .mongodb => |*store| store.getSchedulerState(card_id),
        };
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
        const owned = switch (self.*) {
            .sqlite => |db| try (catalog_mod.Catalog{ .db = db }).dueCards(allocator, deck_id, now_ms, backend_limit),
            .mongodb => |*store| try store.dueCards(allocator, deck_id, now_ms, backend_limit),
        };
        return self.activeDueCardsFromOwned(allocator, owned, limit);
    }

    pub fn decks(
        self: *Store,
        allocator: Allocator,
        now_ms: time.TimestampMs,
    ) ![]report_mod.DeckSummary {
        const summaries = switch (self.*) {
            .sqlite => |db| try (report_mod.Report{ .db = db }).decks(allocator, now_ms),
            .mongodb => |*store| try store.decks(allocator, now_ms),
        };
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
        var result = switch (self.*) {
            .sqlite => |db| try (report_mod.Report{ .db = db }).stats(now_ms, deck_id),
            .mongodb => |*store| try store.stats(now_ms, deck_id),
        };

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
        return switch (self.*) {
            .sqlite => |db| (report_mod.Report{ .db = db }).histories(allocator, deck_id),
            .mongodb => |*store| store.histories(allocator, deck_id),
        };
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
