const std = @import("std");
const Io = std.Io;

const card_types = @import("card_types.zig");
const config = @import("config.zig");
const content = @import("content.zig");
const render = @import("render.zig");
const storage = @import("storage/root.zig");

pub const help_text =
    \\Interactive authoring:
    \\  plandalf add
    \\  plandalf add <deck-id>
    \\  plandalf note add
    \\  plandalf note add <deck-id>
    \\
    \\The interactive flow guides you through deck selection, note type,
    \\type-specific fields, a generated-card preview, and confirmation.
;

const authorable_note_types = [_]content.BuiltInNoteType{
    .basic,
    .basic_reverse,
    .cloze,
    .type_answer,
    .multiple_choice,
    .multiple_select,
    .ordering,
    .image_occlusion,
};

const Draft = struct {
    kind: content.BuiltInNoteType,
    fields: [][]u8,

    fn deinit(self: Draft, allocator: std.mem.Allocator) void {
        for (self.fields) |field| allocator.free(field);
        allocator.free(self.fields);
    }
};

const Choice = struct {
    id: []u8,
    text: []u8,

    fn deinit(self: Choice, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.text);
    }
};

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

pub fn isCommand(args: []const []const u8) bool {
    if (args.len >= 2 and std.mem.eql(u8, args[1], "add")) return args.len <= 3;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "note") and std.mem.eql(u8, args[2], "add")) return args.len <= 4;
    return false;
}

fn requestedDeckId(args: []const []const u8) !?u64 {
    if (args.len >= 2 and std.mem.eql(u8, args[1], "add")) {
        if (args.len == 2) return null;
        return std.fmt.parseInt(u64, args[2], 10) catch return error.InvalidId;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "note") and std.mem.eql(u8, args[2], "add")) {
        if (args.len == 3) return null;
        return std.fmt.parseInt(u64, args[3], 10) catch return error.InvalidId;
    }
    return error.InvalidArguments;
}

fn readByte(io: Io) !u8 {
    var buffer: [1]u8 = undefined;
    var buffers = [_][]u8{buffer[0..]};
    const read = try Io.File.stdin().readStreaming(io, &buffers);
    if (read == 0) return error.EndOfStream;
    return buffer[0];
}

fn readLine(allocator: std.mem.Allocator, io: Io) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    while (true) {
        const byte = readByte(io) catch |err| switch (err) {
            error.EndOfStream => if (bytes.items.len == 0) return err else break,
            else => return err,
        };
        if (byte == '\n') break;
        if (byte != '\r') try bytes.append(allocator, byte);
    }
    return bytes.toOwnedSlice(allocator);
}

