const std = @import("std");
const httpz = @import("httpz");

const Io = std.Io;

pub const max_asset_bytes: usize = 16 * 1024 * 1024;

pub const ServeResult = enum {
    served,
    not_found,
    unsafe_path,
};

pub fn resolveRoot(init: std.process.Init, override: ?[]const u8) !?[]const u8 {
    const allocator = init.arena.allocator();

    if (override) |root| {
        if (!try hasIndex(init.io, allocator, root)) return error.WebRootMissingIndex;
        return root;
    }

    if (init.environ_map.get("PLANDALF_WEB_ROOT")) |root| {
        if (!try hasIndex(init.io, allocator, root)) return error.WebRootMissingIndex;
        return root;
    }

    const executable = std.process.executablePathAlloc(init.io, allocator) catch return null;
    const executable_dir = std.fs.path.dirname(executable) orelse return null;

    const portable = try std.fs.path.join(allocator, &.{ executable_dir, "web" });
    if (try hasIndex(init.io, allocator, portable)) return portable;

    const installed = try std.fs.path.join(allocator, &.{ executable_dir, "..", "share", "plandalf", "web" });
    if (try hasIndex(init.io, allocator, installed)) return installed;

    return null;
}

pub fn serve(
    io: Io,
    root: []const u8,
    request_path: []const u8,
    res: *httpz.Response,
) !ServeResult {
    const relative = normalizeRequestPath(request_path) orelse return .unsafe_path;

    if (try readAsset(io, res.arena, root, relative)) |body| {
        setAssetResponse(res, relative, body);
        return .served;
    }

    // Vite assets and other file-shaped requests should return a real 404.
    // Extensionless paths are client-side Solid Router routes and fall back to
    // index.html so direct navigation and refresh work in the SPA.
    if (std.fs.path.extension(relative).len != 0) return .not_found;

    if (try readAsset(io, res.arena, root, "index.html")) |body| {
        setAssetResponse(res, "index.html", body);
        return .served;
    }

    return .not_found;
}

fn hasIndex(io: Io, allocator: std.mem.Allocator, root: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ root, "index.html" });
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn readAsset(
    io: Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    relative: []const u8,
) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_asset_bytes)) catch |err| {
        const name = @errorName(err);
        if (std.mem.eql(u8, name, "OutOfMemory")) return err;
        if (std.mem.eql(u8, name, "StreamTooLong") or std.mem.eql(u8, name, "FileTooBig")) {
            return error.WebAssetTooLarge;
        }
        return null;
    };
}

fn normalizeRequestPath(path: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] != '/') return null;
    if (std.mem.indexOfAny(u8, path, "%\\\x00") != null) return null;
    if (path.len == 1) return "index.html";

    const relative = path[1..];
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return null;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
    }
    return relative;
}

fn setAssetResponse(res: *httpz.Response, file_name: []const u8, body: []const u8) void {
    const content_type = httpz.ContentType.forFile(file_name);
    res.content_type = if (content_type == .UNKNOWN) .BINARY else content_type;
    res.body = body;
    res.header("X-Content-Type-Options", "nosniff");

    if (std.mem.startsWith(u8, file_name, "assets/")) {
        res.header("Cache-Control", "public, max-age=31536000, immutable");
    } else {
        res.header("Cache-Control", "no-cache");
    }
}

test "web asset paths stay beneath the configured root" {
    try std.testing.expectEqualStrings("index.html", normalizeRequestPath("/").?);
    try std.testing.expectEqualStrings("assets/app.js", normalizeRequestPath("/assets/app.js").?);
    try std.testing.expectEqualStrings("decks/42", normalizeRequestPath("/decks/42").?);

    try std.testing.expect(normalizeRequestPath("") == null);
    try std.testing.expect(normalizeRequestPath("assets/app.js") == null);
    try std.testing.expect(normalizeRequestPath("/../secret") == null);
    try std.testing.expect(normalizeRequestPath("/assets/../secret") == null);
    try std.testing.expect(normalizeRequestPath("/%2e%2e/secret") == null);
    try std.testing.expect(normalizeRequestPath("/assets\\secret") == null);
    try std.testing.expect(normalizeRequestPath("/assets//app.js") == null);
}
