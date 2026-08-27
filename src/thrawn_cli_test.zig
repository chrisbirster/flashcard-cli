const std = @import("std");
const cli = @import("cli.zig");
const thrawn_cli = @import("cli_tree.zig");

fn parse(args: []const []const u8) !thrawn_cli.Route {
    return thrawn_cli.parse(std.testing.allocator, args);
}

test "study defaults remain compatible" {
    const args = [_][]const u8{ "deez", "study", "42" };
    const route = try parse(&args);
    try std.testing.expect(route == .core);
    try std.testing.expectEqual(@as(u64, 42), route.core.study.deck_id);
    try std.testing.expectEqual(@as(?usize, null), route.core.study.new_limit);
    try std.testing.expectEqual(cli.StudyOrder.due, route.core.study.order);
    try std.testing.expect(!route.core.study.shuffle);
}

test "study queue options remain compatible" {
    const args = [_][]const u8{
        "deez",
        "study",
        "42",
        "--new-limit",
        "10",
        "--order",
        "reviews-first",
        "--shuffle",
    };
    const route = try parse(&args);
    try std.testing.expectEqual(@as(?usize, 10), route.core.study.new_limit);
    try std.testing.expectEqual(cli.StudyOrder.reviews_first, route.core.study.order);
    try std.testing.expect(route.core.study.shuffle);
}

test "cards and card add remain compatible" {
    const list_args = [_][]const u8{ "deez", "cards", "3" };
    const listing = try parse(&list_args);
    try std.testing.expectEqual(@as(u64, 3), listing.core.cards.deck_id);

    const add_args = [_][]const u8{
        "deez",
        "card",
        "add",
        "3",
        "What is BSON?",
        "Binary JSON",
    };
    var added = try parse(&add_args);
    defer added.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), added.core.card_add.deck_id);
    try std.testing.expectEqualStrings("What is BSON?", added.core.card_add.question);
    try std.testing.expectEqualStrings("Binary JSON", added.core.card_add.answer);
    try std.testing.expect(added.core.card_add.question.ptr != add_args[4].ptr);
    try std.testing.expect(added.core.card_add.answer.ptr != add_args[5].ptr);
}

test "note add and edit own variadic fields" {
    const add_args = [_][]const u8{
        "deez",
        "note",
        "add",
        "3",
        "reverse",
        "France",
        "Paris",
    };
    var added = try parse(&add_args);
    defer added.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), added.core.note_add.deck_id);
    try std.testing.expectEqualStrings("reverse", added.core.note_add.note_type);
    try std.testing.expectEqual(@as(usize, 2), added.core.note_add.fields.len);
    try std.testing.expect(added.core.note_add.note_type.ptr != add_args[4].ptr);
    try std.testing.expect(added.core.note_add.fields.ptr != add_args[5..].ptr);
    try std.testing.expect(added.core.note_add.fields[0].ptr != add_args[5].ptr);
    try std.testing.expectEqualStrings("France", added.core.note_add.fields[0]);
    try std.testing.expectEqualStrings("Paris", added.core.note_add.fields[1]);

    const edit_args = [_][]const u8{
        "deez",
        "note",
        "edit",
        "3",
        "9",
        "France",
        "Paris",
    };
    var edited = try parse(&edit_args);
    defer edited.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 9), edited.core.note_edit.note_id);
    try std.testing.expectEqual(@as(usize, 2), edited.core.note_edit.fields.len);
    try std.testing.expect(edited.core.note_edit.fields.ptr != edit_args[5..].ptr);
    try std.testing.expect(edited.core.note_edit.fields[0].ptr != edit_args[5].ptr);
}

test "nuts remains an alias in behavior" {
    const args = [_][]const u8{ "deez", "nuts" };
    const route = try parse(&args);
    try std.testing.expect(route.core == .decks);
}

test "nut and deck interchange commands remain compatible" {
    const nut_export_args = [_][]const u8{ "deez", "nut", "export", "7" };
    const nut_export = try parse(&nut_export_args);
    try std.testing.expectEqual(@as(u64, 7), nut_export.core.nut_export.deck_id);

    const nut_import_args = [_][]const u8{ "deez", "nut", "import", "zig.nut" };
    var nut_import = try parse(&nut_import_args);
    defer nut_import.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig.nut", nut_import.core.nut_import.path);
    try std.testing.expect(nut_import.core.nut_import.path.ptr != nut_import_args[3].ptr);

    const deck_export_args = [_][]const u8{ "deez", "deck", "export", "7" };
    const deck_export = try parse(&deck_export_args);
    try std.testing.expectEqual(@as(u64, 7), deck_export.core.deck_export.deck_id);

    const deck_import_args = [_][]const u8{ "deez", "deck", "import", "zig.json" };
    var deck_import = try parse(&deck_import_args);
    defer deck_import.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig.json", deck_import.core.deck_import.path);
    try std.testing.expect(deck_import.core.deck_import.path.ptr != deck_import_args[3].ptr);
}

