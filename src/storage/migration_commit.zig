const std = @import("std");
const fsrs = @import("../fsrs/root.zig");
const card_mod = @import("../card.zig");
const store_mod = @import("store.zig");
const catalog_mod = @import("catalog.zig");

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
    }
}
