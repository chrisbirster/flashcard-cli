const std = @import("std");
const card_mod = @import("card.zig");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const Preview = struct {
    card_id: card_mod.CardId,
    algorithm: fsrs.AlgorithmId,
    parameter_set_id: fsrs.ParameterSetId,
    schedule: fsrs.Schedule,
    retrievability: ?f64,
};

pub const ReviewResult = struct {
    review_id: u64,
    candidate: fsrs.Candidate,
    state: storage.SchedulerState,
};

pub const ReviewOrder = enum {
    due,
    reviews_first,
    new_first,
};

pub const SessionOptions = struct {
    /// Null preserves the historical unlimited-new-card behavior.
    new_limit: ?usize = null,
    review_order: ReviewOrder = .due,
    /// A seed explicitly enables shuffling. Null keeps deterministic ordering.
    shuffle_seed: ?u64 = null,
};

pub const Study = struct {
    store: *storage.Store,

    pub fn init(store: *storage.Store) Study {
        return .{ .store = store };
    }

    fn fsrs7ForDeck(self: Study, deck_id: card_mod.DeckId, now_ms: time.TimestampMs) !struct {
        resolved: storage.ResolvedScheduler,
        parameters: fsrs.v7.Parameters,
        engine: fsrs.v7.Engine,
    } {
        const resolved = try self.store.resolveDeckScheduler(deck_id, now_ms);
        if (!resolved.algorithm.eql(.fsrs7)) return error.UnsupportedAlgorithm;
        const parameters = try self.store.loadFsrs7Parameters(resolved.parameter_set_id);
        return .{
            .resolved = resolved,
            .parameters = parameters,
            .engine = try fsrs.v7.Engine.init(parameters),
        };
    }

    pub fn preview(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        now_ms: time.TimestampMs,
    ) !Preview {
        const card = (try self.store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);
        const scheduler = try self.fsrs7ForDeck(card.deck_id, now_ms);
        const history = try self.store.loadHistory(allocator, card_id);
        defer allocator.free(history);

        const schedule = try scheduler.engine.schedule(history, now_ms);
        const replayed = try scheduler.engine.replay(history);
        const retrievability = if (replayed) |state| blk: {
            if (now_ms < state.last_reviewed_at_ms) return error.NowBeforeLastReview;
            const elapsed_days = time.millisecondsToDays(now_ms - state.last_reviewed_at_ms);
            break :blk try fsrs.v7.model.retrievability(elapsed_days, state.memory, scheduler.parameters);
        } else null;

        return .{
            .card_id = card_id,
            .algorithm = scheduler.resolved.algorithm,
            .parameter_set_id = scheduler.resolved.parameter_set_id,
            .schedule = schedule,
            .retrievability = retrievability,
        };
    }

    fn stateAfterReview(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        history: []const fsrs.HistoryEntry,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
        scheduler: anytype,
        due_at_ms: time.TimestampMs,
    ) !storage.SchedulerState {
        _ = self;
        const combined = try allocator.alloc(fsrs.HistoryEntry, history.len + 1);
        defer allocator.free(combined);
        @memcpy(combined[0..history.len], history);
        combined[history.len] = .{ .rating = rating, .reviewed_at_ms = reviewed_at_ms };
        const replayed = (try scheduler.engine.replay(combined)) orelse return error.MissingReplayState;
        return .{
            .card_id = card_id,
            .stamp = .{
                .algorithm = scheduler.resolved.algorithm,
                .implementation = .current,
                .parameter_set_id = scheduler.resolved.parameter_set_id,
            },
            .stability_days = replayed.memory.stability_days,
            .difficulty = replayed.memory.difficulty,
            .due_at_ms = due_at_ms,
            .last_reviewed_at_ms = reviewed_at_ms,
        };
    }

    pub fn recordReview(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        rating: fsrs.Rating,
        reviewed_at_ms: time.TimestampMs,
    ) !ReviewResult {
        const card = (try self.store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);
        const scheduler = try self.fsrs7ForDeck(card.deck_id, reviewed_at_ms);
        const history = try self.store.loadHistory(allocator, card_id);
        defer allocator.free(history);

        const schedule = try scheduler.engine.schedule(history, reviewed_at_ms);
        const candidate = schedule.forRating(rating);
        const state = try self.stateAfterReview(
            allocator,
            card_id,
            history,
            rating,
            reviewed_at_ms,
            scheduler,
            candidate.due_at_ms,
        );

        const review_id = try self.store.recordReviewAndState(
            card_id,
            rating,
            reviewed_at_ms,
            state,
            candidate.due_at_ms,
        );

        return .{
            .review_id = review_id,
            .candidate = candidate,
            .state = state,
        };
    }

    pub fn rebuildCardState(
        self: Study,
        allocator: std.mem.Allocator,
        card_id: card_mod.CardId,
        now_ms: time.TimestampMs,
    ) !?storage.SchedulerState {
        const card = (try self.store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);
        const scheduler = try self.fsrs7ForDeck(card.deck_id, now_ms);
        const history = try self.store.loadHistory(allocator, card_id);
        defer allocator.free(history);
        if (history.len == 0) {
            try self.store.clearSchedulerState(card_id);
            return null;
        }

        const replayed = (try scheduler.engine.replay(history)) orelse return error.MissingReplayState;
        const interval_days = try fsrs.v7.model.intervalForRetention(
            replayed.memory.stability_days,
            scheduler.parameters.desired_retention,
            scheduler.parameters,
        );
        const due_at_ms = replayed.last_reviewed_at_ms + time.daysToMilliseconds(interval_days);
        const state: storage.SchedulerState = .{
            .card_id = card_id,
            .stamp = .{
                .algorithm = scheduler.resolved.algorithm,
                .implementation = .current,
                .parameter_set_id = scheduler.resolved.parameter_set_id,
            },
            .stability_days = replayed.memory.stability_days,
            .difficulty = replayed.memory.difficulty,
            .due_at_ms = due_at_ms,
            .last_reviewed_at_ms = replayed.last_reviewed_at_ms,
        };
        try self.store.upsertSchedulerState(state);
        return state;
    }

    pub fn dueCards(
        self: Study,
        allocator: std.mem.Allocator,
        deck_id: card_mod.DeckId,
        now_ms: time.TimestampMs,
        limit: usize,
    ) ![]storage.OwnedDueCard {
        return self.store.dueCards(allocator, deck_id, now_ms, limit);
    }
};

