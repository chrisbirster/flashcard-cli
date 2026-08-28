const std = @import("std");
const th = @import("thrawn");
const cli = @import("cli.zig");

pub const Help = union(enum) {
    general,
    core: cli.HelpTopic,
    notes,
    rich,
};

pub const Route = union(enum) {
    help: Help,
    setup,
    core: cli.Command,
    notes_cli,
    rich_cli,

    pub fn deinit(self: *Route, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .core => |command| switch (command) {
                .deck_add => |args| allocator.free(@constCast(args.name)),
                .deck_rename => |args| allocator.free(@constCast(args.name)),
                .deck_import => |args| allocator.free(@constCast(args.path)),
                .note_add => |args| {
                    allocator.free(@constCast(args.note_type));
                    freeFields(allocator, args.fields);
                },
                .note_edit => |args| freeFields(allocator, args.fields),
                .card_add => |args| {
                    allocator.free(@constCast(args.question));
                    allocator.free(@constCast(args.answer));
                },
                .card_edit => |args| {
                    allocator.free(@constCast(args.question));
                    allocator.free(@constCast(args.answer));
                },
                else => {},
            },
            else => {},
        }
    }
};

fn freeFields(allocator: std.mem.Allocator, fields: []const []const u8) void {
    for (fields) |field| allocator.free(@constCast(field));
    allocator.free(@constCast(fields));
}

const ParseState = struct { route: ?Route = null };

fn parseState(ctx: *th.Context) !*ParseState {
    return ctx.state(ParseState) orelse error.MissingParseState;
}

fn setRoute(ctx: *th.Context, route: Route) !void {
    (try parseState(ctx)).route = route;
}

fn parseId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidId;
}

fn parseCount(text: []const u8) !usize {
    return std.fmt.parseInt(usize, text, 10) catch return error.InvalidNumber;
}

fn parseFloat(text: []const u8) !f64 {
    return std.fmt.parseFloat(f64, text) catch return error.InvalidNumber;
}

fn requireText(text: []const u8) ![]const u8 {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidText;
    return text;
}

fn dupeText(ctx: *th.Context, index: usize) ![]u8 {
    _ = try requireText(ctx.args[index]);
    return (try ctx.dupeArgument(ctx.allocator, index)) orelse error.InvalidArguments;
}

fn parseStudyOrder(text: []const u8) !cli.StudyOrder {
    if (std.mem.eql(u8, text, "due")) return .due;
    if (std.mem.eql(u8, text, "reviews-first")) return .reviews_first;
    if (std.mem.eql(u8, text, "new-first")) return .new_first;
    return error.InvalidStudyOrder;
}

fn parseStatsWindow(text: []const u8) !cli.StatsWindow {
    if (std.mem.eql(u8, text, "all")) return .all;
    if (std.mem.eql(u8, text, "today")) return .today;
    if (std.mem.eql(u8, text, "week")) return .week;
    if (std.mem.eql(u8, text, "month")) return .month;
    if (std.mem.eql(u8, text, "year")) return .year;
    return error.InvalidStatsWindow;
}

fn parseHelpTopic(text: []const u8) !cli.HelpTopic {
    if (std.mem.eql(u8, text, "deck") or std.mem.eql(u8, text, "decks")) return .deck;
    if (std.mem.eql(u8, text, "note") or std.mem.eql(u8, text, "notes")) return .note;
    if (std.mem.eql(u8, text, "card") or std.mem.eql(u8, text, "cards")) return .card;
    if (std.mem.eql(u8, text, "study")) return .study;
    if (std.mem.eql(u8, text, "stats")) return .stats;
    if (std.mem.eql(u8, text, "inspect")) return .inspect;
    if (std.mem.eql(u8, text, "fsrs")) return .fsrs;
    if (std.mem.eql(u8, text, "scheduler")) return .scheduler;
    return error.UnknownHelpTopic;
}

