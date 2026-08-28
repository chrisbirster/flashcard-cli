const std = @import("std");
const Io = std.Io;

const card_types = @import("card_types.zig");
const config = @import("config.zig");
const content = @import("content.zig");
const note_mutation = @import("note_mutation.zig");
const render = @import("render.zig");
const storage = @import("storage/root.zig");

pub const help_text =
    \\Interactive editing:
    \\  plandalf edit
    \\  plandalf edit <deck-id>
    \\  plandalf edit <deck-id> <note-id>
    \\  plandalf note edit
    \\  plandalf note edit <deck-id>
    \\  plandalf note edit <deck-id> <note-id>
    \\
    \\Existing values are shown before each prompt. Press Enter to keep a value.
    \\For optional text fields, enter a single - to clear the value.
;

const Request = struct {
    deck_id: ?u64 = null,
    note_id: ?content.NoteId = null,
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
    if (args.len >= 2 and std.mem.eql(u8, args[1], "edit")) return args.len <= 4;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "note") and std.mem.eql(u8, args[2], "edit")) return args.len <= 5;
    return false;
}

fn parseId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidId;
}

fn requestFromArgs(args: []const []const u8) !Request {
    if (args.len >= 2 and std.mem.eql(u8, args[1], "edit")) {
        return .{
            .deck_id = if (args.len >= 3) try parseId(args[2]) else null,
            .note_id = if (args.len >= 4) try parseId(args[3]) else null,
        };
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "note") and std.mem.eql(u8, args[2], "edit")) {
        return .{
            .deck_id = if (args.len >= 4) try parseId(args[3]) else null,
            .note_id = if (args.len >= 5) try parseId(args[4]) else null,
        };
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
) ![]u8 {
    try out.writeAll(label);
    try out.flush();
    return readLine(allocator, io);
}

