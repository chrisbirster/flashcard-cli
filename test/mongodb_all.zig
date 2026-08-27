const std = @import("std");

test {
    _ = @import("mongodb_integration.zig");
    _ = @import("mongodb_scheduler_pinning.zig");
    _ = @import("mongodb_parameter_sets.zig");
    _ = @import("mongodb_durable_history.zig");
    _ = @import("mongodb_parameter_scopes.zig");
    _ = @import("mongodb_interchange.zig");
    _ = @import("mongodb_deck_json.zig");
    _ = @import("mongodb_nut.zig");
    _ = @import("mongodb_content.zig");
    _ = @import("mongodb_card_types.zig");
    _ = @import("mongodb_note_mutation.zig");
    _ = @import("mongodb_recovery.zig");
    _ = @import("mongodb_scheduler_migration.zig");
}