fn helpHandler(ctx: *th.Context) !void {
    if (ctx.args.len == 0) return setRoute(ctx, .{ .help = .general });
    try setRoute(ctx, .{ .help = .{ .core = try parseHelpTopic(ctx.args[0]) } });
}
fn setupHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .setup);
}
fn decksHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .decks });
}
fn cardsHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .cards = .{ .deck_id = try parseId(ctx.args[0]) } } });
}
fn deckAddHandler(ctx: *th.Context) !void {
    const name = try dupeText(ctx, 0);
    errdefer ctx.allocator.free(name);
    try setRoute(ctx, .{ .core = .{ .deck_add = .{ .name = name } } });
}
fn deckRenameHandler(ctx: *th.Context) !void {
    const name = try dupeText(ctx, 1);
    errdefer ctx.allocator.free(name);
    try setRoute(ctx, .{ .core = .{ .deck_rename = .{ .deck_id = try parseId(ctx.args[0]), .name = name } } });
}
fn deckDeleteHandler(ctx: *th.Context) !void {
    if (!ctx.hasOption("yes")) return error.ConfirmationRequired;
    try setRoute(ctx, .{ .core = .{ .deck_delete = .{ .deck_id = try parseId(ctx.args[0]) } } });
}
fn deckExportHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .deck_export = .{ .deck_id = try parseId(ctx.args[0]) } } });
}
fn deckImportHandler(ctx: *th.Context) !void {
    const path = try dupeText(ctx, 0);
    errdefer ctx.allocator.free(path);
    if (!std.mem.endsWith(u8, path, ".deck")) return error.InvalidDeckFile;
    try setRoute(ctx, .{ .core = .{ .deck_import = .{ .path = path } } });
}

fn noteAddHandler(ctx: *th.Context) !void {
    const note_type = try dupeText(ctx, 1);
    errdefer ctx.allocator.free(note_type);
    const fields = try ctx.dupeArguments(ctx.allocator, 2);
    errdefer freeFields(ctx.allocator, fields);
    try setRoute(ctx, .{ .core = .{ .note_add = .{ .deck_id = try parseId(ctx.args[0]), .note_type = note_type, .fields = fields } } });
}
fn noteEditHandler(ctx: *th.Context) !void {
    const fields = try ctx.dupeArguments(ctx.allocator, 2);
    errdefer freeFields(ctx.allocator, fields);
    try setRoute(ctx, .{ .core = .{ .note_edit = .{ .deck_id = try parseId(ctx.args[0]), .note_id = try parseId(ctx.args[1]), .fields = fields } } });
}
fn notesHandler(ctx: *th.Context) !void {
    _ = try parseId(ctx.args[0]);
    try setRoute(ctx, .notes_cli);
}
fn cardAddHandler(ctx: *th.Context) !void {
    const q = try dupeText(ctx, 1);
    errdefer ctx.allocator.free(q);
    const a = try dupeText(ctx, 2);
    errdefer ctx.allocator.free(a);
    try setRoute(ctx, .{ .core = .{ .card_add = .{ .deck_id = try parseId(ctx.args[0]), .question = q, .answer = a } } });
}
fn cardEditHandler(ctx: *th.Context) !void {
    const q = try dupeText(ctx, 1);
    errdefer ctx.allocator.free(q);
    const a = try dupeText(ctx, 2);
    errdefer ctx.allocator.free(a);
    try setRoute(ctx, .{ .core = .{ .card_edit = .{ .card_id = try parseId(ctx.args[0]), .question = q, .answer = a } } });
}
fn cardDeleteHandler(ctx: *th.Context) !void {
    if (!ctx.hasOption("yes")) return error.ConfirmationRequired;
    try setRoute(ctx, .{ .core = .{ .card_delete = .{ .card_id = try parseId(ctx.args[0]) } } });
}
fn studyHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .study = .{
        .deck_id = try parseId(ctx.args[0]),
        .new_limit = if (ctx.optionValue("new-limit")) |v| try parseCount(v) else null,
        .order = if (ctx.optionValue("order")) |v| try parseStudyOrder(v) else .due,
        .shuffle = ctx.hasOption("shuffle"),
    } } });
}
fn statsHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .stats = .{
        .deck_id = if (ctx.args.len == 1) try parseId(ctx.args[0]) else null,
        .json = ctx.hasOption("json"),
        .window = if (ctx.optionValue("period")) |value| try parseStatsWindow(value) else .all,
    } } });
}
fn inspectHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .inspect = .{ .card_id = try parseId(ctx.args[0]), .json = ctx.hasOption("json") } } });
}
fn fsrsOptimizeHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .fsrs_optimize = .{ .deck_id = if (ctx.args.len == 1) try parseId(ctx.args[0]) else null, .recency_half_life_days = if (ctx.hasOption("recency")) 1.0 else null } } });
}
fn fsrsEvaluateHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .fsrs_evaluate = .{ .deck_id = if (ctx.args.len == 1) try parseId(ctx.args[0]) else null } } });
}
fn fsrsSimulateHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .{ .fsrs_simulate = .{ .retention = if (ctx.optionValue("retention")) |v| try parseFloat(v) else null } } });
}
fn fsrsRetentionHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .fsrs_retention });
}
fn schedulerListHandler(ctx: *th.Context) !void {
    try setRoute(ctx, .{ .core = .scheduler_list });
}
fn mediaAddHandler(ctx: *th.Context) !void {
    _ = try requireText(ctx.args[0]);
    try setRoute(ctx, .rich_cli);
}

