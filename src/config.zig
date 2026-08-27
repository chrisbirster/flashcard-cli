const std = @import("std");
const Io = std.Io;

pub const Backend = enum {
    sqlite,
    mongodb,
};

pub const Selection = struct {
    backend: Backend,
    sqlite_path: ?[]const u8 = null,
    mongo_uri: ?[]const u8 = null,
};

const max_config_bytes: usize = 64 * 1024;
const default_mongo_uri = "mongodb://localhost:27017/deez";

fn home(init: std.process.Init) ![]const u8 {
    return init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
}

fn configDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez", .{home_dir});
}

fn configPath(allocator: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.config/deez/config", .{home_dir});
}

fn dataDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/deez", .{home_dir});
}

pub fn defaultSqlitePath(allocator: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.local/share/deez/deez.db", .{home_dir});
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
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') break;
        if (byte != '\r') try bytes.append(allocator, byte);
    }
    return bytes.toOwnedSlice(allocator);
}

fn parseConfig(allocator: std.mem.Allocator, bytes: []const u8) !Selection {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const backend = std.mem.trim(u8, lines.next() orelse return error.InvalidConfig, " \t\r");
    const value = std.mem.trim(u8, lines.next() orelse "", " \t\r");

    if (std.mem.eql(u8, backend, "sqlite")) {
        if (value.len == 0) return error.InvalidConfig;
        return .{ .backend = .sqlite, .sqlite_path = try allocator.dupe(u8, value) };
    }
    if (std.mem.eql(u8, backend, "mongodb")) {
        if (value.len == 0) return error.InvalidConfig;
        return .{ .backend = .mongodb, .mongo_uri = try allocator.dupe(u8, value) };
    }
    return error.InvalidConfig;
}

fn loadConfig(init: std.process.Init, allocator: std.mem.Allocator) !?Selection {
    const home_dir = try home(init);
    const path = try configPath(allocator, home_dir);
    const bytes = Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try parseConfig(allocator, bytes);
}

fn saveConfig(init: std.process.Init, allocator: std.mem.Allocator, selection: Selection) !void {
    const home_dir = try home(init);
    const dir = try configDir(allocator, home_dir);
    try Io.Dir.cwd().createDirPath(init.io, dir);
    const path = try configPath(allocator, home_dir);
    const file = try Io.Dir.createFileAbsolute(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    file.setPermissions(init.io, @enumFromInt(0o600)) catch {};

    switch (selection.backend) {
        .sqlite => {
            try file.writeStreamingAll(init.io, "sqlite\n");
            try file.writeStreamingAll(init.io, selection.sqlite_path.?);
            try file.writeStreamingAll(init.io, "\n");
        },
        .mongodb => {
            try file.writeStreamingAll(init.io, "mongodb\n");
            try file.writeStreamingAll(init.io, selection.mongo_uri.?);
            try file.writeStreamingAll(init.io, "\n");
        },
    }
}

fn ensureSqliteDirectory(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const dir = try dataDir(allocator, try home(init));
    try Io.Dir.cwd().createDirPath(init.io, dir);
}

fn prompt(init: std.process.Init, allocator: std.mem.Allocator) !Selection {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const out = &stderr_file_writer.interface;

    try out.writeAll("Deez storage [sqlite/mongodb] (sqlite): ");
    try out.flush();
    const backend_input = try readLine(allocator, init.io);
    const backend = std.mem.trim(u8, backend_input, " \t\r\n");

    if (backend.len == 0 or std.ascii.eqlIgnoreCase(backend, "sqlite")) {
        try ensureSqliteDirectory(init, allocator);
        return .{
            .backend = .sqlite,
            .sqlite_path = init.environ_map.get("DEEZ_DB") orelse try defaultSqlitePath(allocator, try home(init)),
        };
    }

    if (std.ascii.eqlIgnoreCase(backend, "mongodb") or std.ascii.eqlIgnoreCase(backend, "mongo")) {
        if (init.environ_map.get("DEEZ_MONGO_URI")) |uri| {
            return .{ .backend = .mongodb, .mongo_uri = uri };
        }
        try out.print("MongoDB URI ({s}): ", .{default_mongo_uri});
        try out.flush();
        const uri_input = try readLine(allocator, init.io);
        const uri = std.mem.trim(u8, uri_input, " \t\r\n");
        return .{
            .backend = .mongodb,
            .mongo_uri = if (uri.len == 0) default_mongo_uri else uri,
        };
    }

    return error.InvalidStorageBackend;
}

pub fn resolve(init: std.process.Init) !Selection {
    const allocator = init.arena.allocator();

    if (init.environ_map.get("DEEZ_STORAGE")) |backend| {
        if (std.mem.eql(u8, backend, "mongodb")) {
            return .{
                .backend = .mongodb,
                .mongo_uri = init.environ_map.get("DEEZ_MONGO_URI") orelse return error.MissingMongoUri,
            };
        }
        if (std.mem.eql(u8, backend, "sqlite")) {
            try ensureSqliteDirectory(init, allocator);
            return .{
                .backend = .sqlite,
                .sqlite_path = init.environ_map.get("DEEZ_DB") orelse try defaultSqlitePath(allocator, try home(init)),
            };
        }
        return error.UnsupportedStorageBackend;
    }

    if (try loadConfig(init, allocator)) |configured| {
        return switch (configured.backend) {
            .sqlite => blk: {
                try ensureSqliteDirectory(init, allocator);
                break :blk .{
                    .backend = .sqlite,
                    .sqlite_path = init.environ_map.get("DEEZ_DB") orelse configured.sqlite_path,
                };
            },
            .mongodb => .{
                .backend = .mongodb,
                .mongo_uri = init.environ_map.get("DEEZ_MONGO_URI") orelse configured.mongo_uri,
            },
        };
    }

    const selection = try prompt(init, allocator);
    try saveConfig(init, allocator, selection);
    return selection;
}

pub fn setup(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const selection = try prompt(init, allocator);
    try saveConfig(init, allocator, selection);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    switch (selection.backend) {
        .sqlite => try out.print("Configured SQLite: {s}\n", .{selection.sqlite_path.?}),
        .mongodb => try out.writeAll("Configured MongoDB.\n"),
    }
}

pub fn isSetupCommand(args: []const []const u8) bool {
    return args.len == 2 and std.mem.eql(u8, args[1], "setup");
}

test "default SQLite path is under local share" {
    const path = try defaultSqlitePath(std.testing.allocator, "/Users/test");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/Users/test/.local/share/deez/deez.db", path);
}

test "config parser accepts SQLite and MongoDB" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sqlite = try parseConfig(allocator, "sqlite\n/tmp/deez.db\n");
    try std.testing.expectEqual(Backend.sqlite, sqlite.backend);
    try std.testing.expectEqualStrings("/tmp/deez.db", sqlite.sqlite_path.?);

    const mongo = try parseConfig(allocator, "mongodb\nmongodb://localhost:27017/deez\n");
    try std.testing.expectEqual(Backend.mongodb, mongo.backend);
    try std.testing.expectEqualStrings("mongodb://localhost:27017/deez", mongo.mongo_uri.?);
}
