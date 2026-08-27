const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const storage = @import("storage/root.zig");
const interchange = @import("interchange_mongodb.zig");

const max_archive_bytes: usize = 256 * 1024 * 1024;

pub const help_text =
    \\Backup and restore commands:
    \\  deez backup [deck-id] > deez.backup
    \\  deez restore --dry-run < deez.backup
    \\  deez restore --yes < deez.backup
    \\
    \\Backup and restore target the configured MongoDB backend. Dry-run validates
    \\an archive without connecting to MongoDB or mutating persistent data.
;

const Command = union(enum) {
    help,
    backup: ?u64,
    restore_dry_run,
    restore,
};

fn isHelp(text: []const u8) bool {
    return std.mem.eql(u8, text, "--help") or std.mem.eql(u8, text, "-h");
}

fn parseId(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidId;
}

fn parse(args: []const []const u8) !Command {
    if (args.len < 2) return error.InvalidArguments;

    if (std.mem.eql(u8, args[1], "backup")) {
        if (args.len == 2) return .{ .backup = null };
        if (args.len == 3 and isHelp(args[2])) return .help;
        if (args.len == 3) return .{ .backup = try parseId(args[2]) };
        return error.InvalidArguments;
    }

    if (std.mem.eql(u8, args[1], "restore")) {
        if (args.len == 3 and isHelp(args[2])) return .help;
        if (args.len == 3 and std.mem.eql(u8, args[2], "--dry-run")) return .restore_dry_run;
        if (args.len == 3 and std.mem.eql(u8, args[2], "--yes")) return .restore;
        return error.ConfirmationRequired;
    }

    return error.UnknownCommand;
}

pub fn isCommand(args: []const []const u8) bool {
    if (args.len < 2) return false;
    return std.mem.eql(u8, args[1], "backup") or std.mem.eql(u8, args[1], "restore");
}

fn openMongoStore(init: std.process.Init) !storage.Store {
    const selection = try config.resolve(init);
    if (selection.backend != .mongodb) return error.MongoBackendRequired;
    const mongo = try storage.MongoStore.connect(init.io, init.gpa, selection.mongo_uri.?);
    return .{ .mongodb = mongo };
}

fn readArchive(init: std.process.Init) ![]u8 {
    var stdin_reader = Io.File.stdin().reader(init.io, &.{});
    return stdin_reader.interface.allocRemaining(init.gpa, .limited(max_archive_bytes));
}

fn printReport(out: *Io.Writer, report: interchange.DryRunReport) !void {
    try out.print(
        "parameter_sets={d} groups={d} decks={d} cards={d} reviews={d} unsupported={d}\n",
        .{
            report.parameter_sets,
            report.groups,
            report.decks,
            report.cards,
            report.reviews,
            report.unsupported_records,
        },
    );
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const command = try parse(args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    switch (command) {
        .help => try out.writeAll(help_text),
        .backup => |deck_id| {
            var store = try openMongoStore(init);
            defer store.deinit();
            try interchange.exportArchive(&store, out, .{ .deck_id = deck_id });
        },
        .restore_dry_run => {
            const archive = try readArchive(init);
            defer init.gpa.free(archive);
            try printReport(out, try interchange.dryRun(init.gpa, archive));
        },
        .restore => {
            const archive = try readArchive(init);
            defer init.gpa.free(archive);
            var store = try openMongoStore(init);
            defer store.deinit();
            try printReport(out, try interchange.importArchive(init.gpa, &store, archive));
        },
    }
}

test "backup CLI parses full and selected-deck exports" {
    const all_args = [_][]const u8{ "deez", "backup" };
    const all = try parse(&all_args);
    try std.testing.expectEqual(@as(?u64, null), all.backup);

    const deck_args = [_][]const u8{ "deez", "backup", "42" };
    const selected = try parse(&deck_args);
    try std.testing.expectEqual(@as(?u64, 42), selected.backup);
}

test "restore CLI requires explicit dry-run or confirmation" {
    const dry_args = [_][]const u8{ "deez", "restore", "--dry-run" };
    try std.testing.expect((try parse(&dry_args)) == .restore_dry_run);

    const restore_args = [_][]const u8{ "deez", "restore", "--yes" };
    try std.testing.expect((try parse(&restore_args)) == .restore);

    const unsafe_args = [_][]const u8{ "deez", "restore" };
    try std.testing.expectError(error.ConfirmationRequired, parse(&unsafe_args));
}

test "backup CLI rejects malformed deck IDs" {
    const args = [_][]const u8{ "deez", "backup", "nope" };
    try std.testing.expectError(error.InvalidId, parse(&args));
}
