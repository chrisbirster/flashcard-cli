const std = @import("std");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const Study = @import("study.zig").Study;
const time = @import("time.zig");

pub const CardChange = struct {
    card_id: u64,
    source_good_due_at_ms: i64,
    target_good_due_at_ms: i64,
    source_good_interval_days: f64,
    target_good_interval_days: f64,
};

pub const DryRun = struct {
    deck_id: u64,
    source_algorithm: fsrs.AlgorithmId,
    source_parameter_set_id: fsrs.ParameterSetId,
    target_algorithm: fsrs.AlgorithmId,
    target_parameter_set_id: fsrs.ParameterSetId,
    cards: []CardChange,

    pub fn deinit(self: DryRun, allocator: std.mem.Allocator) void {
        allocator.free(self.cards);
    }
};

pub const Activation = struct {
    deck_id: u64,
    source_algorithm: fsrs.AlgorithmId,
    source_parameter_set_id: fsrs.ParameterSetId,
    target_algorithm: fsrs.AlgorithmId,
    target_parameter_set_id: fsrs.ParameterSetId,
    rebuilt_cards: usize,
};

/// Preview migration to an explicitly selected FSRS-7 parameter set. The
/// preview only reads immutable history and never changes deck configuration or
/// derived state. Future engine majors can add a sibling target handler without
/// changing the review-history contract.
pub fn dryRunFsrs7(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    target_parameter_set_id: fsrs.ParameterSetId,
    now_ms: time.TimestampMs,
) !DryRun {
    const source = try store.resolveDeckScheduler(deck_id, now_ms);
    if (!source.algorithm.eql(.fsrs7)) return error.UnsupportedSourceAlgorithm;
    const source_parameters = try store.loadFsrs7Parameters(source.parameter_set_id);
    const target_parameters = try store.loadFsrs7Parameters(target_parameter_set_id);
    const source_engine = try fsrs.Engine.fsrs7With(source_parameters);
    const target_engine = try fsrs.Engine.fsrs7With(target_parameters);

    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }
    const changes = try allocator.alloc(CardChange, cards.len);
    errdefer allocator.free(changes);

    for (cards, changes) |card, *change| {
        const history = try store.loadHistory(allocator, card.id);
        defer allocator.free(history);
        const comparison = try fsrs.compare.compare(source_engine, target_engine, history, now_ms);
        change.* = .{
            .card_id = card.id,
            .source_good_due_at_ms = comparison.source.good.due_at_ms,
            .target_good_due_at_ms = comparison.target.good.due_at_ms,
            .source_good_interval_days = comparison.source.good.interval_days,
            .target_good_interval_days = comparison.target.good.interval_days,
        };
    }

    return .{
        .deck_id = deck_id,
        .source_algorithm = source.algorithm,
        .source_parameter_set_id = source.parameter_set_id,
        .target_algorithm = .fsrs7,
        .target_parameter_set_id = target_parameter_set_id,
        .cards = changes,
    };
}

fn targetState(
    history: []const fsrs.HistoryEntry,
    card_id: u64,
    target_parameter_set_id: fsrs.ParameterSetId,
    target_parameters: fsrs.v7.Parameters,
    target_engine: fsrs.v7.Engine,
) !?storage.SchedulerState {
    if (history.len == 0) return null;
    const replayed = (try target_engine.replay(history)) orelse return error.MissingReplayState;
    const interval_days = try fsrs.v7.model.intervalForRetention(
        replayed.memory.stability_days,
        target_parameters.desired_retention,
        target_parameters,
    );
    return .{
        .card_id = card_id,
        .stamp = .{
            .algorithm = .fsrs7,
            .implementation = .current,
            .parameter_set_id = target_parameter_set_id,
        },
        .stability_days = replayed.memory.stability_days,
        .difficulty = replayed.memory.difficulty,
        .due_at_ms = replayed.last_reviewed_at_ms + time.daysToMilliseconds(interval_days),
        .last_reviewed_at_ms = replayed.last_reviewed_at_ms,
    };
}

/// Activate only after a successful dry-run. Every target state is computed
/// from immutable history before persistent configuration changes begin. The
/// storage layer then commits the deck pin and all derived states atomically.
/// MongoDB therefore requires transaction support for scheduler migration.
pub fn activateFsrs7(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    target_parameter_set_id: fsrs.ParameterSetId,
    now_ms: time.TimestampMs,
) !Activation {
    const preview = try dryRunFsrs7(allocator, store, deck_id, target_parameter_set_id, now_ms);
    defer preview.deinit(allocator);

    const target_parameters = try store.loadFsrs7Parameters(target_parameter_set_id);
    const target_engine = try fsrs.v7.Engine.init(target_parameters);
    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }

    var states: std.ArrayList(storage.SchedulerState) = .empty;
    defer states.deinit(allocator);
    for (cards) |card| {
        const history = try store.loadHistory(allocator, card.id);
        defer allocator.free(history);
        if (try targetState(
            history,
            card.id,
            target_parameter_set_id,
            target_parameters,
            target_engine,
        )) |state| {
            try states.append(allocator, state);
        }
    }

    try storage.migration_commit.applyFsrs7(
        store,
        deck_id,
        target_parameter_set_id,
        states.items,
    );

    return .{
        .deck_id = deck_id,
        .source_algorithm = preview.source_algorithm,
        .source_parameter_set_id = preview.source_parameter_set_id,
        .target_algorithm = preview.target_algorithm,
        .target_parameter_set_id = preview.target_parameter_set_id,
        .rebuilt_cards = states.items.len,
    };
}

test "scheduler migration preview is side effect free and activation replays history atomically" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("migrate", 0);
    const card_id = try store.createCard(deck_id, "q", "a", 0);
    const source_id = try store.ensureDefaultFsrs7(0);
    try store.setDeckFsrs7(deck_id, source_id);
    const study = Study.init(&store);
    _ = try study.recordReview(std.testing.allocator, card_id, .good, 0);

    var target_parameters: fsrs.v7.Parameters = .{};
    target_parameters.desired_retention = 0.95;
    const target_id = try store.putFsrs7Parameters(target_parameters, "migration-target", 1);
    const history_before = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history_before);
    const state_before = (try store.getSchedulerState(card_id)).?;

    const preview = try dryRunFsrs7(std.testing.allocator, &store, deck_id, target_id, time.milliseconds_per_day);
    try std.testing.expect(std.mem.eql(u8, preview.source_parameter_set_id[0..], source_id[0..]));
    preview.deinit(std.testing.allocator);
    const still_source = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, still_source.parameter_set_id[0..], source_id[0..]));
    const still_state = (try store.getSchedulerState(card_id)).?;
    try std.testing.expect(std.mem.eql(
        u8,
        still_state.stamp.parameter_set_id[0..],
        state_before.stamp.parameter_set_id[0..],
    ));

    const activation = try activateFsrs7(std.testing.allocator, &store, deck_id, target_id, time.milliseconds_per_day);
    try std.testing.expectEqual(@as(usize, 1), activation.rebuilt_cards);
    const active = try store.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, active.parameter_set_id[0..], target_id[0..]));
    const migrated_state = (try store.getSchedulerState(card_id)).?;
    try std.testing.expect(std.mem.eql(u8, migrated_state.stamp.parameter_set_id[0..], target_id[0..]));

    const history_after = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history_after);
    try std.testing.expectEqual(history_before.len, history_after.len);
    try std.testing.expectEqual(history_before[0].rating, history_after[0].rating);
    try std.testing.expectEqual(history_before[0].reviewed_at_ms, history_after[0].reviewed_at_ms);
}
