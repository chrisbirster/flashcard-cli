const std = @import("std");
const cli = @import("cli.zig");
const thrawn_cli = @import("cli_tree.zig");

fn parse(args: []const []const u8) !thrawn_cli.Route {
    return thrawn_cli.parse(std.testing.allocator, args);
}

test "study defaults" {
    const args = [_][]const u8{ "plandalf", "study", "42" };
    const route = try parse(&args);
    try std.testing.expect(route == .core);
    try std.testing.expectEqual(@as(u64, 42), route.core.study.deck_id);
    try std.testing.expectEqual(@as(?usize, null), route.core.study.new_limit);
    try std.testing.expectEqual(cli.StudyOrder.due, route.core.study.order);
    try std.testing.expect(!route.core.study.shuffle);
}

test "study queue options" {
    const args = [_][]const u8{ "plandalf", "study", "42", "--new-limit", "10", "--order", "reviews-first", "--shuffle" };
    const route = try parse(&args);
    try std.testing.expectEqual(@as(?usize, 10), route.core.study.new_limit);
    try std.testing.expectEqual(cli.StudyOrder.reviews_first, route.core.study.order);
    try std.testing.expect(route.core.study.shuffle);
}

test "cards and card add" {
    const list_args = [_][]const u8{ "plandalf", "cards", "3" };
    const listing = try parse(&list_args);
    try std.testing.expectEqual(@as(u64, 3), listing.core.cards.deck_id);

    const add_args = [_][]const u8{ "plandalf", "card", "add", "3", "What is SQLite?", "An embedded SQL database" };
    var added = try parse(&add_args);
    defer added.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), added.core.card_add.deck_id);
    try std.testing.expectEqualStrings("What is SQLite?", added.core.card_add.question);
    try std.testing.expectEqualStrings("An embedded SQL database", added.core.card_add.answer);
    try std.testing.expect(added.core.card_add.question.ptr != add_args[4].ptr);
    try std.testing.expect(added.core.card_add.answer.ptr != add_args[5].ptr);
}

test "note add and edit own variadic fields" {
    const add_args = [_][]const u8{ "plandalf", "note", "add", "3", "reverse", "France", "Paris" };
    var added = try parse(&add_args);
    defer added.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), added.core.note_add.deck_id);
    try std.testing.expectEqualStrings("reverse", added.core.note_add.note_type);
    try std.testing.expectEqual(@as(usize, 2), added.core.note_add.fields.len);
    try std.testing.expect(added.core.note_add.note_type.ptr != add_args[4].ptr);
    try std.testing.expect(added.core.note_add.fields.ptr != add_args[5..].ptr);
    try std.testing.expectEqualStrings("France", added.core.note_add.fields[0]);
    try std.testing.expectEqualStrings("Paris", added.core.note_add.fields[1]);

    const edit_args = [_][]const u8{ "plandalf", "note", "edit", "3", "9", "France", "Paris" };
    var edited = try parse(&edit_args);
    defer edited.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 9), edited.core.note_edit.note_id);
    try std.testing.expectEqual(@as(usize, 2), edited.core.note_edit.fields.len);
}

test "deck interchange is .deck only" {
    const export_args = [_][]const u8{ "plandalf", "deck", "export", "7" };
    const exported = try parse(&export_args);
    try std.testing.expectEqual(@as(u64, 7), exported.core.nut_export.deck_id);

    const import_args = [_][]const u8{ "plandalf", "deck", "import", "zig.deck" };
    var imported = try parse(&import_args);
    defer imported.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig.deck", imported.core.nut_import.path);

    const wrong_extension = [_][]const u8{ "plandalf", "deck", "import", "zig.json" };
    try std.testing.expectError(error.InvalidDeckFile, parse(&wrong_extension));

    const old_command = [_][]const u8{ "plandalf", "nut", "export", "7" };
    try std.testing.expectError(error.UnknownCommand, parse(&old_command));
}

