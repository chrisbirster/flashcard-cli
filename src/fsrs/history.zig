const Rating = @import("rating.zig").Rating;
const TimestampMs = @import("../time.zig").TimestampMs;

pub const Entry = struct {
    rating: Rating,
    reviewed_at_ms: TimestampMs,
};