fn promptYesNo(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    label: []const u8,
    default_yes: bool,
) !bool {
    while (true) {
        const line = try promptOwned(allocator, io, out, label);
        defer allocator.free(line);
        const value = trimmed(line);
        if (value.len == 0) return default_yes;
        if (std.ascii.eqlIgnoreCase(value, "y") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
        if (std.ascii.eqlIgnoreCase(value, "n") or std.ascii.eqlIgnoreCase(value, "no")) return false;
        try out.writeAll("Enter y or n.\n");
    }
}

fn promptExisting(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    label: []const u8,
    current: []const u8,
    optional: bool,
) ![]u8 {
    while (true) {
        try out.print("\n{s}\nCurrent: {s}\n", .{ label, current });
        const line = try promptOwned(allocator, io, out, if (optional)
            "New value [Enter = keep, - = clear]: "
        else
            "New value [Enter = keep]: ");
        if (trimmed(line).len == 0) {
            allocator.free(line);
            return allocator.dupe(u8, current);
        }
        if (optional and std.mem.eql(u8, trimmed(line), "-")) {
            allocator.free(line);
            return allocator.dupe(u8, "");
        }
        if (!optional and trimmed(line).len == 0) {
            allocator.free(line);
            try out.writeAll("A value is required.\n");
            continue;
        }
        return line;
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
    if (decks.len == 0) return error.NoDecks;

    try out.writeAll("\nDecks:\n");
    for (decks) |deck| try out.print("  {d}. {s}\n", .{ deck.id, deck.name });
    while (true) {
        const line = try promptOwned(allocator, io, out, "Deck ID: ");
        defer allocator.free(line);
        const id = parseId(trimmed(line)) catch {
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
        .optional_reverse => "Optional reverse (legacy)",
        .cloze => "Cloze",
        .type_answer => "Type answer",
        .multiple_choice => "Multiple choice",
        .multiple_select => "Multiple select",
        .ordering => "Ordering",
        .image_occlusion => "Image occlusion",
    };
}

fn containsNote(ids: []const content.NoteId, id: content.NoteId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn noteBelongsToDeck(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    note_id: content.NoteId,
) !bool {
    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }
    const content_store = storage.ContentStore.init(store);
    for (cards) |card| {
        const source = (try content_store.cardSource(allocator, card.id)) orelse continue;
        defer source.deinit(allocator);
        if (source.note_id == note_id) return true;
    }
    return false;
}

fn chooseNote(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    store: *storage.Store,
    deck_id: u64,
    requested: ?content.NoteId,
) !content.NoteId {
    if (requested) |note_id| {
        if (!try noteBelongsToDeck(allocator, store, deck_id, note_id)) return error.NoteNotFound;
        return note_id;
    }

    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }
    const content_store = storage.ContentStore.init(store);
    var seen: std.ArrayList(content.NoteId) = .empty;
    defer seen.deinit(allocator);

    try out.writeAll("\nNotes:\n");
    for (cards) |card| {
        const source = (try content_store.cardSource(allocator, card.id)) orelse continue;
        defer source.deinit(allocator);
        if (containsNote(seen.items, source.note_id)) continue;
        try seen.append(allocator, source.note_id);

        const note = (try content_store.getNote(allocator, source.note_id)) orelse continue;
        defer note.deinit(allocator);
        const kind = content.BuiltInNoteType.fromId(note.note_type_id) catch continue;
        const first = if (note.fields.len == 0) "" else note.fields[0].value;
        try out.print("  {d}. [{s}] {s}\n", .{ note.id, noteTypeName(kind), first });
    }
    if (seen.items.len == 0) return error.NoEditableNotes;

    while (true) {
        const line = try promptOwned(allocator, io, out, "Note ID: ");
        defer allocator.free(line);
        const id = parseId(trimmed(line)) catch {
            try out.writeAll("Enter a note ID from the list.\n");
            continue;
        };
        if (containsNote(seen.items, id)) return id;
        try out.writeAll("Enter a note ID from the list.\n");
    }
}

fn fieldAt(note: content.OwnedNote, ordinal: usize) ![]const u8 {
    for (note.fields) |field| if (field.ordinal == ordinal) return field.value;
    return error.MissingNoteField;
}

fn stringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

const ChoiceInput = struct {
    id: []const u8,
    text: []const u8,
};

fn parseChoices(allocator: std.mem.Allocator, source: []const u8) ![]Choice {
    var parsed = try std.json.parseFromSlice([]const ChoiceInput, allocator, source, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const result = try allocator.alloc(Choice, parsed.value.len);
    var completed: usize = 0;
    errdefer {
        for (result[0..completed]) |choice| choice.deinit(allocator);
        allocator.free(result);
    }
    for (parsed.value, 0..) |choice, index| {
        result[index] = .{
            .id = try allocator.dupe(u8, choice.id),
            .text = try allocator.dupe(u8, choice.text),
        };
        completed += 1;
    }
    return result;
}

fn hasChoice(choices: []const Choice, id: []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, choice.id, id)) return true;
    return false;
}

fn editChoiceTexts(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    choices: []Choice,
) !void {
    try out.writeAll("\nChoices:\n");
    for (choices) |*choice| {
        var label_buffer: [96]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buffer, "Choice {s}", .{choice.id});
        const updated = try promptExisting(allocator, io, out, label, choice.text, false);
        allocator.free(choice.text);
        choice.text = updated;
    }
}

fn editTwoField(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    note: content.OwnedNote,
    kind: content.BuiltInNoteType,
) ![][]u8 {
    const fields = try allocator.alloc([]u8, 2);
    errdefer allocator.free(fields);
    fields[0] = try promptExisting(allocator, io, out, "Front", try fieldAt(note, 0), false);
    errdefer allocator.free(fields[0]);
    fields[1] = try promptExisting(allocator, io, out, "Back", try fieldAt(note, 1), false);
    _ = kind;
    return fields;
}

fn editCloze(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    note: content.OwnedNote,
) ![][]u8 {
    try out.writeAll("\nUse {{c1::answer}} syntax directly. Matching cloze numbers hide together.\n");
    const fields = try allocator.alloc([]u8, 2);
    errdefer allocator.free(fields);
    fields[0] = try promptExisting(allocator, io, out, "Text", try fieldAt(note, 0), false);
    errdefer allocator.free(fields[0]);
    fields[1] = try promptExisting(allocator, io, out, "Extra information", try fieldAt(note, 1), true);
    return fields;
}

