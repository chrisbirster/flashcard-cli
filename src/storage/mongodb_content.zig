const std = @import("std");
const bongo = @import("bongo");

const content = @import("../content.zig");
const mongodb = @import("mongodb.zig");

const q = bongo.query;

fn database(store: *mongodb.Store) []const u8 {
    return store.client.databaseName();
}

fn requiredString(document: []const u8, field: []const u8) ![]const u8 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return switch (value) {
        .string => |v| v,
        else => error.InvalidField,
    };
}

fn valueAsI64(value: bongo.bson.Value) ?i64 {
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| v,
        else => null,
    };
}

fn requiredI64(document: []const u8, field: []const u8) !i64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return valueAsI64(value) orelse error.InvalidField;
}

fn nextId(store: *mongodb.Store, kind: []const u8) !i64 {
    var owned = (try store.client.findOneAndUpdate(
        database(store),
        "counters",
        .{ ._id = kind },
        q.inc(.{ .value = @as(i64, 1) }),
        true,
    )) orelse return error.MissingField;
    defer owned.deinit();
    return requiredI64(owned.bytes, "value");
}

pub fn ensureBuiltInBasic(store: *mongodb.Store, created_at_ms: i64) !content.NoteTypeId {
    var existing = try store.client.findOne(database(store), "note_types", .{ ._id = @as(i64, 1) });
    if (existing) |*document| {
        document.deinit();
        return content.basic_note_type.id;
    }

    _ = try store.client.insertOne(database(store), "note_types", .{
        ._id = @as(i64, 1),
        .slug = "basic",
        .name = "Basic",
        .kind = "basic",
        .css = content.basic_note_type.css,
        .fields_json = "[{\"ordinal\":0,\"name\":\"Front\"},{\"ordinal\":1,\"name\":\"Back\"}]",
        .templates_json = "[{\"ordinal\":0,\"name\":\"Card 1\",\"front\":\"{{Front}}\",\"back\":\"{{FrontSide}}<hr id=answer>{{Back}}\"}]",
        .created_at_ms = created_at_ms,
    });
    return content.basic_note_type.id;
}

fn fieldsJson(
    allocator: std.mem.Allocator,
    fields: []const content.FieldValue,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(fields, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn createNote(
    allocator: std.mem.Allocator,
    store: *mongodb.Store,
    note_type_id: content.NoteTypeId,
    fields: []const content.FieldValue,
    tags_json: []const u8,
    created_at_ms: i64,
) !content.NoteId {
    const id = try nextId(store, "note");
    const fields_json = try fieldsJson(allocator, fields);
    defer allocator.free(fields_json);
    _ = try store.client.insertOne(database(store), "notes", .{
        ._id = id,
        .note_type_id = @as(i64, @intCast(note_type_id)),
        .fields_json = fields_json,
        .tags_json = tags_json,
        .created_at_ms = created_at_ms,
        .updated_at_ms = created_at_ms,
    });
    return @intCast(id);
}

fn linkGeneratedCard(
    allocator: std.mem.Allocator,
    store: *mongodb.Store,
    card_id: u64,
    note_id: content.NoteId,
    template_ordinal: content.TemplateOrdinal,
) !void {
    const key = try content.generationKey(allocator, note_id, template_ordinal);
    defer allocator.free(key);
    _ = try store.client.insertOne(database(store), "generated_cards", .{
        ._id = @as(i64, @intCast(card_id)),
        .note_id = @as(i64, @intCast(note_id)),
        .template_ordinal = @as(i32, @intCast(template_ordinal)),
        .generation_key = key,
    });
}

pub fn createBasicNote(
    allocator: std.mem.Allocator,
    store: *mongodb.Store,
    deck_id: u64,
    front: []const u8,
    back: []const u8,
    tags_json: []const u8,
    created_at_ms: i64,
) !content.CreatedNote {
    try content.requireText(front);
    try content.requireText(back);
    _ = try ensureBuiltInBasic(store, created_at_ms);

    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = front },
        .{ .ordinal = 1, .value = back },
    };
    const note_id = try createNote(allocator, store, content.basic_note_type.id, &fields, tags_json, created_at_ms);
    errdefer _ = store.client.deleteOne(database(store), "notes", .{ ._id = @as(i64, @intCast(note_id)) }) catch {};

    const card_id = try store.createCard(deck_id, front, back, created_at_ms);
    errdefer store.deleteCard(card_id) catch {};
    try linkGeneratedCard(allocator, store, card_id, note_id, 0);

    const ids = try allocator.alloc(u64, 1);
    ids[0] = card_id;
    return .{ .note_id = note_id, .card_ids = ids };
}

