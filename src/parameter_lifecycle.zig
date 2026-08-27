const std = @import("std");
const bongo = @import("bongo");
const fsrs = @import("fsrs/root.zig");
const storage = @import("storage/root.zig");
const time = @import("time.zig");

pub const Summary = struct {
    id: fsrs.ParameterSetId,
    source: []u8,
    desired_retention: f64,
    created_at_ms: time.TimestampMs,

    pub fn deinit(self: Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

pub const Activation = struct {
    deck_id: u64,
    previous_parameter_set_id: fsrs.ParameterSetId,
    active_parameter_set_id: fsrs.ParameterSetId,
    activated_at_ms: time.TimestampMs,
};

fn valueI64(value: bongo.bson.Value) ?i64 {
    return switch (value) {
        .int32 => |number| number,
        .int64 => |number| number,
        else => null,
    };
}

fn valueDouble(value: bongo.bson.Value) ?f64 {
    return switch (value) {
        .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        .int64 => |number| @floatFromInt(number),
        else => null,
    };
}

fn field(document: []const u8, name: []const u8) !bongo.bson.Value {
    return (try bongo.bson.Reader.get(document, name)) orelse error.MissingField;
}

pub fn listMongo(
    allocator: std.mem.Allocator,
    store: *storage.Store,
) ![]Summary {
    const mongo = switch (store.*) {
        .mongodb => |*value| value,
        .sqlite => return error.MongoBackendRequired,
    };
    var cursor = try mongo.client.find(
        mongo.client.databaseName(),
        "parameter_sets",
        .{ .algorithm_major = @as(i32, 7) },
        .{ .sort = .{ .created_at_ms = @as(i32, 1), ._id = @as(i32, 1) } },
    );
    defer cursor.deinit();
    var result: std.ArrayList(Summary) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }
    while (try cursor.next()) |document| {
        const binary = switch (try field(document, "_id")) {
            .binary => |value| value,
            else => return error.InvalidParameterSetId,
        };
        if (binary.data.len != 32) return error.InvalidParameterSetId;
        var id: fsrs.ParameterSetId = undefined;
        @memcpy(id[0..], binary.data);
        const source_view = switch (try field(document, "source")) {
            .string => |value| value,
            else => return error.InvalidField,
        };
        try result.append(allocator, .{
            .id = id,
            .source = try allocator.dupe(u8, source_view),
            .desired_retention = valueDouble(try field(document, "desired_retention")) orelse return error.InvalidField,
            .created_at_ms = valueI64(try field(document, "created_at_ms")) orelse return error.InvalidField,
        });
    }
    return result.toOwnedSlice(allocator);
}

pub fn compareDeck(
    allocator: std.mem.Allocator,
    store: *storage.Store,
    deck_id: u64,
    baseline_id: fsrs.ParameterSetId,
    candidate_id: fsrs.ParameterSetId,
    options: fsrs.v7.evaluator.Options,
) !fsrs.v7.evaluator.Comparison {
    const baseline = try store.loadFsrs7Parameters(baseline_id);
    const candidate = try store.loadFsrs7Parameters(candidate_id);
    const owned = try store.histories(allocator, deck_id);
    defer owned.deinit(allocator);
    const views = try allocator.alloc([]const fsrs.HistoryEntry, owned.histories.len);
    defer allocator.free(views);
    for (owned.histories, 0..) |history, index| views[index] = history;
    return fsrs.v7.evaluator.compareParameterSets(views, baseline, candidate, options);
}

pub fn activateDeck(
    store: *storage.Store,
    deck_id: u64,
    target_id: fsrs.ParameterSetId,
    activated_at_ms: time.TimestampMs,
) !Activation {
    _ = try store.loadFsrs7Parameters(target_id);
    const previous = try store.resolveDeckScheduler(deck_id, activated_at_ms);
    if (!previous.algorithm.eql(.fsrs7)) return error.IncompatibleParameterSet;
    try store.setDeckFsrs7(deck_id, target_id);
    return .{
        .deck_id = deck_id,
        .previous_parameter_set_id = previous.parameter_set_id,
        .active_parameter_set_id = target_id,
        .activated_at_ms = activated_at_ms,
    };
}

test "activation audit retains the previous immutable parameter identity" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    try db.migrate();
    var store: storage.Store = .{ .sqlite = &db };
    const deck_id = try store.createDeck("lifecycle", 0);
    const first = try store.ensureDefaultFsrs7(0);
    try store.setDeckFsrs7(deck_id, first);
    var parameters: fsrs.v7.Parameters = .{};
    parameters.desired_retention = 0.95;
    const second = try store.putFsrs7Parameters(parameters, "candidate", 1);
    const audit = try activateDeck(&store, deck_id, second, 2);
    try std.testing.expect(std.mem.eql(u8, audit.previous_parameter_set_id[0..], first[0..]));
    try std.testing.expect(std.mem.eql(u8, audit.active_parameter_set_id[0..], second[0..]));
    _ = try store.loadFsrs7Parameters(first);
}
