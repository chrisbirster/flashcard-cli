const std = @import("std");
const httpz = @import("httpz");
const deez_build_options = @import("deez_build_options");

const config = @import("config.zig");
const content = @import("content.zig");
const note_service = @import("note_service.zig");
const storage = @import("storage/root.zig");

const Io = std.Io;

pub const Options = struct {
    port: u16 = 5882,
};

pub const help_text =
    \\Local API server:
    \\  plandalf serve [--port <1..65535>]
    \\
    \\Binds to 127.0.0.1 only. The default port is 5882.
;

const version = deez_build_options.version;

const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
};

const CreateNoteBody = struct {
    note_type: []const u8,
    fields: []const []const u8,
    tags_json: []const u8 = "[]",
};

const UpdateNoteBody = struct {
    fields: []const []const u8,
    tags_json: []const u8 = "[]",
};

const PreviewNoteBody = struct {
    note_type: []const u8,
    fields: []const []const u8,
};

pub fn isCommand(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[1], "serve");
}

fn parsePort(text: []const u8) !u16 {
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len == 2) return .{};
    if (args.len == 4 and std.mem.eql(u8, args[2], "--port")) {
        return .{ .port = try parsePort(args[3]) };
    }
    return error.InvalidArguments;
}

pub fn runCommand(init: std.process.Init, args: []const []const u8) !void {
    try run(init, try parseOptions(args));
}

pub fn run(init: std.process.Init, options: Options) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const selection = try config.resolve(init);
    const db_path_z = try arena.dupeZ(u8, selection.sqlite_path);
    var db = try storage.Db.open(db_path_z);
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    try serveWithStore(allocator, io, &store, options);
}

