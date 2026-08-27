const std = @import("std");
const Io = std.Io;
const deez = @import("deez");

fn elapsedNs(io: Io, start: Io.Timestamp) i96 {
    return start.durationTo(Io.Timestamp.now(io, .awake)).toNanoseconds();
}

fn makeHistory(allocator: std.mem.Allocator, count: usize) ![]deez.fsrs.HistoryEntry {
    const history = try allocator.alloc(deez.fsrs.HistoryEntry, count);
    const day = deez.time.milliseconds_per_day;
    for (history, 0..) |*entry, index| {
        entry.* = .{
            .rating = switch (index % 7) {
                0 => .again,
                1, 2 => .hard,
                6 => .easy,
                else => .good,
            },
            .reviewed_at_ms = @as(i64, @intCast(index)) * day,
        };
    }
    return history;
}

fn cpuBenchmarks(allocator: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const history = try makeHistory(allocator, 1_000);
    defer allocator.free(history);
    const engine = deez.fsrs.v7.Engine{};
    const now_ms = history[history.len - 1].reviewed_at_ms + deez.time.milliseconds_per_day;

    var start = Io.Timestamp.now(io, .awake);
    for (0..100) |_| _ = try engine.schedule(history, now_ms);
    try out.print("schedule_100_long_history_ns={d}\n", .{elapsedNs(io, start)});

    start = Io.Timestamp.now(io, .awake);
    for (0..100) |_| _ = try engine.replay(history);
    try out.print("replay_100x_1000_reviews_ns={d}\n", .{elapsedNs(io, start)});

    const training_history = history[0..80];
    const histories = [_][]const deez.fsrs.HistoryEntry{training_history};
    start = Io.Timestamp.now(io, .awake);
    const optimized = try deez.fsrs.v7.optimizer.optimize(&histories, .{}, .{
        .epochs = 1,
        .minimum_examples = 20,
        .learning_rate = 0.001,
        .seed = 1,
    });
    try out.print("optimize_79_examples_1_epoch_ns={d} final_loss={d:.8}\n", .{
        elapsedNs(io, start),
        optimized.final_log_loss,
    });

    var archive_buffer: [256 * 1024]u8 = undefined;
    var archive_writer = Io.Writer.fixed(&archive_buffer);
    try archive_writer.writeAll("DEEZ\t1\n");
    for (0..1_000) |index| {
        try archive_writer.print("CARD\t{d}\t1\t71\t61\t{d}\n", .{ index + 1, index });
    }
    const archive = archive_writer.buffered();
    start = Io.Timestamp.now(io, .awake);
    for (0..100) |_| _ = try deez.interchange_mongodb.dryRun(allocator, archive);
    try out.print("archive_dry_run_100x_1000_cards_ns={d}\n", .{elapsedNs(io, start)});
}

fn mongoBenchmarks(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    uri: []const u8,
) !void {
    const mongo = try deez.storage.MongoStore.connect(io, allocator, uri);
    var store: deez.storage.Store = .{ .mongodb = mongo };
    defer store.deinit();

    const deck_id = try store.createDeck("deez-benchmark", 0);
    defer store.deleteDeck(deck_id) catch {};
    for (0..1_000) |index| {
        const question = try std.fmt.allocPrint(allocator, "q-{d}", .{index});
        defer allocator.free(question);
        _ = try store.createCard(deck_id, question, "a", @intCast(index));
    }

    const start = Io.Timestamp.now(io, .awake);
    for (0..25) |_| {
        const cards = try store.dueCards(allocator, deck_id, std.math.maxInt(i64), 1_000);
        defer {
            for (cards) |card| card.deinit(allocator);
            allocator.free(cards);
        }
        if (cards.len != 1_000) return error.UnexpectedDueCount;
    }
    try out.print("mongo_due_queue_25x_1000_cards_ns={d}\n", .{elapsedNs(io, start)});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &file_writer.interface;

    try out.writeAll("deez benchmark format=1\n");
    try cpuBenchmarks(allocator, io, out);
    if (init.environ_map.get("DEEZ_MONGO_BENCH_URI")) |uri| {
        try mongoBenchmarks(allocator, io, out, uri);
    } else {
        try out.writeAll("mongo_due_queue=skipped set DEEZ_MONGO_BENCH_URI\n");
    }
    try out.flush();
}
