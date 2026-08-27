const std = @import("std");
const bongo = @import("bongo");
const card_mod = @import("../card.zig");
const fsrs = @import("../fsrs/root.zig");
const time = @import("../time.zig");
const sqlite = @import("sqlite.zig");
const catalog_mod = @import("catalog.zig");
const report_mod = @import("report.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const q = bongo.query;

pub const Error = error{
    MissingField,
    InvalidField,
    InvalidParameterSetId,
    InvalidParameterWeights,
    ParameterSetNotFound,
    DeckNotFound,
    CardNotFound,
    InvalidSchedulerConfiguration,
    UnsupportedAlgorithmFamily,
};

/// Mongo-native Deez persistence.
///
/// MongoDB intentionally does not mirror the SQLite tables. Scheduler state is
/// embedded in each card, FSRS weights are one BSON array, and counters provide
/// stable numeric IDs so Deez's public IDs do not change between backends.
pub const Store = struct {
    allocator: Allocator,
    client: bongo.RuntimeClient,

    pub fn connect(
        io: Io,
        allocator: Allocator,
        uri: []const u8,
    ) !Store {
        var client = try bongo.RuntimeClient.connectUri(io, allocator, uri, .{});
        errdefer client.deinit();
        var self: Store = .{ .allocator = allocator, .client = client };
        try self.ensureIndexes();
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.client.deinit();
        self.* = undefined;
    }

    fn database(self: *Store) []const u8 {
        return self.client.databaseName();
    }

    pub fn createDeck(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.DeckId {
        const id = try self.nextId("deck");
        _ = try self.client.insertOne(self.database(), "decks", .{
            ._id = id,
            .name = name,
            .created_at_ms = created_at_ms,
            .group_id = @as(?i64, null),
            .algorithm_major = @as(?i32, null),
            .parameter_set_id = @as(?bongo.bson.Binary, null),
        });
        return @intCast(id);
    }

    pub fn getDeck(
        self: *Store,
        allocator: Allocator,
        id: card_mod.DeckId,
    ) !?sqlite.OwnedDeck {
        var owned = (try self.client.findOne(
            self.database(),
            "decks",
            .{ ._id = try idAsI64(id) },
        )) orelse return null;
        defer owned.deinit();
        const document = owned.bytes;
        const name = try allocator.dupe(u8, try requiredString(document, "name"));
        errdefer allocator.free(name);
        const algorithm_major = (try optionalI64(document, "algorithm_major")) orelse 7;
        const parameter_set_id = try optionalParameterSetId(document, "parameter_set_id");
        return .{
            .id = id,
            .name = name,
            .algorithm = .{ .family = .fsrs, .major = @intCast(algorithm_major) },
            .parameter_set_id = parameter_set_id,
        };
    }

    pub fn renameDeck(self: *Store, id: card_mod.DeckId, name: []const u8) !void {
        var result = try self.client.updateOne(
            self.database(),
            "decks",
            .{ ._id = try idAsI64(id) },
            q.set(.{ .name = name }),
            false,
        );
        defer result.deinit();
    }

    pub fn deleteDeck(self: *Store, id: card_mod.DeckId) !void {
        var cards = try self.client.find(
            self.database(),
            "cards",
            .{ .deck_id = try idAsI64(id) },
            .{ .sort = .{ ._id = @as(i32, 1) } },
        );
        defer cards.deinit();
        while (try cards.next()) |document| {
            const card_id: card_mod.CardId = @intCast(try requiredI64(document, "_id"));
            try self.deleteCard(card_id);
        }
        _ = try self.client.deleteOne(
            self.database(),
            "decks",
            .{ ._id = try idAsI64(id) },
        );
    }

    pub fn setDeckScheduler(
        self: *Store,
        id: card_mod.DeckId,
        algorithm: fsrs.AlgorithmId,
        parameter_set_id: ?fsrs.ParameterSetId,
    ) !void {
        if (algorithm.family != .fsrs) return error.UnsupportedAlgorithmFamily;
        const binary = if (parameter_set_id) |*value| parameterBinary(value) else null;
        var result = try self.client.updateOne(
            self.database(),
            "decks",
            .{ ._id = try idAsI64(id) },
            q.set(.{
                .algorithm_major = @as(?i32, @intCast(algorithm.major)),
                .parameter_set_id = binary,
            }),
            false,
        );
        defer result.deinit();
    }

    pub fn createCard(
        self: *Store,
        deck_id: card_mod.DeckId,
        question: []const u8,
        answer: []const u8,
        created_at_ms: time.TimestampMs,
    ) !card_mod.CardId {
        const id = try self.nextId("card");
        _ = try self.client.insertOne(self.database(), "cards", .{
            ._id = id,
            .deck_id = try idAsI64(deck_id),
            .question = question,
            .answer = answer,
            .created_at_ms = created_at_ms,
            // New cards are due immediately. Keeping the sortable due value at
            // the top level avoids a SQL-style join and makes the Mongo query
            // a simple compound-index range scan.
            .due_at_ms = created_at_ms,
            .scheduler_state = @as(?SchedulerDocument, null),
        });
        return @intCast(id);
    }

    pub fn getCard(
        self: *Store,
        allocator: Allocator,
        id: card_mod.CardId,
    ) !?sqlite.OwnedCard {
        var owned = (try self.client.findOne(
            self.database(),
            "cards",
            .{ ._id = try idAsI64(id) },
        )) orelse return null;
        defer owned.deinit();
        const document = owned.bytes;
        const question = try allocator.dupe(u8, try requiredString(document, "question"));
        errdefer allocator.free(question);
        const answer = try allocator.dupe(u8, try requiredString(document, "answer"));
        errdefer allocator.free(answer);
        return .{
            .id = id,
            .deck_id = @intCast(try requiredI64(document, "deck_id")),
            .question = question,
            .answer = answer,
        };
    }

    pub fn updateCard(
        self: *Store,
        id: card_mod.CardId,
        question: []const u8,
        answer: []const u8,
    ) !void {
        var result = try self.client.updateOne(
            self.database(),
            "cards",
            .{ ._id = try idAsI64(id) },
            q.set(.{ .question = question, .answer = answer }),
            false,
        );
        defer result.deinit();
    }

    pub fn deleteCard(self: *Store, id: card_mod.CardId) !void {
        var reviews = try self.client.find(
            self.database(),
            "reviews",
            .{ .card_id = try idAsI64(id) },
            .{ .sort = .{ ._id = @as(i32, 1) } },
        );
        defer reviews.deinit();
        while (try reviews.next()) |document| {
            _ = try self.client.deleteOne(
                self.database(),
                "reviews",
                .{ ._id = try requiredI64(document, "_id") },
            );
        }
        _ = try self.client.deleteOne(
            self.database(),
            "cards",
            .{ ._id = try idAsI64(id) },
        );
    }

    pub fn loadHistory(
        self: *Store,
        allocator: Allocator,
        card_id: card_mod.CardId,
    ) ![]fsrs.HistoryEntry {
        var cursor = try self.client.find(
            self.database(),
            "reviews",
            .{ .card_id = try idAsI64(card_id) },
            .{ .sort = .{ .reviewed_at_ms = @as(i32, 1), ._id = @as(i32, 1) } },
        );
        defer cursor.deinit();
        var history: std.ArrayList(fsrs.HistoryEntry) = .empty;
        errdefer history.deinit(allocator);
        while (try cursor.next()) |document| {
            const rating_value: u8 = @intCast(try requiredI64(document, "rating"));
            try history.append(allocator, .{
                .rating = try fsrs.Rating.fromValue(rating_value),
                .reviewed_at_ms = try requiredI64(document, "reviewed_at_ms"),
            });
        }
        return history.toOwnedSlice(allocator);
    }

    pub fn recordReviewAndState(
        self: *Store,
        card_id: card_mod.CardId,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
        state: catalog_mod.SchedulerState,
        scheduled_at_ms: time.TimestampMs,
    ) !u64 {
        const review_id = try self.nextId("review");
        const review = reviewDocument(review_id, card_id, rating, reviewed_at_ms, &state.stamp, scheduled_at_ms);
        const scheduler = schedulerDocument(&state);

        if (self.client.supports_transactions) {
            var transaction = try self.client.beginTransaction(.{});
            defer transaction.deinit();
            _ = try transaction.insertOne(self.database(), "reviews", review);
            var update = try transaction.updateOne(
                self.database(),
                "cards",
                .{ ._id = try idAsI64(card_id) },
                q.set(.{
                    .scheduler_state = scheduler,
                    .due_at_ms = state.due_at_ms,
                }),
                false,
            );
            defer update.deinit();
            try transaction.commit();
        } else {
            // Standalone mongod cannot run multi-document transactions. Deez's
            // immutable review log is the source of truth, so this safe fallback
            // persists the review first and lets `rebuildCardState` repair the
            // derived state if the second write fails.
            _ = try self.client.insertOne(self.database(), "reviews", review);
            var update = try self.client.updateOne(
                self.database(),
                "cards",
                .{ ._id = try idAsI64(card_id) },
                q.set(.{
                    .scheduler_state = scheduler,
                    .due_at_ms = state.due_at_ms,
                }),
                false,
            );
            defer update.deinit();
        }
        return @intCast(review_id);
    }

    pub fn upsertSchedulerState(self: *Store, state: catalog_mod.SchedulerState) !void {
        const scheduler = schedulerDocument(&state);
        var result = try self.client.updateOne(
            self.database(),
            "cards",
            .{ ._id = try idAsI64(state.card_id) },
            q.set(.{
                .scheduler_state = scheduler,
                .due_at_ms = state.due_at_ms,
            }),
            false,
        );
        defer result.deinit();
    }

    pub fn clearSchedulerState(self: *Store, card_id: card_mod.CardId) !void {
        var card = (try self.client.findOne(
            self.database(),
            "cards",
            .{ ._id = try idAsI64(card_id) },
        )) orelse return error.CardNotFound;
        defer card.deinit();
        const created_at_ms = try requiredI64(card.bytes, "created_at_ms");
        var result = try self.client.updateOne(
            self.database(),
            "cards",
            .{ ._id = try idAsI64(card_id) },
            .{
                .@"$unset" = .{ .scheduler_state = "" },
                .@"$set" = .{ .due_at_ms = created_at_ms },
            },
            false,
        );
        defer result.deinit();
    }

    pub fn getSchedulerState(
        self: *Store,
        card_id: card_mod.CardId,
    ) !?catalog_mod.SchedulerState {
        var card = (try self.client.findOne(
            self.database(),
            "cards",
            .{ ._id = try idAsI64(card_id) },
        )) orelse return null;
        defer card.deinit();
        const value = (try bongo.bson.Reader.get(card.bytes, "scheduler_state")) orelse return null;
        const document = switch (value) {
            .document => |bytes| bytes,
            .null_value => return null,
            else => return error.InvalidField,
        };
        const state = try parseSchedulerState(card_id, document);
        return state;
    }

    pub fn dueCards(
        self: *Store,
        allocator: Allocator,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
        limit: usize,
    ) ![]catalog_mod.OwnedDueCard {
        var cursor = try self.client.find(
            self.database(),
            "cards",
            .{
                .deck_id = try idAsI64(deck_id),
                .due_at_ms = q.lte(now_ms),
            },
            .{
                .sort = .{ .due_at_ms = @as(i32, 1), ._id = @as(i32, 1) },
                .limit = std.math.cast(i64, limit) orelse std.math.maxInt(i64),
            },
        );
        defer cursor.deinit();
        var result: std.ArrayList(catalog_mod.OwnedDueCard) = .empty;
        errdefer {
            for (result.items) |card| card.deinit(allocator);
            result.deinit(allocator);
        }
        while (try cursor.next()) |document| {
            const question = try allocator.dupe(u8, try requiredString(document, "question"));
            errdefer allocator.free(question);
            const answer = try allocator.dupe(u8, try requiredString(document, "answer"));
            errdefer allocator.free(answer);
            var due: ?i64 = null;
            if (try bongo.bson.Reader.get(document, "scheduler_state")) |value| {
                if (value == .document) due = try requiredI64(value.document, "due_at_ms");
            }
            try result.append(allocator, .{
                .id = @intCast(try requiredI64(document, "_id")),
                .deck_id = @intCast(try requiredI64(document, "deck_id")),
                .question = question,
                .answer = answer,
                .due_at_ms = due,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn putFsrs7Parameters(
        self: *Store,
        parameters: fsrs.v7.Parameters,
        source: []const u8,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        try parameters.validate();
        var id = catalog_mod.Catalog.parameterSetId(parameters);
        if (try self.parameterSetExists(id)) return id;
        const id_binary = parameterBinary(&id);
        _ = try self.client.insertOne(self.database(), "parameter_sets", .{
            ._id = id_binary,
            .algorithm_major = @as(i32, 7),
            .implementation_major = @as(i32, fsrs.ImplementationVersion.current.major),
            .implementation_minor = @as(i32, fsrs.ImplementationVersion.current.minor),
            .implementation_patch = @as(i32, fsrs.ImplementationVersion.current.patch),
            .source = source,
            .weights = parameters.weights,
            .desired_retention = parameters.desired_retention,
            .minimum_interval_days = parameters.minimum_interval_days,
            .maximum_interval_days = parameters.maximum_interval_days,
            .created_at_ms = created_at_ms,
        });
        return id;
    }

    pub fn loadFsrs7Parameters(
        self: *Store,
        id: fsrs.ParameterSetId,
    ) !fsrs.v7.Parameters {
        var stable = id;
        var owned = (try self.client.findOne(
            self.database(),
            "parameter_sets",
            .{ ._id = parameterBinary(&stable) },
        )) orelse return error.ParameterSetNotFound;
        defer owned.deinit();
        var parameters: fsrs.v7.Parameters = .{};
        parameters.desired_retention = try requiredDouble(owned.bytes, "desired_retention");
        parameters.minimum_interval_days = try requiredDouble(owned.bytes, "minimum_interval_days");
        parameters.maximum_interval_days = try requiredDouble(owned.bytes, "maximum_interval_days");
        const weights_value = (try bongo.bson.Reader.get(owned.bytes, "weights")) orelse
            return error.InvalidParameterWeights;
        const weights_array = switch (weights_value) {
            .array => |bytes| bytes,
            else => return error.InvalidParameterWeights,
        };
        var reader = try bongo.bson.Reader.init(weights_array);
        var index: usize = 0;
        while (try reader.next()) |element| {
            if (index >= parameters.weights.len) return error.InvalidParameterWeights;
            parameters.weights[index] = valueAsDouble(element.value) orelse
                return error.InvalidParameterWeights;
            index += 1;
        }
        if (index != parameters.weights.len) return error.InvalidParameterWeights;
        try parameters.validate();
        return parameters;
    }

    pub fn ensureDefaultFsrs7(
        self: *Store,
        created_at_ms: time.TimestampMs,
    ) !fsrs.ParameterSetId {
        const id = try self.putFsrs7Parameters(.{}, "default", created_at_ms);
        var stable = id;
        var result = try self.client.updateOne(
            self.database(),
            "metadata",
            .{ ._id = "scheduler_defaults" },
            .{ .@"$setOnInsert" = .{
                .algorithm_major = @as(i32, 7),
                .parameter_set_id = parameterBinary(&stable),
            } },
            true,
        );
        defer result.deinit();
        return id;
    }

    pub fn resolveDeckScheduler(
        self: *Store,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
    ) !catalog_mod.ResolvedScheduler {
        _ = try self.ensureDefaultFsrs7(now_ms);
        var deck = (try self.client.findOne(
            self.database(),
            "decks",
            .{ ._id = try idAsI64(deck_id) },
        )) orelse return error.DeckNotFound;
        defer deck.deinit();

        if (try optionalParameterSetId(deck.bytes, "parameter_set_id")) |id| {
            return .{ .algorithm = .fsrs7, .parameter_set_id = id };
        }
        if (try optionalI64(deck.bytes, "group_id")) |group_id| {
            var group = (try self.client.findOne(
                self.database(),
                "deck_groups",
                .{ ._id = group_id },
            )) orelse null;
            if (group) |*owned| {
                defer owned.deinit();
                if (try optionalParameterSetId(owned.bytes, "parameter_set_id")) |id| {
                    return .{ .algorithm = .fsrs7, .parameter_set_id = id };
                }
            }
        }
        var defaults = (try self.client.findOne(
            self.database(),
            "metadata",
            .{ ._id = "scheduler_defaults" },
        )) orelse return error.InvalidSchedulerConfiguration;
        defer defaults.deinit();
        return .{
            .algorithm = .fsrs7,
            .parameter_set_id = try requiredParameterSetId(defaults.bytes, "parameter_set_id"),
        };
    }

    pub fn setGlobalFsrs7(self: *Store, parameter_set_id: fsrs.ParameterSetId) !void {
        _ = try self.loadFsrs7Parameters(parameter_set_id);
        var stable = parameter_set_id;
        var result = try self.client.updateOne(
            self.database(),
            "metadata",
            .{ ._id = "scheduler_defaults" },
            q.set(.{
                .algorithm_major = @as(i32, 7),
                .parameter_set_id = parameterBinary(&stable),
            }),
            true,
        );
        defer result.deinit();
    }

    pub fn createGroup(
        self: *Store,
        name: []const u8,
        created_at_ms: time.TimestampMs,
    ) !u64 {
        const id = try self.nextId("group");
        _ = try self.client.insertOne(self.database(), "deck_groups", .{
            ._id = id,
            .name = name,
            .created_at_ms = created_at_ms,
            .algorithm_major = @as(?i32, null),
            .parameter_set_id = @as(?bongo.bson.Binary, null),
        });
        return @intCast(id);
    }

    pub fn assignDeckGroup(
        self: *Store,
        deck_id: card_mod.DeckId,
        group_id: ?u64,
    ) !void {
        const group_value: ?i64 = if (group_id) |id| try idAsI64(id) else null;
        var result = try self.client.updateOne(
            self.database(),
            "decks",
            .{ ._id = try idAsI64(deck_id) },
            q.set(.{ .group_id = group_value }),
            false,
        );
        defer result.deinit();
    }

    pub fn inheritDeckScheduler(self: *Store, deck_id: card_mod.DeckId) !void {
        var result = try self.client.updateOne(
            self.database(),
            "decks",
            .{ ._id = try idAsI64(deck_id) },
            q.set(.{
                .algorithm_major = @as(?i32, null),
                .parameter_set_id = @as(?bongo.bson.Binary, null),
            }),
            false,
        );
        defer result.deinit();
    }

    pub fn setGroupFsrs7(
        self: *Store,
        group_id: u64,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        _ = try self.loadFsrs7Parameters(parameter_set_id);
        var stable = parameter_set_id;
        var result = try self.client.updateOne(
            self.database(),
            "deck_groups",
            .{ ._id = try idAsI64(group_id) },
            q.set(.{
                .algorithm_major = @as(i32, 7),
                .parameter_set_id = parameterBinary(&stable),
            }),
            false,
        );
        defer result.deinit();
    }

    pub fn setDeckFsrs7(
        self: *Store,
        deck_id: card_mod.DeckId,
        parameter_set_id: fsrs.ParameterSetId,
    ) !void {
        try self.setDeckScheduler(deck_id, .fsrs7, parameter_set_id);
    }

    pub fn decks(
        self: *Store,
        allocator: Allocator,
        now_ms: time.TimestampMs,
    ) ![]report_mod.DeckSummary {
        var cursor = try self.client.find(
            self.database(),
            "decks",
            .{},
            .{ .sort = .{ .name = @as(i32, 1), ._id = @as(i32, 1) } },
        );
        defer cursor.deinit();
        var result: std.ArrayList(report_mod.DeckSummary) = .empty;
        errdefer {
            for (result.items) |deck| deck.deinit(allocator);
            result.deinit(allocator);
        }
        while (try cursor.next()) |document| {
            const id: card_mod.DeckId = @intCast(try requiredI64(document, "_id"));
            const name = try allocator.dupe(u8, try requiredString(document, "name"));
            errdefer allocator.free(name);
            try result.append(allocator, .{
                .id = id,
                .name = name,
                .card_count = try self.countCards(id, null),
                .due_count = try self.countCards(id, now_ms),
            });
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn stats(
        self: *Store,
        now_ms: time.TimestampMs,
        deck_id: ?card_mod.DeckId,
    ) !report_mod.Stats {
        return .{
            .deck_count = if (deck_id == null) try self.countCollection("decks", .{}) else 1,
            .card_count = if (deck_id) |id| try self.countCards(id, null) else try self.countCollection("cards", .{}),
            .due_count = if (deck_id) |id| try self.countCards(id, now_ms) else try self.countDueAll(now_ms),
            .review_count = if (deck_id) |id| try self.countReviewsForDeck(id) else try self.countCollection("reviews", .{}),
        };
    }

    pub fn histories(
        self: *Store,
        allocator: Allocator,
        deck_id: ?card_mod.DeckId,
    ) !report_mod.OwnedHistories {
        var cursor = if (deck_id) |id|
            try self.client.find(
                self.database(),
                "cards",
                .{ .deck_id = try idAsI64(id) },
                .{ .sort = .{ ._id = @as(i32, 1) } },
            )
        else
            try self.client.find(
                self.database(),
                "cards",
                .{},
                .{ .sort = .{ ._id = @as(i32, 1) } },
            );
        defer cursor.deinit();
        var histories_list: std.ArrayList([]fsrs.HistoryEntry) = .empty;
        errdefer {
            for (histories_list.items) |history| allocator.free(history);
            histories_list.deinit(allocator);
        }
        while (try cursor.next()) |document| {
            const card_id: card_mod.CardId = @intCast(try requiredI64(document, "_id"));
            const history = try self.loadHistory(allocator, card_id);
            if (history.len > 0) {
                try histories_list.append(allocator, history);
            } else allocator.free(history);
        }
        return .{ .histories = try histories_list.toOwnedSlice(allocator) };
    }

    fn ensureIndexes(self: *Store) !void {
        try self.client.createIndex(
            self.database(),
            "cards",
            .{ .deck_id = @as(i32, 1), .due_at_ms = @as(i32, 1), ._id = @as(i32, 1) },
            "deck_due_id",
            .{},
        );
        try self.client.createIndex(
            self.database(),
            "reviews",
            .{ .card_id = @as(i32, 1), .reviewed_at_ms = @as(i32, 1), ._id = @as(i32, 1) },
            "card_history",
            .{},
        );
    }

    fn nextId(self: *Store, kind: []const u8) !i64 {
        var owned = (try self.client.findOneAndUpdate(
            self.database(),
            "counters",
            .{ ._id = kind },
            q.inc(.{ .value = @as(i64, 1) }),
            true,
        )) orelse return error.MissingField;
        defer owned.deinit();
        return requiredI64(owned.bytes, "value");
    }

    fn parameterSetExists(self: *Store, id: fsrs.ParameterSetId) !bool {
        var stable = id;
        var owned = try self.client.findOne(
            self.database(),
            "parameter_sets",
            .{ ._id = parameterBinary(&stable) },
        );
        if (owned) |*document| document.deinit();
        return owned != null;
    }

    fn countCollection(self: *Store, name: []const u8, filter: anytype) !usize {
        var cursor = try self.client.find(self.database(), name, filter, .{});
        defer cursor.deinit();
        var count: usize = 0;
        while (try cursor.next()) |_| count += 1;
        return count;
    }

    fn countCards(self: *Store, deck_id: card_mod.DeckId, due_at: ?i64) !usize {
        if (due_at) |now_ms| {
            return self.countCollection("cards", .{
                .deck_id = try idAsI64(deck_id),
                .due_at_ms = q.lte(now_ms),
            });
        }
        return self.countCollection("cards", .{ .deck_id = try idAsI64(deck_id) });
    }

    fn countDueAll(self: *Store, now_ms: i64) !usize {
        return self.countCollection("cards", .{ .due_at_ms = q.lte(now_ms) });
    }

    fn countReviewsForDeck(self: *Store, deck_id: card_mod.DeckId) !usize {
        var cards = try self.client.find(
            self.database(),
            "cards",
            .{ .deck_id = try idAsI64(deck_id) },
            .{},
        );
        defer cards.deinit();
        var count: usize = 0;
        while (try cards.next()) |document| {
            const card_id = try requiredI64(document, "_id");
            count += try self.countCollection("reviews", .{ .card_id = card_id });
        }
        return count;
    }
};

const SchedulerDocument = struct {
    algorithm_major: i32,
    implementation_major: i32,
    implementation_minor: i32,
    implementation_patch: i32,
    parameter_set_id: bongo.bson.Binary,
    stability_days: ?f64,
    difficulty: ?f64,
    due_at_ms: i64,
    last_reviewed_at_ms: ?i64,
};

fn schedulerDocument(state: *const catalog_mod.SchedulerState) SchedulerDocument {
    return .{
        .algorithm_major = @intCast(state.stamp.algorithm.major),
        .implementation_major = @intCast(state.stamp.implementation.major),
        .implementation_minor = @intCast(state.stamp.implementation.minor),
        .implementation_patch = @intCast(state.stamp.implementation.patch),
        .parameter_set_id = parameterBinary(&state.stamp.parameter_set_id),
        .stability_days = state.stability_days,
        .difficulty = state.difficulty,
        .due_at_ms = state.due_at_ms,
        .last_reviewed_at_ms = state.last_reviewed_at_ms,
    };
}

fn reviewDocument(
    review_id: i64,
    card_id: card_mod.CardId,
    rating: fsrs.Rating,
    reviewed_at_ms: i64,
    stamp: *const fsrs.SchedulerStamp,
    scheduled_at_ms: i64,
) struct {
    _id: i64,
    card_id: i64,
    rating: i32,
    reviewed_at_ms: i64,
    algorithm_major: i32,
    implementation_major: i32,
    implementation_minor: i32,
    implementation_patch: i32,
    parameter_set_id: bongo.bson.Binary,
    scheduled_at_ms: i64,
} {
    return .{
        ._id = review_id,
        .card_id = @intCast(card_id),
        .rating = @intCast(rating.value()),
        .reviewed_at_ms = reviewed_at_ms,
        .algorithm_major = @intCast(stamp.algorithm.major),
        .implementation_major = @intCast(stamp.implementation.major),
        .implementation_minor = @intCast(stamp.implementation.minor),
        .implementation_patch = @intCast(stamp.implementation.patch),
        .parameter_set_id = parameterBinary(&stamp.parameter_set_id),
        .scheduled_at_ms = scheduled_at_ms,
    };
}

fn parseSchedulerState(
    card_id: card_mod.CardId,
    document: []const u8,
) !catalog_mod.SchedulerState {
    return .{
        .card_id = card_id,
        .stamp = .{
            .algorithm = .{
                .family = .fsrs,
                .major = @intCast(try requiredI64(document, "algorithm_major")),
            },
            .implementation = .{
                .major = @intCast(try requiredI64(document, "implementation_major")),
                .minor = @intCast(try requiredI64(document, "implementation_minor")),
                .patch = @intCast(try requiredI64(document, "implementation_patch")),
            },
            .parameter_set_id = try requiredParameterSetId(document, "parameter_set_id"),
        },
        .stability_days = try optionalDouble(document, "stability_days"),
        .difficulty = try optionalDouble(document, "difficulty"),
        .due_at_ms = try requiredI64(document, "due_at_ms"),
        .last_reviewed_at_ms = try optionalI64(document, "last_reviewed_at_ms"),
    };
}

fn parameterBinary(id: *const fsrs.ParameterSetId) bongo.bson.Binary {
    return .{ .subtype = .generic, .data = id[0..] };
}

fn requiredParameterSetId(document: []const u8, field: []const u8) !fsrs.ParameterSetId {
    return (try optionalParameterSetId(document, field)) orelse error.InvalidParameterSetId;
}

fn optionalParameterSetId(document: []const u8, field: []const u8) !?fsrs.ParameterSetId {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return null;
    if (value == .null_value) return null;
    const binary = switch (value) {
        .binary => |v| v,
        else => return error.InvalidParameterSetId,
    };
    if (binary.data.len != 32) return error.InvalidParameterSetId;
    var result: fsrs.ParameterSetId = undefined;
    @memcpy(result[0..], binary.data);
    return result;
}

fn requiredString(document: []const u8, field: []const u8) ![]const u8 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return switch (value) {
        .string => |v| v,
        else => error.InvalidField,
    };
}

fn requiredI64(document: []const u8, field: []const u8) !i64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return valueAsI64(value) orelse error.InvalidField;
}

fn optionalI64(document: []const u8, field: []const u8) !?i64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return null;
    if (value == .null_value) return null;
    return valueAsI64(value) orelse error.InvalidField;
}

fn requiredDouble(document: []const u8, field: []const u8) !f64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return valueAsDouble(value) orelse error.InvalidField;
}

fn optionalDouble(document: []const u8, field: []const u8) !?f64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return null;
    if (value == .null_value) return null;
    return valueAsDouble(value) orelse error.InvalidField;
}

fn valueAsI64(value: bongo.bson.Value) ?i64 {
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| v,
        else => null,
    };
}

fn valueAsDouble(value: bongo.bson.Value) ?f64 {
    return switch (value) {
        .double => |v| v,
        .int32 => |v| @floatFromInt(v),
        .int64 => |v| @floatFromInt(v),
        else => null,
    };
}

fn idAsI64(id: u64) !i64 {
    return std.math.cast(i64, id) orelse error.InvalidField;
}

test "parameter IDs encode as 32-byte BSON binary" {
    var id: fsrs.ParameterSetId = [_]u8{7} ** 32;
    const binary = parameterBinary(&id);
    try std.testing.expectEqual(bongo.bson.BinarySubtype.generic, binary.subtype);
    try std.testing.expectEqual(@as(usize, 32), binary.data.len);
}
