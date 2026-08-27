const std = @import("std");
const httpz = @import("httpz");
const build_options = @import("build_options");
const browser = @import("browser.zig");
const content = @import("content.zig");
const storage = @import("storage/root.zig");
const web_assets = @import("web_assets.zig");
const web_cards = @import("web_cards.zig");
const web_media = @import("web_media.zig");
const web_notes = @import("web_notes.zig");
const web_study = @import("web_study.zig");

const Io = std.Io;

pub const default_port: u16 = 49317;
pub const api_version = "v1";
pub const version = build_options.version;
const max_api_body_bytes: usize = 1024 * 1024;

pub const Options = struct {
    port: u16 = default_port,
    web_root: ?[]const u8 = null,
    open_browser: bool = true,
};

const CapabilityField = struct {
    ordinal: content.FieldOrdinal,
    name: []const u8,
};

const CapabilityNoteType = struct {
    id: []const u8,
    slug: []const u8,
    name: []const u8,
    fields: []const CapabilityField,
};

const DeckResponse = struct {
    id: []const u8,
    name: []const u8,
    note_count: usize,
    card_count: usize,
    due_count: usize,
};

const NoteSummaryResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    note_type: []const u8,
    preview: []const u8,
    card_count: usize,
    updated_at_ms: i64,
};

const NoteResponse = struct {
    id: []const u8,
    deck_id: []const u8,
    note_type: []const u8,
    fields: []const []const u8,
    tags: []const []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const Handler = struct {
    io: Io,
    port: u16,
    store: *storage.Store,
    web_root: ?[]const u8,
    media_root: []const u8,
    store_mutex: Io.Mutex = .init,

    fn requestAllowed(self: *Handler, req: *httpz.Request) bool {
        return isAllowedHost(req.header("host"), self.port) and
            isAllowedOrigin(req.header("origin"), self.port);
    }

    pub fn dispatch(
        self: *Handler,
        action: httpz.Action(*Handler),
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        if (!self.requestAllowed(req)) {
            forbidden(res);
            return;
        }

        const media_request = isMediaApiPath(req.url.path);
        if (!media_request and req.body_len > max_api_body_bytes) {
            try jsonError(res, 413, "request_too_large", "Deez Web API JSON bodies are limited to 1 MiB");
            return;
        }

        // Hash-addressed media reads and uploads do not touch the shared Store,
        // so do not hold the database mutex while transferring local media.
        if (media_request) {
            try action(self, req, res);
            return;
        }

        // The first local API deliberately serializes requests over the shared
        // Store. SQLite uses one connection, and this conservative boundary also
        // avoids assuming Mongo client concurrency guarantees before they are
        // explicitly tested.
        self.store_mutex.lockUncancelable(self.io);
        defer self.store_mutex.unlock(self.io);
        try action(self, req, res);
    }

    pub fn notFound(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        if (!self.requestAllowed(req)) {
            forbidden(res);
            return;
        }

        if (req.method == .GET and
            self.web_root != null and
            !std.mem.startsWith(u8, req.url.path, "/api/"))
        {
            switch (try web_assets.serve(self.io, self.web_root.?, req.url.path, res)) {
                .served => return,
                .not_found, .unsafe_path => {},
            }
        }

        try jsonError(res, 404, "not_found", "Not found");
    }

    pub fn uncaughtError(_: *Handler, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        std.log.err("web request failed path={s} error={}", .{ req.url.path, err });
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}";
    }
};

