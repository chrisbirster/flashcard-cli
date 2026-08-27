const CardId = @import("card.zig").CardId;
const Rating = @import("fsrs/rating.zig").Rating;
const SchedulerStamp = @import("fsrs/algorithm.zig").SchedulerStamp;
const TimestampMs = @import("time.zig").TimestampMs;

pub const ReviewId = u64;

pub const Review = struct {
    id: ReviewId,
    card_id: CardId,
    rating: Rating,
    reviewed_at_ms: TimestampMs,
    scheduler: ?SchedulerStamp = null,
};
