const std = @import("std");
const Io = std.Io;

pub const Selection = struct {
    sqlite_path: []const u8,
};

fn home(init: std.process.Init) ![]const u8 {
    return init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
}

fn dataDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/plandalf", .{home_dir});
}

pub fn defaultSqlitePath(allocator: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/plandalf/plandalf.db", .{home_dir});
}

fn ensureSqliteDirectory(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const dir = try dataDir(allocator, try home(init));
    try Io.Dir.cwd().createDirPath(init.io, dir);
}

pub fn resolve(init: std.process.Init) !Selection {
    const allocator = init.arena.allocator();
    try ensureSqliteDirectory(init, allocator);
    return .{
        .sqlite_path = init.environ_map.get("PLANDALF_DB") orelse try defaultSqlitePath(allocator, try home(init)),
    };
}

pub fn setup(init: std.process.Init) !void {
    const selection = try resolve(init);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    try out.print("Plandalf SQLite database: {s}\n", .{selection.sqlite_path});
}

pub fn isSetupCommand(args: []const []const u8) bool {
    return args.len == 2 and std.mem.eql(u8, args[1], "setup");
}

test "default SQLite path is under Plandalf local share" {
    const path = try defaultSqlitePath(std.testing.allocator, "/Users/test");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/Users/test/.local/share/plandalf/plandalf.db", path);
}
