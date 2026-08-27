const std = @import("std");
const builtin = @import("builtin");

pub fn openDefault(io: std.Io, url: []const u8) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .linux => &.{ "xdg-open", url },
        .windows => &.{ "cmd.exe", "/C", "start", "", url },
        else => return error.UnsupportedBrowserOpenPlatform,
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.BrowserOpenFailed;
}
