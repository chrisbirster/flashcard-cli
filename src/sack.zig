const std = @import("std");
const Io = std.Io;
const media = @import("media.zig");
const nut = @import("nut.zig");
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const format_name = "deez.sack";
pub const format_version: u32 = 1;
pub const max_sack_bytes: usize = 512 * 1024 * 1024;

const local_file_signature: u32 = 0x04034b50;
const central_file_signature: u32 = 0x02014b50;
const end_signature: u32 = 0x06054b50;

const ZipEntry = struct {
    name: []const u8,
    data: []const u8,
};

const ParsedEntry = struct {
    name: []const u8,
    data: []const u8,
};

const CentralEntry = struct {
    name: []const u8,
    crc: u32,
    size: u32,
    local_offset: u32,
};

const ManifestMedia = struct {
    sha256: []const u8,
    path: []const u8,
    mime: []const u8,
    size: u64,
    original_filename: []const u8,
};

const Manifest = struct {
    format: []const u8,
    version: u32,
    deck: []const u8,
    media: []const ManifestMedia,
};

pub const ImportResult = struct {
    deck_id: u64,
    card_count: usize,
    media_count: usize,
};

fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            crc = if ((crc & 1) != 0) (crc >> 1) ^ 0xedb88320 else crc >> 1;
        }
    }
    return ~crc;
}

fn appendByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) !void {
    try out.append(allocator, byte);
}

fn appendBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    for (bytes) |byte| try appendByte(out, allocator, byte);
}

fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try appendByte(out, allocator, @intCast(value & 0xff));
    try appendByte(out, allocator, @intCast((value >> 8) & 0xff));
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try appendByte(out, allocator, @intCast(value & 0xff));
    try appendByte(out, allocator, @intCast((value >> 8) & 0xff));
    try appendByte(out, allocator, @intCast((value >> 16) & 0xff));
    try appendByte(out, allocator, @intCast((value >> 24) & 0xff));
}

fn readU16(bytes: []const u8, index: usize) !u16 {
    if (index + 2 > bytes.len) return error.TruncatedSackArchive;
    return @as(u16, bytes[index]) | (@as(u16, bytes[index + 1]) << 8);
}

fn readU32(bytes: []const u8, index: usize) !u32 {
    if (index + 4 > bytes.len) return error.TruncatedSackArchive;
    return @as(u32, bytes[index]) |
        (@as(u32, bytes[index + 1]) << 8) |
        (@as(u32, bytes[index + 2]) << 16) |
        (@as(u32, bytes[index + 3]) << 24);
}

fn validateEntryPath(name: []const u8) !void {
    if (name.len == 0 or name[0] == '/') return error.UnsafeSackPath;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.UnsafeSackPath;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeSackPath;
    }
}

fn buildZip(allocator: std.mem.Allocator, entries: []const ZipEntry) ![]u8 {
    if (entries.len > std.math.maxInt(u16)) return error.TooManySackEntries;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var central: std.ArrayList(CentralEntry) = .empty;
    defer central.deinit(allocator);

    for (entries) |entry| {
        try validateEntryPath(entry.name);
        if (entry.name.len > std.math.maxInt(u16)) return error.SackEntryNameTooLong;
        if (entry.data.len > std.math.maxInt(u32)) return error.SackEntryTooLarge;
        if (out.items.len > std.math.maxInt(u32)) return error.SackTooLarge;
        for (central.items) |existing| {
            if (std.mem.eql(u8, existing.name, entry.name)) return error.DuplicateSackEntry;
        }

        const crc = crc32(entry.data);
        const size: u32 = @intCast(entry.data.len);
        const offset: u32 = @intCast(out.items.len);
        const name_len: u16 = @intCast(entry.name.len);

        try appendU32(&out, allocator, local_file_signature);
        try appendU16(&out, allocator, 20);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU32(&out, allocator, crc);
        try appendU32(&out, allocator, size);
        try appendU32(&out, allocator, size);
        try appendU16(&out, allocator, name_len);
        try appendU16(&out, allocator, 0);
        try appendBytes(&out, allocator, entry.name);
        try appendBytes(&out, allocator, entry.data);

        try central.append(allocator, .{
            .name = entry.name,
            .crc = crc,
            .size = size,
            .local_offset = offset,
        });
    }

    if (out.items.len > std.math.maxInt(u32)) return error.SackTooLarge;
    const central_offset: u32 = @intCast(out.items.len);
    for (central.items) |entry| {
        const name_len: u16 = @intCast(entry.name.len);
        try appendU32(&out, allocator, central_file_signature);
        try appendU16(&out, allocator, 20);
        try appendU16(&out, allocator, 20);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU32(&out, allocator, entry.crc);
        try appendU32(&out, allocator, entry.size);
        try appendU32(&out, allocator, entry.size);
        try appendU16(&out, allocator, name_len);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU16(&out, allocator, 0);
        try appendU32(&out, allocator, 0);
        try appendU32(&out, allocator, entry.local_offset);
        try appendBytes(&out, allocator, entry.name);
    }
    if (out.items.len > std.math.maxInt(u32)) return error.SackTooLarge;
    const central_size: u32 = @intCast(out.items.len - central_offset);
    const count: u16 = @intCast(central.items.len);

    try appendU32(&out, allocator, end_signature);
    try appendU16(&out, allocator, 0);
    try appendU16(&out, allocator, 0);
    try appendU16(&out, allocator, count);
    try appendU16(&out, allocator, count);
    try appendU32(&out, allocator, central_size);
    try appendU32(&out, allocator, central_offset);
    try appendU16(&out, allocator, 0);

    return out.toOwnedSlice(allocator);
}