fn editChoiceNote(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    note: content.OwnedNote,
    multiple: bool,
) ![][]u8 {
    const prompt = try promptExisting(allocator, io, out, "Question", try fieldAt(note, 0), false);
    errdefer allocator.free(prompt);

    const choices = try parseChoices(allocator, try fieldAt(note, 1));
    defer {
        for (choices) |choice| choice.deinit(allocator);
        allocator.free(choices);
    }
    try editChoiceTexts(allocator, io, out, choices);
    const choices_json = try stringify(allocator, choices);
    errdefer allocator.free(choices_json);

    var correct: []u8 = undefined;
    if (!multiple) {
        const current = try fieldAt(note, 2);
        while (true) {
            const line = try promptExisting(allocator, io, out, "Correct choice", current, false);
            if (hasChoice(choices, trimmed(line))) {
                correct = line;
                break;
            }
            allocator.free(line);
            try out.writeAll("Enter one of the displayed choice IDs.\n");
        }
    } else {
        const current = try fieldAt(note, 2);
        while (true) {
            try out.print("\nCorrect choices\nCurrent: {s}\n", .{current});
            const line = try promptOwned(allocator, io, out, "New choices as comma-separated IDs [Enter = keep]: ");
            if (trimmed(line).len == 0) {
                allocator.free(line);
                correct = try allocator.dupe(u8, current);
                break;
            }

            var ids: std.ArrayList([]const u8) = .empty;
            defer ids.deinit(allocator);
            var parts = std.mem.splitScalar(u8, line, ',');
            var valid = true;
            while (parts.next()) |part| {
                const id = trimmed(part);
                if (id.len == 0 or !hasChoice(choices, id)) {
                    valid = false;
                    break;
                }
                for (ids.items) |existing| if (std.mem.eql(u8, existing, id)) {
                    valid = false;
                    break;
                };
                if (!valid) break;
                try ids.append(allocator, id);
            }
            if (valid and ids.items.len != 0) {
                correct = try stringify(allocator, ids.items);
                allocator.free(line);
                break;
            }
            allocator.free(line);
            try out.writeAll("Enter unique displayed choice IDs separated by commas.\n");
        }
    }
    errdefer allocator.free(correct);

    const explanation = try promptExisting(allocator, io, out, "Explanation", try fieldAt(note, 3), true);
    errdefer allocator.free(explanation);
    const fields = try allocator.alloc([]u8, 4);
    fields[0] = prompt;
    fields[1] = choices_json;
    fields[2] = correct;
    fields[3] = explanation;
    return fields;
}

fn editOrdering(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    note: content.OwnedNote,
) ![][]u8 {
    const prompt = try promptExisting(allocator, io, out, "Prompt", try fieldAt(note, 0), false);
    errdefer allocator.free(prompt);
    const items = try parseChoices(allocator, try fieldAt(note, 1));
    defer {
        for (items) |item| item.deinit(allocator);
        allocator.free(items);
    }
    try out.writeAll("\nItems are stored in the correct order.\n");
    try editChoiceTexts(allocator, io, out, items);
    const items_json = try stringify(allocator, items);
    errdefer allocator.free(items_json);
    const explanation = try promptExisting(allocator, io, out, "Explanation", try fieldAt(note, 2), true);
    errdefer allocator.free(explanation);
    const fields = try allocator.alloc([]u8, 3);
    fields[0] = prompt;
    fields[1] = items_json;
    fields[2] = explanation;
    return fields;
}

fn editImageOcclusion(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    note: content.OwnedNote,
) ![][]u8 {
    const fields = try allocator.alloc([]u8, 3);
    errdefer allocator.free(fields);
    fields[0] = try promptExisting(allocator, io, out, "Image media reference", try fieldAt(note, 0), false);
    errdefer allocator.free(fields[0]);
    fields[1] = try promptExisting(allocator, io, out, "Masks JSON", try fieldAt(note, 1), false);
    errdefer allocator.free(fields[1]);
    fields[2] = try promptExisting(allocator, io, out, "Extra information", try fieldAt(note, 2), true);
    return fields;
}

