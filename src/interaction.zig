const std = @import("std");
const media = @import("media.zig");

pub const CardText = struct {
    question: []u8,
    answer: []u8,

    pub fn deinit(self: CardText, allocator: std.mem.Allocator) void {
        allocator.free(self.question);
        allocator.free(self.answer);
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

fn requireText(value: []const u8) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.InvalidInteractionText;
}

fn validateChoices(choices: []const ChoiceInput) !void {
    if (choices.len < 2) return error.NotEnoughChoices;
    for (choices, 0..) |choice, index| {
        try requireText(choice.id);
        try requireText(choice.text);
        for (choices[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, choice.id)) return error.DuplicateChoiceId;
        }
    }
}

fn choiceText(choices: []const ChoiceInput, id: []const u8) ![]const u8 {
    for (choices) |choice| {
        if (std.mem.eql(u8, choice.id, id)) return choice.text;
    }
    return error.UnknownChoiceId;
}

fn writeExplanation(out: *std.Io.Writer, explanation: []const u8) !void {
    const trimmed = std.mem.trim(u8, explanation, " \t\r\n");
    if (trimmed.len == 0) return;
    try out.writeAll("\n\n");
    try out.writeAll(trimmed);
}

fn ownedWriters(
    allocator: std.mem.Allocator,
    question_writer: *std.Io.Writer.Allocating,
    answer_writer: *std.Io.Writer.Allocating,
) !CardText {
    const question = try question_writer.toOwnedSlice();
    errdefer allocator.free(question);
    return .{
        .question = question,
        .answer = try answer_writer.toOwnedSlice(),
    };
}