fn trimmed(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn promptOwned(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    label: []const u8,
    allow_empty: bool,
) ![]u8 {
    while (true) {
        try out.writeAll(label);
        try out.flush();
        const line = try readLine(allocator, io);
        if (allow_empty or trimmed(line).len != 0) return line;
        allocator.free(line);
        try out.writeAll("A value is required.\n");
    }
}

fn promptYesNo(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    label: []const u8,
    default_yes: bool,
) !bool {
    while (true) {
        const line = try promptOwned(allocator, io, out, label, true);
        defer allocator.free(line);
        const value = trimmed(line);
        if (value.len == 0) return default_yes;
        if (std.ascii.eqlIgnoreCase(value, "y") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(value, "n") or std.ascii.eqlIgnoreCase(value, "no")) return false;
        try out.writeAll("Enter y or n.\n");
    }
}

fn chooseDeck(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    store: *storage.Store,
    requested: ?u64,
    now_ms: i64,
) !u64 {
    if (requested) |deck_id| {
        const deck = (try store.getDeck(allocator, deck_id)) orelse return error.DeckNotFound;
        defer deck.deinit(allocator);
        try out.print("Deck: {s} ({d})\n", .{ deck.name, deck.id });
        return deck_id;
    }

    const decks = try store.decks(allocator, now_ms);
    defer {
        for (decks) |deck| deck.deinit(allocator);
        allocator.free(decks);
    }

    if (decks.len == 0) {
        try out.writeAll("No decks yet. Create one first.\n");
        const name = try promptOwned(allocator, io, out, "Deck name: ", false);
        defer allocator.free(name);
        const id = try store.createDeck(trimmed(name), now_ms);
        _ = try store.ensureDefaultFsrs7(now_ms);
        try out.print("Created deck {d}: {s}\n", .{ id, trimmed(name) });
        return id;
    }

    try out.writeAll("\nDecks:\n");
    for (decks) |deck| try out.print("  {d}. {s}\n", .{ deck.id, deck.name });

    while (true) {
        const line = try promptOwned(allocator, io, out, "Deck ID: ", false);
        defer allocator.free(line);
        const id = std.fmt.parseInt(u64, trimmed(line), 10) catch {
            try out.writeAll("Enter a deck ID from the list.\n");
            continue;
        };
        for (decks) |deck| if (deck.id == id) return id;
        try out.writeAll("Enter a deck ID from the list.\n");
    }
}

fn noteTypeName(kind: content.BuiltInNoteType) []const u8 {
    return switch (kind) {
        .basic => "Basic",
        .basic_reverse => "Reverse",
        .cloze => "Cloze",
        .type_answer => "Type answer",
        .multiple_choice => "Multiple choice",
        .multiple_select => "Multiple select",
        .ordering => "Ordering",
        .image_occlusion => "Image occlusion",
        .optional_reverse => "Optional reverse (legacy)",
    };
}

fn chooseNoteType(allocator: std.mem.Allocator, io: Io, out: *Io.Writer) !content.BuiltInNoteType {
    try out.writeAll("\nNote type:\n");
    for (authorable_note_types, 0..) |kind, index| {
        try out.print("  {d}. {s}\n", .{ index + 1, noteTypeName(kind) });
    }
    while (true) {
        const line = try promptOwned(allocator, io, out, "Type: ", false);
        defer allocator.free(line);
        const selected = std.fmt.parseInt(usize, trimmed(line), 10) catch {
            try out.writeAll("Choose a number from the list.\n");
            continue;
        };
        if (selected >= 1 and selected <= authorable_note_types.len) return authorable_note_types[selected - 1];
        try out.writeAll("Choose a number from the list.\n");
    }
}

fn twoFieldDraft(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    kind: content.BuiltInNoteType,
) !Draft {
    const fields = try allocator.alloc([]u8, 2);
    errdefer allocator.free(fields);
    fields[0] = try promptOwned(allocator, io, out, "Front: ", false);
    errdefer allocator.free(fields[0]);
    fields[1] = try promptOwned(allocator, io, out, "Back: ", false);
    return .{ .kind = kind, .fields = fields };
}

fn indexOfOutsideCloze(source: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > source.len) return null;
    var index: usize = 0;
    while (index + needle.len <= source.len) {
        if (std.mem.startsWith(u8, source[index..], "{{c")) {
            if (std.mem.indexOf(u8, source[index + 3 ..], "}}")) |offset| {
                index = index + 3 + offset + 2;
                continue;
            }
        }
        if (std.mem.eql(u8, source[index .. index + needle.len], needle)) return index;
        index += 1;
    }
    return null;
}

fn wrapCloze(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    length: usize,
    group: u32,
) ![]u8 {
    var writer: Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll(source[0..start]);
    try writer.writer.writeAll("{{c");
    try writer.writer.print("{d}", .{group});
    try writer.writer.writeAll("::");
    try writer.writer.writeAll(source[start .. start + length]);
    try writer.writer.writeAll("}}");
    try writer.writer.writeAll(source[start + length ..]);
    return writer.toOwnedSlice();
}