pub fn run(init: std.process.Init, store: *storage.Store, options: Options) !void {
    if (options.port == 0) return error.InvalidPort;

    const media_root = try web_media.resolveRoot(init, init.arena.allocator());
    var handler: Handler = .{
        .io = init.io,
        .port = options.port,
        .store = store,
        .web_root = options.web_root,
        .media_root = media_root,
    };
    var server = try httpz.Server(*Handler).init(init.io, init.gpa, .{
        .address = .localhost(options.port),
        .workers = .{
            .max_conn = 64,
        },
        .request = .{
            .max_body_size = max_api_body_bytes,
            // Bodies above the normal JSON limit are left on the socket. The
            // dispatch boundary rejects them for every route except media upload,
            // whose handler applies its own 32 MiB cap while reading the stream.
            .lazy_read_size = max_api_body_bytes + 1,
            .max_header_count = 32,
            .max_param_count = 16,
            .max_query_count = 32,
            .max_form_count = 16,
        },
        .response = .{
            .max_header_count = 32,
        },
        .timeout = .{
            .request = 10,
            .keepalive = 15,
            .request_count = 100,
        },
    }, &handler);
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/api/v1/health", health, .{});
    router.get("/api/v1/version", versionInfo, .{});
    router.get("/api/v1/capabilities", capabilities, .{});
    router.post("/api/v1/media", mediaUpload, .{});
    router.get("/api/v1/media/:hash", mediaAsset, .{});
    router.get("/api/v1/decks", decks, .{});
    router.get("/api/v1/decks/:id", deck, .{});
    router.get("/api/v1/decks/:id/notes", deckNotes, .{});
    router.post("/api/v1/decks/:id/notes", createNote, .{});
    router.get("/api/v1/decks/:id/cards", deckCards, .{});
    router.get("/api/v1/decks/:id/study/next", studyNext, .{});
    router.get("/api/v1/notes/:id", note, .{});
    router.patch("/api/v1/notes/:id", updateNote, .{});
    router.delete("/api/v1/notes/:id", deleteNote, .{});
    router.post("/api/v1/notes/preview", previewNote, .{});
    router.get("/api/v1/cards/:id", card, .{});
    router.get("/api/v1/cards/:id/study/preview", studyPreview, .{});
    router.post("/api/v1/cards/:id/reviews", studyReview, .{});

    if (options.web_root) |root| {
        std.debug.print("Deez Web listening on http://127.0.0.1:{d}/ (assets: {s})\n", .{ options.port, root });
    } else {
        std.debug.print("Deez Web API listening on http://127.0.0.1:{d}/ (UI assets not found)\n", .{options.port});
    }

    if (options.web_root != null and options.open_browser) {
        const listen_thread = try server.listenInNewThread();
        const url = try std.fmt.allocPrint(init.arena.allocator(), "http://127.0.0.1:{d}/", .{options.port});
        browser.openDefault(init.io, url) catch |err| {
            std.log.warn("unable to open Deez Web in the default browser: {}", .{err});
        };
        listen_thread.join();
        return;
    }

    try server.listen();
}

fn health(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{ .status = "ok" }, .{});
}

fn versionInfo(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    try res.json(.{
        .version = version,
        .api_version = api_version,
    }, .{});
}

fn capabilities(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const note_types = try res.arena.alloc(CapabilityNoteType, content.built_in_note_types.len);
    for (content.built_in_note_types, 0..) |definition, index| {
        const fields = try res.arena.alloc(CapabilityField, definition.fields.len);
        for (definition.fields, 0..) |field, field_index| {
            fields[field_index] = .{
                .ordinal = field.ordinal,
                .name = field.name,
            };
        }
        note_types[index] = .{
            .id = try idText(res.arena, definition.id),
            .slug = definition.slug,
            .name = definition.name,
            .fields = fields,
        };
    }

    const interactions = [_][]const u8{
        "reveal",
        "type_answer",
        "single_choice",
        "multiple_choice",
        "ordering",
        "image_occlusion",
    };
    const formats = [_][]const u8{ "nut", "sack" };

    try res.json(.{
        .api_version = api_version,
        .note_types = note_types,
        .interactions = &interactions,
        .import_formats = &formats,
        .export_formats = &formats,
    }, .{});
}

fn mediaUpload(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_media.upload(self.io, self.media_root, req, res);
}

fn mediaAsset(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_media.serve(self.io, self.media_root, req, res);
}

