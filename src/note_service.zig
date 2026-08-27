const std = @import("std");

const card_render = @import("card_render.zig");
const card_types = @import("card_types.zig");
const content = @import("content.zig");
const storage = @import("storage/root.zig");
const generated_store = @import("storage/generated_card_store.zig");

pub const Preview = struct {
    cards: []card_render.RenderedCard,

    pub fn deinit(self: Preview, allocator: std.mem.Allocator) void {
        for (self.cards) |card| card.deinit(allocator);
        allocator.free(self.cards);
    }
};

fn generationKey(
    allocator: std.mem.Allocator,
    note_id: content.NoteId,
    generation: card_types.Generation,
) ![]u8 {
    return switch (generation) {
        .template => |ordinal| content.generationKey(allocator, note_id, ordinal),
        .cloze => |ordinal| content.clozeGenerationKey(allocator, note_id, ordinal),
        .occlusion => |id| content.occlusionGenerationKey(allocator, note_id, id),
    };
}

fn generatedContainsKey(
    allocator: std.mem.Allocator,
    note_id: content.NoteId,
    generated: []const card_types.CardDraft,
    key: []const u8,
) !bool {
    for (generated) |draft| {
        const expected = try generationKey(allocator, note_id, draft.generation);
        defer allocator.free(expected);
        if (std.mem.eql(u8, expected, key)) return true;
    }
    return false;
}

fn idIn(ids: []const u64, id: u64) bool {
    for (ids) |value| if (value == id) return true;
    return false;
}

fn deckForNote(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    card_ids: []const u64,
) !u64 {
    if (card_ids.len == 0) return error.NoteHasNoGeneratedCards;

    const first = (try store.getCard(allocator, card_ids[0])) orelse return error.CardNotFound;
    defer first.deinit(allocator);
    const deck_id = first.deck_id;

    for (card_ids[1..]) |card_id| {
        const card = (try store.getCard(allocator, card_id)) orelse return error.CardNotFound;
        defer card.deinit(allocator);
        if (card.deck_id != deck_id) return error.NoteDeckMismatch;
    }
    return deck_id;
}

fn preflightRemovedCards(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    note_id: content.NoteId,
    existing_ids: []const u64,
    generated: []const card_types.CardDraft,
) !void {
    const content_store = storage.ContentStore.init(store);
    for (existing_ids) |card_id| {
        const source = (try content_store.cardSource(allocator, card_id)) orelse return error.GeneratedCardSourceMissing;
        defer source.deinit(allocator);
        if (try generatedContainsKey(allocator, note_id, generated, source.generation_key)) continue;

        const history = try store.loadHistory(allocator, card_id);
        defer allocator.free(history);
        if (history.len != 0) return error.ReviewHistoryExists;
    }
}