fn chooseClozeGroup(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    group_count: u32,
) !u32 {
    if (group_count == 0) return 1;
    while (true) {
        try out.print("Cloze group [Enter = new c{d}; 1-{d} = hide together]: ", .{ group_count + 1, group_count });
        try out.flush();
        const line = try readLine(allocator, io);
        defer allocator.free(line);
        var value = trimmed(line);
        if (value.len == 0) return group_count + 1;
        if (value.len > 1 and (value[0] == 'c' or value[0] == 'C')) value = value[1..];
        const group = std.fmt.parseInt(u32, value, 10) catch {
            try out.writeAll("Use Enter for a new card, or an existing cloze number.\n");
            continue;
        };
        if (group >= 1 and group <= group_count) return group;
        try out.writeAll("Use Enter for a new card, or an existing cloze number.\n");
    }
}

fn clozeDraft(allocator: std.mem.Allocator, io: Io, out: *Io.Writer) !Draft {
    var working = try promptOwned(allocator, io, out, "Text: ", false);
    errdefer allocator.free(working);
    var groups: u32 = 0;
    var clozes: usize = 0;

    try out.writeAll("Select text to hide by typing it exactly as it appears.\n");
    while (true) {
        const selected = try promptOwned(allocator, io, out, if (clozes == 0) "Text to hide: " else "Text to hide (blank when done): ", clozes != 0);
        defer allocator.free(selected);
        const selection = trimmed(selected);
        if (selection.len == 0 and clozes != 0) break;

        const start = indexOfOutsideCloze(working, selection) orelse {
            try out.writeAll("That text was not found outside an existing cloze. Try again.\n");
            continue;
        };
        const group = try chooseClozeGroup(allocator, io, out, groups);
        if (group > groups) groups = group;
        const updated = try wrapCloze(allocator, working, start, selection.len, group);
        allocator.free(working);
        working = updated;
        clozes += 1;
        try out.print("Added c{d}. Current text:\n{s}\n", .{ group, working });
    }

    const extra = try promptOwned(allocator, io, out, "Extra information (optional): ", true);
    errdefer allocator.free(extra);
    const fields = try allocator.alloc([]u8, 2);
    fields[0] = working;
    fields[1] = extra;
    return .{ .kind = .cloze, .fields = fields };
}

fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn collectChoices(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    item_name: []const u8,
) ![]Choice {
    var choices: std.ArrayList(Choice) = .empty;
    errdefer {
        for (choices.items) |choice| choice.deinit(allocator);
        choices.deinit(allocator);
    }

    while (choices.items.len < 26) {
        const index = choices.items.len;
        var label_buffer: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "{s} {c}{s}: ", .{
            item_name,
            @as(u8, 'A') + @as(u8, @intCast(index)),
            if (index >= 2) " (blank to finish)" else "",
        });
        const text = try promptOwned(allocator, io, out, label, index >= 2);
        if (trimmed(text).len == 0 and index >= 2) {
            allocator.free(text);
            break;
        }
        const id = try std.fmt.allocPrint(allocator, "{c}", .{@as(u8, 'A') + @as(u8, @intCast(index))});
        errdefer allocator.free(id);
        try choices.append(allocator, .{ .id = id, .text = text });
    }
    return choices.toOwnedSlice(allocator);
}

fn choiceIndex(value: []const u8, count: usize) ?usize {
    const text = trimmed(value);
    if (text.len != 1) return null;
    const letter = std.ascii.toUpper(text[0]);
    if (letter < 'A') return null;
    const index: usize = letter - 'A';
    return if (index < count) index else null;
}