fn decks(self: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    const summaries = try self.store.decks(res.arena, nowMs(self.io));
    const result = try res.arena.alloc(DeckResponse, summaries.len);
    const content_store = storage.ContentStore.init(self.store);

    for (summaries, 0..) |summary, index| {
        const notes = try content_store.notesForDeck(res.arena, summary.id);
        result[index] = .{
            .id = try idText(res.arena, summary.id),
            .name = summary.name,
            .note_count = notes.len,
            .card_count = summary.card_count,
            .due_count = summary.due_count,
        };
    }
    try res.json(result, .{});
}

fn deck(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = parseRouteId(req, res, "id") orelse return;
    const owned = (try self.store.getDeck(res.arena, deck_id)) orelse {
        try jsonError(res, 404, "deck_not_found", "Deck not found");
        return;
    };
    const stats = try self.store.stats(nowMs(self.io), deck_id);
    const notes = try storage.ContentStore.init(self.store).notesForDeck(res.arena, deck_id);

    try res.json(DeckResponse{
        .id = try idText(res.arena, owned.id),
        .name = owned.name,
        .note_count = notes.len,
        .card_count = stats.card_count,
        .due_count = stats.due_count,
    }, .{});
}

fn deckNotes(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const deck_id = parseRouteId(req, res, "id") orelse return;
    if (try self.store.getDeck(res.arena, deck_id) == null) {
        try jsonError(res, 404, "deck_not_found", "Deck not found");
        return;
    }

    const notes = try storage.ContentStore.init(self.store).notesForDeck(res.arena, deck_id);
    const result = try res.arena.alloc(NoteSummaryResponse, notes.len);
    for (notes, 0..) |entry, index| {
        result[index] = .{
            .id = try idText(res.arena, entry.note.id),
            .deck_id = try idText(res.arena, deck_id),
            .note_type = try noteTypeSlug(entry.note.note_type_id),
            .preview = if (entry.note.fields.len == 0) "" else entry.note.fields[0].value,
            .card_count = entry.card_count,
            .updated_at_ms = entry.note.updated_at_ms,
        };
    }
    try res.json(result, .{});
}

fn deckCards(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_cards.deckCards(self.store, req, res);
}

fn studyNext(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_study.next(self.store, self.io, req, res);
}

fn note(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const note_id = parseRouteId(req, res, "id") orelse return;
    const owned = (try storage.ContentStore.init(self.store).getNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_found", "Note not found");
        return;
    };
    const deck_id = (try storage.ContentMembership.init(self.store).deckIdForNote(res.arena, note_id)) orelse {
        try jsonError(res, 404, "note_not_attached", "Note is not attached to a deck");
        return;
    };

    const fields = try res.arena.alloc([]const u8, owned.fields.len);
    for (owned.fields, 0..) |field, index| fields[index] = field.value;

    var parsed_tags = std.json.parseFromSlice([]const []const u8, res.arena, owned.tags_json, .{}) catch {
        try jsonError(res, 500, "invalid_note_tags", "Stored note tags are invalid");
        return;
    };
    defer parsed_tags.deinit();

    try res.json(NoteResponse{
        .id = try idText(res.arena, owned.id),
        .deck_id = try idText(res.arena, deck_id),
        .note_type = try noteTypeSlug(owned.note_type_id),
        .fields = fields,
        .tags = parsed_tags.value,
        .created_at_ms = owned.created_at_ms,
        .updated_at_ms = owned.updated_at_ms,
    }, .{});
}

fn createNote(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_notes.createNote(self.store, self.io, req, res);
}

fn updateNote(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_notes.updateNote(self.store, self.io, req, res);
}

fn deleteNote(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_notes.deleteNote(self.store, self.io, req, res);
}

fn previewNote(_: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_notes.previewNote(req, res);
}

fn card(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_cards.card(self.store, req, res);
}

fn studyPreview(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_study.preview(self.store, self.io, req, res);
}

fn studyReview(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    try web_study.review(self.store, self.io, req, res);
}

fn parseRouteId(req: *httpz.Request, res: *httpz.Response, name: []const u8) ?u64 {
    const text = req.param(name) orelse {
        jsonError(res, 400, "invalid_id", "Missing resource ID") catch {};
        return null;
    };
    return parseIdText(text) catch {
        jsonError(res, 400, "invalid_id", "Resource ID must be an unsigned integer") catch {};
        return null;
    };
}

