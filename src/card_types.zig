const std = @import("std");

const content = @import("content.zig");
const interaction = @import("interaction.zig");
const render = @import("render.zig");
const card_render = @import("card_render.zig");
const storage = @import("storage/root.zig");
const note_type_store = @import("storage/note_type_store.zig");
const generated_store = @import("storage/generated_card_store.zig");

pub const Generation = union(enum) {
    template: content.TemplateOrdinal,
    cloze: u32,
    occlusion: u32,
};

pub const CardDraft = struct {
    generation: Generation,
    question: []u8,
    answer: []u8,

    pub fn deinit(self: CardDraft, allocator: std.mem.Allocator) void {
        allocator.free(self.question);
        allocator.free(self.answer);
    }
};

/// A generated card rendered through the shared client-facing renderer.
///
/// This is the authoritative preview/generation shape for built-in notes.
/// Persistence projects `front`/`back` to the legacy stored CardDraft while
/// web/desktop/mobile clients can consume the structured interaction directly.
pub const RenderedDraft = struct {
    generation: Generation,
    rendered: card_render.RenderedCard,

    pub fn deinit(self: RenderedDraft, allocator: std.mem.Allocator) void {
        self.rendered.deinit(allocator);
    }
};

pub const Generated = struct {
    note_id: content.NoteId,
    card_ids: []u64,

    pub fn deinit(self: Generated, allocator: std.mem.Allocator) void {
        allocator.free(self.card_ids);
    }
};

fn builtinForId(id: content.NoteTypeId) !content.BuiltInNoteType {
    return content.BuiltInNoteType.fromId(id) catch return error.UnsupportedBuiltInNoteType;
}

fn requireFields(kind: content.BuiltInNoteType, values: []const []const u8) !void {
    const expected = kind.definition().fields.len;
    if (values.len != expected) return error.InvalidFieldCount;
    switch (kind) {
        .cloze => try content.requireText(values[0]),
        .optional_reverse => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
        .basic, .basic_reverse, .type_answer => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
        .multiple_choice => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
            try content.requireText(values[2]);
        },
        .multiple_select => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
            try content.requireText(values[2]);
        },
        .ordering => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
        .image_occlusion => {
            try content.requireText(values[0]);
            try content.requireText(values[1]);
        },
    }
}

const Cloze = struct {
    ordinal: u32,
    text: []const u8,
    hint: ?[]const u8,
    start: usize,
    end: usize,
};

fn parseClozeAt(source: []const u8, start: usize) !?Cloze {
    if (!std.mem.startsWith(u8, source[start..], "{{c")) return null;
    var index = start + 3;
    const number_start = index;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    if (index == number_start or index + 1 >= source.len or source[index] != ':' or source[index + 1] != ':') return null;
    const ordinal = std.fmt.parseInt(u32, source[number_start..index], 10) catch return error.InvalidCloze;
    if (ordinal == 0) return error.InvalidCloze;
    index += 2;
    const body_start = index;
    const close_rel = std.mem.indexOf(u8, source[index..], "}}") orelse return error.InvalidCloze;
    const close = index + close_rel;
    const body = source[body_start..close];
    const hint_sep = std.mem.indexOf(u8, body, "::");
    return .{
        .ordinal = ordinal,
        .text = if (hint_sep) |position| body[0..position] else body,
        .hint = if (hint_sep) |position| body[position + 2 ..] else null,
        .start = start,
        .end = close + 2,
    };
}

fn collectClozeOrdinals(allocator: std.mem.Allocator, source: []const u8) ![]u32 {
    var ordinals: std.ArrayList(u32) = .empty;
    errdefer ordinals.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) {
        if (try parseClozeAt(source, index)) |cloze| {
            var exists = false;
            for (ordinals.items) |value| {
                if (value == cloze.ordinal) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try ordinals.append(allocator, cloze.ordinal);
            index = cloze.end;
        } else index += 1;
    }
    if (ordinals.items.len == 0) return error.ClozeRequired;
    std.mem.sort(u32, ordinals.items, {}, std.sort.asc(u32));
    return ordinals.toOwnedSlice(allocator);
}

fn fieldValues(allocator: std.mem.Allocator, values: []const []const u8) ![]content.FieldValue {
    const fields = try allocator.alloc(content.FieldValue, values.len);
    for (values, 0..) |value, index| fields[index] = .{ .ordinal = @intCast(index), .value = value };
    return fields;
}