test "stats and inspect retain json option" {
    const stats_args = [_][]const u8{ "deez", "stats", "4", "--json" };
    const stats = try parse(&stats_args);
    try std.testing.expectEqual(@as(?u64, 4), stats.core.stats.deck_id);
    try std.testing.expect(stats.core.stats.json);

    const inspect_args = [_][]const u8{ "deez", "inspect", "9", "--json" };
    const inspect = try parse(&inspect_args);
    try std.testing.expectEqual(@as(u64, 9), inspect.core.inspect.card_id);
    try std.testing.expect(inspect.core.inspect.json);
}

test "fsrs commands retain optional deck and options" {
    const optimize_args = [_][]const u8{ "deez", "fsrs", "optimize", "5", "--recency" };
    const optimize = try parse(&optimize_args);
    try std.testing.expectEqual(@as(?u64, 5), optimize.core.fsrs_optimize.deck_id);
    try std.testing.expect(optimize.core.fsrs_optimize.recency_half_life_days != null);

    const evaluate_args = [_][]const u8{ "deez", "fsrs", "evaluate" };
    const evaluate = try parse(&evaluate_args);
    try std.testing.expectEqual(@as(?u64, null), evaluate.core.fsrs_evaluate.deck_id);

    const simulate_args = [_][]const u8{ "deez", "fsrs", "simulate", "--retention", "0.9" };
    const simulate = try parse(&simulate_args);
    try std.testing.expectEqual(@as(?f64, 0.9), simulate.core.fsrs_simulate.retention);
}

test "explicit help routing remains compatible" {
    const fsrs_args = [_][]const u8{ "deez", "help", "fsrs" };
    const fsrs = try parse(&fsrs_args);
    try std.testing.expect(fsrs == .help);
    switch (fsrs.help) {
        .core => |topic| try std.testing.expectEqual(cli.HelpTopic.fsrs, topic),
        else => return error.UnexpectedHelpTarget,
    }

    const nuts_args = [_][]const u8{ "deez", "help", "nuts" };
    const nuts = try parse(&nuts_args);
    switch (nuts.help) {
        .core => |topic| try std.testing.expectEqual(cli.HelpTopic.nut, topic),
        else => return error.UnexpectedHelpTarget,
    }
}

test "destructive commands still require confirmation" {
    const deck_args = [_][]const u8{ "deez", "deck", "delete", "3" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&deck_args));

    const card_args = [_][]const u8{ "deez", "card", "delete", "9" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&card_args));

    const restore_args = [_][]const u8{ "deez", "restore" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&restore_args));
}

test "blank text and invalid ids remain rejected" {
    const blank_deck = [_][]const u8{ "deez", "deck", "add", "   " };
    try std.testing.expectError(error.InvalidText, parse(&blank_deck));

    const blank_card = [_][]const u8{ "deez", "card", "add", "1", "", "answer" };
    try std.testing.expectError(error.InvalidText, parse(&blank_card));

    const invalid_id = [_][]const u8{ "deez", "cards", "nope" };
    try std.testing.expectError(error.InvalidId, parse(&invalid_id));
}

test "missing arguments and unknown commands remain usage errors" {
    const cases = [_][]const []const u8{
        &.{ "deez", "deck", "add" },
        &.{ "deez", "deck", "export" },
        &.{ "deez", "nut", "export" },
        &.{ "deez", "note", "add", "1" },
        &.{ "deez", "cards" },
        &.{ "deez", "card", "add", "1" },
        &.{ "deez", "study" },
        &.{ "deez", "inspect" },
    };
    for (cases) |case_args| {
        try std.testing.expectError(error.InvalidArguments, parse(case_args));
    }

    const unknown = [_][]const u8{ "deez", "wat" };
    try std.testing.expectError(error.UnknownCommand, parse(&unknown));
}

test "duplicate options remain usage errors" {
    const recency = [_][]const u8{
        "deez",
        "fsrs",
        "optimize",
        "--recency",
        "--recency",
    };
    try std.testing.expectError(error.InvalidArguments, parse(&recency));

    const json = [_][]const u8{ "deez", "stats", "--json", "--json" };
    try std.testing.expectError(error.InvalidArguments, parse(&json));
}

test "special executors are selected after Thrawn validation" {
    const backup_args = [_][]const u8{ "deez", "backup", "42" };
    try std.testing.expect((try parse(&backup_args)) == .backup_cli);

    const restore_args = [_][]const u8{ "deez", "restore", "--dry-run" };
    try std.testing.expect((try parse(&restore_args)) == .backup_cli);

    const notes_args = [_][]const u8{ "deez", "notes", "1" };
    try std.testing.expect((try parse(&notes_args)) == .notes_cli);

    const media_args = [_][]const u8{ "deez", "media", "add", "diagram.png" };
    try std.testing.expect((try parse(&media_args)) == .rich_cli);

    const sack_args = [_][]const u8{ "deez", "sack", "import", "deck.sack" };
    try std.testing.expect((try parse(&sack_args)) == .rich_cli);
}
