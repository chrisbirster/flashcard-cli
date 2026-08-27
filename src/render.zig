const std = @import("std");
const content = @import("content.zig");

pub const Mode = enum {
    html,
    plain_text,
};

const Side = enum {
    front,
    back,
};

pub const Options = struct {
    mode: Mode = .html,
    cloze_ordinal: ?u32 = null,
};

pub const RenderedCard = struct {
    front: []u8,
    back: []u8,
    css: []u8,
    typed_answer: ?[]u8,

    pub fn deinit(self: RenderedCard, allocator: std.mem.Allocator) void {
        allocator.free(self.front);
        allocator.free(self.back);
        allocator.free(self.css);
        if (self.typed_answer) |answer| allocator.free(answer);
    }
};

const Context = struct {
    definition: content.NoteTypeDefinition,
    fields: []const content.FieldValue,
    cloze_ordinal: ?u32,
};

const RenderState = struct {
    typed_answer: ?[]const u8 = null,
};

const SectionEnd = struct {
    body_end: usize,
    after_close: usize,
};

fn equalIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |start| {
        if (equalIgnoreCase(haystack[start .. start + needle.len], needle)) return start;
    }
    return null;
}

/// The renderer intentionally supports HTML/CSS presentation but not script
/// execution. This is the common safety boundary for terminal, web, desktop,
/// and mobile clients.
pub fn validateSafeMarkup(markup: []const u8) !void {
    if (indexOfIgnoreCase(markup, "<script") != null) return error.UnsafeTemplateMarkup;
    if (indexOfIgnoreCase(markup, "javascript:") != null) return error.UnsafeTemplateMarkup;
    if (indexOfIgnoreCase(markup, "expression(") != null) return error.UnsafeTemplateMarkup;

    var index: usize = 0;
    while (index + 3 < markup.len) : (index += 1) {
        if (markup[index] != ' ' and markup[index] != '<' and markup[index] != '\n' and markup[index] != '\t') continue;
        var cursor = index + 1;
        if (cursor + 2 >= markup.len) continue;
        if (std.ascii.toLower(markup[cursor]) != 'o' or std.ascii.toLower(markup[cursor + 1]) != 'n') continue;
        cursor += 2;
        const event_start = cursor;
        while (cursor < markup.len and std.ascii.isAlphabetic(markup[cursor])) : (cursor += 1) {}
        if (cursor == event_start) continue;
        while (cursor < markup.len and (markup[cursor] == ' ' or markup[cursor] == '\t')) : (cursor += 1) {}
        if (cursor < markup.len and markup[cursor] == '=') return error.UnsafeTemplateMarkup;
    }
}

fn fieldByName(ctx: Context, name: []const u8) ![]const u8 {
    var ordinal: ?content.FieldOrdinal = null;
    for (ctx.definition.fields) |definition| {
        if (std.mem.eql(u8, definition.name, name)) {
            ordinal = definition.ordinal;
            break;
        }
    }
    const wanted = ordinal orelse return error.UnknownTemplateField;
    for (ctx.fields) |field| {
        if (field.ordinal == wanted) return field.value;
    }
    return "";
}

