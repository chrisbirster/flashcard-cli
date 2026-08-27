const std = @import("std");
const Io = std.Io;
const plandalf = @import("plandalf");

fn writeHelp(out: *Io.Writer, target: plandalf.thrawn_cli.Help) !void {
    switch (target) {
        .general => try out.print("{s}\n{s}\n{s}\n{s}\n{s}", .{
            plandalf.cli.help_text,
            plandalf.notes_cli.help_text,
            plandalf.rich_cli.help_text,
            plandalf.web_cli.help_text,
            plandalf.server.help_text,
        }),
        .core => |topic| try out.writeAll(plandalf.cli.helpText(topic)),
        .notes => try out.writeAll(plandalf.notes_cli.help_text),
        .rich => try out.writeAll(plandalf.rich_cli.help_text),
    }
}

fn printErrorAndExit(init: std.process.Init, err: anyerror, help: plandalf.thrawn_cli.Help) noreturn {
    var stderr_buffer: [16384]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    stderr.print("plandalf: {s}\n\n", .{@errorName(err)}) catch {};
    writeHelp(stderr, help) catch {};
    stderr.flush() catch {};
    std.process.exit(2);
}

fn printRawErrorAndExit(init: std.process.Init, err: anyerror, help: []const u8) noreturn {
    var stderr_buffer: [16384]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    stderr.print("plandalf: {s}\n\n{s}", .{ @errorName(err), help }) catch {};
    stderr.flush() catch {};
    std.process.exit(2);
}

fn printHelp(init: std.process.Init, help: plandalf.thrawn_cli.Help) !void {
    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};
    try writeHelp(out, help);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| args[index] = arg;

    if (plandalf.server.isCommand(args)) {
        plandalf.server.runCommand(init, args) catch |err|
            printRawErrorAndExit(init, err, plandalf.server.help_text);
        return;
    }

    if (plandalf.web_cli.isCommand(args)) {
        plandalf.web_cli.run(init, args) catch |err| {
            switch (err) {
                error.InvalidArguments, error.InvalidPort => printRawErrorAndExit(init, err, plandalf.web_cli.help_text),
                else => return err,
            }
        };
        return;
    }

    var route = plandalf.thrawn_cli.parse(arena, args) catch |err| {
        printErrorAndExit(init, err, plandalf.thrawn_cli.errorHelp(args));
    };
    defer route.deinit(arena);

    switch (route) {
        .help => |help| try printHelp(init, help),
        .setup => try plandalf.config.setup(init),
        .core => |command| try plandalf.app.run(init, command),
        .notes_cli => {
            plandalf.notes_cli.run(init, args) catch |err| {
                switch (err) {
                    error.InvalidArguments, error.InvalidId => printErrorAndExit(init, err, .notes),
                    else => return err,
                }
            };
        },
        .rich_cli => {
            plandalf.rich_cli.run(init, args) catch |err| {
                switch (err) {
                    error.InvalidArguments => printErrorAndExit(init, err, .rich),
                    else => return err,
                }
            };
        },
    }
}

test {
    std.testing.refAllDecls(plandalf);
}
