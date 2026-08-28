const std = @import("std");
const httpz = @import("httpz");

const media = @import("media.zig");

const Io = std.Io;

pub const max_upload_bytes: usize = 32 * 1024 * 1024;

const UploadResponse = struct {
    reference: []const u8,
    sha256: []const u8,
    mime: []const u8,
    size: u64,
    original_filename: []const u8,
};

pub fn resolveRoot(init: std.process.Init, allocator: std.mem.Allocator) ![]const u8 {
    const root = if (init.environ_map.get("PLANDALF_MEDIA_ROOT")) |override| blk: {
        if (override.len == 0) return error.InvalidMediaRoot;
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const home = init.environ_map.get("HOME") orelse return error.MissingHomeDirectory;
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/share/plandalf/media", .{home});
    };
    try Io.Dir.cwd().createDirPath(init.io, root);
    return root;
}

fn jsonError(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    try res.json(.{
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

fn isMissing(err: anyerror) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "FileNotFound") or std.mem.eql(u8, name, "PathNotFound");
}

fn validateMime(value: []const u8) !void {
    if (value.len > 255) return error.InvalidMediaMime;
    if (std.mem.trim(u8, value, " \t\r\n").len == 0) return error.InvalidMediaMime;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidMediaMime;
}

fn validateFilename(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 255) return error.InvalidMediaFilename;
    if (std.mem.indexOfAny(u8, trimmed, "/\\") != null) return error.InvalidMediaFilename;
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) return error.InvalidMediaFilename;
    return trimmed;
}

fn setImmutableHeaders(res: *httpz.Response, hash: []const u8, mime: []const u8) ![]const u8 {
    try validateMime(mime);
    const etag = try std.fmt.allocPrint(res.arena, "\"{s}\"", .{hash});
    try res.headerOpts("Content-Type", mime, .{ .dupe_value = true });
    res.header("Cache-Control", "public, max-age=31536000, immutable");
    res.header("ETag", etag);
    res.header("X-Content-Type-Options", "nosniff");
    res.header("Cross-Origin-Resource-Policy", "same-origin");
    res.header("Content-Security-Policy", "sandbox; default-src 'none'");
    return etag;
}

fn uploadBody(req: *httpz.Request, res: *httpz.Response) !?[]const u8 {
    if (req.body_len == 0) {
        try jsonError(res, 400, "empty_media", "Media upload body must not be empty");
        return null;
    }
    if (req.body_len > max_upload_bytes) {
        try jsonError(res, 413, "media_too_large", "Web media uploads are limited to 32 MiB");
        return null;
    }

    if (req.unread_body == 0) {
        return req.body() orelse {
            try jsonError(res, 400, "empty_media", "Media upload body must not be empty");
            return null;
        };
    }

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(res.arena);
    try bytes.ensureTotalCapacity(res.arena, req.body_len);

    var reader = try req.reader(5_000);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try reader.read(&buffer);
        if (count == 0) break;
        if (bytes.items.len + count > max_upload_bytes) {
            try jsonError(res, 413, "media_too_large", "Web media uploads are limited to 32 MiB");
            return null;
        }
        try bytes.appendSlice(res.arena, buffer[0..count]);
    }
    if (bytes.items.len != req.body_len) return error.MediaUploadLengthMismatch;
    return try bytes.toOwnedSlice(res.arena);
}

pub fn upload(
    io: Io,
    media_root: []const u8,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const raw_filename = req.header("x-plandalf-filename") orelse {
        try jsonError(res, 400, "missing_media_filename", "X-Plandalf-Filename header is required");
        return;
    };
    const filename = validateFilename(raw_filename) catch {
        try jsonError(res, 400, "invalid_media_filename", "Media filename must be a simple filename up to 255 bytes");
        return;
    };

    const mime = req.header("content-type") orelse {
        try jsonError(res, 400, "missing_media_mime", "Content-Type header is required");
        return;
    };
    validateMime(mime) catch {
        try jsonError(res, 400, "invalid_media_mime", "Media Content-Type is invalid");
        return;
    };

    const body = try uploadBody(req, res) orelse return;
    const metadata_allocator = std.heap.page_allocator;
    const metadata = try media.addBytes(metadata_allocator, io, media_root, filename, mime, body);
    defer metadata.deinit(metadata_allocator);

    const reference = try media.reference(res.arena, metadata.sha256);
    res.status = 201;
    try res.json(UploadResponse{
        .reference = reference,
        .sha256 = metadata.sha256,
        .mime = metadata.mime,
        .size = metadata.size,
        .original_filename = metadata.original_filename,
    }, .{});
}

pub fn serve(
    io: Io,
    media_root: []const u8,
    req: *httpz.Request,
    res: *httpz.Response,
) !void {
    const hash = req.param("hash") orelse {
        try jsonError(res, 400, "invalid_media_hash", "Missing media SHA-256 hash");
        return;
    };
    if (!media.isValidHashHex(hash)) {
        try jsonError(res, 400, "invalid_media_hash", "Media hash must be 64 lowercase hexadecimal characters");
        return;
    }

    const metadata_allocator = std.heap.page_allocator;
    const metadata = media.loadMetadata(metadata_allocator, io, media_root, hash) catch |err| {
        if (isMissing(err)) {
            try jsonError(res, 404, "media_not_found", "Media not found");
            return;
        }
        return err;
    };
    defer metadata.deinit(metadata_allocator);

    const etag = try setImmutableHeaders(res, hash, metadata.mime);
    if (req.header("if-none-match")) |candidate| {
        if (std.mem.eql(u8, candidate, etag)) {
            res.status = 304;
            res.body = "";
            return;
        }
    }

    const blob = media.loadBlob(res.arena, io, media_root, hash) catch |err| {
        if (isMissing(err)) {
            try jsonError(res, 404, "media_not_found", "Media not found");
            return;
        }
        return err;
    };
    if (metadata.size != blob.len) return error.MediaSizeMismatch;
    res.body = blob;
}

test "media MIME header validation rejects line breaks" {
    try validateMime("image/png");
    try std.testing.expectError(error.InvalidMediaMime, validateMime("image/png\r\nX-Evil: yes"));
    try std.testing.expectError(error.InvalidMediaMime, validateMime(""));
}

test "Web upload filenames are simple bounded basenames" {
    try std.testing.expectEqualStrings("diagram.png", try validateFilename(" diagram.png "));
    try std.testing.expectError(error.InvalidMediaFilename, validateFilename("../diagram.png"));
    try std.testing.expectError(error.InvalidMediaFilename, validateFilename("folder\\diagram.png"));
    try std.testing.expectError(error.InvalidMediaFilename, validateFilename(""));
}