fn fieldPresent(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn parseClozeAt(source: []const u8, start: usize) !?struct {
    ordinal: u32,
    text: []const u8,
    hint: ?[]const u8,
    end: usize,
} {
    if (!std.mem.startsWith(u8, source[start..], "{{c")) return null;
    var index = start + 3;
    const number_start = index;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {}
    if (index == number_start or index + 1 >= source.len or source[index] != ':' or source[index + 1] != ':') return null;
    const ordinal = std.fmt.parseInt(u32, source[number_start..index], 10) catch return error.InvalidCloze;
    if (ordinal == 0) return error.InvalidCloze;
    index += 2;
    const close_rel = std.mem.indexOf(u8, source[index..], "}}") orelse return error.InvalidCloze;
    const close = index + close_rel;
    const body = source[index..close];
    const hint_sep = std.mem.indexOf(u8, body, "::");
    return .{
        .ordinal = ordinal,
        .text = if (hint_sep) |position| body[0..position] else body,
        .hint = if (hint_sep) |position| body[position + 2 ..] else null,
        .end = close + 2,
    };
}

fn renderClozeValue(
    source: []const u8,
    target: u32,
    side: Side,
    out: *std.Io.Writer,
) !void {
    var index: usize = 0;
    var found_target = false;
    while (index < source.len) {
        if (try parseClozeAt(source, index)) |cloze| {
            if (cloze.ordinal == target) {
                found_target = true;
                if (side == .front) {
                    if (cloze.hint) |hint| try out.print("[{s}]", .{hint}) else try out.writeAll("[...]");
                } else {
                    try out.print("<span class=\"cloze\">{s}</span>", .{cloze.text});
                }
            } else {
                try out.writeAll(cloze.text);
            }
            index = cloze.end;
        } else {
            try out.writeByte(source[index]);
            index += 1;
        }
    }
    if (!found_target) return error.ClozeOrdinalNotFound;
}

fn findSectionEnd(source: []const u8, start: usize, name: []const u8) !SectionEnd {
    var cursor = start;
    var depth: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, source, open + 2, "}}") orelse return error.UnclosedTemplateTag;
        const token = std.mem.trim(u8, source[open + 2 .. close], " \t\r\n");
        if (token.len > 1 and (token[0] == '#' or token[0] == '^') and std.mem.eql(u8, std.mem.trim(u8, token[1..], " \t\r\n"), name)) {
            depth += 1;
        } else if (token.len > 1 and token[0] == '/' and std.mem.eql(u8, std.mem.trim(u8, token[1..], " \t\r\n"), name)) {
            if (depth == 0) return .{ .body_end = open, .after_close = close + 2 };
            depth -= 1;
        }
        cursor = close + 2;
    }
    return error.UnclosedTemplateSection;
}

fn renderToken(
    token: []const u8,
    ctx: Context,
    side: Side,
    front_side: []const u8,
    out: *std.Io.Writer,
    state: *RenderState,
) !void {
    if (std.mem.eql(u8, token, "FrontSide")) {
        if (side == .front) return error.FrontSideOnFront;
        try out.writeAll(front_side);
        return;
    }
    if (std.mem.startsWith(u8, token, "cloze:")) {
        const name = std.mem.trim(u8, token[6..], " \t\r\n");
        const value = try fieldByName(ctx, name);
        const target = ctx.cloze_ordinal orelse return error.ClozeOrdinalRequired;
        try renderClozeValue(value, target, side, out);
        return;
    }
    if (std.mem.startsWith(u8, token, "type:")) {
        const name = std.mem.trim(u8, token[5..], " \t\r\n");
        const value = try fieldByName(ctx, name);
        if (state.typed_answer) |existing| {
            if (!std.mem.eql(u8, existing, value)) return error.MultipleTypeAnswerFields;
        } else state.typed_answer = value;
        if (side == .front) try out.print("<span class=\"deez-type-answer\" data-field=\"{s}\"></span>", .{name}) else try out.writeAll(value);
        return;
    }
    try out.writeAll(try fieldByName(ctx, token));
}

fn renderTemplateInto(
    source: []const u8,
    ctx: Context,
    side: Side,
    front_side: []const u8,
    out: *std.Io.Writer,
    state: *RenderState,
) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "{{")) |open| {
        try out.writeAll(source[cursor..open]);
        const close = std.mem.indexOfPos(u8, source, open + 2, "}}") orelse return error.UnclosedTemplateTag;
        const token = std.mem.trim(u8, source[open + 2 .. close], " \t\r\n");
        if (token.len == 0) return error.EmptyTemplateTag;

        if (token[0] == '#' or token[0] == '^') {
            const inverted = token[0] == '^';
            const name = std.mem.trim(u8, token[1..], " \t\r\n");
            if (name.len == 0) return error.EmptyTemplateTag;
            const section = try findSectionEnd(source, close + 2, name);
            const value = try fieldByName(ctx, name);
            if (fieldPresent(value) != inverted) {
                try renderTemplateInto(source[close + 2 .. section.body_end], ctx, side, front_side, out, state);
            }
            cursor = section.after_close;
            continue;
        }
        if (token[0] == '/') return error.UnexpectedTemplateClose;
        try renderToken(token, ctx, side, front_side, out, state);
        cursor = close + 2;
    }
    try out.writeAll(source[cursor..]);
}