fn parseIdText(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidId;
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidId;
}

fn noteTypeSlug(note_type_id: content.NoteTypeId) ![]const u8 {
    return (try content.BuiltInNoteType.fromId(note_type_id)).definition().slug;
}

fn idText(allocator: std.mem.Allocator, id: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{id});
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds() * 1_000;
}

fn jsonError(res: *httpz.Response, status: u16, code: []const u8, message: []const u8) !void {
    res.status = status;
    try res.json(.{
        .@"error" = .{
            .code = code,
            .message = message,
        },
    }, .{});
}

fn forbidden(res: *httpz.Response) void {
    res.status = 403;
    res.content_type = .JSON;
    res.body = "{\"error\":{\"code\":\"forbidden_origin\",\"message\":\"Request is not from the local Deez Web origin\"}}";
}

fn isMediaApiPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/api/v1/media") or
        std.mem.startsWith(u8, path, "/api/v1/media/");
}

fn isAllowedHost(value: ?[]const u8, port: u16) bool {
    const host = value orelse return false;
    const colon = std.mem.lastIndexOfScalar(u8, host, ':') orelse return false;
    if (colon == 0 or colon + 1 >= host.len) return false;

    const name = host[0..colon];
    const parsed_port = std.fmt.parseInt(u16, host[colon + 1 ..], 10) catch return false;
    if (parsed_port != port) return false;

    return std.mem.eql(u8, name, "127.0.0.1") or std.ascii.eqlIgnoreCase(name, "localhost");
}

fn isAllowedOrigin(value: ?[]const u8, port: u16) bool {
    const origin = value orelse return true;
    const prefix = "http://";
    if (!std.mem.startsWith(u8, origin, prefix)) return false;
    return isAllowedHost(origin[prefix.len..], port);
}

test "local web host validation only accepts the configured loopback endpoint" {
    try std.testing.expect(isAllowedHost("127.0.0.1:49317", 49317));
    try std.testing.expect(isAllowedHost("localhost:49317", 49317));
    try std.testing.expect(isAllowedHost("LOCALHOST:49317", 49317));

    try std.testing.expect(!isAllowedHost(null, 49317));
    try std.testing.expect(!isAllowedHost("127.0.0.1:49318", 49317));
    try std.testing.expect(!isAllowedHost("127.0.0.1.evil.example:49317", 49317));
    try std.testing.expect(!isAllowedHost("example.com:49317", 49317));
}

test "local web origin validation permits absent or exact same-origin headers" {
    try std.testing.expect(isAllowedOrigin(null, 49317));
    try std.testing.expect(isAllowedOrigin("http://127.0.0.1:49317", 49317));
    try std.testing.expect(isAllowedOrigin("http://localhost:49317", 49317));

    try std.testing.expect(!isAllowedOrigin("https://127.0.0.1:49317", 49317));
    try std.testing.expect(!isAllowedOrigin("http://127.0.0.1:49318", 49317));
    try std.testing.expect(!isAllowedOrigin("http://localhost:49317.evil.example", 49317));
    try std.testing.expect(!isAllowedOrigin("https://example.com", 49317));
}

test "media API path covers the collection and hash resources only" {
    try std.testing.expect(isMediaApiPath("/api/v1/media"));
    try std.testing.expect(isMediaApiPath("/api/v1/media/abc"));
    try std.testing.expect(!isMediaApiPath("/api/v1/mediax"));
    try std.testing.expect(!isMediaApiPath("/api/v1/notes/1"));
}

test "resource IDs normalize invalid unsigned input" {
    try std.testing.expectEqual(@as(u64, 42), try parseIdText("42"));
    try std.testing.expectError(error.InvalidId, parseIdText("-1"));
    try std.testing.expectError(error.InvalidId, parseIdText("abc"));
    try std.testing.expectError(error.InvalidId, parseIdText(""));
}