fn appendRenderedDraft(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(RenderedDraft),
    kind: content.BuiltInNoteType,
    fields: []const content.FieldValue,
    generation: Generation,
    mode: render.Mode,
) !void {
    const template_ordinal: content.TemplateOrdinal = switch (generation) {
        .template => |ordinal| ordinal,
        .cloze, .occlusion => 0,
    };
    const options: card_render.Options = switch (generation) {
        .template => .{ .mode = mode },
        .cloze => |ordinal| .{ .mode = mode, .cloze_ordinal = ordinal },
        .occlusion => |id| .{ .mode = mode, .occlusion_id = id },
    };
    const rendered = try card_render.renderBuiltIn(
        allocator,
        kind,
        fields,
        template_ordinal,
        options,
    );
    errdefer rendered.deinit(allocator);
    try result.append(allocator, .{ .generation = generation, .rendered = rendered });
}

/// Generate and render every card variant for an unsaved logical built-in note.
///
/// This function performs no storage writes and allocates no persistent card
/// IDs. It is shared by persistence and client preview so generated-card
/// multiplicity, rendering, CSS, and structured interaction cannot drift.
pub fn renderedDrafts(
    allocator: std.mem.Allocator,
    kind: content.BuiltInNoteType,
    values: []const []const u8,
    mode: render.Mode,
) ![]RenderedDraft {
    try requireFields(kind, values);
    const fields = try fieldValues(allocator, values);
    defer allocator.free(fields);

    var result: std.ArrayList(RenderedDraft) = .empty;
    errdefer {
        for (result.items) |draft| draft.deinit(allocator);
        result.deinit(allocator);
    }

    switch (kind) {
        .basic, .type_answer => {
            try appendRenderedDraft(allocator, &result, kind, fields, .{ .template = 0 }, mode);
        },
        .basic_reverse => {
            try appendRenderedDraft(allocator, &result, kind, fields, .{ .template = 0 }, mode);
            try appendRenderedDraft(allocator, &result, kind, fields, .{ .template = 1 }, mode);
        },
        .optional_reverse => {
            try appendRenderedDraft(allocator, &result, kind, fields, .{ .template = 0 }, mode);
            if (std.mem.trim(u8, values[2], " \t\r\n").len != 0) {
                try appendRenderedDraft(allocator, &result, kind, fields, .{ .template = 1 }, mode);
            }
        },
        .cloze => {
            const ordinals = try collectClozeOrdinals(allocator, values[0]);
            defer allocator.free(ordinals);
            for (ordinals) |ordinal| {
                try appendRenderedDraft(allocator, &result, kind, fields, .{ .cloze = ordinal }, mode);
            }
        },
        .multiple_choice, .multiple_select, .ordering => {
            try appendRenderedDraft(allocator, &result, kind, fields, .{ .template = 0 }, mode);
        },
        .image_occlusion => {
            const ids = try interaction.occlusionIds(allocator, values[0], values[1]);
            defer allocator.free(ids);
            for (ids) |id| {
                try appendRenderedDraft(allocator, &result, kind, fields, .{ .occlusion = id }, mode);
            }
        },
    }

    return result.toOwnedSlice(allocator);
}

/// Legacy persistent-card projection used by storage and terminal study.
/// The source rendering is the same `renderedDrafts` representation exposed to
/// graphical clients; only the structured interaction/CSS is discarded here.
pub fn drafts(
    allocator: std.mem.Allocator,
    kind: content.BuiltInNoteType,
    values: []const []const u8,
) ![]CardDraft {
    const rendered = try renderedDrafts(allocator, kind, values, .plain_text);
    defer {
        for (rendered) |draft| draft.deinit(allocator);
        allocator.free(rendered);
    }

    var result: std.ArrayList(CardDraft) = .empty;
    errdefer {
        for (result.items) |draft| draft.deinit(allocator);
        result.deinit(allocator);
    }

    for (rendered) |draft| {
        const question = try allocator.dupe(u8, draft.rendered.front);
        const answer = allocator.dupe(u8, draft.rendered.back) catch |err| {
            allocator.free(question);
            return err;
        };
        result.append(allocator, .{
            .generation = draft.generation,
            .question = question,
            .answer = answer,
        }) catch |err| {
            allocator.free(question);
            allocator.free(answer);
            return err;
        };
    }

    return result.toOwnedSlice(allocator);
}

