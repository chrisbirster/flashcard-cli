const std = @import("std");
const Rating = @import("../rating.zig").Rating;
const model = @import("model.zig");
const Parameters = @import("parameters.zig").Parameters;

pub const RatingModel = struct {
    new_again_probability: f64 = 0.15,
    new_hard_probability: f64 = 0.20,
    new_easy_probability: f64 = 0.15,
    recalled_hard_probability: f64 = 0.15,
    recalled_easy_probability: f64 = 0.15,
};

pub const Config = struct {
    card_count: usize = 100,
    horizon_days: usize = 365,
    new_cards_per_day: usize = 10,
    seconds_per_review: f64 = 12.0,
    seed: u64 = 0x4445455a,
    maximum_reviews: usize = 10_000_000,
    rating_model: RatingModel = .{},
};

pub const Result = struct {
    cards_introduced: usize = 0,
    reviews: usize = 0,
    lapses: usize = 0,
    again_count: usize = 0,
    hard_count: usize = 0,
    good_count: usize = 0,
    easy_count: usize = 0,
    maximum_daily_reviews: usize = 0,
    average_daily_reviews: f64 = 0,
    estimated_study_seconds: f64 = 0,
    average_retrievability_at_horizon: f64 = 0,
    average_stability_days_at_horizon: f64 = 0,
    average_difficulty_at_horizon: f64 = 0,
};

const SimCard = struct {
    available_day: f64,
    due_day: f64,
    last_review_day: f64 = 0,
    state: ?model.MemoryState = null,
};

