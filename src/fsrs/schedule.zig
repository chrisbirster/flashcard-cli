const Rating = @import("rating.zig").Rating;
const TimestampMs = @import("../time.zig").TimestampMs;

pub const Candidate = struct {
    rating: Rating,
    due_at_ms: TimestampMs,
    interval_days: f64,
};

pub const Schedule = struct {
    again: Candidate,
    hard: Candidate,
    good: Candidate,
    easy: Candidate,

    pub fn forRating(self: Schedule, rating: Rating) Candidate {
        return switch (rating) {
            .again => self.again,
            .hard => self.hard,
            .good => self.good,
            .easy => self.easy,
        };
    }
};