fn renderHtml(
    allocator: std.mem.Allocator,
    source: []const u8,
    ctx: Context,
    side: Side,
    front_side: []const u8,
    state: *RenderState,
) ![]u8 {
    try validateSafeMarkup(source);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try renderTemplateInto(source, ctx, side, front_side, &out.writer, state);
    const bytes = out.written();
    try validateSafeMarkup(bytes);
    return out.toOwnedSlice();
}

fn writeEntity(entity: []const u8, out: *std.Io.Writer) !bool {
    if (std.mem.eql(u8, entity, "amp")) try out.writeByte('&') else if (std.mem.eql(u8, entity, "lt")) try out.writeByte('<') else if (std.mem.eql(u8, entity, "gt")) try out.writeByte('>') else if (std.mem.eql(u8, entity, "quot")) try out.writeByte('"') else if (std.mem.eql(u8, entity, "#39")) try out.writeByte('\'') else if (std.mem.eql(u8, entity, "nbsp")) try out.writeByte(' ') else return false;
    return true;
}

pub fn plainText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < html.len) {
        if (html[index] == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, index, '>') orelse {
                try out.writer.writeByte('<');
                index += 1;
                continue;
            };
            const tag = std.mem.trim(u8, html[index + 1 .. close], " \t\r\n/");
            if (std.mem.startsWith(u8, tag, "br") or std.mem.startsWith(u8, tag, "hr") or std.mem.startsWith(u8, tag, "div") or std.mem.startsWith(u8, tag, "p")) {
                if (out.written().len != 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte('\n');
            }
            index = close + 1;
            continue;
        }
        if (html[index] == '&') {
            if (std.mem.indexOfScalarPos(u8, html, index + 1, ';')) |semi| {
                if (try writeEntity(html[index + 1 .. semi], &out.writer)) {
                    index = semi + 1;
                    continue;
                }
            }
        }
        try out.writer.writeByte(html[index]);
        index += 1;
    }
    const raw = out.written();
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const result = try allocator.dupe(u8, trimmed);
    out.deinit();
    return result;
}

pub fn renderCard(
    allocator: std.mem.Allocator,
    definition: content.NoteTypeDefinition,
    fields: []const content.FieldValue,
    template_ordinal: content.TemplateOrdinal,
    options: Options,
) !RenderedCard {
    try content.validateNoteType(definition);
    try validateSafeMarkup(definition.css);
    for (fields) |field| try validateSafeMarkup(field.value);

    const template = blk: {
        for (definition.templates) |candidate| {
            if (candidate.ordinal == template_ordinal) break :blk candidate;
        }
        return error.TemplateNotFound;
    };
    const ctx: Context = .{ .definition = definition, .fields = fields, .cloze_ordinal = options.cloze_ordinal };
    var state: RenderState = .{};
    const front_html = try renderHtml(allocator, template.front, ctx, .front, "", &state);
    errdefer allocator.free(front_html);
    const back_html = try renderHtml(allocator, template.back, ctx, .back, front_html, &state);
    errdefer allocator.free(back_html);

    const front = if (options.mode == .html) front_html else blk: {
        const plain = try plainText(allocator, front_html);
        allocator.free(front_html);
        break :blk plain;
    };
    errdefer allocator.free(front);
    const back = if (options.mode == .html) back_html else blk: {
        const plain = try plainText(allocator, back_html);
        allocator.free(back_html);
        break :blk plain;
    };
    errdefer allocator.free(back);

    return .{
        .front = front,
        .back = back,
        .css = try allocator.dupe(u8, definition.css),
        .typed_answer = if (state.typed_answer) |answer| try allocator.dupe(u8, answer) else null,
    };
}

test "basic renders FrontSide and plain text deterministically" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "<b>Question</b>" },
        .{ .ordinal = 1, .value = "Answer" },
    };
    const rendered = try renderCard(std.testing.allocator, content.basic_note_type, &fields, 0, .{ .mode = .plain_text });
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Question", rendered.front);
    try std.testing.expectEqualStrings("Question\nAnswer", rendered.back);
}