fn choiceDraft(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    multiple: bool,
) !Draft {
    const prompt = try promptOwned(allocator, io, out, "Question: ", false);
    errdefer allocator.free(prompt);
    const choices = try collectChoices(allocator, io, out, "Choice");
    defer {
        for (choices) |choice| choice.deinit(allocator);
        allocator.free(choices);
    }
    const choices_json = try stringify(allocator, choices);
    errdefer allocator.free(choices_json);

    var correct: []u8 = undefined;
    if (!multiple) {
        while (true) {
            const line = try promptOwned(allocator, io, out, "Correct choice: ", false);
            defer allocator.free(line);
            const index = choiceIndex(line, choices.len) orelse {
                try out.writeAll("Enter the letter of one of the choices.\n");
                continue;
            };
            correct = try allocator.dupe(u8, choices[index].id);
            break;
        }
    } else {
        while (true) {
            const line = try promptOwned(allocator, io, out, "Correct choices (comma separated, e.g. A,C): ", false);
            defer allocator.free(line);
            var ids: std.ArrayList([]const u8) = .empty;
            defer ids.deinit(allocator);
            var parts = std.mem.splitScalar(u8, line, ',');
            var valid = true;
            while (parts.next()) |part| {
                const index = choiceIndex(part, choices.len) orelse {
                    valid = false;
                    break;
                };
                for (ids.items) |existing| {
                    if (std.mem.eql(u8, existing, choices[index].id)) {
                        valid = false;
                        break;
                    }
                }
                if (!valid) break;
                try ids.append(allocator, choices[index].id);
            }
            if (!valid or ids.items.len == 0) {
                try out.writeAll("Enter unique choice letters separated by commas.\n");
                continue;
            }
            correct = try stringify(allocator, ids.items);
            break;
        }
    }
    errdefer allocator.free(correct);

    const explanation = try promptOwned(allocator, io, out, "Explanation (optional): ", true);
    errdefer allocator.free(explanation);
    const fields = try allocator.alloc([]u8, 4);
    fields[0] = prompt;
    fields[1] = choices_json;
    fields[2] = correct;
    fields[3] = explanation;
    return .{ .kind = if (multiple) .multiple_select else .multiple_choice, .fields = fields };
}

fn orderingDraft(allocator: std.mem.Allocator, io: Io, out: *Io.Writer) !Draft {
    const prompt = try promptOwned(allocator, io, out, "Prompt: ", false);
    errdefer allocator.free(prompt);
    const items = try collectChoices(allocator, io, out, "Item");
    defer {
        for (items) |item| item.deinit(allocator);
        allocator.free(items);
    }
    const items_json = try stringify(allocator, items);
    errdefer allocator.free(items_json);
    const explanation = try promptOwned(allocator, io, out, "Explanation (optional): ", true);
    errdefer allocator.free(explanation);
    const fields = try allocator.alloc([]u8, 3);
    fields[0] = prompt;
    fields[1] = items_json;
    fields[2] = explanation;
    return .{ .kind = .ordering, .fields = fields };
}

fn imageOcclusionDraft(allocator: std.mem.Allocator, io: Io, out: *Io.Writer) !Draft {
    try out.writeAll("Image occlusion currently accepts the media reference and mask data directly.\nRun `plandalf media add <path>` first if needed.\n");
    const fields = try allocator.alloc([]u8, 3);
    errdefer allocator.free(fields);
    fields[0] = try promptOwned(allocator, io, out, "Image media reference: ", false);
    errdefer allocator.free(fields[0]);
    fields[1] = try promptOwned(allocator, io, out, "Masks JSON: ", false);
    errdefer allocator.free(fields[1]);
    fields[2] = try promptOwned(allocator, io, out, "Extra information (optional): ", true);
    return .{ .kind = .image_occlusion, .fields = fields };
}

fn buildDraft(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    kind: content.BuiltInNoteType,
) !Draft {
    return switch (kind) {
        .basic, .basic_reverse, .type_answer => twoFieldDraft(allocator, io, out, kind),
        .cloze => clozeDraft(allocator, io, out),
        .multiple_choice => choiceDraft(allocator, io, out, false),
        .multiple_select => choiceDraft(allocator, io, out, true),
        .ordering => orderingDraft(allocator, io, out),
        .image_occlusion => imageOcclusionDraft(allocator, io, out),
        .optional_reverse => error.LegacyNoteTypeNotAuthorable,
    };
}

