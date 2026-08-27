const std = @import("std");

const content = @import("content.zig");
const interaction_text = @import("interaction.zig");
const template_render = @import("render.zig");

pub const Choice = struct {
    id: []u8,
    text: []u8,

    pub fn deinit(self: Choice, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.text);
    }
};

pub const TypeAnswer = struct {
    answer: []u8,

    pub fn deinit(self: TypeAnswer, allocator: std.mem.Allocator) void {
        allocator.free(self.answer);
    }
};

pub const SingleChoice = struct {
    choices: []Choice,
    correct_id: []u8,

    pub fn deinit(self: SingleChoice, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| choice.deinit(allocator);
        allocator.free(self.choices);
        allocator.free(self.correct_id);
    }
};

pub const MultiChoice = struct {
    choices: []Choice,
    correct_ids: [][]u8,

    pub fn deinit(self: MultiChoice, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| choice.deinit(allocator);
        allocator.free(self.choices);
        for (self.correct_ids) |id| allocator.free(id);
        allocator.free(self.correct_ids);
    }
};

pub const Ordering = struct {
    /// Canonical correct order. Clients may choose their own deterministic or
    /// randomized display order without changing these stable item IDs.
    items: []Choice,

    pub fn deinit(self: Ordering, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const OcclusionMask = struct {
    id: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    answer: []u8,
    prompt: ?[]u8,

    pub fn deinit(self: OcclusionMask, allocator: std.mem.Allocator) void {
        allocator.free(self.answer);
        if (self.prompt) |prompt| allocator.free(prompt);
    }
};

pub const ImageOcclusion = struct {
    image_ref: []u8,
    masks: []OcclusionMask,
    target_mask_id: u32,

    pub fn deinit(self: ImageOcclusion, allocator: std.mem.Allocator) void {
        allocator.free(self.image_ref);
        for (self.masks) |mask| mask.deinit(allocator);
        allocator.free(self.masks);
    }
};

/// Client-facing study interaction contract.
///
/// Note-type names and interaction names intentionally differ for choices:
/// `multiple-choice` is a single-answer question and therefore renders as
/// `.single_choice`; `multiple-select` renders as `.multiple_choice` because
/// more than one choice can be correct.
pub const Interaction = union(enum) {
    reveal,
    type_answer: TypeAnswer,
    single_choice: SingleChoice,
    multiple_choice: MultiChoice,
    ordering: Ordering,
    image_occlusion: ImageOcclusion,

    pub fn deinit(self: Interaction, allocator: std.mem.Allocator) void {
        switch (self) {
            .reveal => {},
            .type_answer => |value| value.deinit(allocator),
            .single_choice => |value| value.deinit(allocator),
            .multiple_choice => |value| value.deinit(allocator),
            .ordering => |value| value.deinit(allocator),
            .image_occlusion => |value| value.deinit(allocator),
        }
    }
};

pub const Options = struct {
    mode: template_render.Mode = .html,
    cloze_ordinal: ?u32 = null,
    occlusion_id: ?u32 = null,
};

pub const RenderedCard = struct {
    front: []u8,
    back: []u8,
    css: []u8,
    interaction: Interaction,

    pub fn deinit(self: RenderedCard, allocator: std.mem.Allocator) void {
        allocator.free(self.front);
        allocator.free(self.back);
        allocator.free(self.css);
        self.interaction.deinit(allocator);
    }
};

const ChoiceInput = struct {
    id: []const u8,
    text: []const u8,
};

const OcclusionMaskInput = struct {
    id: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    answer: []const u8,
    prompt: ?[]const u8 = null,
};

fn field(fields: []const content.FieldValue, ordinal: content.FieldOrdinal) ![]const u8 {
    for (fields) |value| {
        if (value.ordinal == ordinal) return value.value;
    }
    return error.MissingInteractionField;
}

fn ownChoices(allocator: std.mem.Allocator, choices_json: []const u8) ![]Choice {
    var parsed = try std.json.parseFromSlice([]const ChoiceInput, allocator, choices_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (parsed.value.len < 2) return error.NotEnoughChoices;

    const choices = try allocator.alloc(Choice, parsed.value.len);
    var completed: usize = 0;
    errdefer {
        for (choices[0..completed]) |choice| choice.deinit(allocator);
        allocator.free(choices);
    }

    for (parsed.value, 0..) |source, index| {
        if (std.mem.trim(u8, source.id, " \t\r\n").len == 0 or
            std.mem.trim(u8, source.text, " \t\r\n").len == 0)
        {
            return error.InvalidInteractionText;
        }
        for (parsed.value[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, source.id)) return error.DuplicateChoiceId;
        }
        choices[index] = .{
            .id = try allocator.dupe(u8, source.id),
            .text = try allocator.dupe(u8, source.text),
        };
        completed += 1;
    }
    return choices;
}

fn containsChoice(choices: []const Choice, id: []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, choice.id, id)) return true;
    return false;
}