const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = if (seed == 0) 0x9e3779b97f4a7c15 else seed };
    }

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545f4914f6cdd1d;
    }

    fn unit(self: *Rng) f64 {
        const bits = self.next() >> 11;
        return @as(f64, @floatFromInt(bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }
};

fn validateProbability(value: f64) !void {
    if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidProbability;
}

fn validateConfig(config: Config) !void {
    if (config.card_count == 0) return error.NoCards;
    if (config.horizon_days == 0) return error.InvalidHorizon;
    if (config.new_cards_per_day == 0) return error.InvalidNewCardLimit;
    if (config.seconds_per_review < 0 or !std.math.isFinite(config.seconds_per_review)) return error.InvalidReviewDuration;
    try validateProbability(config.rating_model.new_again_probability);
    try validateProbability(config.rating_model.new_hard_probability);
    try validateProbability(config.rating_model.new_easy_probability);
    if (config.rating_model.new_again_probability + config.rating_model.new_hard_probability + config.rating_model.new_easy_probability > 1) {
        return error.InvalidRatingDistribution;
    }
    try validateProbability(config.rating_model.recalled_hard_probability);
    try validateProbability(config.rating_model.recalled_easy_probability);
    if (config.rating_model.recalled_hard_probability + config.rating_model.recalled_easy_probability > 1) {
        return error.InvalidRatingDistribution;
    }
}

fn initialRating(rng: *Rng, ratings: RatingModel) Rating {
    const roll = rng.unit();
    if (roll < ratings.new_again_probability) return .again;
    if (roll < ratings.new_again_probability + ratings.new_hard_probability) return .hard;
    if (roll < ratings.new_again_probability + ratings.new_hard_probability + ratings.new_easy_probability) return .easy;
    return .good;
}

fn recalledRating(rng: *Rng, ratings: RatingModel) Rating {
    const roll = rng.unit();
    if (roll < ratings.recalled_hard_probability) return .hard;
    if (roll < ratings.recalled_hard_probability + ratings.recalled_easy_probability) return .easy;
    return .good;
}

fn countRating(result: *Result, rating: Rating) void {
    switch (rating) {
        .again => result.again_count += 1,
        .hard => result.hard_count += 1,
        .good => result.good_count += 1,
        .easy => result.easy_count += 1,
    }
}

/// Probabilistic FSRS simulation. Recall/failure is sampled from the FSRS
/// retrievability probability; recalled answers are then split between
/// Hard/Good/Easy according to RatingModel. The supplied seed makes the entire
/// outcome sequence reproducible.
pub fn simulate(
    allocator: std.mem.Allocator,
    parameters: Parameters,
    config: Config,
) !Result {
    try parameters.validate();
    try validateConfig(config);

    var cards = try allocator.alloc(SimCard, config.card_count);
    defer allocator.free(cards);
    var daily_reviews = try allocator.alloc(usize, config.horizon_days + 1);
    defer allocator.free(daily_reviews);
    @memset(daily_reviews, 0);

    for (cards, 0..) |*card, index| {
        const introduction_day = @as(f64, @floatFromInt(index / config.new_cards_per_day));
        card.* = .{ .available_day = introduction_day, .due_day = introduction_day };
    }

    var rng = Rng.init(config.seed);
    var result: Result = .{};
    const horizon = @as(f64, @floatFromInt(config.horizon_days));

    while (result.reviews < config.maximum_reviews) {
        var next_index: ?usize = null;
        var next_day = horizon + 1.0;
        for (cards, 0..) |card, index| {
            if (card.due_day <= horizon and card.due_day < next_day) {
                next_day = card.due_day;
                next_index = index;
            }
        }
        const index = next_index orelse break;
        var card = &cards[index];
        if (card.available_day > horizon) break;

        const rating: Rating = if (card.state) |state| blk: {
            const elapsed_days = @max(0.0, next_day - card.last_review_day);
            const recall_probability = try model.retrievability(elapsed_days, state, parameters);
            if (rng.unit() > recall_probability) {
                result.lapses += 1;
                break :blk .again;
            }
            break :blk recalledRating(&rng, config.rating_model);
        } else blk: {
            result.cards_introduced += 1;
            break :blk initialRating(&rng, config.rating_model);
        };

        const new_state = if (card.state) |state|
            try model.nextMemoryState(state, @max(0.0, next_day - card.last_review_day), rating, parameters)
        else
            model.initialMemoryState(rating, parameters);

        const interval = try model.intervalForRetention(new_state.stability_days, parameters.desired_retention, parameters);
        card.state = new_state;
        card.last_review_day = next_day;
        card.due_day = next_day + interval;
        result.reviews += 1;
        countRating(&result, rating);

        const day_index: usize = @min(@as(usize, @intFromFloat(@floor(next_day))), config.horizon_days);
        daily_reviews[day_index] += 1;
        result.maximum_daily_reviews = @max(result.maximum_daily_reviews, daily_reviews[day_index]);
    }

    if (result.reviews == config.maximum_reviews) return error.MaximumReviewsExceeded;

    var retrievability_sum: f64 = 0;
    var stability_sum: f64 = 0;
    var difficulty_sum: f64 = 0;
    var memory_count: usize = 0;
    for (cards) |card| {
        if (card.state) |state| {
            retrievability_sum += try model.retrievability(@max(0.0, horizon - card.last_review_day), state, parameters);
            stability_sum += state.stability_days;
            difficulty_sum += state.difficulty;
            memory_count += 1;
        }
    }

    result.average_daily_reviews = @as(f64, @floatFromInt(result.reviews)) / @as(f64, @floatFromInt(config.horizon_days));
    result.estimated_study_seconds = @as(f64, @floatFromInt(result.reviews)) * config.seconds_per_review;
    if (memory_count > 0) {
        const divisor: f64 = @floatFromInt(memory_count);
        result.average_retrievability_at_horizon = retrievability_sum / divisor;
        result.average_stability_days_at_horizon = stability_sum / divisor;
        result.average_difficulty_at_horizon = difficulty_sum / divisor;
    }
    return result;
}

test "simulation is deterministic" {
    const config: Config = .{
        .card_count = 20,
        .horizon_days = 30,
        .new_cards_per_day = 5,
        .seed = 1234,
    };
    const first = try simulate(std.testing.allocator, .{}, config);
    const second = try simulate(std.testing.allocator, .{}, config);
    try std.testing.expectEqual(first.reviews, second.reviews);
    try std.testing.expectEqual(first.lapses, second.lapses);
    try std.testing.expectApproxEqAbs(first.average_retrievability_at_horizon, second.average_retrievability_at_horizon, 1e-12);
    try std.testing.expectApproxEqAbs(first.average_stability_days_at_horizon, second.average_stability_days_at_horizon, 1e-12);
    try std.testing.expectApproxEqAbs(first.average_difficulty_at_horizon, second.average_difficulty_at_horizon, 1e-12);
}

test "simulation exposes finite memory state at the horizon" {
    const result = try simulate(std.testing.allocator, .{}, .{ .card_count = 4, .horizon_days = 10, .new_cards_per_day = 4, .seed = 99 });
    try std.testing.expect(result.average_stability_days_at_horizon > 0);
    try std.testing.expect(result.average_difficulty_at_horizon >= 1 and result.average_difficulty_at_horizon <= 10);
}

test "higher desired retention costs more reviews" {
    const config: Config = .{ .card_count = 20, .horizon_days = 60, .new_cards_per_day = 5, .seed = 7 };
    var lower: Parameters = .{};
    lower.desired_retention = 0.85;
    var higher: Parameters = .{};
    higher.desired_retention = 0.95;
    const low_result = try simulate(std.testing.allocator, lower, config);
    const high_result = try simulate(std.testing.allocator, higher, config);
    try std.testing.expect(high_result.reviews >= low_result.reviews);
}
