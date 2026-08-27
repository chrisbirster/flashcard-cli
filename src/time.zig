const std = @import("std");

pub const TimestampMs = i64;
pub const DurationMs = i64;

pub const milliseconds_per_second: i64 = 1_000;
pub const milliseconds_per_minute: i64 = 60 * milliseconds_per_second;
pub const milliseconds_per_hour: i64 = 60 * milliseconds_per_minute;
pub const milliseconds_per_day: i64 = 24 * milliseconds_per_hour;

pub fn millisecondsToDays(milliseconds: i64) f64 {
    return @as(f64, @floatFromInt(milliseconds)) / @as(f64, @floatFromInt(milliseconds_per_day));
}

pub fn daysToMilliseconds(days: f64) i64 {
    return @intFromFloat(@round(days * @as(f64, @floatFromInt(milliseconds_per_day))));
}

test "time conversions preserve fractional days" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), millisecondsToDays(6 * milliseconds_per_hour), 1e-12);
    try std.testing.expectEqual(6 * milliseconds_per_hour, daysToMilliseconds(0.25));
}
