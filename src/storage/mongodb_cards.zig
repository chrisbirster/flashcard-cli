const std = @import("std");
const bongo = @import("bongo");

const card_mod = @import("../card.zig");
const mongodb = @import("mongodb.zig");
const sqlite = @import("sqlite.zig");

fn requiredI64(document: []const u8, field: []const u8) !i64 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return switch (value) {
        .int32 => |v| v,
        .int64 => |v| v,
        else => error.InvalidField,
    };
}

fn requiredString(document: []const u8, field: []const u8) ![]const u8 {
    const value = (try bongo.bson.Reader.get(document, field)) orelse return error.MissingField;
    return switch (value) {
        .string => |v| v,
        else => error.InvalidField,
    };
}

pub fn list(
    store: *mongodb.Store,
    allocator: std.mem.Allocator,
    deck_id: card_mod.DeckId,
) ![]sqlite.OwnedCard {
    const signed_id = std.math.cast(i64, deck_id) orelse return error.IdOutOfRange;
    var cursor = try store.client.find(
        store.client.databaseName(),
        "cards",
        .{ .deck_id = signed_id },
        .{ .sort = .{ ._id = @as(i32, 1) } },
    );
    defer cursor.deinit();

    var cards: std.ArrayList(sqlite.OwnedCard) = .empty;
    errdefer {
        for (cards.items) |card| card.deinit(allocator);
        cards.deinit(allocator);
    }

    while (try cursor.next()) |document| {
        const question = try allocator.dupe(u8, try requiredString(document, "question"));
        errdefer allocator.free(question);
        const answer = try allocator.dupe(u8, try requiredString(document, "answer"));
        errdefer allocator.free(answer);

        try cards.append(allocator, .{
            .id = @intCast(try requiredI64(document, "_id")),
            .deck_id = @intCast(try requiredI64(document, "deck_id")),
            .question = question,
            .answer = answer,
        });
    }

    return cards.toOwnedSlice(allocator);
}