const help_command: th.Command = .{ .name = "help", .summary = "Show help", .handler = helpHandler, .args = .{ .positionals = &.{.{ .name = "topic", .required = false }} } };
const setup_command: th.Command = .{ .name = "setup", .summary = "Show the SQLite database path", .handler = setupHandler, .args = .{ .exact = 0 } };
const decks_command: th.Command = .{ .name = "decks", .summary = "List decks", .handler = decksHandler, .args = .{ .exact = 0 } };
const cards_command: th.Command = .{ .name = "cards", .summary = "List cards in a deck", .handler = cardsHandler, .args = .{ .positionals = &.{.{ .name = "deck-id" }} } };

const deck_add_command: th.Command = .{ .name = "add", .summary = "Create a deck", .handler = deckAddHandler, .args = .{ .positionals = &.{.{ .name = "name" }} } };
const deck_rename_command: th.Command = .{ .name = "rename", .summary = "Rename a deck", .handler = deckRenameHandler, .args = .{ .positionals = &.{ .{ .name = "deck-id" }, .{ .name = "name" } } } };
const deck_delete_command: th.Command = .{ .name = "delete", .summary = "Delete a deck", .handler = deckDeleteHandler, .args = .{ .positionals = &.{.{ .name = "deck-id" }} }, .options = &.{.{ .long = "yes", .summary = "Confirm deletion" }} };
const deck_export_command: th.Command = .{ .name = "export", .summary = "Export a .deck file", .handler = deckExportHandler, .args = .{ .positionals = &.{.{ .name = "deck-id" }} } };
const deck_import_command: th.Command = .{ .name = "import", .summary = "Import a .deck file", .handler = deckImportHandler, .args = .{ .positionals = &.{.{ .name = "path" }} } };
const deck_command: th.Command = .{ .name = "deck", .summary = "Manage decks", .children = &.{ &deck_add_command, &deck_rename_command, &deck_delete_command, &deck_export_command, &deck_import_command } };