fn editLegacyOptionalReverse(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    note: content.OwnedNote,
) ![][]u8 {
    const fields = try allocator.alloc([]u8, 3);
    errdefer allocator.free(fields);
    fields[0] = try promptExisting(allocator, io, out, "Front", try fieldAt(note, 0), false);
    errdefer allocator.free(fields[0]);
    fields[1] = try promptExisting(allocator, io, out, "Back", try fieldAt(note, 1), false);
    errdefer allocator.free(fields[1]);
    fields[2] = try allocator.dupe(u8, try fieldAt(note, 2));
    try out.writeAll("\nThis is a legacy optional-reverse note. Its reverse setting is preserved.\n");
    return fields;
}

fn editFields(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    note: content.OwnedNote,
    kind: content.BuiltInNoteType,
) ![][]u8 {
    return switch (kind) {
        .basic, .basic_reverse, .type_answer => editTwoField(allocator, io, out, note, kind),
        .cloze => editCloze(allocator, io, out, note),
        .multiple_choice => editChoiceNote(allocator, io, out, note, false),
        .multiple_select => editChoiceNote(allocator, io, out, note, true),
        .ordering => editOrdering(allocator, io, out, note),
        .image_occlusion => editImageOcclusion(allocator, io, out, note),
        .optional_reverse => editLegacyOptionalReverse(allocator, io, out, note),
    };
}

fn deinitFields(allocator: std.mem.Allocator, fields: [][]u8) void {
    for (fields) |field| allocator.free(field);
    allocator.free(fields);
}

fn preview(
    allocator: std.mem.Allocator,
    out: *Io.Writer,
    kind: content.BuiltInNoteType,
    fields: []const []const u8,
) !void {
    const rendered = try card_types.renderedDrafts(allocator, kind, fields, render.Mode.plain_text);
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
    request: Request,
) !void {
    const deck_id = try chooseDeck(allocator, io, out, store, request.deck_id, nowMs(io));

    while (true) {
        const note_id = try chooseNote(allocator, io, out, store, deck_id, request.note_id);
        const content_store = storage.ContentStore.init(store);
        const note = (try content_store.getNote(allocator, note_id)) orelse return error.NoteNotFound;
        defer note.deinit(allocator);
        const kind = content.BuiltInNoteType.fromId(note.note_type_id) catch return error.UnsupportedNoteType;

        try out.print("\nEdit note {d} > {s}\n", .{ note.id, noteTypeName(kind) });
        const fields = try editFields(allocator, io, out, note, kind);
        defer deinitFields(allocator, fields);

        try preview(allocator, out, kind, fields);
        if (try promptYesNo(allocator, io, out, "\nSave changes? [Y/n] ", true)) {
            const card_ids = try note_mutation.update(
                allocator,
                store,
                deck_id,
                note.id,
                fields,
                note.tags_json,
                nowMs(io),
            );
            defer allocator.free(card_ids);
            try out.print("Updated note {d} ({d} active card{s}).\n", .{
                note.id,
                card_ids.len,
                if (card_ids.len == 1) "" else "s",
            });
        } else {
            try out.writeAll("Not saved.\n");
        }

        if (request.note_id != null) break;
        if (!try promptYesNo(allocator, io, out, "Edit another note in this deck? [y/N] ", false)) break;
    }
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (!isCommand(args)) return error.InvalidArguments;
    const request = try requestFromArgs(args);
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

    try runWithStore(allocator, init.io, out, &store, request);
}

test "interactive edit detection does not steal scripted note edit" {
    const edit = [_][]const u8{ "plandalf", "edit" };
    const edit_deck = [_][]const u8{ "plandalf", "edit", "4" };
    const edit_note = [_][]const u8{ "plandalf", "edit", "4", "9" };
    const note_edit = [_][]const u8{ "plandalf", "note", "edit" };
    const note_edit_deck = [_][]const u8{ "plandalf", "note", "edit", "4" };
    const note_edit_note = [_][]const u8{ "plandalf", "note", "edit", "4", "9" };
    const scripted = [_][]const u8{ "plandalf", "note", "edit", "4", "9", "front", "back" };

    try std.testing.expect(isCommand(&edit));
    try std.testing.expect(isCommand(&edit_deck));
    try std.testing.expect(isCommand(&edit_note));
    try std.testing.expect(isCommand(&note_edit));
    try std.testing.expect(isCommand(&note_edit_deck));
    try std.testing.expect(isCommand(&note_edit_note));
    try std.testing.expect(!isCommand(&scripted));
}
