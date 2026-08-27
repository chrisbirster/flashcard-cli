const std = @import("std");
const Io = std.Io;

const media = @import("media.zig");

pub const help_text =
    \\Media commands:
    \\  plandalf media add <path>
    \\
    \\`plandalf media add` stores a file by SHA-256 and prints its stable media reference.
;

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "media");
}

fn mediaRoot(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    const home = init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
    const path = try std.fmt.allocPrint(allocator, "{s}/.local/share/plandalf/media", .{home});
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

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len != 4 or !std.mem.eql(u8, args[1], "media") or !std.mem.eql(u8, args[2], "add")) {
        return error.InvalidArguments;
    }

    const allocator = init.gpa;
    const media_root = try mediaRoot(init, init.arena.allocator());
    const metadata = try media.addFile(allocator, init.io, media_root, args[3]);
    defer metadata.deinit(allocator);
    try printMediaAdded(init, metadata);
}

test "media command is routed" {
    const media_args = [_][]const u8{ "plandalf", "media", "add", "diagram.png" };
    try std.testing.expect(isCommand(&media_args));
}
