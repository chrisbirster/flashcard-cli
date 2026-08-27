const std = @import("std");
const Engine = @import("engine.zig").Engine;
const HistoryEntry = @import("history.zig").Entry;
const Schedule = @import("schedule.zig").Schedule;
const TimestampMs = @import("../time.zig").TimestampMs;
const time = @import("../time.zig");
const v7 = @import("v7/root.zig");

pub const EngineMetrics = struct {
    retrievability: ?f64 = null,
    evaluation: ?v7.evaluator.Metrics = null,
    projected_workload: ?v7.simulator.Result = null,
    unsupported_reason: ?[]const u8 = null,
};

pub const Comparison = struct {
    source_algorithm: @import("algorithm.zig").AlgorithmId,
    target_algorithm: @import("algorithm.zig").AlgorithmId,
    source: Schedule,
    target: Schedule,
    source_metrics: EngineMetrics = .{},
    target_metrics: EngineMetrics = .{},
};

pub const DetailedOptions = struct {
    simulation: ?v7.simulator.Config = null,
    evaluation: v7.evaluator.Options = .{},
};

pub fn compare(
    source_engine: Engine,
    target_engine: Engine,
    history: []const HistoryEntry,
    now_ms: TimestampMs,
) !Comparison {
    return .{
        .source_algorithm = source_engine.algorithm(),
        .target_algorithm = target_engine.algorithm(),
        .source = try source_engine.schedule(history, now_ms),
        .target = try target_engine.schedule(history, now_ms),
    };
}

fn fsrs7Metrics(
    engine: v7.Engine,
    history: []const HistoryEntry,
    now_ms: TimestampMs,
    options: DetailedOptions,
) !EngineMetrics {
    var result: EngineMetrics = .{};
    if (try engine.replay(history)) |replayed| {
        if (now_ms < replayed.last_reviewed_at_ms) return error.NowBeforeLastReview;
        const elapsed_days = time.millisecondsToDays(now_ms - replayed.last_reviewed_at_ms);
        result.retrievability = try v7.model.retrievability(elapsed_days, replayed.memory, engine.parameters);
    }
    const histories = [_][]const HistoryEntry{history};
    result.evaluation = try v7.evaluator.evaluate(&histories, engine.parameters, options.evaluation);
    if (options.simulation) |simulation| {
        result.projected_workload = try v7.simulator.simulate(std.heap.page_allocator, engine.parameters, simulation);
    }
    return result;
}

fn metricsFor(
    engine: Engine,
    history: []const HistoryEntry,
    now_ms: TimestampMs,
    options: DetailedOptions,
) !EngineMetrics {
    return switch (engine) {
        .fsrs7 => |value| fsrs7Metrics(value, history, now_ms, options),
        .fixture => .{ .unsupported_reason = "engine exposes scheduling/replay fixture only" },
    };
}

pub fn compareDetailed(
    source_engine: Engine,
    target_engine: Engine,
    history: []const HistoryEntry,
    now_ms: TimestampMs,
    options: DetailedOptions,
) !Comparison {
    var result = try compare(source_engine, target_engine, history, now_ms);
    result.source_metrics = try metricsFor(source_engine, history, now_ms, options);
    result.target_metrics = try metricsFor(target_engine, history, now_ms, options);
    return result;
}

test "comparison is side-effect free and reflects parameter differences" {
    var high_retention: v7.Parameters = .{};
    high_retention.desired_retention = 0.95;

    const source = Engine.defaultFsrs7();
    const target = try Engine.fsrs7With(high_retention);
    const result = try compare(source, target, &.{}, 0);

    try std.testing.expect(result.source_algorithm.eql(.fsrs7));
    try std.testing.expect(result.target_algorithm.eql(.fsrs7));
    try std.testing.expect(result.target.good.interval_days < result.source.good.interval_days);
}

test "detailed comparison reports supported and unsupported engine metrics" {
    const engine_mod = @import("engine.zig");
    const day = time.milliseconds_per_day;
    const history = [_]HistoryEntry{
        .{ .rating = .good, .reviewed_at_ms = 0 },
        .{ .rating = .good, .reviewed_at_ms = 3 * day },
    };
    const result = try compareDetailed(
        Engine.defaultFsrs7(),
        try Engine.fixtureForTesting(),
        &history,
        4 * day,
        .{ .simulation = .{ .card_count = 3, .horizon_days = 7, .new_cards_per_day = 3, .seed = 1 } },
    );
    try std.testing.expect(result.source_metrics.retrievability != null);
    try std.testing.expect(result.source_metrics.evaluation != null);
    try std.testing.expect(result.source_metrics.projected_workload != null);
    try std.testing.expect(result.target_algorithm.eql(engine_mod.fixture_algorithm));
    try std.testing.expect(result.target_metrics.unsupported_reason != null);
}
