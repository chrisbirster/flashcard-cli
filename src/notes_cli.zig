const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const content = @import("content.zig");
const storage = @import("storage/root.zig");

pub const help_text = "Usage: plandalf notes <deck-id>\n";

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "notes");
}

fn parseId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidId;
}

fn typeLabel(note_type_id: content.NoteTypeId) []const u8 {
    const kind = content.BuiltInNoteType.fromId(note_type_id) catch return "custom";
    return kind.definition().slug;
}

fn contains(ids: []const content.NoteId, id: content.NoteId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn listWithStore(
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    deck_id: u64,
) !void {
    const cards = try store.cards(allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }

    var seen: std.ArrayList(content.NoteId) = .empty;
    defer seen.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const content_store = storage.ContentStore.init(store);
    try out.writeAll("ID  TYPE  FIRST FIELD\n");

    for (cards) |card| {
        const maybe_source = try content_store.cardSource(allocator, card.id);
        if (maybe_source) |source| {
            defer source.deinit(allocator);
            if (contains(seen.items, source.note_id)) continue;
            try seen.append(allocator, source.note_id);

            const note = (try content_store.getNote(allocator, source.note_id)) orelse continue;
            defer note.deinit(allocator);
            const first = if (note.fields.len == 0) "" else note.fields[0].value;
            try out.print("{d}  {s}  {s}\n", .{ note.id, typeLabel(note.note_type_id), first });
        } else {
            try out.print("-  legacy-basic  {s}\n", .{card.question});
        }
    }
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 3) return error.InvalidArguments;
    const deck_id = try parseId(args[2]);
    const selection = try config.resolve(init);
    const db_path_z = try init.arena.allocator().dupeZ(u8, selection.sqlite_path);
    var db = try storage.Db.open(db_path_z);
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    try listWithStore(init.gpa, init.io, &store, deck_id);
}
