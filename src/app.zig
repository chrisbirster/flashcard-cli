const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const config = @import("config.zig");
const content = @import("content.zig");
const card_types = @import("card_types.zig");
const deck_file = @import("deck_file.zig");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const study_mod = @import("study.zig");

fn nowMs(io: Io) i64 {
    const seconds = Io.Timestamp.now(io, .real).toSeconds();
    return seconds * 1_000;
}

fn printInterval(out: *Io.Writer, days: f64) !void {
    if (days < 1.0 / 24.0) {
        try out.print("{d:.1}m", .{days * 24.0 * 60.0});
    } else if (days < 1.0) {
        try out.print("{d:.1}h", .{days * 24.0});
    } else {
        try out.print("{d:.1}d", .{days});
    }
}

fn readByte(io: Io) !u8 {
    var buffer: [1]u8 = undefined;
    var buffers = [_][]u8{buffer[0..]};
    while (true) {
        const read = try Io.File.stdin().readStreaming(io, &buffers);
        if (read == 0) return error.EndOfStream;
        return buffer[0];
    }
}

fn waitForEnter(io: Io) !void {
    while (try readByte(io) != '\n') {}
}

fn readRating(io: Io) !fsrs.Rating {
    while (true) {
        const byte = try readByte(io);
        if (byte >= '1' and byte <= '4') {
            while (try readByte(io) != '\n') {}
            return fsrs.Rating.fromValue(byte - '0');
        }
    }
}

fn historyViews(
    allocator: std.mem.Allocator,
    owned: storage.OwnedHistories,
) ![]const []const fsrs.HistoryEntry {
    const views = try allocator.alloc([]const fsrs.HistoryEntry, owned.histories.len);
    for (owned.histories, 0..) |history, index| views[index] = history;
    return views;
}

fn baseParameters(store: *storage.Store, deck_id: ?u64, now_ms: i64) !fsrs.v7.Parameters {
    if (deck_id) |id| {
        const resolved = try store.resolveDeckScheduler(id, now_ms);
        if (!resolved.algorithm.eql(.fsrs7)) return error.UnsupportedAlgorithm;
        return store.loadFsrs7Parameters(resolved.parameter_set_id);
    }
    return .{};
}

fn studyDeck(
    allocator: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    study: study_mod.Study,
    deck_id: u64,
    options: study_mod.SessionOptions,
) !void {
    var session = study_mod.Session.init(study, deck_id, options);
    while (true) {
        const maybe_card = try session.next(allocator, nowMs(io));
        if (maybe_card == null) break;
        const card = maybe_card.?;
        defer card.deinit(allocator);

        try out.print("\n{s}\n\nPress Enter to reveal...", .{card.question});
        try out.flush();
        try waitForEnter(io);

        const preview = try study.preview(allocator, card.id, nowMs(io));
        try out.print("\n{s}\n\n1 Again  ", .{card.answer});
        try printInterval(out, preview.schedule.again.interval_days);
        try out.print("\n2 Hard   ", .{});
        try printInterval(out, preview.schedule.hard.interval_days);
        try out.print("\n3 Good   ", .{});
        try printInterval(out, preview.schedule.good.interval_days);
        try out.print("\n4 Easy   ", .{});
        try printInterval(out, preview.schedule.easy.interval_days);
        try out.print("\n\n> ", .{});
        try out.flush();

        const rating = try readRating(io);
        const reviewed_at_ms = nowMs(io);
        const result = try study.recordReview(allocator, card.id, rating, reviewed_at_ms);
        try out.print("scheduled in ", .{});
        try printInterval(out, result.candidate.interval_days);
        try out.print("\n", .{});
        try out.flush();
    }
}

pub fn run(init: std.process.Init, command: cli.Command) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const selection = try config.resolve(init);
    const db_path_z = try arena.dupeZ(u8, selection.sqlite_path);
    var db = try storage.Db.open(db_path_z);
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    return runWithStore(allocator, io, command, &store);
}