fn parseZip(allocator: std.mem.Allocator, bytes: []const u8) ![]ParsedEntry {
    var entries: std.ArrayList(ParsedEntry) = .empty;
    errdefer entries.deinit(allocator);
    var index: usize = 0;

    while (index + 4 <= bytes.len) {
        const signature = try readU32(bytes, index);
        if (signature == central_file_signature or signature == end_signature) break;
        if (signature != local_file_signature) return error.InvalidSackArchive;
        if (index + 30 > bytes.len) return error.TruncatedSackArchive;

        const flags = try readU16(bytes, index + 6);
        const method = try readU16(bytes, index + 8);
        const expected_crc = try readU32(bytes, index + 14);
        const compressed_size = try readU32(bytes, index + 18);
        const uncompressed_size = try readU32(bytes, index + 22);
        const name_len = try readU16(bytes, index + 26);
        const extra_len = try readU16(bytes, index + 28);
        if ((flags & 0x08) != 0) return error.UnsupportedSackDataDescriptor;
        if (method != 0) return error.UnsupportedSackCompression;
        if (compressed_size != uncompressed_size) return error.InvalidSackArchive;

        const name_start = index + 30;
        const name_end = name_start + name_len;
        const data_start = name_end + extra_len;
        const data_end = data_start + compressed_size;
        if (data_end > bytes.len) return error.TruncatedSackArchive;
        const name = bytes[name_start..name_end];
        const data = bytes[data_start..data_end];
        try validateEntryPath(name);
        if (crc32(data) != expected_crc) return error.SackCrcMismatch;
        for (entries.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateSackEntry;
        }
        try entries.append(allocator, .{ .name = name, .data = data });
        index = data_end;
    }

    if (entries.items.len == 0) return error.EmptySackArchive;
    return entries.toOwnedSlice(allocator);
}

fn findEntry(entries: []const ParsedEntry, name: []const u8) ?ParsedEntry {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

fn containsHash(hashes: []const []u8, candidate: []const u8) bool {
    for (hashes) |hash| if (std.mem.eql(u8, hash, candidate)) return true;
    return false;
}

fn collectHashes(allocator: std.mem.Allocator, bytes: []const u8) ![][]u8 {
    var hashes: std.ArrayList([]u8) = .empty;
    errdefer {
        for (hashes.items) |hash| allocator.free(hash);
        hashes.deinit(allocator);
    }
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, cursor, media.reference_prefix)) |position| {
        const start = position + media.reference_prefix.len;
        if (start + 64 <= bytes.len) {
            const candidate = bytes[start .. start + 64];
            if (media.isValidHashHex(candidate) and !containsHash(hashes.items, candidate)) {
                try hashes.append(allocator, try allocator.dupe(u8, candidate));
            }
        }
        cursor = start;
        if (cursor >= bytes.len) break;
    }
    return hashes.toOwnedSlice(allocator);
}

fn mediaPath(allocator: std.mem.Allocator, hash: []const u8) ![]u8 {
    if (!media.isValidHashHex(hash)) return error.InvalidMediaHash;
    return std.fmt.allocPrint(allocator, "media/sha256/{s}", .{hash});
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    const file = if (std.fs.path.isAbsolute(path))
        try Io.Dir.createFileAbsolute(io, path, .{ .truncate = true })
    else
        try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

pub fn exportFile(
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    deck_id: u64,
    media_root: []const u8,
    output_path: []const u8,
) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var deck_writer: Io.Writer.Allocating = .init(a);
    try nut.exportDeck(a, store, deck_id, &deck_writer.writer);
    const deck_bytes = deck_writer.written();
    const hashes = try collectHashes(a, deck_bytes);

    var manifest_media: std.ArrayList(ManifestMedia) = .empty;
    var media_entries: std.ArrayList(ZipEntry) = .empty;
    for (hashes) |hash| {
        const metadata = try media.loadMetadata(a, io, media_root, hash);
        const blob = try media.loadBlob(a, io, media_root, hash);
        if (metadata.size != blob.len) return error.MediaSizeMismatch;
        const path = try mediaPath(a, hash);
        try manifest_media.append(a, .{
            .sha256 = metadata.sha256,
            .path = path,
            .mime = metadata.mime,
            .size = metadata.size,
            .original_filename = metadata.original_filename,
        });
        try media_entries.append(a, .{ .name = path, .data = blob });
    }

    const manifest_value: Manifest = .{
        .format = format_name,
        .version = format_version,
        .deck = "deck.nut",
        .media = manifest_media.items,
    };
    var manifest_writer: Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(manifest_value, .{}, &manifest_writer.writer);

    var entries: std.ArrayList(ZipEntry) = .empty;
    try entries.append(a, .{ .name = "manifest.json", .data = manifest_writer.written() });
    try entries.append(a, .{ .name = "deck.nut", .data = deck_bytes });
    for (media_entries.items) |entry| try entries.append(a, entry);

    const archive = try buildZip(a, entries.items);
    try writeFile(io, output_path, archive);
    return hashes.len;
}