fn previewDraft(
    allocator: std.mem.Allocator,
    out: *Io.Writer,
    draft: Draft,
) !void {
    const rendered = try card_types.renderedDrafts(allocator, draft.kind, draft.fields, render.Mode.plain_text);
    defer {
        for (rendered) |card| card.deinit(allocator);
        allocator.free(rendered);
    }
    try out.print("\nPreview ({d} card{s}):\n", .{ rendered.len, if (rendered.len == 1) "" else "s" });
    for (rendered, 0..) |card, index| {
        try out.print("\nCard {d}\nFront:\n{s}\n\nBack:\n{s}\n", .{ index + 1, card.rendered.front, card.rendered.back });
    }
}

fn runWithStore(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    store: *storage.Store,
    requested_deck_id: ?u64,
) !void {
    const now_ms = nowMs(io);
    const deck_id = try chooseDeck(allocator, io, out, store, requested_deck_id, now_ms);

    while (true) {
        const kind = try chooseNoteType(allocator, io, out);
        try out.print("\nAdd note > {s}\n\n", .{noteTypeName(kind)});
        const draft = try buildDraft(allocator, io, out, kind);
        defer draft.deinit(allocator);

        try previewDraft(allocator, out, draft);
        if (try promptYesNo(allocator, io, out, "\nSave this note? [Y/n] ", true)) {
            const result = try card_types.create(allocator, store, deck_id, draft.kind, draft.fields, "[]", nowMs(io));
            defer result.deinit(allocator);
            try out.print("Saved note {d} ({d} card{s}).\n", .{ result.note_id, result.card_ids.len, if (result.card_ids.len == 1) "" else "s" });
        } else {
            try out.writeAll("Not saved.\n");
        }

        if (!try promptYesNo(allocator, io, out, "Add another note to this deck? [y/N] ", false)) break;
    }
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (!isCommand(args)) return error.InvalidArguments;
    const requested = try requestedDeckId(args);
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const selection = try config.resolve(init);
    const db_path_z = try arena.dupeZ(u8, selection.sqlite_path);
    var db = try storage.Db.open(db_path_z);
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    try runWithStore(allocator, init.io, out, &store, requested);
}

test "interactive authoring command detection does not steal scripted note add" {
    const add = [_][]const u8{ "plandalf", "add" };
    const add_deck = [_][]const u8{ "plandalf", "add", "4" };
    const note_add = [_][]const u8{ "plandalf", "note", "add" };
    const note_add_deck = [_][]const u8{ "plandalf", "note", "add", "4" };
    const scripted = [_][]const u8{ "plandalf", "note", "add", "4", "basic", "front", "back" };
    try std.testing.expect(isCommand(&add));
    try std.testing.expect(isCommand(&add_deck));
    try std.testing.expect(isCommand(&note_add));
    try std.testing.expect(isCommand(&note_add_deck));
    try std.testing.expect(!isCommand(&scripted));
}

test "cloze groups can hide two spans together and a third separately" {
    const allocator = std.testing.allocator;
    var text = try allocator.dupe(u8, "primary secondary arbiter");
    defer allocator.free(text);

    var start = indexOfOutsideCloze(text, "primary").?;
    var updated = try wrapCloze(allocator, text, start, "primary".len, 1);
    allocator.free(text);
    text = updated;

    start = indexOfOutsideCloze(text, "secondary").?;
    updated = try wrapCloze(allocator, text, start, "secondary".len, 1);
    allocator.free(text);
    text = updated;

    start = indexOfOutsideCloze(text, "arbiter").?;
    updated = try wrapCloze(allocator, text, start, "arbiter".len, 2);
    allocator.free(text);
    text = updated;

    try std.testing.expectEqualStrings("{{c1::primary}} {{c1::secondary}} {{c2::arbiter}}", text);
    try std.testing.expect(indexOfOutsideCloze(text, "primary") == null);
}
