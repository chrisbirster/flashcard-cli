const std = @import("std");
const httpz = @import("httpz");
const deez_build_options = @import("deez_build_options");

const config = @import("config.zig");
const content = @import("content.zig");
const note_service = @import("note_service.zig");
const storage = @import("storage/root.zig");
const web_cards = @import("web_cards.zig");
const web_study = @import("web_study.zig");

const Io = std.Io;

pub const Bind = enum {
    localhost,
    all,
};

pub const Options = struct {
    port: u16 = 5882,
    bind: Bind = .localhost,
    cors_origin: ?[]const u8 = null,
};

pub const help_text =
    \\Plandalf API server:
    \\  plandalf serve [--port <1..65535>] [--bind localhost|all] [--cors-origin <origin>]
    \\
    \\The default is http://127.0.0.1:5882 and does not require authentication.
    \\Remote/LAN mode is explicit:
    \\
    \\  export PLANDALF_API_TOKEN=<long-random-secret>
    \\  plandalf serve --bind all --cors-origin https://study.example.com
    \\
    \\When --bind all is used, PLANDALF_API_TOKEN is required and all data/study
    \\endpoints require `Authorization: Bearer <token>`. Health and version remain
    \\public. --cors-origin enables one exact browser origin; omit it for non-browser
    \\API clients. TLS should be provided by a trusted reverse proxy or private VPN.
;

const version = deez_build_options.version;
const api_version = "v1";

const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    bind: Bind,
    api_token: ?[]const u8,
    cors_origin: ?[]const u8,

    fn publicPath(req: *httpz.Request) bool {
        return std.mem.eql(u8, req.url.path, "/api/v1/health") or
            std.mem.eql(u8, req.url.path, "/api/v1/version");
    }

    fn originAllowed(self: *App, req: *httpz.Request) bool {
        const origin = req.header("origin") orelse return true;
        const allowed = self.cors_origin orelse return false;
        return std.mem.eql(u8, origin, allowed);
    }

    fn authorized(self: *App, req: *httpz.Request) bool {
        const token = self.api_token orelse return true;
        const authorization = req.header("authorization") orelse return false;
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, authorization, prefix)) return false;
        return std.mem.eql(u8, authorization[prefix.len..], token);
    }

    fn applyCors(self: *App, res: *httpz.Response) void {
        const origin = self.cors_origin orelse return;
        res.header("Access-Control-Allow-Origin", origin);
        res.header("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS");
        res.header("Access-Control-Allow-Headers", "Authorization, Content-Type");
        res.header("Access-Control-Max-Age", "600");
        res.header("Vary", "Origin");
    }

    pub fn dispatch(
        self: *App,
        action: httpz.Action(*App),
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        if (!self.originAllowed(req)) {
            try writeError(res, 403, "forbidden_origin", "request origin is not allowed");
            return;
        }
        self.applyCors(res);

        if (!publicPath(req) and !self.authorized(req)) {
            res.header("WWW-Authenticate", "Bearer");
            try writeError(res, 401, "unauthorized", "a valid Plandalf API bearer token is required");
            return;
        }

        try action(self, req, res);
    }

    pub fn notFound(self: *App, req: *httpz.Request, res: *httpz.Response) !void {
        if (req.method == .OPTIONS and std.mem.startsWith(u8, req.url.path, "/api/v1/")) {
            if (!self.originAllowed(req)) {
                try writeError(res, 403, "forbidden_origin", "request origin is not allowed");
                return;
            }
            self.applyCors(res);
            res.status = 204;
            return;
        }

        if (self.originAllowed(req)) self.applyCors(res);
        try writeError(res, 404, "not_found", "endpoint does not exist");
    }

    pub fn uncaughtError(_: *App, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.log.err("API request failed path={s} error={}", .{ req.url.path, err });
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":{\"code\":\"internal_error\",\"message\":\"internal server error\"}}";
    }
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

fn parseBind(text: []const u8) !Bind {
    if (std.mem.eql(u8, text, "localhost")) return .localhost;
    if (std.mem.eql(u8, text, "all")) return .all;
    return error.InvalidBind;
}

fn validateCorsOrigin(origin: []const u8) !void {
    if (origin.len == 0 or std.mem.indexOfAny(u8, origin, "\r\n") != null) return error.InvalidCorsOrigin;
    if (!std.mem.startsWith(u8, origin, "http://") and !std.mem.startsWith(u8, origin, "https://")) {
        return error.InvalidCorsOrigin;
    }
    if (std.mem.endsWith(u8, origin, "/")) return error.InvalidCorsOrigin;
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len < 2) return error.InvalidArguments;
    var options: Options = .{};
    var index: usize = 2;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--port")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            options.port = try parsePort(args[index + 1]);
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bind")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            options.bind = try parseBind(args[index + 1]);
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cors-origin")) {
            if (index + 1 >= args.len) return error.InvalidArguments;
            try validateCorsOrigin(args[index + 1]);
            options.cors_origin = args[index + 1];
            index += 2;
            continue;
        }
        return error.InvalidArguments;
    }
    return options;
}