fn serveWithStore(
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    options: Options,
) !void {
    var app: App = .{ .allocator = allocator, .io = io, .store = store };
    var server = try httpz.Server(*App).init(io, allocator, .{
        .address = .localhost(options.port),
        .workers = .{
            .count = 1,
            .max_conn = 64,
        },
        .thread_pool = .{
            .count = 1,
            .backlog = 64,
        },
        .request = .{
            .max_body_size = 1024 * 1024,
            .max_header_count = 32,
            .max_param_count = 16,
            .max_query_count = 32,
        },
        .response = .{ .max_header_count = 32 },
        .timeout = .{
            .request = 15,
            .keepalive = 10,
            .request_count = 100,
        },
    }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get("/api/v1/health", health, .{});
    router.get("/api/v1/version", versionInfo, .{});
    router.get("/api/v1/capabilities", capabilities, .{});
    router.get("/api/v1/decks", listDecks, .{});
    router.get("/api/v1/decks/:deck_id", getDeck, .{});
    router.get("/api/v1/decks/:deck_id/notes", listNotes, .{});
    router.post("/api/v1/decks/:deck_id/notes", createNote, .{});
    router.get("/api/v1/notes/:note_id", getNote, .{});
    router.patch("/api/v1/notes/:note_id", updateNote, .{});
    router.delete("/api/v1/notes/:note_id", deleteNote, .{});
    router.post("/api/v1/notes/preview", previewNote, .{});
    router.get("/api/v1/decks/:deck_id/cards", listCards, .{});
    router.get("/api/v1/cards/:card_id", getCard, .{});

    var stdout_buffer: [256]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    try out.print("Plandalf API: http://127.0.0.1:{d}\n", .{options.port});
    try out.flush();

    try server.listen();
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn writeError(
    res: *httpz.Response,
    status: u16,
    code: []const u8,
    message: []const u8,
) !void {
    res.status = status;
    try res.json(.{
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

fn writeDomainError(res: *httpz.Response, err: anyerror) !void {
    return switch (err) {
        error.NoteNotFound => writeError(res, 404, "note_not_found", "note does not exist"),
        error.ReviewHistoryExists => writeError(
            res,
            409,
            "review_history_exists",
            "this change would remove a generated card that has review history",
        ),
        error.NoteHasNoGeneratedCards,
        error.NoteDeckMismatch,
        error.GeneratedCardSourceMissing,
        error.CardNotFound,
        => writeError(res, 409, "inconsistent_note_state", "note/card generation state is inconsistent"),
        error.UnsupportedBuiltInNoteType,
        error.UnknownNoteType,
        => writeError(res, 422, "unknown_note_type", "note type is not supported"),
        error.InvalidFieldCount,
        error.InvalidText,
        error.InvalidCloze,
        error.ClozeRequired,
        error.NotEnoughChoices,
        error.InvalidInteractionText,
        error.DuplicateChoiceId,
        error.UnknownChoiceId,
        error.CorrectChoiceRequired,
        error.DuplicateCorrectChoiceId,
        error.InvalidOcclusionMediaReference,
        error.OcclusionMaskRequired,
        error.InvalidOcclusionRect,
        error.DuplicateOcclusionId,
        error.OcclusionMaskNotFound,
        => writeError(res, 422, "invalid_note", @errorName(err)),
        else => err,
    };
}

fn pathId(req: *httpz.Request, name: []const u8) !u64 {
    const raw = req.param(name) orelse return error.InvalidId;
    return std.fmt.parseInt(u64, raw, 10) catch return error.InvalidId;
}

fn parseBody(req: *httpz.Request, comptime T: type, res: *httpz.Response) !?T {
    const value = req.json(T) catch {
        try writeError(res, 400, "invalid_json", "request body must be valid JSON");
        return null;
    };
    if (value == null) {
        try writeError(res, 400, "missing_body", "request body is required");
        return null;
    }
    return value;
}

fn health(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;
    try res.json(.{ .status = "ok" }, .{});
}

fn versionInfo(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;
    try res.json(.{ .version = version }, .{});
}

fn capabilities(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;

    var note_types: [content.built_in_note_types.len][]const u8 = undefined;
    for (content.built_in_note_types, 0..) |definition, index| {
        note_types[index] = definition.slug;
    }

    const interactions = [_][]const u8{
        "reveal",
        "type_answer",
        "single_choice",
        "multiple_choice",
        "ordering",
        "image_occlusion",
    };

    try res.json(.{
        .note_types = note_types[0..],
        .interactions = interactions[0..],
    }, .{});
}

fn listDecks(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    const decks = try app.store.decks(app.allocator, nowMs(app.io));
    defer {
        for (decks) |deck| deck.deinit(app.allocator);
        app.allocator.free(decks);
    }
    try res.json(.{ .decks = decks }, .{});
}

fn getDeck(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = pathId(req, "deck_id") catch
        return writeError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
    const deck = (try app.store.getDeck(app.allocator, deck_id)) orelse
        return writeError(res, 404, "deck_not_found", "deck does not exist");
    defer deck.deinit(app.allocator);

    try res.json(.{
        .deck = .{
            .id = deck.id,
            .name = deck.name,
        },
    }, .{});
}

fn listCards(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = pathId(req, "deck_id") catch
        return writeError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
    const deck = (try app.store.getDeck(app.allocator, deck_id)) orelse
        return writeError(res, 404, "deck_not_found", "deck does not exist");
    defer deck.deinit(app.allocator);

    const cards = try app.store.cards(app.allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(app.allocator);
        app.allocator.free(cards);
    }
    try res.json(.{ .cards = cards }, .{});
}

fn getCard(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const card_id = pathId(req, "card_id") catch
        return writeError(res, 400, "invalid_id", "card_id must be an unsigned integer");
    const card = (try app.store.getCard(app.allocator, card_id)) orelse
        return writeError(res, 404, "card_not_found", "card does not exist");
    defer card.deinit(app.allocator);
    try res.json(.{ .card = card }, .{});
}

fn hasNote(notes: []const content.OwnedNote, note_id: content.NoteId) bool {
    for (notes) |note| {
        if (note.id == note_id) return true;
    }
    return false;
}

fn listNotes(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = pathId(req, "deck_id") catch
        return writeError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
    const deck = (try app.store.getDeck(app.allocator, deck_id)) orelse
        return writeError(res, 404, "deck_not_found", "deck does not exist");
    defer deck.deinit(app.allocator);

    const cards = try app.store.cards(app.allocator, deck_id);
    defer {
        for (cards) |card| card.deinit(app.allocator);
        app.allocator.free(cards);
    }

    const content_store = storage.ContentStore.init(app.store);
    var notes: std.ArrayList(content.OwnedNote) = .empty;
    defer {
        for (notes.items) |note| note.deinit(app.allocator);
        notes.deinit(app.allocator);
    }

    for (cards) |card| {
        const source = (try content_store.cardSource(app.allocator, card.id)) orelse continue;
        defer source.deinit(app.allocator);
        if (hasNote(notes.items, source.note_id)) continue;
        const note = (try content_store.getNote(app.allocator, source.note_id)) orelse continue;
        errdefer note.deinit(app.allocator);
        try notes.append(app.allocator, note);
    }

    try res.json(.{ .notes = notes.items }, .{});
}

fn getNote(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const note_id = pathId(req, "note_id") catch
        return writeError(res, 400, "invalid_id", "note_id must be an unsigned integer");
    const content_store = storage.ContentStore.init(app.store);
    const note = (try content_store.getNote(app.allocator, note_id)) orelse
        return writeError(res, 404, "note_not_found", "note does not exist");
    defer note.deinit(app.allocator);
    try res.json(.{ .note = note }, .{});
}

fn createNote(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = pathId(req, "deck_id") catch
        return writeError(res, 400, "invalid_id", "deck_id must be an unsigned integer");
    const deck = (try app.store.getDeck(app.allocator, deck_id)) orelse
        return writeError(res, 404, "deck_not_found", "deck does not exist");
    defer deck.deinit(app.allocator);

    const body = (try parseBody(req, CreateNoteBody, res)) orelse return;
    const kind = content.BuiltInNoteType.parse(body.note_type) catch
        return writeError(res, 422, "unknown_note_type", "note type is not supported");

    const created = note_service.create(
        app.allocator,
        app.store,
        deck_id,
        kind,
        body.fields,
        body.tags_json,
        nowMs(app.io),
    ) catch |err| return writeDomainError(res, err);
    defer created.deinit(app.allocator);

    res.status = 201;
    try res.json(.{
        .note_id = created.note_id,
        .card_ids = created.card_ids,
    }, .{});
}

fn updateNote(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const note_id = pathId(req, "note_id") catch
        return writeError(res, 400, "invalid_id", "note_id must be an unsigned integer");
    const body = (try parseBody(req, UpdateNoteBody, res)) orelse return;

    const card_ids = note_service.update(
        app.allocator,
        app.store,
        note_id,
        body.fields,
        body.tags_json,
        nowMs(app.io),
    ) catch |err| return writeDomainError(res, err);
    defer app.allocator.free(card_ids);

    try res.json(.{
        .note_id = note_id,
        .card_ids = card_ids,
    }, .{});
}

fn deleteNote(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const note_id = pathId(req, "note_id") catch
        return writeError(res, 400, "invalid_id", "note_id must be an unsigned integer");
    note_service.delete(app.allocator, app.store, note_id) catch |err|
        return writeDomainError(res, err);
    res.status = 204;
}

fn previewNote(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const body = (try parseBody(req, PreviewNoteBody, res)) orelse return;
    const kind = content.BuiltInNoteType.parse(body.note_type) catch
        return writeError(res, 422, "unknown_note_type", "note type is not supported");

    const preview = note_service.preview(app.allocator, kind, body.fields) catch |err|
        return writeDomainError(res, err);
    defer preview.deinit(app.allocator);
    try res.json(.{ .cards = preview.cards }, .{});
}

test "serve options are loopback-port only" {
    const default_args = [_][]const u8{ "plandalf", "serve" };
    try std.testing.expectEqual(@as(u16, 5882), (try parseOptions(&default_args)).port);

    const custom_args = [_][]const u8{ "plandalf", "serve", "--port", "9000" };
    try std.testing.expectEqual(@as(u16, 9000), (try parseOptions(&custom_args)).port);

    const zero_args = [_][]const u8{ "plandalf", "serve", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parseOptions(&zero_args));
}