fn singleChoice(
    allocator: std.mem.Allocator,
    choices_json: []const u8,
    correct_id: []const u8,
) !Interaction {
    const choices = try ownChoices(allocator, choices_json);
    errdefer {
        for (choices) |choice| choice.deinit(allocator);
        allocator.free(choices);
    }
    const trimmed = std.mem.trim(u8, correct_id, " \t\r\n");
    if (!containsChoice(choices, trimmed)) return error.UnknownChoiceId;
    return .{ .single_choice = .{
        .choices = choices,
        .correct_id = try allocator.dupe(u8, trimmed),
    } };
}

fn multipleChoice(
    allocator: std.mem.Allocator,
    choices_json: []const u8,
    correct_ids_json: []const u8,
) !Interaction {
    const choices = try ownChoices(allocator, choices_json);
    errdefer {
        for (choices) |choice| choice.deinit(allocator);
        allocator.free(choices);
    }

    var parsed = try std.json.parseFromSlice([]const []const u8, allocator, correct_ids_json, .{});
    defer parsed.deinit();
    if (parsed.value.len == 0) return error.CorrectChoiceRequired;

    const correct_ids = try allocator.alloc([]u8, parsed.value.len);
    var completed: usize = 0;
    errdefer {
        for (correct_ids[0..completed]) |id| allocator.free(id);
        allocator.free(correct_ids);
    }
    for (parsed.value, 0..) |id, index| {
        const trimmed = std.mem.trim(u8, id, " \t\r\n");
        if (!containsChoice(choices, trimmed)) return error.UnknownChoiceId;
        for (parsed.value[0..index]) |previous| {
            if (std.mem.eql(u8, previous, id)) return error.DuplicateCorrectChoiceId;
        }
        correct_ids[index] = try allocator.dupe(u8, trimmed);
        completed += 1;
    }

    return .{ .multiple_choice = .{
        .choices = choices,
        .correct_ids = correct_ids,
    } };
}

fn orderingInteraction(allocator: std.mem.Allocator, items_json: []const u8) !Interaction {
    return .{ .ordering = .{ .items = try ownChoices(allocator, items_json) } };
}