fn priority(card: storage.OwnedDueCard, order: ReviewOrder) u8 {
    const is_new = card.due_at_ms == null;
    return switch (order) {
        .due => 0,
        .reviews_first => if (is_new) 1 else 0,
        .new_first => if (is_new) 0 else 1,
    };
}

fn orderCandidates(cards: []storage.OwnedDueCard, order: ReviewOrder) void {
    if (order == .due) return;
    var index: usize = 1;
    while (index < cards.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and priority(cards[cursor], order) < priority(cards[cursor - 1], order)) {
            const previous = cards[cursor - 1];
            cards[cursor - 1] = cards[cursor];
            cards[cursor] = previous;
            cursor -= 1;
        }
    }
}

fn nextRandom(state: *u64) u64 {
    var value = state.*;
    if (value == 0) value = 0x9e3779b97f4a7c15;
    value ^= value >> 12;
    value ^= value << 25;
    value ^= value >> 27;
    state.* = value;
    return value *% 0x2545f4914f6cdd1d;
}

fn shuffleSlice(cards: []storage.OwnedDueCard, state: *u64) void {
    var remaining = cards.len;
    while (remaining > 1) {
        remaining -= 1;
        const bound: u64 = @intCast(remaining + 1);
        const selected: usize = @intCast(nextRandom(state) % bound);
        const temp = cards[remaining];
        cards[remaining] = cards[selected];
        cards[selected] = temp;
    }
}

fn sameDuePriority(a: storage.OwnedDueCard, b: storage.OwnedDueCard) bool {
    if (a.due_at_ms == null or b.due_at_ms == null) return a.due_at_ms == null and b.due_at_ms == null;
    return a.due_at_ms.? == b.due_at_ms.?;
}

