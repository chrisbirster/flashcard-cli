const std = @import("std");

pub const Rating = enum(u8) {
    again = 1,
    hard = 2,
    good = 3,
    easy = 4,

    pub fn value(self: Rating) u8 {
        return @intFromEnum(self);
    }

    pub fn fromValue(raw_value: u8) !Rating {
        return switch (raw_value) {
            1 => .again,
            2 => .hard,
            3 => .good,
            4 => .easy,
            else => error.InvalidRating,
        };
    }
};

test "ratings map to FSRS grades" {
    try std.testing.expectEqual(@as(u8, 1), Rating.again.value());
    try std.testing.expectEqual(Rating.easy, try Rating.fromValue(4));
    try std.testing.expectError(error.InvalidRating, Rating.fromValue(0));
}
