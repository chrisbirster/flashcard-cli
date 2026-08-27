const std = @import("std");
const bongo = @import("bongo");
const deez = @import("deez");

const source_uri = "mongodb://localhost:27019/deez_interchange_source?replicaSet=rs0";
const target_uri = "mongodb://localhost:27019/deez_interchange_target?replicaSet=rs0";

fn connectStore(uri: []const u8) !deez.storage.Store {
    const mongo = try deez.storage.MongoStore.connect(
        std.testing.io,
        std.testing.allocator,
        uri,
    );
    return .{ .mongodb = mongo };
}

fn clearCollection(mongo: *deez.storage.MongoStore, name: []const u8) !void {
    while (true) {
        var cursor = try mongo.client.find(mongo.client.databaseName(), name, .{}, .{ .limit = @as(i64, 1) });
        const document = (try cursor.next()) orelse {
            cursor.deinit();
            return;
        };
        const id = (try bongo.bson.Reader.get(document, "_id")) orelse return error.MissingId;
        const owned_id = switch (id) {
            .int32 => |value| @as(i64, value),
            .int64 => |value| value,
            .string => {
                cursor.deinit();
                _ = try mongo.client.deleteOne(mongo.client.databaseName(), name, .{});
                continue;
            },
            .binary => {
                cursor.deinit();
                var all = try mongo.client.find(mongo.client.databaseName(), name, .{}, .{});
                defer all.deinit();
                while (try all.next()) |item| {
                    const binary_value = (try bongo.bson.Reader.get(item, "_id")).?.binary;
                    _ = try mongo.client.deleteOne(mongo.client.databaseName(), name, .{ ._id = binary_value });
                }
                return;
            },
            else => return error.InvalidId,
        };
        cursor.deinit();
        _ = try mongo.client.deleteOne(mongo.client.databaseName(), name, .{ ._id = owned_id });
    }
}

fn clearStore(store: *deez.storage.Store) !void {
    const mongo = switch (store.*) {
        .mongodb => |*value| value,
        .sqlite => return error.MongoRequired,
    };
    inline for (.{ "reviews", "cards", "decks", "deck_groups", "parameter_sets", "metadata", "counters" }) |name| {
        try clearCollection(mongo, name);
    }
}

test "MongoStore Deez archive dry-run and transactional restore preserve history" {
    const allocator = std.testing.allocator;
    var source = try connectStore(source_uri);
    defer source.deinit();
    try clearStore(&source);
    defer clearStore(&source) catch {};

    const deck_id = try source.createDeck("mongo-backup", 0);
    const card_id = try source.createCard(deck_id, "What is BSON?", "Binary JSON", 1);
    var parameters: deez.fsrs.v7.Parameters = .{};
    parameters.desired_retention = 0.94;
    const parameter_id = try source.putFsrs7Parameters(parameters, "backup-test", 0);
    try source.setDeckFsrs7(deck_id, parameter_id);
    const study = deez.Study.init(&source);
    _ = try study.recordReview(allocator, card_id, .good, deez.time.milliseconds_per_day);
    _ = try study.recordReview(allocator, card_id, .hard, 3 * deez.time.milliseconds_per_day);

    var archive_buffer: [256 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&archive_buffer);
    try deez.interchange_mongodb.exportArchive(&source, &writer, .{});
    const archive = writer.buffered();

    const preview = try deez.interchange_mongodb.dryRun(allocator, archive);
    try std.testing.expectEqual(@as(usize, 1), preview.decks);
    try std.testing.expectEqual(@as(usize, 1), preview.cards);
    try std.testing.expectEqual(@as(usize, 2), preview.reviews);
    try std.testing.expectEqual(@as(usize, 0), preview.unsupported_records);

    var target = try connectStore(target_uri);
    defer target.deinit();
    try clearStore(&target);
    defer clearStore(&target) catch {};

    const imported = try deez.interchange_mongodb.importArchive(allocator, &target, archive);
    try std.testing.expectEqual(preview.cards, imported.cards);
    try std.testing.expectEqual(preview.reviews, imported.reviews);

    const restored_deck = (try target.getDeck(allocator, deck_id)) orelse return error.MissingRestoredDeck;
    defer restored_deck.deinit(allocator);
    try std.testing.expectEqualStrings("mongo-backup", restored_deck.name);

    const restored_history = try target.loadHistory(allocator, card_id);
    defer allocator.free(restored_history);
    try std.testing.expectEqual(@as(usize, 2), restored_history.len);
    try std.testing.expectEqual(deez.fsrs.Rating.good, restored_history[0].rating);
    try std.testing.expectEqual(deez.fsrs.Rating.hard, restored_history[1].rating);

    const resolved = try target.resolveDeckScheduler(deck_id, 0);
    try std.testing.expect(std.mem.eql(u8, resolved.parameter_set_id[0..], parameter_id[0..]));
    const state = (try target.getSchedulerState(card_id)) orelse return error.MissingRestoredState;
    try std.testing.expect(std.mem.eql(u8, state.stamp.parameter_set_id[0..], parameter_id[0..]));

    try std.testing.expectError(
        error.DestinationNotEmpty,
        deez.interchange_mongodb.importArchive(allocator, &target, archive),
    );
}