fn shuffleCandidates(cards: []storage.OwnedDueCard, order: ReviewOrder, seed: ?u64) void {
    var state = seed orelse return;
    if (cards.len < 2) return;

    if (order == .due) {
        var start: usize = 0;
        while (start < cards.len) {
            var end = start + 1;
            while (end < cards.len and sameDuePriority(cards[start], cards[end])) : (end += 1) {}
            shuffleSlice(cards[start..end], &state);
            start = end;
        }
        return;
    }

    const first_priority = priority(cards[0], order);
    var boundary: usize = 1;
    while (boundary < cards.len and priority(cards[boundary], order) == first_priority) : (boundary += 1) {}
    shuffleSlice(cards[0..boundary], &state);
    shuffleSlice(cards[boundary..], &state);
}

pub const Session = struct {
    study: Study,
    deck_id: card_mod.DeckId,
    options: SessionOptions,
    new_seen: usize = 0,

    pub fn init(study: Study, deck_id: card_mod.DeckId, options: SessionOptions) Session {
        return .{
            .study = study,
            .deck_id = deck_id,
            .options = options,
        };
    }

    fn canIntroduceNew(self: Session) bool {
        const limit = self.options.new_limit orelse return true;
        return self.new_seen < limit;
    }

    pub fn next(
        self: *Session,
        allocator: std.mem.Allocator,
        now_ms: time.TimestampMs,
    ) !?storage.OwnedDueCard {
        const scan_limit: usize = std.math.maxInt(i32);
        const due = try self.study.dueCards(allocator, self.deck_id, now_ms, scan_limit);
        defer allocator.free(due);

        var candidates: std.ArrayList(storage.OwnedDueCard) = .empty;
        errdefer {
            for (candidates.items) |card| card.deinit(allocator);
            candidates.deinit(allocator);
        }

        for (due) |card| {
            if (card.due_at_ms == null and !self.canIntroduceNew()) {
                card.deinit(allocator);
                continue;
            }
            candidates.append(allocator, card) catch |err| {
                card.deinit(allocator);
                return err;
            };
        }

        if (candidates.items.len == 0) {
            candidates.deinit(allocator);
            return null;
        }

        orderCandidates(candidates.items, self.options.review_order);
        shuffleCandidates(candidates.items, self.options.review_order, self.options.shuffle_seed);

        const selected = candidates.items[0];
        for (candidates.items[1..]) |card| card.deinit(allocator);
        candidates.deinit(allocator);

        if (selected.due_at_ms == null) self.new_seen += 1;
        return selected;
    }
};

test "recorded review updates immutable history and derived state" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("bson", 0);
    const card_id = try store.createCard(deck_id, "What is a byte?", "8 bits", 0);

    const result = try study.recordReview(std.testing.allocator, card_id, .good, 0);
    try std.testing.expect(result.candidate.due_at_ms > 0);
    const history = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(fsrs.Rating.good, history[0].rating);

    const stored = (try store.getSchedulerState(card_id)).?;
    try std.testing.expectApproxEqAbs(result.state.stability_days.?, stored.stability_days.?, 1e-12);
    try std.testing.expectEqual(result.state.due_at_ms, stored.due_at_ms);
}

test "derived state rebuilds deterministically from history" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("zig", 0);
    const card_id = try store.createCard(deck_id, "What is comptime?", "Compile-time evaluation", 0);
    const day = time.milliseconds_per_day;
    _ = try study.recordReview(std.testing.allocator, card_id, .good, 0);
    _ = try study.recordReview(std.testing.allocator, card_id, .hard, 2 * day);

    const before = (try store.getSchedulerState(card_id)).?;
    try store.clearSchedulerState(card_id);
    try std.testing.expect((try store.getSchedulerState(card_id)) == null);
    const rebuilt = (try study.rebuildCardState(std.testing.allocator, card_id, 2 * day)).?;
    try std.testing.expectApproxEqAbs(before.stability_days.?, rebuilt.stability_days.?, 1e-12);
    try std.testing.expectApproxEqAbs(before.difficulty.?, rebuilt.difficulty.?, 1e-12);
    try std.testing.expectEqual(before.due_at_ms, rebuilt.due_at_ms);
}