const note_add_command: th.Command = .{ .name = "add", .summary = "Create a note", .handler = noteAddHandler, .args = .{ .min = 4, .positionals = &.{ .{ .name = "deck-id" }, .{ .name = "note-type" }, .{ .name = "fields", .variadic = true } } } };
const note_edit_command: th.Command = .{ .name = "edit", .summary = "Edit a note", .handler = noteEditHandler, .args = .{ .min = 4, .positionals = &.{ .{ .name = "deck-id" }, .{ .name = "note-id" }, .{ .name = "fields", .variadic = true } } } };
const note_command: th.Command = .{ .name = "note", .summary = "Manage notes", .children = &.{ &note_add_command, &note_edit_command } };
const notes_command: th.Command = .{ .name = "notes", .summary = "List notes in a deck", .handler = notesHandler, .args = .{ .positionals = &.{.{ .name = "deck-id" }} } };

const card_add_command: th.Command = .{ .name = "add", .summary = "Create a card", .handler = cardAddHandler, .args = .{ .positionals = &.{ .{ .name = "deck-id" }, .{ .name = "question" }, .{ .name = "answer" } } } };
const card_edit_command: th.Command = .{ .name = "edit", .summary = "Edit a card", .handler = cardEditHandler, .args = .{ .positionals = &.{ .{ .name = "card-id" }, .{ .name = "question" }, .{ .name = "answer" } } } };
const card_delete_command: th.Command = .{ .name = "delete", .summary = "Delete a card", .handler = cardDeleteHandler, .args = .{ .positionals = &.{.{ .name = "card-id" }} }, .options = &.{.{ .long = "yes", .summary = "Confirm deletion" }} };
const card_command: th.Command = .{ .name = "card", .summary = "Manage cards", .children = &.{ &card_add_command, &card_edit_command, &card_delete_command } };

const study_command: th.Command = .{ .name = "study", .summary = "Study a deck", .handler = studyHandler, .args = .{ .positionals = &.{.{ .name = "deck-id" }} }, .options = &.{ .{ .long = "new-limit", .kind = .value, .value_type = .integer, .value_name = "count", .summary = "Limit new cards" }, .{ .long = "order", .kind = .value, .value_type = .choice, .value_name = "order", .choices = &.{ "due", "reviews-first", "new-first" }, .summary = "Study queue order" }, .{ .long = "shuffle", .summary = "Shuffle the session" } } };
const stats_command: th.Command = .{ .name = "stats", .summary = "Show study statistics", .handler = statsHandler, .args = .{ .positionals = &.{.{ .name = "deck-id", .required = false }} }, .options = &.{ .{ .long = "period", .kind = .value, .value_type = .choice, .value_name = "period", .choices = &.{ "all", "today", "week", "month", "year" }, .summary = "Historical review window" }, .{ .long = "json", .summary = "Emit JSON" } } };
const inspect_command: th.Command = .{ .name = "inspect", .summary = "Inspect scheduler state", .handler = inspectHandler, .args = .{ .positionals = &.{.{ .name = "card-id" }} }, .options = &.{.{ .long = "json", .summary = "Emit JSON" }} };

const fsrs_optimize_command: th.Command = .{ .name = "optimize", .summary = "Optimize FSRS parameters", .handler = fsrsOptimizeHandler, .args = .{ .positionals = &.{.{ .name = "deck-id", .required = false }} }, .options = &.{.{ .long = "recency", .summary = "Use recency weighting" }} };
const fsrs_evaluate_command: th.Command = .{ .name = "evaluate", .summary = "Evaluate FSRS parameters", .handler = fsrsEvaluateHandler, .args = .{ .positionals = &.{.{ .name = "deck-id", .required = false }} } };
const fsrs_simulate_command: th.Command = .{ .name = "simulate", .summary = "Simulate FSRS retention", .handler = fsrsSimulateHandler, .args = .{ .exact = 0 }, .options = &.{.{ .long = "retention", .kind = .value, .value_type = .float, .value_name = "0..1", .summary = "Desired retention" }} };
const fsrs_retention_command: th.Command = .{ .name = "retention", .summary = "Show current retention", .handler = fsrsRetentionHandler, .args = .{ .exact = 0 } };
const fsrs_command: th.Command = .{ .name = "fsrs", .summary = "FSRS tools", .children = &.{ &fsrs_optimize_command, &fsrs_evaluate_command, &fsrs_simulate_command, &fsrs_retention_command } };
const scheduler_list_command: th.Command = .{ .name = "list", .summary = "List scheduler configuration", .handler = schedulerListHandler, .args = .{ .exact = 0 } };
const scheduler_command: th.Command = .{ .name = "scheduler", .summary = "Inspect scheduler configuration", .children = &.{&scheduler_list_command} };
const media_add_command: th.Command = .{ .name = "add", .summary = "Add a media file", .handler = mediaAddHandler, .args = .{ .positionals = &.{.{ .name = "path" }} } };
const media_command: th.Command = .{ .name = "media", .summary = "Manage media", .children = &.{&media_add_command} };

