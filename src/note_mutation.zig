const std = @import("std");

const card_types = @import("card_types.zig");
const content = @import("content.zig");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const generated_store = @import("storage/generated_card_store.zig");

fn contains(ids: []const u64, id: u64) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

/// Reconcile the physical generated cards for a logical note after an edit.
///
/// `card_types.update` remains authoritative for rendering and generated-card
/// multiplicity. This layer only manages lifecycle: generated variants returned
/// by that update are active, while variants that used to belong to the note
/// but are no longer generated are retired rather than deleted. Retirement
/// preserves card IDs, scheduler state, generation keys, and immutable reviews.
fn reconcile(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    note_id: content.NoteId,
    active_ids: []const u64,
    updated_at_ms: i64,
) !void {
    for (active_ids) |card_id| try store.restoreCard(card_id);

    const physical = try store.allCards(allocator, deck_id);
    defer {
        for (physical) |card| card.deinit(allocator);
        allocator.free(physical);
    }

    const content_store = storage.ContentStore.init(store);
    for (physical) |card| {
        const source = (try content_store.cardSource(allocator, card.id)) orelse continue;
        defer source.deinit(allocator);
        if (source.note_id != note_id) continue;
        if (contains(active_ids, card.id)) {
            try store.restoreCard(card.id);
        } else {
            try store.retireCard(card.id, updated_at_ms);
        }
    }
}

pub fn create(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    kind: content.BuiltInNoteType,
    values: []const []const u8,
    tags_json: []const u8,
    created_at_ms: i64,
) !card_types.Generated {
    const generated = try card_types.create(
        allocator,
        store,
        deck_id,
        kind,
        values,
        tags_json,
        created_at_ms,
    );
    errdefer generated.deinit(allocator);
    for (generated.card_ids) |card_id| try store.restoreCard(card_id);
    return generated;
}

pub fn update(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    note_id: content.NoteId,
    values: []const []const u8,
    tags_json: []const u8,
    updated_at_ms: i64,
) ![]u64 {
    const active_ids = try card_types.update(
        allocator,
        store,
        deck_id,
        note_id,
        values,
        tags_json,
        updated_at_ms,
    );
    errdefer allocator.free(active_ids);
    try reconcile(allocator, store, deck_id, note_id, active_ids, updated_at_ms);
    return active_ids;
}

/// Delete an editable logical note while retaining its physical study history.
/// Generated cards are retired first; only note/generated-card metadata is then
/// removed. This makes the deletion final without violating immutable reviews.
pub fn delete(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    note_id: content.NoteId,
    deleted_at_ms: i64,
) !void {
    const physical = try store.allCards(allocator, deck_id);
    defer {
        for (physical) |card| card.deinit(allocator);
        allocator.free(physical);
    }

    var found = false;
    const content_store = storage.ContentStore.init(store);
    for (physical) |card| {
        const source = (try content_store.cardSource(allocator, card.id)) orelse continue;
        defer source.deinit(allocator);
        if (source.note_id != note_id) continue;
        found = true;
        try store.retireCard(card.id, deleted_at_ms);
    }
    if (!found) return error.NoteNotFound;
    try generated_store.deleteNote(store, note_id);
}

test "editing generated multiplicity retires and later restores the same reviewed card" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("optional reverse", 0);

    const initial = [_][]const u8{ "front", "back", "reverse please" };
    const created = try create(
        std.testing.allocator,
        &store,
        deck_id,
        .optional_reverse,
        &initial,
        "[]",
        0,
    );
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);
    const reverse_id = created.card_ids[1];

    _ = try db.appendReview(reverse_id, fsrs.Rating.good, 1, null, null);

    const forward_only = [_][]const u8{ "front", "back", "" };
    const one = try update(
        std.testing.allocator,
        &store,
        deck_id,
        created.note_id,
        &forward_only,
        "[]",
        2,
    );
    defer std.testing.allocator.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expect(try store.isCardRetired(reverse_id));

    const active = try store.cards(std.testing.allocator, deck_id);
    defer {
        for (active) |card| card.deinit(std.testing.allocator);
        std.testing.allocator.free(active);
    }
    try std.testing.expectEqual(@as(usize, 1), active.len);

    const history_while_retired = try store.loadHistory(std.testing.allocator, reverse_id);
    defer std.testing.allocator.free(history_while_retired);
    try std.testing.expectEqual(@as(usize, 1), history_while_retired.len);
    try std.testing.expectEqual(fsrs.Rating.good, history_while_retired[0].rating);

    const restored_values = [_][]const u8{ "front", "back", "reverse again" };
    const two = try update(
        std.testing.allocator,
        &store,
        deck_id,
        created.note_id,
        &restored_values,
        "[]",
        3,
    );
    defer std.testing.allocator.free(two);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqual(reverse_id, two[1]);
    try std.testing.expect(!try store.isCardRetired(reverse_id));

    const history_after_restore = try store.loadHistory(std.testing.allocator, reverse_id);
    defer std.testing.allocator.free(history_after_restore);
    try std.testing.expectEqual(@as(usize, 1), history_after_restore.len);
}

test "deleting a reviewed note retires its card but preserves review history" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("delete", 0);
    const values = [_][]const u8{ "front", "back" };
    const created = try create(
        std.testing.allocator,
        &store,
        deck_id,
        .basic,
        &values,
        "[]",
        0,
    );
    defer created.deinit(std.testing.allocator);
    const card_id = created.card_ids[0];
    _ = try db.appendReview(card_id, fsrs.Rating.easy, 1, null, null);

    try delete(std.testing.allocator, &store, deck_id, created.note_id, 2);
    try std.testing.expect(try store.isCardRetired(card_id));
    try std.testing.expect((try storage.ContentStore.init(&store).getNote(std.testing.allocator, created.note_id)) == null);

    const active = try store.cards(std.testing.allocator, deck_id);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqual(@as(usize, 0), active.len);

    const history = try store.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqual(fsrs.Rating.easy, history[0].rating);
}
