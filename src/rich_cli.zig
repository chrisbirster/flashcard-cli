const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const media = @import("media.zig");
const sack = @import("sack.zig");
const storage = @import("storage/root.zig");

pub const help_text =
    \\Media and sack commands:
    \\  deez media add <path>
    \\  deez sack export <deck-id> <output.sack>
    \\  deez sack import <input.sack>
    \\
    \\`deez media add` stores a file by SHA-256 and prints its stable deez-media:// reference.
    \\`.sack` is a ZIP-compatible bundle containing deck.nut, manifest.json, and referenced media.
;

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and (std.mem.eql(u8, args[1], "media") or std.mem.eql(u8, args[1], "sack"));
}

fn parseId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidId;
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn mediaRoot(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    const home = init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
    const path = try std.fmt.allocPrint(allocator, "{s}/.local/share/deez/media", .{home});
    try Io.Dir.cwd().createDirPath(init.io, path);
    return path;
}

fn printMediaAdded(init: std.process.Init, metadata: media.Metadata) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    const uri = try media.reference(init.arena.allocator(), metadata.sha256);
    try out.print("{s}\nsha256={s}\nmime={s}\nsize={d}\n", .{ uri, metadata.sha256, metadata.mime, metadata.size });
}

fn runSackWithStore(
    init: std.process.Init,
    args: []const []const u8,
    store: *storage.Store,
    media_root: []const u8,
) !void {
    const allocator = init.gpa;
    if (args.len < 3) return error.InvalidArguments;

    var buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    if (std.mem.eql(u8, args[2], "export")) {
        if (args.len != 5) return error.InvalidArguments;
        const deck_id = try parseId(args[3]);
        const media_count = try sack.exportFile(allocator, init.io, store, deck_id, media_root, args[4]);
        try out.print("Exported deck {d} to {s} ({d} media files).\n", .{ deck_id, args[4], media_count });
        return;
    }
    if (std.mem.eql(u8, args[2], "import")) {
        if (args.len != 4) return error.InvalidArguments;
        const result = try sack.importFile(allocator, init.io, store, media_root, args[3], nowMs(init.io));
        try out.print("Imported deck {d} ({d} cards, {d} media files).\n", .{ result.deck_id, result.card_count, result.media_count });
        return;
    }
    return error.UnknownCommand;
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 3) return error.InvalidArguments;
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const media_root = try mediaRoot(init, arena);

    if (std.mem.eql(u8, args[1], "media")) {
        if (args.len != 4 or !std.mem.eql(u8, args[2], "add")) return error.InvalidArguments;
        const metadata = try media.addFile(allocator, init.io, media_root, args[3]);
        defer metadata.deinit(allocator);
        try printMediaAdded(init, metadata);
        return;
    }

    if (!std.mem.eql(u8, args[1], "sack")) return error.UnknownCommand;
    const selection = try config.resolve(init);
    switch (selection.backend) {
        .mongodb => {
            const mongo = try storage.MongoStore.connect(init.io, allocator, selection.mongo_uri.?);
            var store: storage.Store = .{ .mongodb = mongo };
            defer store.deinit();
            try runSackWithStore(init, args, &store, media_root);
        },
        .sqlite => {
            const db_path_z = try arena.dupeZ(u8, selection.sqlite_path.?);
            var db = try storage.Db.open(db_path_z);
            defer db.close();
            try db.migrate();
            var store: storage.Store = .{ .sqlite = &db };
            try runSackWithStore(init, args, &store, media_root);
        },
    }
}

test "media and sack commands are routed separately" {
    const media_args = [_][]const u8{ "deez", "media", "add", "diagram.png" };
    const sack_args = [_][]const u8{ "deez", "sack", "import", "deck.sack" };
    try std.testing.expect(isCommand(&media_args));
    try std.testing.expect(isCommand(&sack_args));
}
