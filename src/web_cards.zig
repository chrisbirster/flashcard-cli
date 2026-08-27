const std = @import("std");
const httpz = @import("httpz");

const card_render = @import("card_render.zig");
const card_types = @import("card_types.zig");
const content = @import("content.zig");
const storage = @import("storage/root.zig");

const GenerationResponse = struct {
    kind: []const u8,
    ordinal: u32,
};

const CardSummaryResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    front: []const u8,
    note_id: ?[]const u8 = null,
    generation: ?GenerationResponse = null,
    due_at_ms: ?i64 = null,
    last_reviewed_at_ms: ?i64 = null,
};

const ChoiceResponse = struct {
    id: []const u8,
    text: []const u8,
};

const OcclusionMaskResponse = struct {
    id: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    answer: []const u8,
    prompt: ?[]const u8 = null,
};

const InteractionResponse = struct {
    type: []const u8,
    answer: ?[]const u8 = null,
    choices: ?[]const ChoiceResponse = null,
    correct_id: ?[]const u8 = null,
    correct_ids: ?[]const []const u8 = null,
    items: ?[]const ChoiceResponse = null,
    image_ref: ?[]const u8 = null,
    masks: ?[]const OcclusionMaskResponse = null,
    target_mask_id: ?u32 = null,
};

const RenderedResponse = struct {
    front: []const u8,
    back: []const u8,
    css: []const u8,
    interaction: InteractionResponse,
};

const SchedulerResponse = struct {
    stability_days: ?f64,
    difficulty: ?f64,
    due_at_ms: i64,
    last_reviewed_at_ms: ?i64,
};

const CardResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    note_id: ?[]const u8 = null,
    note_type: ?[]const u8 = null,
    generation: ?GenerationResponse = null,
    rendered: RenderedResponse,
    scheduler: ?SchedulerResponse = null,
    review_count: usize,
};

fn idText(allocator: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{id});
}

