const std = @import("std");
const Io = std.Io;

// Keep the established media reference URI stable. This is embedded in card
// content and is independent from the executable/product name.
pub const reference_prefix = "deez-media://sha256:";
pub const max_media_bytes: usize = 256 * 1024 * 1024;

pub const Metadata = struct {
    sha256: []u8,
    mime: []u8,
    size: u64,
    original_filename: []u8,

    pub fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256);
        allocator.free(self.mime);
        allocator.free(self.original_filename);
    }
};

const MetadataRecord = struct {
    sha256: []const u8,
    mime: []const u8,
    size: u64,
    original_filename: []const u8,
};

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        hex[index * 2] = std.fmt.hex_charset[byte >> 4];
        hex[index * 2 + 1] = std.fmt.hex_charset[byte & 0x0f];
    }
    return hex;
}

pub fn isValidHashHex(hash: []const u8) bool {
    if (hash.len != 64) return false;
    for (hash) |byte| {
        if (!std.ascii.isHex(byte) or (byte >= 'A' and byte <= 'F')) return false;
    }
    return true;
}

pub fn reference(allocator: std.mem.Allocator, hash: []const u8) ![]u8 {
    if (!isValidHashHex(hash)) return error.InvalidMediaHash;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ reference_prefix, hash });
}

pub fn parseReference(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, reference_prefix)) return null;
    const hash = value[reference_prefix.len..];
    if (!isValidHashHex(hash)) return null;
    return hash;
}

pub fn mimeForFilename(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, ".mp3")) return "audio/mpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".m4a")) return "audio/mp4";
    if (std.ascii.eqlIgnoreCase(ext, ".wav")) return "audio/wav";
    if (std.ascii.eqlIgnoreCase(ext, ".ogg")) return "audio/ogg";
    if (std.ascii.eqlIgnoreCase(ext, ".mp4")) return "video/mp4";
    if (std.ascii.eqlIgnoreCase(ext, ".webm")) return "video/webm";
    return "application/octet-stream";
}

fn prefixDirPath(allocator: std.mem.Allocator, media_root: []const u8, hash: []const u8) ![]u8 {
    if (!isValidHashHex(hash)) return error.InvalidMediaHash;
    return std.fmt.allocPrint(allocator, "{s}/sha256/{s}", .{ media_root, hash[0..2] });
}

pub fn blobPath(allocator: std.mem.Allocator, media_root: []const u8, hash: []const u8) ![]u8 {
    if (!isValidHashHex(hash)) return error.InvalidMediaHash;
    return std.fmt.allocPrint(allocator, "{s}/sha256/{s}/{s}", .{ media_root, hash[0..2], hash });
}

pub fn metadataPath(allocator: std.mem.Allocator, media_root: []const u8, hash: []const u8) ![]u8 {
    const blob = try blobPath(allocator, media_root, hash);
    defer allocator.free(blob);
    return std.fmt.allocPrint(allocator, "{s}.json", .{blob});
}

fn writeBytes(io: Io, path: []const u8, bytes: []const u8) !void {
    const file = if (std.fs.path.isAbsolute(path))
        try Io.Dir.createFileAbsolute(io, path, .{ .truncate = true })
    else
        try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

pub fn addBytes(
    allocator: std.mem.Allocator,
    io: Io,
    media_root: []const u8,
    original_filename: []const u8,
    mime: []const u8,
    bytes: []const u8,
) !Metadata {
    if (bytes.len > max_media_bytes) return error.MediaTooLarge;
    if (std.mem.trim(u8, original_filename, " \t\r\n").len == 0) return error.InvalidMediaFilename;
    if (std.mem.trim(u8, mime, " \t\r\n").len == 0) return error.InvalidMediaMime;

    const hash_array = sha256Hex(bytes);
    const hash = hash_array[0..];
    const dir_path = try prefixDirPath(allocator, media_root, hash);
    defer allocator.free(dir_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);

    const blob_path = try blobPath(allocator, media_root, hash);
    defer allocator.free(blob_path);
    try writeBytes(io, blob_path, bytes);

    const filename = std.fs.path.basename(original_filename);
    const record: MetadataRecord = .{
        .sha256 = hash,
        .mime = mime,
        .size = bytes.len,
        .original_filename = filename,
    };
    var json: Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.json.Stringify.value(record, .{}, &json.writer);

    const metadata_path = try metadataPath(allocator, media_root, hash);
    defer allocator.free(metadata_path);
    try writeBytes(io, metadata_path, json.written());

    return .{
        .sha256 = try allocator.dupe(u8, hash),
        .mime = try allocator.dupe(u8, mime),
        .size = bytes.len,
        .original_filename = try allocator.dupe(u8, filename),
    };
}

pub fn addFile(
    allocator: std.mem.Allocator,
    io: Io,
    media_root: []const u8,
    source_path: []const u8,
) !Metadata {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, source_path, allocator, .limited(max_media_bytes));
    defer allocator.free(bytes);
    return addBytes(allocator, io, media_root, source_path, mimeForFilename(source_path), bytes);
}

pub fn loadMetadata(
    allocator: std.mem.Allocator,
    io: Io,
    media_root: []const u8,
    hash: []const u8,
) !Metadata {
    const path = try metadataPath(allocator, media_root, hash);
    defer allocator.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(MetadataRecord, allocator, bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.sha256, hash)) return error.MediaMetadataHashMismatch;
    if (!isValidHashHex(parsed.value.sha256)) return error.InvalidMediaHash;
    return .{
        .sha256 = try allocator.dupe(u8, parsed.value.sha256),
        .mime = try allocator.dupe(u8, parsed.value.mime),
        .size = parsed.value.size,
        .original_filename = try allocator.dupe(u8, parsed.value.original_filename),
    };
}

pub fn loadBlob(
    allocator: std.mem.Allocator,
    io: Io,
    media_root: []const u8,
    hash: []const u8,
) ![]u8 {
    const path = try blobPath(allocator, media_root, hash);
    defer allocator.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_media_bytes));
    const actual = sha256Hex(bytes);
    if (!std.mem.eql(u8, &actual, hash)) {
        allocator.free(bytes);
        return error.MediaHashMismatch;
    }
    return bytes;
}

pub fn storeImported(
    allocator: std.mem.Allocator,
    io: Io,
    media_root: []const u8,
    expected_hash: []const u8,
    mime: []const u8,
    original_filename: []const u8,
    bytes: []const u8,
) !void {
    if (!isValidHashHex(expected_hash)) return error.InvalidMediaHash;
    const actual = sha256Hex(bytes);
    if (!std.mem.eql(u8, &actual, expected_hash)) return error.MediaHashMismatch;
    const metadata = try addBytes(allocator, io, media_root, original_filename, mime, bytes);
    defer metadata.deinit(allocator);
    if (!std.mem.eql(u8, metadata.sha256, expected_hash)) return error.MediaHashMismatch;
}

test "SHA-256 media identity and references are stable" {
    const hash = sha256Hex("hello");
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", &hash);
    const uri = try reference(std.testing.allocator, &hash);
    defer std.testing.allocator.free(uri);
    try std.testing.expectEqualStrings(&hash, parseReference(uri).?);
}

test "MIME type covers common rich-media extensions" {
    try std.testing.expectEqualStrings("image/png", mimeForFilename("diagram.PNG"));
    try std.testing.expectEqualStrings("audio/mpeg", mimeForFilename("answer.mp3"));
    try std.testing.expectEqualStrings("video/mp4", mimeForFilename("clip.mp4"));
}