fn removeStaleCards(
    store: *storage.Store,
    existing_ids: []const u64,
    desired_ids: []const u64,
) !void {
    for (existing_ids) |card_id| {
        if (idIn(desired_ids, card_id)) continue;
        try generated_store.unlink(store, card_id);
        try store.deleteCard(card_id);
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
    return card_types.create(allocator, store, deck_id, kind, values, tags_json, created_at_ms);
}

pub fn update(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    note_id: content.NoteId,
    values: []const []const u8,
    tags_json: []const u8,
    updated_at_ms: i64,
) ![]u64 {
    const content_store = storage.ContentStore.init(store);
    const note = (try content_store.getNote(allocator, note_id)) orelse return error.NoteNotFound;
    defer note.deinit(allocator);
    const kind = content.BuiltInNoteType.fromId(note.note_type_id) catch return error.UnsupportedBuiltInNoteType;

    const generated = try card_types.drafts(allocator, kind, values);
    defer {
        for (generated) |draft| draft.deinit(allocator);
        allocator.free(generated);
    }

    const existing_ids = try generated_store.cardIdsForNote(allocator, store, note_id);
    defer allocator.free(existing_ids);
    const deck_id = try deckForNote(allocator, store, existing_ids);
    try preflightRemovedCards(allocator, store, note_id, existing_ids, generated);

    const desired_ids = try card_types.update(
        allocator,
        store,
        deck_id,
        note_id,
        values,
        tags_json,
        updated_at_ms,
    );
    errdefer allocator.free(desired_ids);
    try removeStaleCards(store, existing_ids, desired_ids);
    return desired_ids;
}

pub fn delete(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    note_id: content.NoteId,
) !void {
    const content_store = storage.ContentStore.init(store);
    const note = (try content_store.getNote(allocator, note_id)) orelse return error.NoteNotFound;
    defer note.deinit(allocator);

    const card_ids = try generated_store.cardIdsForNote(allocator, store, note_id);
    defer allocator.free(card_ids);

    for (card_ids) |card_id| {
        const history = try store.loadHistory(allocator, card_id);
        defer allocator.free(history);
        if (history.len != 0) return error.ReviewHistoryExists;
    }

    for (card_ids) |card_id| {
        try generated_store.unlink(store, card_id);
        try store.deleteCard(card_id);
    }
    try generated_store.deleteNote(store, note_id);
}

fn fieldValues(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]content.FieldValue {
    const fields = try allocator.alloc(content.FieldValue, values.len);
    for (values, 0..) |value, index| {
        fields[index] = .{ .ordinal = @intCast(index), .value = value };
    }
    return fields;
}

pub fn preview(
    allocator: std.mem.Allocator,
    kind: content.BuiltInNoteType,
    values: []const []const u8,
) !Preview {
    const generated = try card_types.drafts(allocator, kind, values);
    defer {
        for (generated) |draft| draft.deinit(allocator);
        allocator.free(generated);
    }

    const fields = try fieldValues(allocator, values);
    defer allocator.free(fields);

    const cards = try allocator.alloc(card_render.RenderedCard, generated.len);
    var completed: usize = 0;
    errdefer {
        for (cards[0..completed]) |card| card.deinit(allocator);
        allocator.free(cards);
    }

    for (generated, 0..) |draft, index| {
        var options: card_render.Options = .{};
        const template_ordinal: content.TemplateOrdinal = switch (draft.generation) {
            .template => |ordinal| ordinal,
            .cloze => |ordinal| blk: {
                options.cloze_ordinal = ordinal;
                break :blk 0;
            },
            .occlusion => |id| blk: {
                options.occlusion_id = id;
                break :blk 0;
            },
        };
        cards[index] = try card_render.renderBuiltIn(
            allocator,
            kind,
            fields,
            template_ordinal,
            options,
        );
        completed += 1;
    }

    return .{ .cards = cards };
}

test "optional reverse edit removes obsolete unreviewed generated card" {
    const allocator = std.testing.allocator;
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("optional", 0);

    const initial = [_][]const u8{ "France", "Paris", "yes" };
    const created = try create(allocator, &store, deck_id, .optional_reverse, &initial, "[]", 0);
    defer created.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);

    const changed = [_][]const u8{ "France", "Paris", "" };
    const updated = try update(allocator, &store, created.note_id, &changed, "[]", 1);
    defer allocator.free(updated);
    try std.testing.expectEqual(@as(usize, 1), updated.len);

    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }
    try std.testing.expectEqual(@as(usize, 1), cards.len);
}

test "delete removes an unreviewed generated note and its card" {
    const allocator = std.testing.allocator;
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("delete", 0);
    const values = [_][]const u8{ "Q", "A" };
    const created = try create(allocator, &store, deck_id, .basic, &values, "[]", 0);
    defer created.deinit(allocator);

    try delete(allocator, &store, created.note_id);
    const content_store = storage.ContentStore.init(&store);
    try std.testing.expect((try content_store.getNote(allocator, created.note_id)) == null);
    try std.testing.expect((try store.getCard(allocator, created.card_ids[0])) == null);
}

test "preview uses the structured client renderer" {
    const allocator = std.testing.allocator;
    const choices = "[{\"id\":\"stack\",\"text\":\"Stack\"},{\"id\":\"queue\",\"text\":\"Queue\"}]";
    const values = [_][]const u8{ "Which is LIFO?", choices, "stack", "A stack is LIFO." };
    const result = try preview(allocator, .multiple_choice, &values);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.cards.len);
    switch (result.cards[0].interaction) {
        .single_choice => |choice| try std.testing.expectEqualStrings("stack", choice.correct_id),
        else => return error.TestExpectedSingleChoice,
    }
}
