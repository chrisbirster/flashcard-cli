const std = @import("std");
const builtin = @import("builtin");
const AlgorithmId = @import("algorithm.zig").AlgorithmId;
const engine_mod = @import("engine.zig");
const Engine = engine_mod.Engine;

pub const Capabilities = struct {
    schedule: bool,
    optimize: bool,
    evaluate: bool,
    simulate: bool,
    retention_analysis: bool,
    replay_history: bool,
};

pub const Status = enum {
    supported,
};

pub const Descriptor = struct {
    algorithm: AlgorithmId,
    name: []const u8,
    status: Status,
    capabilities: Capabilities,
};

pub const fsrs7: Descriptor = .{
    .algorithm = .fsrs7,
    .name = "FSRS-7",
    .status = .supported,
    .capabilities = .{
        .schedule = true,
        .optimize = true,
        .evaluate = true,
        .simulate = true,
        .retention_analysis = true,
        .replay_history = true,
    },
};

const fixture: Descriptor = .{
    .algorithm = engine_mod.fixture_algorithm,
    .name = "test-fixture",
    .status = .supported,
    .capabilities = .{
        .schedule = true,
        .optimize = false,
        .evaluate = false,
        .simulate = false,
        .retention_analysis = false,
        .replay_history = true,
    },
};

/// Published production engines. Test fixtures are intentionally absent.
pub const supported = [_]Descriptor{fsrs7};

pub fn lookup(algorithm: AlgorithmId) ?Descriptor {
    for (supported) |descriptor| {
        if (descriptor.algorithm.eql(algorithm)) return descriptor;
    }
    if (builtin.is_test and algorithm.eql(fixture.algorithm)) return fixture;
    return null;
}

pub fn createDefault(algorithm: AlgorithmId) !Engine {
    _ = lookup(algorithm) orelse return error.UnsupportedAlgorithm;
    return Engine.forAlgorithm(algorithm);
}

test "registry resolves FSRS-7 and rejects unpublished FSRS-8" {
    try std.testing.expect(lookup(.fsrs7) != null);
    try std.testing.expect(lookup(.{ .family = .fsrs, .major = 8 }) == null);
    try std.testing.expectError(
        error.UnsupportedAlgorithm,
        createDefault(.{ .family = .fsrs, .major = 8 }),
    );
}

test "registry resolves fixture engine only in tests" {
    const descriptor = lookup(engine_mod.fixture_algorithm) orelse return error.MissingFixture;
    try std.testing.expect(descriptor.capabilities.schedule);
    try std.testing.expect(!descriptor.capabilities.optimize);
    const fixture_engine = try createDefault(engine_mod.fixture_algorithm);
    try std.testing.expect(fixture_engine.algorithm().eql(engine_mod.fixture_algorithm));
    try std.testing.expectEqual(@as(usize, 1), supported.len);
}