fn jsonError(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    try res.json(.{
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

fn parseId(req: *httpz.Request, res: *httpz.Response, name: []const u8) ?u64 {
    const text = req.param(name) orelse {
        jsonError(res, 400, "invalid_id", "Missing resource ID") catch {};
        return null;
    };
    if (text.len == 0) {
        jsonError(res, 400, "invalid_id", "Resource ID must be an unsigned integer") catch {};
        return null;
    }
    return std.fmt.parseInt(u64, text, 10) catch {
        jsonError(res, 400, "invalid_id", "Resource ID must be an unsigned integer") catch {};
        return null;
    };
}

fn generationResponse(generation: card_types.Generation) GenerationResponse {
    return switch (generation) {
        .template => |ordinal| .{ .kind = "template", .ordinal = ordinal },
        .cloze => |ordinal| .{ .kind = "cloze", .ordinal = ordinal },
        .occlusion => |id| .{ .kind = "occlusion", .ordinal = id },
    };
}

fn parseGenerationKey(
    generation_key: []const u8,
    expected_note_id: content.NoteId,
    template_ordinal: content.TemplateOrdinal,
) !card_types.Generation {
    var parts = std.mem.splitScalar(u8, generation_key, ':');
    const namespace = parts.next() orelse return error.InvalidGenerationKey;
    const note_text = parts.next() orelse return error.InvalidGenerationKey;
    const kind = parts.next() orelse return error.InvalidGenerationKey;
    const ordinal_text = parts.next() orelse return error.InvalidGenerationKey;
    if (parts.next() != null or !std.mem.eql(u8, namespace, "note")) return error.InvalidGenerationKey;

    const note_id = std.fmt.parseInt(u64, note_text, 10) catch return error.InvalidGenerationKey;
    if (note_id != expected_note_id) return error.InvalidGenerationKey;
    const ordinal = std.fmt.parseInt(u32, ordinal_text, 10) catch return error.InvalidGenerationKey;

    if (std.mem.eql(u8, kind, "template")) {
        if (ordinal != template_ordinal) return error.InvalidGenerationKey;
        return .{ .template = ordinal };
    }
    if (std.mem.eql(u8, kind, "cloze")) return .{ .cloze = ordinal };
    if (std.mem.eql(u8, kind, "occlusion")) return .{ .occlusion = ordinal };
    return error.InvalidGenerationKey;
}

fn generationEqual(left: card_types.Generation, right: card_types.Generation) bool {
    return switch (left) {
        .template => |value| switch (right) {
            .template => |other| value == other,
            else => false,
        },
        .cloze => |value| switch (right) {
            .cloze => |other| value == other,
            else => false,
        },
        .occlusion => |value| switch (right) {
            .occlusion => |other| value == other,
            else => false,
        },
    };
}

fn copyChoices(allocator: std.mem.Allocator, choices: []const card_render.Choice) ![]ChoiceResponse {
    const result = try allocator.alloc(ChoiceResponse, choices.len);
    for (choices, 0..) |choice, index| result[index] = .{ .id = choice.id, .text = choice.text };
    return result;
}

fn copyIds(allocator: std.mem.Allocator, ids: []const []u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, ids.len);
    for (ids, 0..) |id, index| result[index] = id;
    return result;
}

fn interactionResponse(
    allocator: std.mem.Allocator,
    interaction: card_render.Interaction,
) !InteractionResponse {
    return switch (interaction) {
        .reveal => .{ .type = "reveal" },
        .type_answer => |value| .{ .type = "type_answer", .answer = value.answer },
        .single_choice => |value| .{
            .type = "single_choice",
            .choices = try copyChoices(allocator, value.choices),
            .correct_id = value.correct_id,
        },
        .multiple_choice => |value| .{
            .type = "multiple_choice",
            .choices = try copyChoices(allocator, value.choices),
            .correct_ids = try copyIds(allocator, value.correct_ids),
        },
        .ordering => |value| .{
            .type = "ordering",
            .items = try copyChoices(allocator, value.items),
        },
        .image_occlusion => |value| blk: {
            const masks = try allocator.alloc(OcclusionMaskResponse, value.masks.len);
            for (value.masks, 0..) |mask, index| {
                masks[index] = .{
                    .id = mask.id,
                    .x = mask.x,
                    .y = mask.y,
                    .width = mask.width,
                    .height = mask.height,
                    .answer = mask.answer,
                    .prompt = mask.prompt,
                };
            }
            break :blk .{
                .type = "image_occlusion",
                .image_ref = value.image_ref,
                .masks = masks,
                .target_mask_id = value.target_mask_id,
            };
        },
    };
}

fn generatedRenderedResponse(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    source: content.GeneratedCardSource,
    generation: card_types.Generation,
) !struct { note_type: []const u8, rendered: RenderedResponse } {
    const note = (try storage.ContentStore.init(store).getNote(allocator, source.note_id)) orelse
        return error.NoteNotFound;
    const kind = try content.BuiltInNoteType.fromId(note.note_type_id);
    const values = try allocator.alloc([]const u8, note.fields.len);
    for (note.fields, 0..) |field, index| values[index] = field.value;

    const drafts = try card_types.renderedDrafts(allocator, kind, values, .html);
    for (drafts) |draft| {
        if (!generationEqual(draft.generation, generation)) continue;
        return .{
            .note_type = kind.definition().slug,
            .rendered = .{
                .front = draft.rendered.front,
                .back = draft.rendered.back,
                .css = draft.rendered.css,
                .interaction = try interactionResponse(allocator, draft.rendered.interaction),
            },
        };
    }
    return error.GeneratedVariantNotFound;
}

pub fn deckCards(
    store: *storage.Store,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const deck_id = parseId(req, res, "id") orelse return;
    if (try store.getDeck(res.arena, deck_id) == null) {
        try jsonError(res, 404, "deck_not_found", "Deck not found");
        return;
    }

    const cards = try store.cards(res.arena, deck_id);
    const result = try res.arena.alloc(CardSummaryResponse, cards.len);
    const content_store = storage.ContentStore.init(store);
    for (cards, 0..) |entry, index| {
        const source = try content_store.cardSource(res.arena, entry.id);
        const state = try store.getSchedulerState(entry.id);
        result[index] = .{
            .id = try idText(res.arena, entry.id),
            .deck_id = try idText(res.arena, entry.deck_id),
            .front = entry.question,
            .note_id = if (source) |value| try idText(res.arena, value.note_id) else null,
            .generation = if (source) |value| generationResponse(try parseGenerationKey(value.generation_key, value.note_id, value.template_ordinal)) else null,
            .due_at_ms = if (state) |value| value.due_at_ms else null,
            .last_reviewed_at_ms = if (state) |value| value.last_reviewed_at_ms else null,
        };
    }
    try res.json(result, .{ .emit_null_optional_fields = false });
}

pub fn card(
    store: *storage.Store,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const card_id = parseId(req, res, "id") orelse return;
    const owned = (try store.getCard(res.arena, card_id)) orelse {
        try jsonError(res, 404, "card_not_found", "Card not found");
        return;
    };
    if (try store.isCardRetired(card_id)) {
        try jsonError(res, 404, "card_not_found", "Card not found");
        return;
    }

    const source = try storage.ContentStore.init(store).cardSource(res.arena, card_id);
    var note_id: ?[]const u8 = null;
    var note_type: ?[]const u8 = null;
    var generation: ?GenerationResponse = null;
    var rendered: RenderedResponse = .{
        .front = owned.question,
        .back = owned.answer,
        .css = "",
        .interaction = .{ .type = "reveal" },
    };

    if (source) |value| {
        const parsed_generation = try parseGenerationKey(value.generation_key, value.note_id, value.template_ordinal);
        const rich = try generatedRenderedResponse(res.arena, store, value, parsed_generation);
        note_id = try idText(res.arena, value.note_id);
        note_type = rich.note_type;
        generation = generationResponse(parsed_generation);
        rendered = rich.rendered;
    }

    const scheduler: ?SchedulerResponse = if (try store.getSchedulerState(card_id)) |state| .{
        .stability_days = state.stability_days,
        .difficulty = state.difficulty,
        .due_at_ms = state.due_at_ms,
        .last_reviewed_at_ms = state.last_reviewed_at_ms,
    } else null;
    const history = try store.loadHistory(res.arena, card_id);

    try res.json(CardResponse{
        .id = try idText(res.arena, owned.id),
        .deck_id = try idText(res.arena, owned.deck_id),
        .note_id = note_id,
        .note_type = note_type,
        .generation = generation,
        .rendered = rendered,
        .scheduler = scheduler,
        .review_count = history.len,
    }, .{ .emit_null_optional_fields = false });
}

test "generation keys decode into the public generation contract" {
    const template = try parseGenerationKey("note:42:template:1", 42, 1);
    try std.testing.expect(generationEqual(template, .{ .template = 1 }));
    const cloze = try parseGenerationKey("note:42:cloze:3", 42, 0);
    try std.testing.expect(generationEqual(cloze, .{ .cloze = 3 }));
    const occlusion = try parseGenerationKey("note:42:occlusion:7", 42, 0);
    try std.testing.expect(generationEqual(occlusion, .{ .occlusion = 7 }));
    try std.testing.expectError(error.InvalidGenerationKey, parseGenerationKey("note:41:template:1", 42, 1));
    try std.testing.expectError(error.InvalidGenerationKey, parseGenerationKey("note:42:template:2", 42, 1));
}
