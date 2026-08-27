const std = @import("std");
const cli_tree = @import("cli_tree.zig");

test "note add variadic fields are owned independently of caller argv" {
    var note_type_buf = [_]u8{ 'r', 'e', 'v', 'e', 'r', 's', 'e' };
    var front_buf = [_]u8{ 'F', 'r', 'a', 'n', 'c', 'e' };
    var back_buf = [_]u8{ 'P', 'a', 'r', 'i', 's' };
    const args = [_][]const u8{
        "deez",
        "note",
        "add",
        "3",
        note_type_buf[0..],
        front_buf[0..],
        back_buf[0..],
    };

    var route = try cli_tree.parse(std.testing.allocator, &args);
    defer route.deinit(std.testing.allocator);
    const note = route.core.note_add;

    try std.testing.expectEqual(@as(usize, 2), note.fields.len);
    try std.testing.expect(note.note_type.ptr != args[4].ptr);
    try std.testing.expect(note.fields.ptr != args[5..].ptr);
    try std.testing.expect(note.fields[0].ptr != args[5].ptr);
    try std.testing.expect(note.fields[1].ptr != args[6].ptr);

    note_type_buf[0] = 'X';
    front_buf[0] = 'Y';
    back_buf[0] = 'Z';

    try std.testing.expectEqualStrings("reverse", note.note_type);
    try std.testing.expectEqualStrings("France", note.fields[0]);
    try std.testing.expectEqualStrings("Paris", note.fields[1]);
}

test "note edit variadic fields are owned independently of caller argv" {
    var front_buf = [_]u8{ 'F', 'r', 'a', 'n', 'c', 'e' };
    var back_buf = [_]u8{ 'P', 'a', 'r', 'i', 's' };
    const args = [_][]const u8{
        "deez",
        "note",
        "edit",
        "3",
        "9",
        front_buf[0..],
        back_buf[0..],
    };

    var route = try cli_tree.parse(std.testing.allocator, &args);
    defer route.deinit(std.testing.allocator);
    const fields = route.core.note_edit.fields;

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields.ptr != args[5..].ptr);
    try std.testing.expect(fields[0].ptr != args[5].ptr);
    try std.testing.expect(fields[1].ptr != args[6].ptr);

    front_buf[0] = 'Y';
    back_buf[0] = 'Z';

    try std.testing.expectEqualStrings("France", fields[0]);
    try std.testing.expectEqualStrings("Paris", fields[1]);
}
