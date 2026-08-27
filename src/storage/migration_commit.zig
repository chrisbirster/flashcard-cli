const std = @import("std");
const bongo = @import("bongo");
const fsrs = @import("../fsrs/root.zig");
const card_mod = @import("../card.zig");
const store_mod = @import("store.zig");
const catalog_mod = @import("catalog.zig");

const q = bongo.query;

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

fn parameterBinary(id: *const fsrs.ParameterSetId) bongo.bson.Binary {
    return .{ .subtype = .generic, .data = id[0..] };
}

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

fn validateState(
    state: catalog_mod.SchedulerState,
    target_parameter_set_id: fsrs.ParameterSetId,
) !void {
    if (!state.stamp.algorithm.eql(.fsrs7)) return error.InvalidSchedulerState;
    if (!std.mem.eql(
        u8,
        state.stamp.parameter_set_id[0..],
        target_parameter_set_id[0..],
    )) return error.InvalidSchedulerState;
}

fn applySqlite(
    db: anytype,
    deck_id: card_mod.DeckId,
    target_parameter_set_id: fsrs.ParameterSetId,
    states: []const catalog_mod.SchedulerState,
) !void {
    const catalog: catalog_mod.Catalog = .{ .db = db };
    _ = try catalog.loadFsrs7Parameters(target_parameter_set_id);
    for (states) |state| try validateState(state, target_parameter_set_id);

    try db.beginImmediate();
    errdefer db.rollback();
    try catalog.setDeckFsrs7(deck_id, target_parameter_set_id);
    for (states) |state| try catalog.upsertSchedulerState(state);
    try db.commit();
}

fn applyMongo(
    mongo: anytype,
    deck_id: card_mod.DeckId,
    target_parameter_set_id: fsrs.ParameterSetId,
    states: []const catalog_mod.SchedulerState,
) !void {
    _ = try mongo.loadFsrs7Parameters(target_parameter_set_id);
    for (states) |state| try validateState(state, target_parameter_set_id);
    if (!mongo.client.supports_transactions) return error.TransactionsRequired;

    var stable_id = target_parameter_set_id;
    var transaction = try mongo.client.beginTransaction(.{});
    defer transaction.deinit();

    var deck_update = try transaction.updateOne(
        mongo.client.databaseName(),
        "decks",
        .{ ._id = std.math.cast(i64, deck_id) orelse return error.IdOutOfRange },
        q.set(.{
            .algorithm_major = @as(i32, 7),
            .parameter_set_id = parameterBinary(&stable_id),
        }),
        false,
    );
    defer deck_update.deinit();

    for (states) |*state| {
        const scheduler = schedulerDocument(state);
        var update = try transaction.updateOne(
            mongo.client.databaseName(),
            "cards",
            .{ ._id = std.math.cast(i64, state.card_id) orelse return error.IdOutOfRange },
            q.set(.{
                .scheduler_state = scheduler,
                .due_at_ms = state.due_at_ms,
            }),
            false,
        );
        update.deinit();
    }

    try transaction.commit();
}

/// Atomically activates an FSRS-7 parameter set and all derived card states.
/// Immutable review history is never written by this operation.
pub fn applyFsrs7(
    store: *store_mod.Store,
    deck_id: card_mod.DeckId,
    target_parameter_set_id: fsrs.ParameterSetId,
    states: []const catalog_mod.SchedulerState,
) !void {
    switch (store.*) {
        .sqlite => |db| try applySqlite(db, deck_id, target_parameter_set_id, states),
        .mongodb => |*mongo| try applyMongo(mongo, deck_id, target_parameter_set_id, states),
    }
}