pub fn multipleChoice(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    choices_json: []const u8,
    correct_id: []const u8,
    explanation: []const u8,
) !CardText {
    try requireText(prompt);
    try requireText(correct_id);
    var parsed = try std.json.parseFromSlice([]const ChoiceInput, allocator, choices_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateChoices(parsed.value);
    const correct_text = try choiceText(parsed.value, std.mem.trim(u8, correct_id, " \t\r\n"));

    var question: std.Io.Writer.Allocating = .init(allocator);
    errdefer question.deinit();
    var answer: std.Io.Writer.Allocating = .init(allocator);
    errdefer answer.deinit();

    try question.writer.writeAll(prompt);
    for (parsed.value, 0..) |choice, index| {
        try question.writer.print("\n{d}. {s}", .{ index + 1, choice.text });
    }
    try answer.writer.print("Correct: {s}", .{correct_text});
    try writeExplanation(&answer.writer, explanation);
    return ownedWriters(allocator, &question, &answer);
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

pub fn multipleSelect(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    choices_json: []const u8,
    correct_ids_json: []const u8,
    explanation: []const u8,
) !CardText {
    try requireText(prompt);
    var parsed_choices = try std.json.parseFromSlice([]const ChoiceInput, allocator, choices_json, .{ .ignore_unknown_fields = false });
    defer parsed_choices.deinit();
    try validateChoices(parsed_choices.value);

    var parsed_correct = try std.json.parseFromSlice([]const []const u8, allocator, correct_ids_json, .{});
    defer parsed_correct.deinit();
    if (parsed_correct.value.len == 0) return error.CorrectChoiceRequired;
    for (parsed_correct.value, 0..) |id, index| {
        try requireText(id);
        _ = try choiceText(parsed_choices.value, id);
        if (containsId(parsed_correct.value[0..index], id)) return error.DuplicateCorrectChoiceId;
    }

    var question: std.Io.Writer.Allocating = .init(allocator);
    errdefer question.deinit();
    var answer: std.Io.Writer.Allocating = .init(allocator);
    errdefer answer.deinit();

    try question.writer.writeAll(prompt);
    for (parsed_choices.value, 0..) |choice, index| {
        try question.writer.print("\n{d}. {s}", .{ index + 1, choice.text });
    }
    try answer.writer.writeAll("Correct selections:");
    for (parsed_correct.value) |id| {
        try answer.writer.print("\n- {s}", .{try choiceText(parsed_choices.value, id)});
    }
    try writeExplanation(&answer.writer, explanation);
    return ownedWriters(allocator, &question, &answer);
}

pub fn ordering(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    items_json: []const u8,
    explanation: []const u8,
) !CardText {
    try requireText(prompt);
    var parsed = try std.json.parseFromSlice([]const ChoiceInput, allocator, items_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateChoices(parsed.value);

    var question: std.Io.Writer.Allocating = .init(allocator);
    errdefer question.deinit();
    var answer: std.Io.Writer.Allocating = .init(allocator);
    errdefer answer.deinit();

    try question.writer.writeAll(prompt);
    const odd_count = parsed.value.len / 2;
    for (0..parsed.value.len) |display_index| {
        const item_index = if (display_index < odd_count)
            display_index * 2 + 1
        else
            (display_index - odd_count) * 2;
        if (item_index < parsed.value.len) {
            try question.writer.print("\n{d}. {s}", .{ display_index + 1, parsed.value[item_index].text });
        }
    }

    try answer.writer.writeAll("Correct order:");
    for (parsed.value, 0..) |item, index| {
        try answer.writer.print("\n{d}. {s}", .{ index + 1, item.text });
    }
    try writeExplanation(&answer.writer, explanation);
    return ownedWriters(allocator, &question, &answer);
}

fn validateMask(mask: OcclusionMaskInput) !void {
    if (mask.id == 0) return error.InvalidOcclusionId;
    try requireText(mask.answer);
    if (mask.prompt) |prompt| try requireText(prompt);
    if (mask.x < 0 or mask.y < 0 or mask.width <= 0 or mask.height <= 0) return error.InvalidOcclusionRect;
    if (mask.x > 1 or mask.y > 1 or mask.width > 1 or mask.height > 1) return error.InvalidOcclusionRect;
    if (mask.x + mask.width > 1.0000001 or mask.y + mask.height > 1.0000001) return error.InvalidOcclusionRect;
}

fn validateMasks(image_ref: []const u8, masks: []const OcclusionMaskInput) !void {
    if (media.parseReference(image_ref) == null) return error.InvalidOcclusionMediaReference;
    if (masks.len == 0) return error.OcclusionMaskRequired;
    for (masks, 0..) |mask, index| {
        try validateMask(mask);
        for (masks[0..index]) |previous| {
            if (previous.id == mask.id) return error.DuplicateOcclusionId;
        }
    }
}

pub fn occlusionIds(
    allocator: std.mem.Allocator,
    image_ref: []const u8,
    masks_json: []const u8,
) ![]u32 {
    var parsed = try std.json.parseFromSlice([]const OcclusionMaskInput, allocator, masks_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateMasks(image_ref, parsed.value);
    const ids = try allocator.alloc(u32, parsed.value.len);
    for (parsed.value, 0..) |mask, index| ids[index] = mask.id;
    std.mem.sort(u32, ids, {}, std.sort.asc(u32));
    return ids;
}

pub fn imageOcclusion(
    allocator: std.mem.Allocator,
    image_ref: []const u8,
    masks_json: []const u8,
    extra: []const u8,
    mask_id: u32,
) !CardText {
    var parsed = try std.json.parseFromSlice([]const OcclusionMaskInput, allocator, masks_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try validateMasks(image_ref, parsed.value);
    const mask = blk: {
        for (parsed.value) |candidate| {
            if (candidate.id == mask_id) break :blk candidate;
        }
        return error.OcclusionMaskNotFound;
    };

    var question: std.Io.Writer.Allocating = .init(allocator);
    errdefer question.deinit();
    var answer: std.Io.Writer.Allocating = .init(allocator);
    errdefer answer.deinit();

    try question.writer.writeAll(if (mask.prompt) |prompt| prompt else "Identify the masked region.");
    try question.writer.print("\n[image: {s}]", .{image_ref});
    try question.writer.print(
        "\n[mask {d}: x={d:.3} y={d:.3} width={d:.3} height={d:.3}]",
        .{ mask.id, mask.x, mask.y, mask.width, mask.height },
    );
    try answer.writer.writeAll(mask.answer);
    try writeExplanation(&answer.writer, extra);
    return ownedWriters(allocator, &question, &answer);
}

test "multiple choice uses stable choice ids" {
    const choices =
        \\[{"id":"stack","text":"Stack"},{"id":"queue","text":"Queue"},{"id":"hash","text":"Hash table"}]
    ;
    const card = try multipleChoice(std.testing.allocator, "Average O(1) lookup?", choices, "hash", "Uses hashing.");
    defer card.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, card.question, "3. Hash table") != null);
    try std.testing.expect(std.mem.indexOf(u8, card.answer, "Correct: Hash table") != null);
}

test "multiple select validates every correct id" {
    const choices =
        \\[{"id":"push","text":"Push"},{"id":"pop","text":"Pop"},{"id":"search","text":"Search"}]
    ;
    const card = try multipleSelect(std.testing.allocator, "Typical O(1) stack ops?", choices, "[\"push\",\"pop\"]", "");
    defer card.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, card.answer, "Push") != null);
    try std.testing.expect(std.mem.indexOf(u8, card.answer, "Pop") != null);
}

test "ordering does not present canonical sequence on the front" {
    const items =
        \\[{"id":"a","text":"First"},{"id":"b","text":"Second"},{"id":"c","text":"Third"},{"id":"d","text":"Fourth"}]
    ;
    const card = try ordering(std.testing.allocator, "Order these", items, "");
    defer card.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, card.question, "1. Second") != null);
    try std.testing.expect(std.mem.indexOf(u8, card.answer, "1. First") != null);
}

test "image occlusion exposes stable mask ids" {
    const image_ref = "deez-media://sha256:0000000000000000000000000000000000000000000000000000000000000000";
    const masks =
        \\[{"id":2,"x":0.5,"y":0.1,"width":0.2,"height":0.2,"answer":"right"},{"id":1,"x":0.1,"y":0.1,"width":0.2,"height":0.2,"answer":"left"}]
    ;
    const ids = try occlusionIds(std.testing.allocator, image_ref, masks);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2 }, ids);
    const card = try imageOcclusion(std.testing.allocator, image_ref, masks, "tree", 1);
    defer card.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, card.answer, "left") != null);
}