fn imageOcclusionInteraction(
    allocator: std.mem.Allocator,
    image_ref: []const u8,
    masks_json: []const u8,
    target_mask_id: u32,
) !Interaction {
    if (@import("media.zig").parseReference(image_ref) == null) return error.InvalidOcclusionMediaReference;
    var parsed = try std.json.parseFromSlice([]const OcclusionMaskInput, allocator, masks_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (parsed.value.len == 0) return error.OcclusionMaskRequired;

    const masks = try allocator.alloc(OcclusionMask, parsed.value.len);
    var completed: usize = 0;
    var target_found = false;
    errdefer {
        for (masks[0..completed]) |mask| mask.deinit(allocator);
        allocator.free(masks);
    }

    for (parsed.value, 0..) |source, index| {
        if (source.id == 0 or source.width <= 0 or source.height <= 0 or
            source.x < 0 or source.y < 0 or source.x > 1 or source.y > 1 or
            source.width > 1 or source.height > 1 or
            source.x + source.width > 1.0000001 or source.y + source.height > 1.0000001)
        {
            return error.InvalidOcclusionRect;
        }
        if (std.mem.trim(u8, source.answer, " \t\r\n").len == 0) return error.InvalidInteractionText;
        for (parsed.value[0..index]) |previous| {
            if (previous.id == source.id) return error.DuplicateOcclusionId;
        }
        if (source.id == target_mask_id) target_found = true;

        masks[index] = .{
            .id = source.id,
            .x = source.x,
            .y = source.y,
            .width = source.width,
            .height = source.height,
            .answer = try allocator.dupe(u8, source.answer),
            .prompt = if (source.prompt) |prompt| try allocator.dupe(u8, prompt) else null,
        };
        completed += 1;
    }
    if (!target_found) return error.OcclusionMaskNotFound;

    return .{ .image_occlusion = .{
        .image_ref = try allocator.dupe(u8, image_ref),
        .masks = masks,
        .target_mask_id = target_mask_id,
    } };
}

fn fromTemplate(
    allocator: std.mem.Allocator,
    definition: content.NoteTypeDefinition,
    fields: []const content.FieldValue,
    template_ordinal: content.TemplateOrdinal,
    options: Options,
) !RenderedCard {
    var rendered = try template_render.renderCard(allocator, definition, fields, template_ordinal, .{
        .mode = options.mode,
        .cloze_ordinal = options.cloze_ordinal,
    });
    errdefer rendered.deinit(allocator);

    const client_interaction: Interaction = if (rendered.typed_answer) |answer| blk: {
        rendered.typed_answer = null;
        break :blk .{ .type_answer = .{ .answer = answer } };
    } else .reveal;

    return .{
        .front = rendered.front,
        .back = rendered.back,
        .css = rendered.css,
        .interaction = client_interaction,
    };
}

/// Render any built-in note/card into a shared client-facing representation.
/// Terminal clients can display `front`/`back`; graphical clients can use the
/// structured `interaction` payload for native controls.
pub fn renderBuiltIn(
    allocator: std.mem.Allocator,
    kind: content.BuiltInNoteType,
    fields: []const content.FieldValue,
    template_ordinal: content.TemplateOrdinal,
    options: Options,
) !RenderedCard {
    const definition = kind.definition();
    switch (kind) {
        .basic, .basic_reverse, .optional_reverse, .cloze, .type_answer => {
            return fromTemplate(allocator, definition, fields, template_ordinal, options);
        },
        .multiple_choice => {
            const prompt = try field(fields, 0);
            const choices_json = try field(fields, 1);
            const correct_id = try field(fields, 2);
            const explanation = try field(fields, 3);
            const text = try interaction_text.multipleChoice(allocator, prompt, choices_json, correct_id, explanation);
            errdefer text.deinit(allocator);
            return .{
                .front = text.question,
                .back = text.answer,
                .css = try allocator.dupe(u8, definition.css),
                .interaction = try singleChoice(allocator, choices_json, correct_id),
            };
        },
        .multiple_select => {
            const prompt = try field(fields, 0);
            const choices_json = try field(fields, 1);
            const correct_ids_json = try field(fields, 2);
            const explanation = try field(fields, 3);
            const text = try interaction_text.multipleSelect(allocator, prompt, choices_json, correct_ids_json, explanation);
            errdefer text.deinit(allocator);
            return .{
                .front = text.question,
                .back = text.answer,
                .css = try allocator.dupe(u8, definition.css),
                .interaction = try multipleChoice(allocator, choices_json, correct_ids_json),
            };
        },
        .ordering => {
            const prompt = try field(fields, 0);
            const items_json = try field(fields, 1);
            const explanation = try field(fields, 2);
            const text = try interaction_text.ordering(allocator, prompt, items_json, explanation);
            errdefer text.deinit(allocator);
            return .{
                .front = text.question,
                .back = text.answer,
                .css = try allocator.dupe(u8, definition.css),
                .interaction = try orderingInteraction(allocator, items_json),
            };
        },
        .image_occlusion => {
            const image_ref = try field(fields, 0);
            const masks_json = try field(fields, 1);
            const extra = try field(fields, 2);
            const id = options.occlusion_id orelse return error.OcclusionIdRequired;
            const text = try interaction_text.imageOcclusion(allocator, image_ref, masks_json, extra, id);
            errdefer text.deinit(allocator);
            return .{
                .front = text.question,
                .back = text.answer,
                .css = try allocator.dupe(u8, definition.css),
                .interaction = try imageOcclusionInteraction(allocator, image_ref, masks_json, id),
            };
        },
    }
}

test "type answer is represented by Interaction rather than a client special case" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "Capital of France?" },
        .{ .ordinal = 1, .value = "Paris" },
    };
    const rendered = try renderBuiltIn(std.testing.allocator, .type_answer, &fields, 0, .{ .mode = .plain_text });
    defer rendered.deinit(std.testing.allocator);
    switch (rendered.interaction) {
        .type_answer => |typed| try std.testing.expectEqualStrings("Paris", typed.answer),
        else => return error.TestExpectedTypeAnswer,
    }
}