fn runWithStore(
    allocator: std.mem.Allocator,
    io: Io,
    command: cli.Command,
    store: *storage.Store,
) !void {
    const study = study_mod.Study.init(store);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    defer out.flush() catch {};

    const now_ms = nowMs(io);
    switch (command) {
        .help => |topic| try out.print("{s}", .{cli.helpText(topic)}),
        .decks => {
            const decks = try store.decks(allocator, now_ms);
            defer {
                for (decks) |deck| deck.deinit(allocator);
                allocator.free(decks);
            }
            try out.print("ID  NAME  CARDS  DUE\n", .{});
            for (decks) |deck| try out.print("{d}  {s}  {d}  {d}\n", .{ deck.id, deck.name, deck.card_count, deck.due_count });
        },
        .cards => |args| {
            const cards = try store.cards(allocator, args.deck_id);
            defer {
                for (cards) |card| card.deinit(allocator);
                allocator.free(cards);
            }
            try out.print("ID  QUESTION\n", .{});
            for (cards) |card| try out.print("{d}  {s}\n", .{ card.id, card.question });
        },
        .deck_add => |args| {
            const id = try store.createDeck(args.name, now_ms);
            _ = try store.ensureDefaultFsrs7(now_ms);
            try out.print("Created deck {d}: {s}\n", .{ id, args.name });
        },
        .deck_rename => |args| {
            try store.renameDeck(args.deck_id, args.name);
            try out.print("Renamed deck {d}.\n", .{args.deck_id});
        },
        .deck_delete => |args| {
            try store.deleteDeck(args.deck_id);
            try out.print("Deleted deck {d}.\n", .{args.deck_id});
        },
        .deck_export => |args| try deck_file.exportDeck(allocator, store, args.deck_id, out),
        .deck_import => |args| {
            const bytes = try Io.Dir.cwd().readFileAlloc(io, args.path, allocator, .limited(64 * 1024 * 1024));
            defer allocator.free(bytes);
            const result = try deck_file.importSlice(allocator, store, bytes, now_ms);
            try out.print("Imported deck {d} ({d} cards).\n", .{ result.deck_id, result.card_count });
        },
        .note_add => |args| {
            const kind = try content.BuiltInNoteType.parse(args.note_type);
            const result = try card_types.create(allocator, store, args.deck_id, kind, args.fields, "[]", now_ms);
            defer result.deinit(allocator);
            try out.print("Created note {d} ({d} cards).\n", .{ result.note_id, result.card_ids.len });
        },
        .note_edit => |args| {
            const ids = try card_types.update(allocator, store, args.deck_id, args.note_id, args.fields, "[]", now_ms);
            defer allocator.free(ids);
            try out.print("Updated note {d} ({d} cards).\n", .{ args.note_id, ids.len });
        },
        .card_add => |args| {
            const id = try store.createCard(args.deck_id, args.question, args.answer, now_ms);
            try out.print("Created card {d}.\n", .{id});
        },
        .card_edit => |args| {
            try store.updateCard(args.card_id, args.question, args.answer);
            try out.print("Updated card {d}.\n", .{args.card_id});
        },
        .card_delete => |args| {
            try store.deleteCard(args.card_id);
            try out.print("Deleted card {d}.\n", .{args.card_id});
        },
        .study => |args| try studyDeck(allocator, io, out, study, args.deck_id, .{
            .new_limit = args.new_limit,
            .review_order = switch (args.order) {
                .due => .due,
                .reviews_first => .reviews_first,
                .new_first => .new_first,
            },
            .shuffle_seed = if (args.shuffle) @as(u64, @bitCast(now_ms)) else null,
        }),
        .stats => |args| {
            const stats = try store.stats(now_ms, args.deck_id);
            if (args.json) {
                try out.print("{{\"decks\":{d},\"cards\":{d},\"due\":{d},\"reviews\":{d}}}\n", .{
                    stats.deck_count,
                    stats.card_count,
                    stats.due_count,
                    stats.review_count,
                });
            } else {
                try out.print("Decks: {d}\nCards: {d}\nDue: {d}\nReviews: {d}\n", .{
                    stats.deck_count,
                    stats.card_count,
                    stats.due_count,
                    stats.review_count,
                });
            }
        },
        .inspect => |args| {
            const preview = try study.preview(allocator, args.card_id, now_ms);
            const state = try store.getSchedulerState(args.card_id);
            const parameters = try store.loadFsrs7Parameters(preview.parameter_set_id);
            const implementation = fsrs.ImplementationVersion.current;
            if (args.json) {
                try out.print(
                    "{{\"card_id\":{d},\"scheduler\":\"fsrs/{d}\",\"implementation\":\"{d}.{d}.{d}\",\"desired_retention\":{d},\"parameter_set\":\"{x}\",",
                    .{
                        args.card_id,
                        preview.algorithm.major,
                        implementation.major,
                        implementation.minor,
                        implementation.patch,
                        parameters.desired_retention,
                        preview.parameter_set_id,
                    },
                );
                if (preview.retrievability) |value| {
                    try out.print("\"retrievability\":{d},", .{value});
                } else try out.print("\"retrievability\":null,", .{});
                if (state) |stored| {
                    if (stored.stability_days) |value| try out.print("\"stability_days\":{d},", .{value}) else try out.print("\"stability_days\":null,", .{});
                    if (stored.difficulty) |value| try out.print("\"difficulty\":{d},", .{value}) else try out.print("\"difficulty\":null,", .{});
                    try out.print("\"due_at_ms\":{d}}}\n", .{stored.due_at_ms});
                } else {
                    try out.print("\"stability_days\":null,\"difficulty\":null,\"due_at_ms\":null}}\n", .{});
                }
            } else {
                try out.print(
                    "Card: {d}\nScheduler: FSRS-{d}\nImplementation: {d}.{d}.{d}\nDesired retention: {d:.2}%\nParameter set: {x}\n",
                    .{
                        args.card_id,
                        preview.algorithm.major,
                        implementation.major,
                        implementation.minor,
                        implementation.patch,
                        parameters.desired_retention * 100.0,
                        preview.parameter_set_id,
                    },
                );
                if (preview.retrievability) |value| try out.print("Retrievability: {d:.2}%\n", .{value * 100.0});
                if (state) |stored| {
                    if (stored.stability_days) |value| try out.print("Stability: {d:.3} days\n", .{value});
                    if (stored.difficulty) |value| try out.print("Difficulty: {d:.3}\n", .{value});
                    try out.print("Due: {d}\n", .{stored.due_at_ms});
                }
            }
        },
        .fsrs_optimize => |args| {
            const owned = try store.histories(allocator, args.deck_id);
            defer owned.deinit(allocator);
            const views = try historyViews(allocator, owned);
            defer allocator.free(views);
            const initial = try baseParameters(store, args.deck_id, now_ms);
            const result = try fsrs.v7.optimizer.optimize(views, initial, .{ .recency_half_life_days = args.recency_half_life_days });
            const id = try store.putFsrs7Parameters(result.parameters, "optimized", now_ms);
            if (args.deck_id) |deck_id| try store.setDeckFsrs7(deck_id, id) else try store.setGlobalFsrs7(id);
            try out.print("Examples: {d}\nLog loss: {d:.6} -> {d:.6}\nParameter set: {x}\n", .{
                result.examples,
                result.initial_log_loss,
                result.final_log_loss,
                id,
            });
        },
        .fsrs_evaluate => |args| {
            const owned = try store.histories(allocator, args.deck_id);
            defer owned.deinit(allocator);
            const views = try historyViews(allocator, owned);
            defer allocator.free(views);
            const parameters = try baseParameters(store, args.deck_id, now_ms);
            const metrics = try fsrs.v7.evaluator.evaluate(views, parameters, .{});
            try out.print("Examples: {d}\nLog loss: {d:.6}\nRMSE: {d:.6}\nCalibration error: {d:.6}\n", .{
                metrics.examples,
                metrics.log_loss,
                metrics.rmse,
                metrics.calibration_error,
            });
        },
        .fsrs_simulate => |args| {
            var parameters: fsrs.v7.Parameters = .{};
            if (args.retention) |retention| parameters.desired_retention = retention;
            const result = try fsrs.v7.simulator.simulate(allocator, parameters, .{});
            try out.print("Reviews: {d}\nLapses: {d}\nAverage/day: {d:.2}\nStudy time: {d:.1} minutes\nHorizon retrievability: {d:.2}%\n", .{
                result.reviews,
                result.lapses,
                result.average_daily_reviews,
                result.estimated_study_seconds / 60.0,
                result.average_retrievability_at_horizon * 100.0,
            });
        },
        .fsrs_retention => {
            const analysis = try fsrs.v7.retention.analyze(allocator, .{}, .{});
            defer analysis.deinit(allocator);
            try out.print("Suggested retention: {d:.2}%\n", .{analysis.optimal_retention * 100.0});
            for (analysis.points) |point| {
                try out.print("{d:.0}%  reviews={d}  lapses={d}  cost={d:.1}m\n", .{
                    point.desired_retention * 100.0,
                    point.reviews,
                    point.lapses,
                    point.total_cost_seconds / 60.0,
                });
            }
        },
        .scheduler_list => {
            const implementation = fsrs.ImplementationVersion.current;
            try out.print("FSRS-7  supported  implementation={d}.{d}.{d}\n", .{
                implementation.major,
                implementation.minor,
                implementation.patch,
            });
        },
    }
}
