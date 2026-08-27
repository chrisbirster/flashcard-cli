const std = @import("std");

pub const model = @import("model.zig");
pub const parameters = @import("parameters.zig");
pub const scheduler = @import("scheduler.zig");
pub const optimizer = @import("optimizer.zig");
pub const evaluator = @import("evaluator.zig");
pub const time_series_split = @import("time_series_split.zig");
pub const simulator = @import("simulator.zig");
pub const trajectory = @import("trajectory.zig");
pub const forecast = @import("forecast.zig");
pub const retention = @import("retention.zig");
pub const migration = @import("migration.zig");

pub const MemoryState = model.MemoryState;
pub const Parameters = parameters.Parameters;
pub const Engine = scheduler.Engine;

pub const algorithm_major: u16 = 7;

test {
    std.testing.refAllDecls(@This());
    _ = @import("parity_tests.zig");
    _ = @import("scheduler_parity_tests.zig");
    _ = @import("optimizer_reference_tests.zig");
    _ = @import("property_tests.zig");
}