pub fn runCommand(init: std.process.Init, args: []const []const u8) !void {
    try run(init, try parseOptions(args));
}

pub fn run(init: std.process.Init, options: Options) !void {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const api_token = init.environ_map.get("PLANDALF_API_TOKEN");
    if (options.bind == .all and (api_token == null or api_token.?.len == 0)) return error.MissingApiToken;
    if (options.cors_origin) |origin| try validateCorsOrigin(origin);

    const selection = try config.resolve(init);
    const db_path_z = try arena.dupeZ(u8, selection.sqlite_path);
    var db = try storage.Db.open(db_path_z);
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    try serveWithStore(allocator, io, &store, options, api_token);
}

fn serveWithStore(
    allocator: std.mem.Allocator,
    io: Io,
    store: *storage.Store,
    options: Options,
    api_token: ?[]const u8,
) !void {
    var app: App = .{
        .allocator = allocator,
        .io = io,
        .store = store,
        .bind = options.bind,
        .api_token = api_token,
        .cors_origin = options.cors_origin,
    };
    var server = try httpz.Server(*App).init(io, allocator, .{
        .address = switch (options.bind) {
            .localhost => .localhost(options.port),
            .all => .all(options.port),
        },
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
        .response = .{ .max_header_count = 40 },
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

    // Mobile/rich study API. These routes reuse the exact same rendering and
    // FSRS review implementation as the local web client.
    router.get("/api/v1/decks/:id/study/next", studyNext, .{});
    router.get("/api/v1/cards/:id/rendered", renderedCard, .{});
    router.get("/api/v1/cards/:id/study/preview", studyPreview, .{});
    router.post("/api/v1/cards/:id/reviews", studyReview, .{});

    var stdout_buffer: [512]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    switch (options.bind) {
        .localhost => try out.print("Plandalf API: http://127.0.0.1:{d}\n", .{options.port}),
        .all => try out.print("Plandalf API listening on 0.0.0.0:{d} (bearer token required)\n", .{options.port}),
    }
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
    try res.json(.{ .version = version, .api_version = api_version }, .{});
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
        .api_version = api_version,
        .note_types = note_types[0..],
        .interactions = interactions[0..],
        .study = true,
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

fn studyNext(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    try web_study.next(app.store, app.io, req, res);
}

fn renderedCard(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    try web_cards.card(app.store, req, res);
}

fn studyPreview(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    try web_study.preview(app.store, app.io, req, res);
}

fn studyReview(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    try web_study.review(app.store, app.io, req, res);
}

test "serve options preserve localhost defaults and support explicit remote mode" {
    const default_args = [_][]const u8{ "plandalf", "serve" };
    const defaults = try parseOptions(&default_args);
    try std.testing.expectEqual(@as(u16, 5882), defaults.port);
    try std.testing.expectEqual(Bind.localhost, defaults.bind);
    try std.testing.expect(defaults.cors_origin == null);

    const remote_args = [_][]const u8{
        "plandalf",
        "serve",
        "--bind",
        "all",
        "--port",
        "9000",
        "--cors-origin",
        "https://study.example.com",
    };
    const remote = try parseOptions(&remote_args);
    try std.testing.expectEqual(@as(u16, 9000), remote.port);
    try std.testing.expectEqual(Bind.all, remote.bind);
    try std.testing.expectEqualStrings("https://study.example.com", remote.cors_origin.?);
}

test "serve options reject unsafe or malformed remote configuration" {
    const zero_args = [_][]const u8{ "plandalf", "serve", "--port", "0" };
    try std.testing.expectError(error.InvalidPort, parseOptions(&zero_args));

    const bad_bind = [_][]const u8{ "plandalf", "serve", "--bind", "internet" };
    try std.testing.expectError(error.InvalidBind, parseOptions(&bad_bind));

    const bad_origin = [_][]const u8{ "plandalf", "serve", "--cors-origin", "https://study.example.com/" };
    try std.testing.expectError(error.InvalidCorsOrigin, parseOptions(&bad_origin));
}

test "bearer authorization requires the exact configured token" {
    const token = "secret-token";
    try std.testing.expect(std.mem.eql(u8, "secret-token", token));
    try std.testing.expect(!std.mem.eql(u8, "wrong-token", token));
}