test "study session supports review ordering and a session-wide new-card limit" {
    const allocator = std.testing.allocator;
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("queue", 0);
    const review_card = try store.createCard(deck_id, "review", "r", 0);
    const first_review = try study.recordReview(allocator, review_card, .good, 0);
    const now_ms = first_review.candidate.due_at_ms;
    const new_a = try store.createCard(deck_id, "new-a", "a", 1);
    _ = try store.createCard(deck_id, "new-b", "b", 2);

    var reviews_first = Session.init(study, deck_id, .{ .review_order = .reviews_first });
    const selected_review = (try reviews_first.next(allocator, now_ms)).?;
    try std.testing.expectEqual(review_card, selected_review.id);
    selected_review.deinit(allocator);

    var new_first = Session.init(study, deck_id, .{
        .new_limit = 1,
        .review_order = .new_first,
    });
    const selected_new = (try new_first.next(allocator, now_ms)).?;
    try std.testing.expectEqual(new_a, selected_new.id);
    const selected_new_id = selected_new.id;
    selected_new.deinit(allocator);
    _ = try study.recordReview(allocator, selected_new_id, .good, now_ms);

    const after_limit = (try new_first.next(allocator, now_ms)).?;
    try std.testing.expectEqual(review_card, after_limit.id);
    after_limit.deinit(allocator);
}

test "study session is deterministic unless shuffle is explicitly enabled" {
    const allocator = std.testing.allocator;
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("deterministic", 0);
    const first = try store.createCard(deck_id, "one", "1", 0);
    _ = try store.createCard(deck_id, "two", "2", 0);
    _ = try store.createCard(deck_id, "three", "3", 0);

    var deterministic = Session.init(study, deck_id, .{});
    const deterministic_card = (try deterministic.next(allocator, 0)).?;
    try std.testing.expectEqual(first, deterministic_card.id);
    deterministic_card.deinit(allocator);

    var shuffled_a = Session.init(study, deck_id, .{ .shuffle_seed = 42 });
    var shuffled_b = Session.init(study, deck_id, .{ .shuffle_seed = 42 });
    const shuffled_card_a = (try shuffled_a.next(allocator, 0)).?;
    defer shuffled_card_a.deinit(allocator);
    const shuffled_card_b = (try shuffled_b.next(allocator, 0)).?;
    defer shuffled_card_b.deinit(allocator);
    try std.testing.expectEqual(shuffled_card_a.id, shuffled_card_b.id);
}

test "relearning card re-enters the same session at its exact due timestamp" {
    const allocator = std.testing.allocator;
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const study = Study.init(&store);
    const deck_id = try store.createDeck("relearning", 0);
    const card_id = try store.createCard(deck_id, "again", "again", 0);

    const learned = try study.recordReview(allocator, card_id, .good, 0);
    var session = Session.init(study, deck_id, .{ .review_order = .reviews_first });
    const due_review = (try session.next(allocator, learned.candidate.due_at_ms)).?;
    try std.testing.expectEqual(card_id, due_review.id);
    due_review.deinit(allocator);

    const lapse = try study.recordReview(allocator, card_id, .again, learned.candidate.due_at_ms);
    try std.testing.expect(lapse.candidate.due_at_ms >= learned.candidate.due_at_ms);
    try std.testing.expect(lapse.candidate.due_at_ms - learned.candidate.due_at_ms < time.milliseconds_per_day);

    if (lapse.candidate.due_at_ms > learned.candidate.due_at_ms) {
        try std.testing.expect((try session.next(allocator, lapse.candidate.due_at_ms - 1)) == null);
    }

    const relearning = (try session.next(allocator, lapse.candidate.due_at_ms)).?;
    try std.testing.expectEqual(card_id, relearning.id);
    relearning.deinit(allocator);

    const overdue = (try session.next(allocator, lapse.candidate.due_at_ms + 1)).?;
    try std.testing.expectEqual(card_id, overdue.id);
    overdue.deinit(allocator);
}