test "conditional fields support normal and inverted sections" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "front" },
        .{ .ordinal = 1, .value = "" },
    };
    const field_defs = [_]content.FieldDefinition{
        .{ .ordinal = 0, .name = "Front" },
        .{ .ordinal = 1, .name = "Back" },
    };
    const templates = [_]content.CardTemplate{.{
        .ordinal = 0,
        .name = "conditional",
        .front = "{{#Front}}yes {{Front}}{{/Front}}{{^Back}} no-back{{/Back}}",
        .back = "{{FrontSide}}",
    }};
    const definition: content.NoteTypeDefinition = .{
        .id = 99,
        .slug = "conditional-test",
        .name = "Conditional",
        .kind = .custom,
        .css = "",
        .fields = &field_defs,
        .templates = &templates,
    };
    const rendered = try renderCard(std.testing.allocator, definition, &fields, 0, .{ .mode = .plain_text });
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("yes front no-back", rendered.front);
}

test "cloze renderer uses a stable ordinal" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "{{c1::Paris::city}} is in {{c2::France}}" },
        .{ .ordinal = 1, .value = "Europe" },
    };
    const rendered = try renderCard(std.testing.allocator, content.cloze_note_type, &fields, 0, .{ .mode = .plain_text, .cloze_ordinal = 1 });
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, rendered.front, "[city]") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.front, "France") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.back, "Paris") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.back, "Europe") != null);
}

test "type answer exposes expected answer without executable script" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "2 + 2" },
        .{ .ordinal = 1, .value = "4" },
    };
    const rendered = try renderCard(std.testing.allocator, content.type_answer_note_type, &fields, 0, .{});
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expect(rendered.typed_answer != null);
    try std.testing.expectEqualStrings("4", rendered.typed_answer.?);
    try std.testing.expect(std.mem.indexOf(u8, rendered.front, "deez-type-answer") != null);
}

test "unsafe script and event handlers are rejected" {
    try std.testing.expectError(error.UnsafeTemplateMarkup, validateSafeMarkup("<script>alert(1)</script>"));
    try std.testing.expectError(error.UnsafeTemplateMarkup, validateSafeMarkup("<img src=x onerror=alert(1)>"));
    try std.testing.expectError(error.UnsafeTemplateMarkup, validateSafeMarkup("<a href=javascript:alert(1)>x</a>"));
}

test "golden built-in basic plain-text rendering" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "<b>Capital of France?</b>" },
        .{ .ordinal = 1, .value = "Paris" },
    };

    const rendered = try renderCard(
        std.testing.allocator,
        content.basic_note_type,
        &fields,
        0,
        .{ .mode = .plain_text },
    );
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Capital of France?", rendered.front);
    try std.testing.expectEqualStrings("Capital of France?\nParis", rendered.back);
}

test "golden built-in reverse plain-text rendering" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "Capital of France?" },
        .{ .ordinal = 1, .value = "Paris" },
    };

    const rendered = try renderCard(
        std.testing.allocator,
        content.basic_reverse_note_type,
        &fields,
        1,
        .{ .mode = .plain_text },
    );
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Paris", rendered.front);
    try std.testing.expectEqualStrings("Paris\nCapital of France?", rendered.back);
}

test "golden built-in cloze plain-text rendering" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "Paris is the capital of {{c1::France}}." },
        .{ .ordinal = 1, .value = "Europe" },
    };

    const rendered = try renderCard(
        std.testing.allocator,
        content.cloze_note_type,
        &fields,
        0,
        .{
            .mode = .plain_text,
            .cloze_ordinal = 1,
        },
    );
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "Paris is the capital of [...].",
        rendered.front,
    );
    try std.testing.expectEqualStrings(
        "Paris is the capital of France.\nEurope",
        rendered.back,
    );
}

test "golden type-answer exposes typed answer metadata" {
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = "Capital of France?" },
        .{ .ordinal = 1, .value = "Paris" },
    };

    const rendered = try renderCard(
        std.testing.allocator,
        content.type_answer_note_type,
        &fields,
        0,
        .{ .mode = .plain_text },
    );
    defer rendered.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Capital of France?", rendered.front);
    try std.testing.expectEqualStrings("Paris", rendered.typed_answer.?);
    try std.testing.expectEqualStrings("Capital of France?\nParis", rendered.back);
}