pub fn importFile(
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    media_root: []const u8,
    input_path: []const u8,
    created_at_ms: time.TimestampMs,
) !ImportResult {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(max_sack_bytes));
    defer allocator.free(bytes);
    const entries = try parseZip(allocator, bytes);
    defer allocator.free(entries);

    const manifest_entry = findEntry(entries, "manifest.json") orelse return error.MissingSackManifest;
    const deck_entry = findEntry(entries, "deck.nut") orelse return error.MissingSackDeck;
    var parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_entry.data, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.format, format_name)) return error.UnsupportedSackFormat;
    if (parsed.value.version != format_version) return error.UnsupportedSackVersion;
    if (!std.mem.eql(u8, parsed.value.deck, "deck.nut")) return error.InvalidSackDeckPath;

    const referenced = try collectHashes(allocator, deck_entry.data);
    defer {
        for (referenced) |hash| allocator.free(hash);
        allocator.free(referenced);
    }
    if (referenced.len != parsed.value.media.len) return error.SackMediaManifestMismatch;

    for (parsed.value.media) |item| {
        if (!media.isValidHashHex(item.sha256)) return error.InvalidMediaHash;
        if (item.size > media.max_media_bytes) return error.MediaTooLarge;
        if (!containsHash(referenced, item.sha256)) return error.SackMediaManifestMismatch;
        const expected_path = try mediaPath(allocator, item.sha256);
        defer allocator.free(expected_path);
        if (!std.mem.eql(u8, item.path, expected_path)) return error.UnsafeSackPath;
        const media_entry = findEntry(entries, item.path) orelse return error.MissingSackMedia;
        if (media_entry.data.len != item.size) return error.MediaSizeMismatch;
        const actual_hash = media.sha256Hex(media_entry.data);
        if (!std.mem.eql(u8, &actual_hash, item.sha256)) return error.MediaHashMismatch;
    }

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "manifest.json") or std.mem.eql(u8, entry.name, "deck.nut")) continue;
        var known = false;
        for (parsed.value.media) |item| {
            if (std.mem.eql(u8, entry.name, item.path)) {
                known = true;
                break;
            }
        }
        if (!known) return error.UnexpectedSackEntry;
    }

    const imported = try nut.importSlice(allocator, store, deck_entry.data, created_at_ms);
    errdefer store.deleteDeck(imported.deck_id) catch {};
    for (parsed.value.media) |item| {
        const entry = findEntry(entries, item.path).?;
        try media.storeImported(allocator, io, media_root, item.sha256, item.mime, item.original_filename, entry.data);
    }
    return .{
        .deck_id = imported.deck_id,
        .card_count = imported.card_count,
        .media_count = parsed.value.media.len,
    };
}

test "stored ZIP round trip preserves sack entries" {
    const source = [_]ZipEntry{
        .{ .name = "manifest.json", .data = "{}" },
        .{ .name = "deck.nut", .data = "deck" },
        .{ .name = "media/sha256/abc", .data = "blob" },
    };
    const archive = try buildZip(std.testing.allocator, &source);
    defer std.testing.allocator.free(archive);
    const parsed = try parseZip(std.testing.allocator, archive);
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("deck", findEntry(parsed, "deck.nut").?.data);
}

test "sack archive rejects path traversal" {
    const source = [_]ZipEntry{.{ .name = "../evil", .data = "nope" }};
    try std.testing.expectError(error.UnsafeSackPath, buildZip(std.testing.allocator, &source));
}

test "sack archive verifies CRC" {
    const source = [_]ZipEntry{.{ .name = "deck.nut", .data = "abc" }};
    const archive = try buildZip(std.testing.allocator, &source);
    defer std.testing.allocator.free(archive);
    archive[30 + "deck.nut".len] ^= 1;
    try std.testing.expectError(
        error.SackCrcMismatch,
        parseZip(std.testing.allocator, archive),
    );
}
