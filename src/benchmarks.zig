const std = @import("std");
const Io = std.Io;
const plandalf = @import("plandalf");

fn elapsedNs(io: Io, start: Io.Timestamp) i96 {
    return start.durationTo(Io.Timestamp.now(io, .awake)).toNanoseconds();
}

fn makeHistory(allocator: std.mem.Allocator, count: usize) ![]plandalf.fsrs.HistoryEntry {
    const history = try allocator.alloc(plandalf.fsrs.HistoryEntry, count);
    const day = plandalf.time.milliseconds_per_day;
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
    const engine = plandalf.fsrs.v7.Engine{};
    const now_ms = history[history.len - 1].reviewed_at_ms + plandalf.time.milliseconds_per_day;

    var start = Io.Timestamp.now(io, .awake);
    for (0..100) |_| _ = try engine.schedule(history, now_ms);
    try out.print("schedule_100_long_history_ns={d}\n", .{elapsedNs(io, start)});

    start = Io.Timestamp.now(io, .awake);
    for (0..100) |_| _ = try engine.replay(history);
    try out.print("replay_100x_1000_reviews_ns={d}\n", .{elapsedNs(io, start)});

    const training_history = history[0..80];
    const histories = [_][]const plandalf.fsrs.HistoryEntry{training_history};
    start = Io.Timestamp.now(io, .awake);
    const optimized = try plandalf.fsrs.v7.optimizer.optimize(&histories, .{}, .{
        .epochs = 1,
        .minimum_examples = 20,
        .learning_rate = 0.001,
        .seed = 1,
    });
    try out.print("optimize_79_examples_1_epoch_ns={d} final_loss={d:.8}\n", .{
        elapsedNs(io, start),
        optimized.final_log_loss,
    });
}

fn deckBenchmarks(allocator: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    var source: Io.Writer.Allocating = .init(allocator);
    defer source.deinit();
    try source.writer.writeAll("{\"kind\":\"deck\",\"format\":\"plandalf.deck\",\"version\":1,\"name\":\"Benchmark\"}\n");
    for (0..1_000) |index| {
        try source.writer.print(
            "{{\"kind\":\"card\",\"question\":\"q-{d}\",\"answer\":\"a-{d}\"}}\n",
            .{ index, index },
        );
    }

    var db = try plandalf.storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: plandalf.storage.Store = .{ .sqlite = &db };

    const start = Io.Timestamp.now(io, .awake);
    for (0..10) |index| {
        const imported = try plandalf.deck_file.importSlice(
            allocator,
            &store,
            source.written(),
            @intCast(index),
        );
        if (imported.card_count != 1_000) return error.UnexpectedCardCount;
        try store.deleteDeck(imported.deck_id);
    }
    try out.print("deck_import_10x_1000_cards_ns={d}\n", .{elapsedNs(io, start)});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &file_writer.interface;

    try out.writeAll("plandalf benchmark format=1\n");
    try cpuBenchmarks(allocator, io, out);
    try deckBenchmarks(allocator, io, out);
    try out.flush();
}
