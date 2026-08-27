const std = @import("std");
const deez = @import("deez");

const replica_uri = "mongodb://localhost:27019/deez_integration?replicaSet=rs0";

test ".nut decks import and export through MongoDB Store" {
    const allocator = std.testing.allocator;
    const mongo = try deez.storage.MongoStore.connect(
        std.testing.io,
        allocator,
        replica_uri,
    );
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    const source =
        \\{"kind":"deck","format":"deez.nut","version":1,"name":"Mongo Nut Deck"}
        \\{"kind":"card","question":"Mongo question?","answer":"Mongo answer"}
        \\{"kind":"card","question":"Portable?","answer":"Yes"}
    ;

    const result = try deez.nut.importSlice(allocator, &store, source, 1234);
    defer store.deleteDeck(result.deck_id) catch {};
    try std.testing.expectEqual(@as(usize, 2), result.card_count);

    const deck = (try store.getDeck(allocator, result.deck_id)) orelse return error.MissingDeck;
    defer deck.deinit(allocator);
    try std.testing.expectEqualStrings("Mongo Nut Deck", deck.name);

    const cards = try store.cards(allocator, result.deck_id);
    defer {
        for (cards) |card| card.deinit(allocator);
        allocator.free(cards);
    }
    try std.testing.expectEqual(@as(usize, 2), cards.len);
    try std.testing.expectEqualStrings("Mongo question?", cards[0].question);
    try std.testing.expectEqualStrings("Portable?", cards[1].question);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try deez.nut.exportDeck(allocator, &store, result.deck_id, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"format\":\"deez.nut\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "Mongo question?") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.written(), "\n"));
}
