const std = @import("std");
const storage = @import("storage/root.zig");
const Study = @import("study.zig").Study;
const interchange = @import("interchange.zig");
const importer = @import("interchange_import.zig");
const time = @import("time.zig");

fn deinitDecks(allocator: std.mem.Allocator, decks: []storage.DeckSummary) void {
    for (decks) |deck| deck.deinit(allocator);
    allocator.free(decks);
}

test "Deez archive round trips immutable history and parameters" {
    var source = try storage.Db.open(":memory:");
    defer source.close();
    try source.migrate();

    const catalog: storage.Catalog = .{ .db = &source };
    const default_id = try catalog.ensureDefaultFsrs7(0);
    const deck_id = try source.createDeck("bson", 0);
    const card_id = try source.createCard(deck_id, "What is BSON?", "Binary JSON", 1);
    var source_store: storage.Store = .{ .sqlite = &source };
    const study = Study.init(&source_store);
    _ = try study.recordReview(std.testing.allocator, card_id, .good, 2 * time.milliseconds_per_day);
    _ = try study.recordReview(std.testing.allocator, card_id, .hard, 5 * time.milliseconds_per_day);

    var archive_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&archive_buffer);
    try interchange.exportAll(&source, &writer);
    const archive = writer.buffered();
    try importer.validateArchive(archive);

    var destination = try storage.Db.open(":memory:");
    defer destination.close();
    try destination.migrate();
    try importer.importArchive(std.testing.allocator, &destination, archive);

    const source_report: storage.Report = .{ .db = &source };
    const destination_report: storage.Report = .{ .db = &destination };
    const source_stats = try source_report.stats(10 * time.milliseconds_per_day, null);
    const destination_stats = try destination_report.stats(10 * time.milliseconds_per_day, null);
    try std.testing.expectEqual(source_stats.deck_count, destination_stats.deck_count);
    try std.testing.expectEqual(source_stats.card_count, destination_stats.card_count);
    try std.testing.expectEqual(source_stats.review_count, destination_stats.review_count);

    const imported_history = try destination.loadHistory(std.testing.allocator, card_id);
    defer std.testing.allocator.free(imported_history);
    try std.testing.expectEqual(@as(usize, 2), imported_history.len);
    try std.testing.expectEqual(.good, imported_history[0].rating);
    try std.testing.expectEqual(.hard, imported_history[1].rating);

    const imported_catalog: storage.Catalog = .{ .db = &destination };
    const parameters = try imported_catalog.loadFsrs7Parameters(default_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), parameters.desired_retention, 1e-12);

    const decks = try destination_report.decks(std.testing.allocator, 10 * time.milliseconds_per_day);
    defer deinitDecks(std.testing.allocator, decks);
    try std.testing.expectEqualStrings("bson", decks[0].name);
}