test "multiple-choice exposes stable IDs independent of display labels" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "Best average key lookup?" },
        .{ .ordinal = 1, .value = "[{\"id\":\"arr\",\"text\":\"Array\"},{\"id\":\"hash\",\"text\":\"Hash table\"}]" },
        .{ .ordinal = 2, .value = "hash" },
        .{ .ordinal = 3, .value = "Hashing chooses a bucket." },
    };
    const rendered = try renderBuiltIn(std.testing.allocator, .multiple_choice, &fields, 0, .{ .mode = .plain_text });
    defer rendered.deinit(std.testing.allocator);
    switch (rendered.interaction) {
        .single_choice => |choice| {
            try std.testing.expectEqualStrings("hash", choice.correct_id);
            try std.testing.expectEqualStrings("arr", choice.choices[0].id);
        },
        else => return error.TestExpectedSingleChoice,
    }
}

test "multiple-select maps to multiple_choice interaction" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "O(1) stack operations?" },
        .{ .ordinal = 1, .value = "[{\"id\":\"push\",\"text\":\"Push\"},{\"id\":\"pop\",\"text\":\"Pop\"},{\"id\":\"search\",\"text\":\"Search\"}]" },
        .{ .ordinal = 2, .value = "[\"push\",\"pop\"]" },
        .{ .ordinal = 3, .value = "" },
    };
    const rendered = try renderBuiltIn(std.testing.allocator, .multiple_select, &fields, 0, .{ .mode = .plain_text });
    defer rendered.deinit(std.testing.allocator);
    switch (rendered.interaction) {
        .multiple_choice => |choice| try std.testing.expectEqual(@as(usize, 2), choice.correct_ids.len),
        else => return error.TestExpectedMultipleChoice,
    }
}

test "image occlusion interaction includes target and all masks" {
    const image_ref = "deez-media://sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = image_ref },
        .{ .ordinal = 1, .value = "[{\"id\":2,\"x\":0.5,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"right\"},{\"id\":1,\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2,\"answer\":\"left\"}]" },
        .{ .ordinal = 2, .value = "tree" },
    };
    const rendered = try renderBuiltIn(std.testing.allocator, .image_occlusion, &fields, 0, .{ .mode = .plain_text, .occlusion_id = 1 });
    defer rendered.deinit(std.testing.allocator);
    switch (rendered.interaction) {
        .image_occlusion => |value| {
            try std.testing.expectEqual(@as(u32, 1), value.target_mask_id);
            try std.testing.expectEqual(@as(usize, 2), value.masks.len);
        },
        else => return error.TestExpectedImageOcclusion,
    }
}