test "stats and inspect retain json option" {
    const stats_args = [_][]const u8{ "plandalf", "stats", "4", "--json" };
    const stats = try parse(&stats_args);
    try std.testing.expectEqual(@as(?u64, 4), stats.core.stats.deck_id);
    try std.testing.expect(stats.core.stats.json);

    const inspect_args = [_][]const u8{ "plandalf", "inspect", "9", "--json" };
    const inspect = try parse(&inspect_args);
    try std.testing.expectEqual(@as(u64, 9), inspect.core.inspect.card_id);
    try std.testing.expect(inspect.core.inspect.json);
}

test "fsrs commands retain optional deck and options" {
    const optimize_args = [_][]const u8{ "plandalf", "fsrs", "optimize", "5", "--recency" };
    const optimize = try parse(&optimize_args);
    try std.testing.expectEqual(@as(?u64, 5), optimize.core.fsrs_optimize.deck_id);
    try std.testing.expect(optimize.core.fsrs_optimize.recency_half_life_days != null);

    const evaluate_args = [_][]const u8{ "plandalf", "fsrs", "evaluate" };
    const evaluate = try parse(&evaluate_args);
    try std.testing.expectEqual(@as(?u64, null), evaluate.core.fsrs_evaluate.deck_id);

    const simulate_args = [_][]const u8{ "plandalf", "fsrs", "simulate", "--retention", "0.9" };
    const simulate = try parse(&simulate_args);
    try std.testing.expectEqual(@as(?f64, 0.9), simulate.core.fsrs_simulate.retention);
}

test "explicit help routing" {
    const fsrs_args = [_][]const u8{ "plandalf", "help", "fsrs" };
    const fsrs = try parse(&fsrs_args);
    switch (fsrs.help) {
        .core => |topic| try std.testing.expectEqual(cli.HelpTopic.fsrs, topic),
        else => return error.UnexpectedHelpTarget,
    }
}

test "destructive commands require confirmation" {
    const deck_args = [_][]const u8{ "plandalf", "deck", "delete", "3" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&deck_args));
    const card_args = [_][]const u8{ "plandalf", "card", "delete", "9" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&card_args));
}

test "blank text and invalid ids are rejected" {
    const blank_deck = [_][]const u8{ "plandalf", "deck", "add", "   " };
    try std.testing.expectError(error.InvalidText, parse(&blank_deck));
    const blank_card = [_][]const u8{ "plandalf", "card", "add", "1", "", "answer" };
    try std.testing.expectError(error.InvalidText, parse(&blank_card));
    const invalid_id = [_][]const u8{ "plandalf", "cards", "nope" };
    try std.testing.expectError(error.InvalidId, parse(&invalid_id));
}

test "missing arguments and removed commands are usage errors" {
    const cases = [_][]const []const u8{
        &.{ "plandalf", "deck", "add" },
        &.{ "plandalf", "deck", "export" },
        &.{ "plandalf", "note", "add", "1" },
        &.{ "plandalf", "cards" },
        &.{ "plandalf", "card", "add", "1" },
        &.{ "plandalf", "study" },
        &.{ "plandalf", "inspect" },
    };
    for (cases) |case_args| try std.testing.expectError(error.InvalidArguments, parse(case_args));

    const removed_nuts = [_][]const u8{ "plandalf", "nuts" };
    try std.testing.expectError(error.UnknownCommand, parse(&removed_nuts));
    const removed_sack = [_][]const u8{ "plandalf", "sack", "import", "deck.sack" };
    try std.testing.expectError(error.UnknownCommand, parse(&removed_sack));
    const removed_backup = [_][]const u8{ "plandalf", "backup" };
    try std.testing.expectError(error.UnknownCommand, parse(&removed_backup));
}

test "duplicate options remain usage errors" {
    const recency = [_][]const u8{ "plandalf", "fsrs", "optimize", "--recency", "--recency" };
    try std.testing.expectError(error.InvalidArguments, parse(&recency));
    const json = [_][]const u8{ "plandalf", "stats", "--json", "--json" };
    try std.testing.expectError(error.InvalidArguments, parse(&json));
}

test "special executors are selected after Thrawn validation" {
    const notes_args = [_][]const u8{ "plandalf", "notes", "1" };
    try std.testing.expect((try parse(&notes_args)) == .notes_cli);
    const media_args = [_][]const u8{ "plandalf", "media", "add", "diagram.png" };
    try std.testing.expect((try parse(&media_args)) == .rich_cli);
}