fn existingNoteForCard(store: *mongodb.Store, card_id: u64) !?content.NoteId {
    var owned = (try store.client.findOne(
        database(store),
        "generated_cards",
        .{ ._id = @as(i64, @intCast(card_id)) },
    )) orelse return null;
    defer owned.deinit();
    return @intCast(try requiredI64(owned.bytes, "note_id"));
}

pub fn adoptLegacyCard(
    allocator: std.mem.Allocator,
    store: *mongodb.Store,
    card_id: u64,
    adopted_at_ms: i64,
) !content.NoteId {
    _ = try ensureBuiltInBasic(store, adopted_at_ms);
    if (try existingNoteForCard(store, card_id)) |note_id| return note_id;

    const card = (try store.getCard(allocator, card_id)) orelse return error.CardNotFound;
    defer card.deinit(allocator);
    const fields = [_]content.FieldValue{
        .{ .ordinal = 0, .value = card.question },
        .{ .ordinal = 1, .value = card.answer },
    };
    const note_id = try createNote(allocator, store, content.basic_note_type.id, &fields, "[]", adopted_at_ms);
    errdefer _ = store.client.deleteOne(database(store), "notes", .{ ._id = @as(i64, @intCast(note_id)) }) catch {};
    try linkGeneratedCard(allocator, store, card_id, note_id, 0);
    return note_id;
}

pub fn getNote(
    allocator: std.mem.Allocator,
    store: *mongodb.Store,
    note_id: content.NoteId,
) !?content.OwnedNote {
    var owned = (try store.client.findOne(
        database(store),
        "notes",
        .{ ._id = @as(i64, @intCast(note_id)) },
    )) orelse return null;
    defer owned.deinit();
    const document = owned.bytes;

    const fields_json = try requiredString(document, "fields_json");
    var parsed = try std.json.parseFromSlice([]content.FieldValue, allocator, fields_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const fields = try allocator.alloc(content.OwnedFieldValue, parsed.value.len);
    var initialized: usize = 0;
    errdefer {
        for (fields[0..initialized]) |field| field.deinit(allocator);
        allocator.free(fields);
    }
    for (parsed.value, 0..) |field, index| {
        fields[index] = .{
            .ordinal = field.ordinal,
            .value = try allocator.dupe(u8, field.value),
        };
        initialized += 1;
    }

    return .{
        .id = note_id,
        .note_type_id = @intCast(try requiredI64(document, "note_type_id")),
        .tags_json = try allocator.dupe(u8, try requiredString(document, "tags_json")),
        .fields = fields,
        .created_at_ms = try requiredI64(document, "created_at_ms"),
        .updated_at_ms = try requiredI64(document, "updated_at_ms"),
    };
}

pub fn cardSource(
    allocator: std.mem.Allocator,
    store: *mongodb.Store,
    card_id: u64,
) !?content.GeneratedCardSource {
    var owned = (try store.client.findOne(
        database(store),
        "generated_cards",
        .{ ._id = @as(i64, @intCast(card_id)) },
    )) orelse return null;
    defer owned.deinit();
    return .{
        .note_id = @intCast(try requiredI64(owned.bytes, "note_id")),
        .template_ordinal = @intCast(try requiredI64(owned.bytes, "template_ordinal")),
        .generation_key = try allocator.dupe(u8, try requiredString(owned.bytes, "generation_key")),
    };
}