pub const root_command: th.Command = .{
    .name = "plandalf",
    .summary = "Spaced repetition that arrives precisely when it means to",
    .children = &.{
        &help_command,    &setup_command, &decks_command,     &cards_command, &deck_command,
        &note_command,    &notes_command, &card_command,      &study_command, &stats_command,
        &inspect_command, &fsrs_command,  &scheduler_command, &media_command,
    },
};

fn helpFor(command: *const th.Command) Help {
    if (command == &root_command or command == &help_command or command == &setup_command) return .general;
    if (command == &decks_command or command == &deck_command or command == &deck_add_command or command == &deck_rename_command or command == &deck_delete_command or command == &deck_export_command or command == &deck_import_command) return .{ .core = .deck };
    if (command == &note_command or command == &note_add_command or command == &note_edit_command) return .{ .core = .note };
    if (command == &cards_command or command == &card_command or command == &card_add_command or command == &card_edit_command or command == &card_delete_command) return .{ .core = .card };
    if (command == &study_command) return .{ .core = .study };
    if (command == &stats_command) return .{ .core = .stats };
    if (command == &inspect_command) return .{ .core = .inspect };
    if (command == &fsrs_command or command == &fsrs_optimize_command or command == &fsrs_evaluate_command or command == &fsrs_simulate_command or command == &fsrs_retention_command) return .{ .core = .fsrs };
    if (command == &scheduler_command or command == &scheduler_list_command) return .{ .core = .scheduler };
    if (command == &notes_command) return .notes;
    if (command == &media_command or command == &media_add_command) return .rich;
    return .general;
}

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !Route {
    const args = if (argv.len > 0) argv[1..] else &.{};
    try th.validation.validate(&root_command);
    const selection = switch (th.resolveWithOptions(&root_command, args, .{ .help_tokens = .{ .command = null } })) {
        .help => |selected| return .{ .help = helpFor(selected.command) },
        .unknown => return error.UnknownCommand,
        .execute => |selected| selected,
    };

    var parsed = th.options.parseWithMode(allocator, selection.command.options, selection.args, selection.command.passthrough) catch return error.InvalidArguments;
    defer parsed.deinit();
    if (!selection.command.args.valid(parsed.positionals.len)) return error.InvalidArguments;

    var state: ParseState = .{};
    var stdout_buffer: [1]u8 = undefined;
    var stderr_buffer: [1]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&stdout_buffer);
    var stderr = std.Io.Writer.fixed(&stderr_buffer);
    var command_path = [_]*const th.Command{selection.command};
    var ctx: th.Context = .{
        .allocator = allocator,
        .root = &root_command,
        .command = selection.command,
        .command_path = &command_path,
        .args = parsed.positionals,
        .options = parsed.values,
        .stdout = &stdout,
        .stderr = &stderr,
        .app_state = &state,
    };
    const handler = selection.command.handler orelse return error.UnknownCommand;
    try handler(&ctx);
    return state.route orelse error.UnknownCommand;
}

pub fn errorHelp(argv: []const []const u8) Help {
    if (argv.len < 2) return .general;
    const command = argv[1];
    if (std.mem.eql(u8, command, "notes")) return .notes;
    if (std.mem.eql(u8, command, "media")) return .rich;
    return .general;
}
