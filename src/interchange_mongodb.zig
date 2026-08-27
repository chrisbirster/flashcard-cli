const std = @import("std");
const bongo = @import("bongo");
const storage = @import("storage/root.zig");
const study_mod = @import("study.zig");
const validate_mod = @import("interchange_import.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const hex = "0123456789abcdef";

pub const DryRunReport = struct {
    parameter_sets: usize = 0,
    groups: usize = 0,
    decks: usize = 0,
    cards: usize = 0,
    reviews: usize = 0,
    unsupported_records: usize = 0,
};

pub const ExportOptions = struct {
    deck_id: ?u64 = null,
};

const ParameterRecord = struct {
    id: [32]u8,
    algorithm_major: i32,
    implementation_major: i32,
    implementation_minor: i32,
    implementation_patch: i32,
    source: []u8,
    weights: [35]f64 = [_]f64{0} ** 35,
    weight_seen: [35]bool = [_]bool{false} ** 35,
    desired_retention: f64,
    minimum_interval_days: f64,
    maximum_interval_days: f64,
    created_at_ms: i64,

    fn deinit(self: ParameterRecord, allocator: Allocator) void {
        allocator.free(self.source);
    }
};

const DefaultRecord = struct {
    algorithm_major: i32,
    parameter_set_id: ?[32]u8,
};

const GroupRecord = struct {
    id: i64,
    name: []u8,
    algorithm_major: ?i32,
    parameter_set_id: ?[32]u8,
    created_at_ms: i64,

    fn deinit(self: GroupRecord, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const DeckRecord = struct {
    id: i64,
    name: []u8,
    group_id: ?i64,
    algorithm_major: ?i32,
    parameter_set_id: ?[32]u8,
    created_at_ms: i64,

    fn deinit(self: DeckRecord, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

const CardRecord = struct {
    id: i64,
    deck_id: i64,
    question: []u8,
    answer: []u8,
    created_at_ms: i64,

    fn deinit(self: CardRecord, allocator: Allocator) void {
        allocator.free(self.question);
        allocator.free(self.answer);
    }
};

const ReviewRecord = struct {
    id: i64,
    card_id: i64,
    rating: i32,
    reviewed_at_ms: i64,
    algorithm_major: i32,
    implementation_major: i32,
    implementation_minor: i32,
    implementation_patch: i32,
    parameter_set_id: [32]u8,
    scheduled_at_ms: i64,
};

const Archive = struct {
    parameters: std.ArrayList(ParameterRecord) = .empty,
    default: ?DefaultRecord = null,
    groups: std.ArrayList(GroupRecord) = .empty,
    decks: std.ArrayList(DeckRecord) = .empty,
    cards: std.ArrayList(CardRecord) = .empty,
    reviews: std.ArrayList(ReviewRecord) = .empty,

    fn deinit(self: *Archive, allocator: Allocator) void {
        for (self.parameters.items) |item| item.deinit(allocator);
        self.parameters.deinit(allocator);
        for (self.groups.items) |item| item.deinit(allocator);
        self.groups.deinit(allocator);
        for (self.decks.items) |item| item.deinit(allocator);
        self.decks.deinit(allocator);
        for (self.cards.items) |item| item.deinit(allocator);
        self.cards.deinit(allocator);
        self.reviews.deinit(allocator);
        self.* = undefined;
    }
};

fn mongoStore(store: *storage.Store) !*storage.MongoStore {
    return switch (store.*) {
        .mongodb => |*mongo| mongo,
        .sqlite => error.MongoBackendRequired,
    };
}

fn writeHex(writer: *Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| {
        const pair = [2]u8{ hex[byte >> 4], hex[byte & 0x0f] };
        try writer.writeAll(&pair);
    }
}

fn nibble(byte: u8) !u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn decodeHex(allocator: Allocator, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.InvalidHex;
    const result = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(result);
    for (result, 0..) |*byte, index| {
        byte.* = (try nibble(text[index * 2])) << 4 | try nibble(text[index * 2 + 1]);
    }
    return result;
}

fn decodeId(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidParameterSetId;
    var result: [32]u8 = undefined;
    for (&result, 0..) |*byte, index| {
        byte.* = (try nibble(text[index * 2])) << 4 | try nibble(text[index * 2 + 1]);
    }
    return result;
}

fn idBinary(id: *const [32]u8) bongo.bson.Binary {
    return .{ .subtype = .generic, .data = id[0..] };
}

fn writeOptionalI64(writer: *Io.Writer, value: ?i64) !void {
    if (value) |number| try writer.print("{d}", .{number}) else try writer.writeAll("-");
}

fn writeOptionalId(writer: *Io.Writer, value: ?[32]u8) !void {
    if (value) |id| try writeHex(writer, id[0..]) else try writer.writeAll("-");
}

fn valueI64(value: bongo.bson.Value) ?i64 {
    return switch (value) {
        .int32 => |number| number,
        .int64 => |number| number,
        else => null,
    };
}

fn valueDouble(value: bongo.bson.Value) ?f64 {
    return switch (value) {
        .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        .int64 => |number| @floatFromInt(number),
        else => null,
    };
}

fn requiredValue(document: []const u8, field_name: []const u8) !bongo.bson.Value {
    return (try bongo.bson.Reader.get(document, field_name)) orelse error.MissingField;
}

fn requiredI64(document: []const u8, field_name: []const u8) !i64 {
    return valueI64(try requiredValue(document, field_name)) orelse error.InvalidField;
}

fn optionalI64(document: []const u8, field_name: []const u8) !?i64 {
    const value = (try bongo.bson.Reader.get(document, field_name)) orelse return null;
    if (value == .null_value) return null;
    return valueI64(value) orelse error.InvalidField;
}

fn requiredDouble(document: []const u8, field_name: []const u8) !f64 {
    return valueDouble(try requiredValue(document, field_name)) orelse error.InvalidField;
}

fn requiredString(document: []const u8, field_name: []const u8) ![]const u8 {
    return switch (try requiredValue(document, field_name)) {
        .string => |text| text,
        else => error.InvalidField,
    };
}

fn optionalIdFromBson(document: []const u8, field_name: []const u8) !?[32]u8 {
    const value = (try bongo.bson.Reader.get(document, field_name)) orelse return null;
    if (value == .null_value) return null;
    const binary = switch (value) {
        .binary => |item| item,
        else => return error.InvalidParameterSetId,
    };
    if (binary.data.len != 32) return error.InvalidParameterSetId;
    var id: [32]u8 = undefined;
    @memcpy(id[0..], binary.data);
    return id;
}

fn requiredIdFromBson(document: []const u8, field_name: []const u8) ![32]u8 {
    return (try optionalIdFromBson(document, field_name)) orelse error.InvalidParameterSetId;
}

fn exportParameters(mongo: *storage.MongoStore, writer: *Io.Writer) !void {
    var cursor = try mongo.client.find(mongo.client.databaseName(), "parameter_sets", .{}, .{ .sort = .{ ._id = @as(i32, 1) } });
    defer cursor.deinit();
    while (try cursor.next()) |document| {
        const id = try requiredIdFromBson(document, "_id");
        try writer.writeAll("PARAM\t");
        try writeHex(writer, id[0..]);
        try writer.print("\tfsrs\t{d}\t{d}\t{d}\t{d}\t", .{
            try requiredI64(document, "algorithm_major"),
            try requiredI64(document, "implementation_major"),
            try requiredI64(document, "implementation_minor"),
            try requiredI64(document, "implementation_patch"),
        });
        try writeHex(writer, try requiredString(document, "source"));
        try writer.print("\t{d:.17}\t{d:.17}\t{d:.17}\t{d}\n", .{
            try requiredDouble(document, "desired_retention"),
            try requiredDouble(document, "minimum_interval_days"),
            try requiredDouble(document, "maximum_interval_days"),
            try requiredI64(document, "created_at_ms"),
        });
    }
}

fn exportWeights(mongo: *storage.MongoStore, writer: *Io.Writer) !void {
    var cursor = try mongo.client.find(mongo.client.databaseName(), "parameter_sets", .{}, .{ .sort = .{ ._id = @as(i32, 1) } });
    defer cursor.deinit();
    while (try cursor.next()) |document| {
        const id = try requiredIdFromBson(document, "_id");
        const weights_value = try requiredValue(document, "weights");
        const weights = switch (weights_value) {
            .array => |bytes| bytes,
            else => return error.InvalidParameterWeights,
        };
        var reader = try bongo.bson.Reader.init(weights);
        var index: usize = 0;
        while (try reader.next()) |element| : (index += 1) {
            const weight = valueDouble(element.value) orelse return error.InvalidParameterWeights;
            try writer.writeAll("WEIGHT\t");
            try writeHex(writer, id[0..]);
            try writer.print("\t{d}\t{d:.17}\n", .{ index, weight });
        }
        if (index != 35) return error.InvalidParameterWeights;
    }
}

fn exportDefault(mongo: *storage.MongoStore, writer: *Io.Writer) !void {
    var owned = (try mongo.client.findOne(mongo.client.databaseName(), "metadata", .{ ._id = "scheduler_defaults" })) orelse return error.MissingSchedulerDefault;
    defer owned.deinit();
    try writer.print("DEFAULT\tfsrs\t{d}\t", .{try requiredI64(owned.bytes, "algorithm_major")});
    try writeOptionalId(writer, try optionalIdFromBson(owned.bytes, "parameter_set_id"));
    try writer.writeAll("\n");
}

fn exportGroups(mongo: *storage.MongoStore, writer: *Io.Writer) !void {
    var cursor = try mongo.client.find(mongo.client.databaseName(), "deck_groups", .{}, .{ .sort = .{ ._id = @as(i32, 1) } });
    defer cursor.deinit();
    while (try cursor.next()) |document| {
        try writer.print("GROUP\t{d}\t", .{try requiredI64(document, "_id")});
        try writeHex(writer, try requiredString(document, "name"));
        const major = try optionalI64(document, "algorithm_major");
        if (major) |value| try writer.print("\tfsrs\t{d}", .{value}) else try writer.writeAll("\t-\t-");
        try writer.writeAll("\t");
        try writeOptionalId(writer, try optionalIdFromBson(document, "parameter_set_id"));
        try writer.print("\t{d}\n", .{try requiredI64(document, "created_at_ms")});
    }
}

fn exportDecks(mongo: *storage.MongoStore, writer: *Io.Writer, options: ExportOptions) !void {
    var cursor = if (options.deck_id) |deck_id|
        try mongo.client.find(mongo.client.databaseName(), "decks", .{ ._id = std.math.cast(i64, deck_id) orelse return error.IdOutOfRange }, .{ .sort = .{ ._id = @as(i32, 1) } })
    else
        try mongo.client.find(mongo.client.databaseName(), "decks", .{}, .{ .sort = .{ ._id = @as(i32, 1) } });
    defer cursor.deinit();
    while (try cursor.next()) |document| {
        try writer.print("DECK\t{d}\t", .{try requiredI64(document, "_id")});
        try writeHex(writer, try requiredString(document, "name"));
        try writer.writeAll("\t");
        try writeOptionalI64(writer, try optionalI64(document, "group_id"));
        const major = try optionalI64(document, "algorithm_major");
        if (major) |value| try writer.print("\tfsrs\t{d}", .{value}) else try writer.writeAll("\t-\t-");
        try writer.writeAll("\t");
        try writeOptionalId(writer, try optionalIdFromBson(document, "parameter_set_id"));
        try writer.print("\t{d}\n", .{try requiredI64(document, "created_at_ms")});
    }
}

fn exportCards(mongo: *storage.MongoStore, writer: *Io.Writer, options: ExportOptions) !void {
    var cursor = if (options.deck_id) |deck_id|
        try mongo.client.find(mongo.client.databaseName(), "cards", .{ .deck_id = std.math.cast(i64, deck_id) orelse return error.IdOutOfRange }, .{ .sort = .{ ._id = @as(i32, 1) } })
    else
        try mongo.client.find(mongo.client.databaseName(), "cards", .{}, .{ .sort = .{ ._id = @as(i32, 1) } });
    defer cursor.deinit();
    while (try cursor.next()) |document| {
        try writer.print("CARD\t{d}\t{d}\t", .{ try requiredI64(document, "_id"), try requiredI64(document, "deck_id") });
        try writeHex(writer, try requiredString(document, "question"));
        try writer.writeAll("\t");
        try writeHex(writer, try requiredString(document, "answer"));
        try writer.print("\t{d}\n", .{try requiredI64(document, "created_at_ms")});
    }
}

fn exportReviews(mongo: *storage.MongoStore, writer: *Io.Writer, options: ExportOptions) !void {
    var cursor = try mongo.client.find(mongo.client.databaseName(), "reviews", .{}, .{ .sort = .{ ._id = @as(i32, 1) } });
    defer cursor.deinit();
    while (try cursor.next()) |document| {
        const card_id = try requiredI64(document, "card_id");
        if (options.deck_id) |wanted_deck| {
            var card = (try mongo.client.findOne(mongo.client.databaseName(), "cards", .{ ._id = card_id })) orelse continue;
            defer card.deinit();
            const wanted = std.math.cast(i64, wanted_deck) orelse return error.IdOutOfRange;
            if (try requiredI64(card.bytes, "deck_id") != wanted) continue;
        }
        try writer.print("REVIEW\t{d}\t{d}\t{d}\t{d}\tfsrs\t{d}\t{d}\t{d}\t{d}\t", .{
            try requiredI64(document, "_id"),
            card_id,
            try requiredI64(document, "rating"),
            try requiredI64(document, "reviewed_at_ms"),
            try requiredI64(document, "algorithm_major"),
            try requiredI64(document, "implementation_major"),
            try requiredI64(document, "implementation_minor"),
            try requiredI64(document, "implementation_patch"),
        });
        try writeOptionalId(writer, try optionalIdFromBson(document, "parameter_set_id"));
        try writer.writeAll("\t");
        try writeOptionalI64(writer, try optionalI64(document, "scheduled_at_ms"));
        try writer.writeAll("\n");
    }
}

pub fn exportArchive(store: *storage.Store, writer: *Io.Writer, options: ExportOptions) !void {
    const mongo = try mongoStore(store);
    try writer.writeAll("DEEZ\t1\n");
    try exportParameters(mongo, writer);
    try exportWeights(mongo, writer);
    try exportDefault(mongo, writer);
    try exportGroups(mongo, writer);
    try exportDecks(mongo, writer, options);
    try exportCards(mongo, writer, options);
    try exportReviews(mongo, writer, options);
}

fn nextField(fields: *std.mem.SplitIterator(u8, .scalar)) ![]const u8 {
    return fields.next() orelse error.InvalidFieldCount;
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn parseI64(text: []const u8) !i64 {
    return std.fmt.parseInt(i64, text, 10) catch return error.InvalidInteger;
}

fn parseI32(text: []const u8) !i32 {
    return std.fmt.parseInt(i32, text, 10) catch return error.InvalidInteger;
}

fn parseF64(text: []const u8) !f64 {
    const value = std.fmt.parseFloat(f64, text) catch return error.InvalidFloat;
    if (!std.math.isFinite(value)) return error.InvalidFloat;
    return value;
}

fn optionalI64Text(text: []const u8) !?i64 {
    if (std.mem.eql(u8, text, "-")) return null;
    return try parseI64(text);
}

fn optionalI32Text(text: []const u8) !?i32 {
    if (std.mem.eql(u8, text, "-")) return null;
    return try parseI32(text);
}

fn optionalIdText(text: []const u8) !?[32]u8 {
    if (std.mem.eql(u8, text, "-")) return null;
    return try decodeId(text);
}

fn requireFsrs7(major: i32) !void {
    if (major != 7) return error.UnsupportedAlgorithm;
}

fn findParameter(archive: *Archive, id: [32]u8) ?*ParameterRecord {
    for (archive.parameters.items) |*parameter| {
        if (std.mem.eql(u8, parameter.id[0..], id[0..])) return parameter;
    }
    return null;
}

fn parseArchive(allocator: Allocator, bytes: []const u8) !Archive {
    try validate_mod.validateArchive(bytes);
    var archive: Archive = .{};
    errdefer archive.deinit(allocator);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = stripCr(raw);
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = try nextField(&fields);

        if (std.mem.eql(u8, kind, "PARAM")) {
            const id = try decodeId(try nextField(&fields));
            if (!std.mem.eql(u8, try nextField(&fields), "fsrs")) return error.UnsupportedAlgorithmFamily;
            const algorithm_major = try parseI32(try nextField(&fields));
            try requireFsrs7(algorithm_major);
            const implementation_major = try parseI32(try nextField(&fields));
            const implementation_minor = try parseI32(try nextField(&fields));
            const implementation_patch = try parseI32(try nextField(&fields));
            const source = try decodeHex(allocator, try nextField(&fields));
            errdefer allocator.free(source);
            try archive.parameters.append(allocator, .{
                .id = id,
                .algorithm_major = algorithm_major,
                .implementation_major = implementation_major,
                .implementation_minor = implementation_minor,
                .implementation_patch = implementation_patch,
                .source = source,
                .desired_retention = try parseF64(try nextField(&fields)),
                .minimum_interval_days = try parseF64(try nextField(&fields)),
                .maximum_interval_days = try parseF64(try nextField(&fields)),
                .created_at_ms = try parseI64(try nextField(&fields)),
            });
            continue;
        }

        if (std.mem.eql(u8, kind, "WEIGHT")) {
            const id = try decodeId(try nextField(&fields));
            const position = try std.fmt.parseInt(usize, try nextField(&fields), 10);
            if (position >= 35) return error.InvalidWeightPosition;
            const parameter = findParameter(&archive, id) orelse return error.ParameterSetNotFound;
            parameter.weights[position] = try parseF64(try nextField(&fields));
            parameter.weight_seen[position] = true;
            continue;
        }

        if (std.mem.eql(u8, kind, "DEFAULT")) {
            if (!std.mem.eql(u8, try nextField(&fields), "fsrs")) return error.UnsupportedAlgorithmFamily;
            const major = try parseI32(try nextField(&fields));
            try requireFsrs7(major);
            archive.default = .{
                .algorithm_major = major,
                .parameter_set_id = try optionalIdText(try nextField(&fields)),
            };
            continue;
        }

        if (std.mem.eql(u8, kind, "GROUP")) {
            const id = try parseI64(try nextField(&fields));
            const name = try decodeHex(allocator, try nextField(&fields));
            errdefer allocator.free(name);
            const family = try nextField(&fields);
            const major_text = try nextField(&fields);
            if (!std.mem.eql(u8, family, "-") and !std.mem.eql(u8, family, "fsrs")) return error.UnsupportedAlgorithmFamily;
            const major = try optionalI32Text(major_text);
            if (major) |value| try requireFsrs7(value);
            try archive.groups.append(allocator, .{
                .id = id,
                .name = name,
                .algorithm_major = major,
                .parameter_set_id = try optionalIdText(try nextField(&fields)),
                .created_at_ms = try parseI64(try nextField(&fields)),
            });
            continue;
        }

        if (std.mem.eql(u8, kind, "DECK")) {
            const id = try parseI64(try nextField(&fields));
            const name = try decodeHex(allocator, try nextField(&fields));
            errdefer allocator.free(name);
            const group_id = try optionalI64Text(try nextField(&fields));
            const family = try nextField(&fields);
            const major_text = try nextField(&fields);
            if (!std.mem.eql(u8, family, "-") and !std.mem.eql(u8, family, "fsrs")) return error.UnsupportedAlgorithmFamily;
            const major = try optionalI32Text(major_text);
            if (major) |value| try requireFsrs7(value);
            try archive.decks.append(allocator, .{
                .id = id,
                .name = name,
                .group_id = group_id,
                .algorithm_major = major,
                .parameter_set_id = try optionalIdText(try nextField(&fields)),
                .created_at_ms = try parseI64(try nextField(&fields)),
            });
            continue;
        }

        if (std.mem.eql(u8, kind, "CARD")) {
            const id = try parseI64(try nextField(&fields));
            const deck_id = try parseI64(try nextField(&fields));
            const question = try decodeHex(allocator, try nextField(&fields));
            errdefer allocator.free(question);
            const answer = try decodeHex(allocator, try nextField(&fields));
            errdefer allocator.free(answer);
            try archive.cards.append(allocator, .{
                .id = id,
                .deck_id = deck_id,
                .question = question,
                .answer = answer,
                .created_at_ms = try parseI64(try nextField(&fields)),
            });
            continue;
        }

        if (std.mem.eql(u8, kind, "REVIEW")) {
            const id = try parseI64(try nextField(&fields));
            const card_id = try parseI64(try nextField(&fields));
            const rating = try parseI32(try nextField(&fields));
            const reviewed_at_ms = try parseI64(try nextField(&fields));
            if (!std.mem.eql(u8, try nextField(&fields), "fsrs")) return error.UnsupportedAlgorithmFamily;
            const algorithm_major = try parseI32(try nextField(&fields));
            try requireFsrs7(algorithm_major);
            const implementation_major = try parseI32(try nextField(&fields));
            const implementation_minor = try parseI32(try nextField(&fields));
            const implementation_patch = try parseI32(try nextField(&fields));
            const parameter_set_id = (try optionalIdText(try nextField(&fields))) orelse return error.InvalidParameterSetId;
            const scheduled_at_ms = (try optionalI64Text(try nextField(&fields))) orelse reviewed_at_ms;
            try archive.reviews.append(allocator, .{
                .id = id,
                .card_id = card_id,
                .rating = rating,
                .reviewed_at_ms = reviewed_at_ms,
                .algorithm_major = algorithm_major,
                .implementation_major = implementation_major,
                .implementation_minor = implementation_minor,
                .implementation_patch = implementation_patch,
                .parameter_set_id = parameter_set_id,
                .scheduled_at_ms = scheduled_at_ms,
            });
            continue;
        }

        return error.UnknownRecordType;
    }

    for (archive.parameters.items) |parameter| {
        for (parameter.weight_seen) |seen| if (!seen) return error.InvalidParameterWeights;
    }
    return archive;
}

pub fn dryRun(allocator: Allocator, bytes: []const u8) !DryRunReport {
    var archive = try parseArchive(allocator, bytes);
    defer archive.deinit(allocator);
    return .{
        .parameter_sets = archive.parameters.items.len,
        .groups = archive.groups.items.len,
        .decks = archive.decks.items.len,
        .cards = archive.cards.items.len,
        .reviews = archive.reviews.items.len,
    };
}

fn destinationIsEmpty(mongo: *storage.MongoStore) !bool {
    inline for (.{ "parameter_sets", "deck_groups", "decks", "cards", "reviews", "metadata", "counters" }) |name| {
        var cursor = try mongo.client.find(mongo.client.databaseName(), name, .{}, .{ .limit = @as(i64, 1) });
        defer cursor.deinit();
        if (try cursor.next() != null) return false;
    }
    return true;
}

fn maxId(comptime T: type, items: []const T) i64 {
    var maximum: i64 = 0;
    for (items) |item| maximum = @max(maximum, item.id);
    return maximum;
}

fn insertArchive(mongo: *storage.MongoStore, archive: *const Archive) !void {
    if (!mongo.client.supports_transactions) return error.TransactionsUnsupported;
    var transaction = try mongo.client.beginTransaction(.{});
    errdefer transaction.abort() catch {};
    defer transaction.deinit();
    const db = mongo.client.databaseName();

    for (archive.parameters.items) |parameter| {
        var id = parameter.id;
        _ = try transaction.insertOne(db, "parameter_sets", .{
            ._id = idBinary(&id),
            .algorithm_major = parameter.algorithm_major,
            .implementation_major = parameter.implementation_major,
            .implementation_minor = parameter.implementation_minor,
            .implementation_patch = parameter.implementation_patch,
            .source = parameter.source,
            .weights = parameter.weights,
            .desired_retention = parameter.desired_retention,
            .minimum_interval_days = parameter.minimum_interval_days,
            .maximum_interval_days = parameter.maximum_interval_days,
            .created_at_ms = parameter.created_at_ms,
        });
    }

    if (archive.default) |defaults| {
        var parameter_id = defaults.parameter_set_id;
        const binary: ?bongo.bson.Binary = if (parameter_id) |*value| idBinary(value) else null;
        _ = try transaction.insertOne(db, "metadata", .{
            ._id = "scheduler_defaults",
            .algorithm_major = defaults.algorithm_major,
            .parameter_set_id = binary,
        });
    }

    for (archive.groups.items) |group| {
        var parameter_id = group.parameter_set_id;
        const binary: ?bongo.bson.Binary = if (parameter_id) |*value| idBinary(value) else null;
        _ = try transaction.insertOne(db, "deck_groups", .{
            ._id = group.id,
            .name = group.name,
            .created_at_ms = group.created_at_ms,
            .algorithm_major = group.algorithm_major,
            .parameter_set_id = binary,
        });
    }

    for (archive.decks.items) |deck| {
        var parameter_id = deck.parameter_set_id;
        const binary: ?bongo.bson.Binary = if (parameter_id) |*value| idBinary(value) else null;
        _ = try transaction.insertOne(db, "decks", .{
            ._id = deck.id,
            .name = deck.name,
            .created_at_ms = deck.created_at_ms,
            .group_id = deck.group_id,
            .algorithm_major = deck.algorithm_major,
            .parameter_set_id = binary,
        });
    }

    for (archive.cards.items) |card| {
        _ = try transaction.insertOne(db, "cards", .{
            ._id = card.id,
            .deck_id = card.deck_id,
            .question = card.question,
            .answer = card.answer,
            .created_at_ms = card.created_at_ms,
            .due_at_ms = card.created_at_ms,
            .scheduler_state = @as(?i32, null),
        });
    }

    for (archive.reviews.items) |review| {
        var parameter_id = review.parameter_set_id;
        _ = try transaction.insertOne(db, "reviews", .{
            ._id = review.id,
            .card_id = review.card_id,
            .rating = review.rating,
            .reviewed_at_ms = review.reviewed_at_ms,
            .algorithm_major = review.algorithm_major,
            .implementation_major = review.implementation_major,
            .implementation_minor = review.implementation_minor,
            .implementation_patch = review.implementation_patch,
            .parameter_set_id = idBinary(&parameter_id),
            .scheduled_at_ms = review.scheduled_at_ms,
        });
    }

    const deck_max = maxId(DeckRecord, archive.decks.items);
    const card_max = maxId(CardRecord, archive.cards.items);
    const review_max = maxId(ReviewRecord, archive.reviews.items);
    const group_max = maxId(GroupRecord, archive.groups.items);
    if (deck_max > 0) _ = try transaction.insertOne(db, "counters", .{ ._id = "deck", .value = deck_max });
    if (card_max > 0) _ = try transaction.insertOne(db, "counters", .{ ._id = "card", .value = card_max });
    if (review_max > 0) _ = try transaction.insertOne(db, "counters", .{ ._id = "review", .value = review_max });
    if (group_max > 0) _ = try transaction.insertOne(db, "counters", .{ ._id = "group", .value = group_max });

    try transaction.commit();
}

fn rebuildDerivedState(allocator: Allocator, store: *storage.Store, archive: *const Archive) !void {
    const study = study_mod.Study.init(store);
    for (archive.cards.items) |card| {
        var last_reviewed_at_ms: ?i64 = null;
        for (archive.reviews.items) |review| {
            if (review.card_id == card.id) {
                if (last_reviewed_at_ms == null or review.reviewed_at_ms > last_reviewed_at_ms.?) {
                    last_reviewed_at_ms = review.reviewed_at_ms;
                }
            }
        }
        if (last_reviewed_at_ms) |timestamp| {
            _ = try study.rebuildCardState(allocator, @intCast(card.id), timestamp);
        }
    }
}

pub fn importArchive(allocator: Allocator, store: *storage.Store, bytes: []const u8) !DryRunReport {
    var archive = try parseArchive(allocator, bytes);
    defer archive.deinit(allocator);
    const mongo = try mongoStore(store);
    if (!try destinationIsEmpty(mongo)) return error.DestinationNotEmpty;

    const report: DryRunReport = .{
        .parameter_sets = archive.parameters.items.len,
        .groups = archive.groups.items.len,
        .decks = archive.decks.items.len,
        .cards = archive.cards.items.len,
        .reviews = archive.reviews.items.len,
    };
    try insertArchive(mongo, &archive);
    try rebuildDerivedState(allocator, store, &archive);
    return report;
}