fn syncCards(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    note_id: content.NoteId,
    generated: []const CardDraft,
    created_at_ms: i64,
) ![]u64 {
    const ids = try allocator.alloc(u64, generated.len);
    errdefer allocator.free(ids);
    for (generated, 0..) |draft, index| {
        const key = switch (draft.generation) {
            .template => |ordinal| try content.generationKey(allocator, note_id, ordinal),
            .cloze => |ordinal| try content.clozeGenerationKey(allocator, note_id, ordinal),
            .occlusion => |id| try content.occlusionGenerationKey(allocator, note_id, id),
        };
        defer allocator.free(key);
        if (try generated_store.cardIdForKey(store, key)) |card_id| {
            try store.updateCard(card_id, draft.question, draft.answer);
            ids[index] = card_id;
        } else {
            const card_id = try store.createCard(deck_id, draft.question, draft.answer, created_at_ms);
            errdefer store.deleteCard(card_id) catch {};
            const template_ordinal: content.TemplateOrdinal = switch (draft.generation) {
                .template => |ordinal| ordinal,
                .cloze, .occlusion => 0,
            };
            try generated_store.link(store, card_id, note_id, template_ordinal, key);
            ids[index] = card_id;
        }
    }
    return ids;
}

pub fn create(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    kind: content.BuiltInNoteType,
    values: []const []const u8,
    tags_json: []const u8,
    created_at_ms: i64,
) !Generated {
    try requireFields(kind, values);
    const definition = kind.definition();
    try note_type_store.ensure(allocator, store, definition, created_at_ms);
    _ = try store.ensureDefaultFsrs7(created_at_ms);
    const fields = try fieldValues(allocator, values);
    defer allocator.free(fields);
    const content_store = storage.ContentStore.init(store);
    const note_id = try content_store.createNote(allocator, definition.id, fields, tags_json, created_at_ms);
    const generated = try drafts(allocator, kind, values);
    defer {
        for (generated) |draft| draft.deinit(allocator);
        allocator.free(generated);
    }
    return .{ .note_id = note_id, .card_ids = try syncCards(allocator, store, deck_id, note_id, generated, created_at_ms) };
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
    const content_store = storage.ContentStore.init(store);
    const note = (try content_store.getNote(allocator, note_id)) orelse return error.NoteNotFound;
    defer note.deinit(allocator);
    const kind = try builtinForId(note.note_type_id);
    try requireFields(kind, values);
    const fields = try fieldValues(allocator, values);
    defer allocator.free(fields);
    try generated_store.updateNote(allocator, store, note_id, fields, tags_json, updated_at_ms);
    const generated = try drafts(allocator, kind, values);
    defer {
        for (generated) |draft| draft.deinit(allocator);
        allocator.free(generated);
    }
    return syncCards(allocator, store, deck_id, note_id, generated, updated_at_ms);
}

fn expectSharedProjection(kind: content.BuiltInNoteType, values: []const []const u8) !void {
    const persisted = try drafts(std.testing.allocator, kind, values);
    defer {
        for (persisted) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(persisted);
    }
    const rendered = try renderedDrafts(std.testing.allocator, kind, values, .plain_text);
    defer {
        for (rendered) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(rendered);
    }
    try std.testing.expectEqual(persisted.len, rendered.len);
    for (persisted, rendered) |plain, rich| {
        try std.testing.expectEqualStrings(plain.question, rich.rendered.front);
        try std.testing.expectEqualStrings(plain.answer, rich.rendered.back);
    }
}

