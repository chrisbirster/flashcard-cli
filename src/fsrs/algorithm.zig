const std = @import("std");

pub const Family = enum {
    fsrs,
};

pub const AlgorithmId = struct {
    family: Family,
    major: u16,

    pub const fsrs7: AlgorithmId = .{ .family = .fsrs, .major = 7 };

    pub fn eql(a: AlgorithmId, b: AlgorithmId) bool {
        return a.family == b.family and a.major == b.major;
    }

    pub fn parse(text: []const u8) !AlgorithmId {
        const prefix = "fsrs/";
        if (!std.mem.startsWith(u8, text, prefix)) return error.InvalidAlgorithmId;
        const major_text = text[prefix.len..];
        if (major_text.len == 0) return error.InvalidAlgorithmId;
        const major = std.fmt.parseInt(u16, major_text, 10) catch return error.InvalidAlgorithmId;
        if (major == 0) return error.InvalidAlgorithmId;
        return .{ .family = .fsrs, .major = major };
    }
};

pub const ImplementationVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub const current: ImplementationVersion = .{ .major = 0, .minor = 1, .patch = 0 };

    pub fn eql(a: ImplementationVersion, b: ImplementationVersion) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch;
    }
};

pub const ParameterSetId = [32]u8;

pub const ParameterSetIdentity = struct {
    id: ParameterSetId,
    algorithm: AlgorithmId,

    pub fn validateFor(self: ParameterSetIdentity, algorithm: AlgorithmId) !void {
        if (!self.algorithm.eql(algorithm)) return error.IncompatibleParameterSet;
    }
};

pub const SchedulerStamp = struct {
    algorithm: AlgorithmId,
    implementation: ImplementationVersion,
    parameter_set_id: ParameterSetId,
};

test "algorithm ids parse and compare" {
    const parsed = try AlgorithmId.parse("fsrs/7");
    try std.testing.expect(parsed.eql(.fsrs7));
    try std.testing.expect(!(try AlgorithmId.parse("fsrs/8")).eql(.fsrs7));
    try std.testing.expectError(error.InvalidAlgorithmId, AlgorithmId.parse("fsrs/"));
}

test "parameter sets reject cross-version use" {
    const id = [_]u8{0} ** 32;
    const identity: ParameterSetIdentity = .{ .id = id, .algorithm = .fsrs7 };
    try identity.validateFor(.fsrs7);
    try std.testing.expectError(error.IncompatibleParameterSet, identity.validateFor(.{ .family = .fsrs, .major = 8 }));
}
