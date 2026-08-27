const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const storage = @import("storage/root.zig");
const web = @import("web.zig");
const web_assets = @import("web_assets.zig");

pub const help_text =
    \\Usage: plandalf web [--port <port>] [--web-root <path>] [--no-open]
    \\
    \\Start the local Plandalf Web app on 127.0.0.1.
    \\The default port is 49317. When UI assets are available, Plandalf opens
    \\the app in your default browser after the local listener is ready.
    \\
    \\Options:
    \\  --port <port>      Override the local listen port.
    \\  --web-root <path>  Serve a specific built Plandalf Web dist directory.
    \\  --no-open          Do not open the default browser.
    \\
    \\Web assets are resolved in this order:
    \\  1. --web-root <path>
    \\  2. PLANDALF_WEB_ROOT
    \\  3. packaged web assets beside the installed plandalf binary
    \\
;

const CliOptions = struct {
    port: u16 = web.default_port,
    web_root: ?[]const u8 = null,
    open_browser: bool = true,
};

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "web");
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len == 3 and isHelp(args[2])) {
        try printHelp(init);
        return;
    }

    const options = try parseOptions(args);
    const web_root = try web_assets.resolveRoot(init, options.web_root);
    const open_browser = options.open_browser and init.environ_map.get("CI") == null;
    const selection = try config.resolve(init);

    const db_path_z = try init.arena.allocator().dupeZ(u8, selection.sqlite_path.?);
    var db = try storage.Db.open(db_path_z);
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    try web.run(init, &store, .{
        .port = options.port,
        .web_root = web_root,
        .open_browser = open_browser,
    });
}

fn parseOptions(args: []const []const u8) !CliOptions {
    if (args.len < 2) return error.InvalidArguments;

    var options: CliOptions = .{};
    var index: usize = 2;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            const port = std.fmt.parseInt(u16, args[index + 1], 10) catch return error.InvalidPort;
            if (port == 0) return error.InvalidPort;
            options.port = port;
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--web-root")) {
            if (index + 1 >= args.len or args[index + 1].len == 0) return error.InvalidArguments;
            options.web_root = args[index + 1];
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-open")) {
            options.open_browser = false;
            index += 1;
            continue;
        }
        return error.InvalidArguments;
    }
    return options;
}

fn isHelp(value: []const u8) bool {
    return std.mem.eql(u8, value, "--help") or std.mem.eql(u8, value, "-h");
}

fn printHelp(init: std.process.Init) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    try out.writeAll(help_text);
}

test "web cli defaults to browser open on the fixed local port" {
    const args = [_][]const u8{ "plandalf", "web" };
    const options = try parseOptions(&args);
    try std.testing.expectEqual(web.default_port, options.port);
    try std.testing.expect(options.web_root == null);
    try std.testing.expect(options.open_browser);
}

test "web cli accepts port web root and no-open" {
    const first = [_][]const u8{ "plandalf", "web", "--port", "55000", "--web-root", "/tmp/plandalf-web", "--no-open" };
    const first_options = try parseOptions(&first);
    try std.testing.expectEqual(@as(u16, 55000), first_options.port);
    try std.testing.expectEqualStrings("/tmp/plandalf-web", first_options.web_root.?);
    try std.testing.expect(!first_options.open_browser);

    const second = [_][]const u8{ "plandalf", "web", "--no-open", "--web-root", "/tmp/plandalf-web", "--port", "55001" };
    const second_options = try parseOptions(&second);
    try std.testing.expectEqual(@as(u16, 55001), second_options.port);
    try std.testing.expect(!second_options.open_browser);
}

test "web cli rejects invalid ports and arguments" {
    const zero = [_][]const u8{ "plandalf", "web", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parseOptions(&zero));
    const missing_root = [_][]const u8{ "plandalf", "web", "--web-root" };
    try std.testing.expectError(error.InvalidArguments, parseOptions(&missing_root));
    const invalid = [_][]const u8{ "plandalf", "web", "55000" };
    try std.testing.expectError(error.InvalidArguments, parseOptions(&invalid));
}