test "all built-in persistent drafts project from shared rendered drafts" {
    const choices = "[{\"id\":\"stack\",\"text\":\"Stack\"},{\"id\":\"queue\",\"text\":\"Queue\"},{\"id\":\"heap\",\"text\":\"Heap\"}]";
    const image = "deez-media://sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const masks = "[{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left\"}]";

    const basic = [_][]const u8{ "Front", "Back" };
    try expectSharedProjection(.basic, &basic);
    try expectSharedProjection(.basic_reverse, &basic);

    const optional = [_][]const u8{ "Front", "Back", "true" };
    try expectSharedProjection(.optional_reverse, &optional);

    const cloze = [_][]const u8{ "Paris is {{c1::France}} and Rome is {{c2::Italy}}.", "Europe" };
    try expectSharedProjection(.cloze, &cloze);

    try expectSharedProjection(.type_answer, &basic);

    const single = [_][]const u8{ "Which is LIFO?", choices, "stack", "A stack is LIFO." };
    try expectSharedProjection(.multiple_choice, &single);

    const multiple = [_][]const u8{ "Select structures", choices, "[\"stack\",\"queue\"]", "" };
    try expectSharedProjection(.multiple_select, &multiple);

    const ordering = [_][]const u8{ "Order these", choices, "" };
    try expectSharedProjection(.ordering, &ordering);

    const occlusion = [_][]const u8{ image, masks, "extra" };
    try expectSharedProjection(.image_occlusion, &occlusion);
}

test "reverse note generates stable forward and reverse cards" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("reverse", 0);
    const values = [_][]const u8{ "capital of France", "Paris" };
    const created = try create(std.testing.allocator, &store, deck_id, .basic_reverse, &values, "[]", 0);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);

    const ids = try update(std.testing.allocator, &store, deck_id, created.note_id, &values, "[]", 1);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(u64, created.card_ids, ids);
}

test "optional reverse allows a blank toggle" {
    const values = [_][]const u8{ "France", "Paris", "" };
    const generated = try drafts(std.testing.allocator, .optional_reverse, &values);
    defer {
        for (generated) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated);
    }
    try std.testing.expectEqual(@as(usize, 1), generated.len);
}

test "cloze generates one card per distinct cloze ordinal" {
    const values = [_][]const u8{ "Paris is {{c1::France}} and Rome is {{c2::Italy}}; {{c1::Paris}} is a city.", "" };
    const generated = try drafts(std.testing.allocator, .cloze, &values);
    defer {
        for (generated) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated);
    }
    try std.testing.expectEqual(@as(usize, 2), generated.len);
    try std.testing.expect(std.mem.indexOf(u8, generated[0].question, "[...]") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated[0].answer, "France") != null);
}

test "multiple choice and multiple select generate one logical card" {
    const choices = "[{\"id\":\"stack\",\"text\":\"Stack\"},{\"id\":\"queue\",\"text\":\"Queue\"},{\"id\":\"hash\",\"text\":\"Hash table\"}]";
    const mc = [_][]const u8{ "Average O(1) lookup?", choices, "hash", "Uses hashing." };
    const generated_mc = try drafts(std.testing.allocator, .multiple_choice, &mc);
    defer {
        for (generated_mc) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated_mc);
    }
    try std.testing.expectEqual(@as(usize, 1), generated_mc.len);
    try std.testing.expect(std.mem.indexOf(u8, generated_mc[0].answer, "Hash table") != null);

    const ms = [_][]const u8{ "Stack O(1) operations?", choices, "[\"stack\",\"queue\"]", "Example only." };
    const generated_ms = try drafts(std.testing.allocator, .multiple_select, &ms);
    defer {
        for (generated_ms) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), generated_ms.len);
}

test "ordering generates a scrambled prompt and canonical answer" {
    const items = "[{\"id\":\"a\",\"text\":\"First\"},{\"id\":\"b\",\"text\":\"Second\"},{\"id\":\"c\",\"text\":\"Third\"}]";
    const values = [_][]const u8{ "Put these in order", items, "" };
    const generated = try drafts(std.testing.allocator, .ordering, &values);
    defer {
        for (generated) |draft| draft.deinit(std.testing.allocator);
        std.testing.allocator.free(generated);
    }
    try std.testing.expectEqual(@as(usize, 1), generated.len);
    try std.testing.expect(std.mem.indexOf(u8, generated[0].answer, "1. First") != null);
}

test "image occlusion identity follows mask id across reordering" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("occlusion", 0);
    const image = "deez-media://sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const masks_a = "[{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"right\"},{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left\"}]";
    const fields_a = [_][]const u8{ image, masks_a, "tree" };
    const created = try create(std.testing.allocator, &store, deck_id, .image_occlusion, &fields_a, "[]", 0);
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), created.card_ids.len);

    const masks_b = "[{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left node\"},{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"right node\"}]";
    const fields_b = [_][]const u8{ image, masks_b, "tree" };
    const updated = try update(std.testing.allocator, &store, deck_id, created.note_id, &fields_b, "[]", 1);
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualSlices(u64, created.card_ids, updated);
}
