const std = @import("std");

pub const schema = @import("schema.zig");
pub const sqlite = @import("sqlite.zig");
pub const mongodb = @import("mongodb.zig");
pub const store = @import("store.zig");
pub const card_lifecycle = @import("card_lifecycle.zig");
pub const sqlite_content = @import("sqlite_content.zig");
pub const mongodb_content = @import("mongodb_content.zig");
pub const content_store = @import("content_store.zig");
pub const content_membership = @import("content_membership.zig");
pub const note_type_store = @import("note_type_store.zig");
pub const generated_card_store = @import("generated_card_store.zig");
pub const catalog = @import("catalog.zig");
pub const report = @import("report.zig");
pub const backup = @import("backup.zig");
pub const recovery = @import("recovery.zig");
pub const migration_commit = @import("migration_commit.zig");

pub const Db = sqlite.Db;
pub const Store = store.Store;
pub const ContentStore = content_store.ContentStore;
pub const ContentMembership = content_membership.ContentMembership;
pub const MongoStore = mongodb.Store;
pub const OwnedDeck = sqlite.OwnedDeck;
pub const OwnedCard = sqlite.OwnedCard;
pub const ParameterSetRecord = sqlite.ParameterSetRecord;
pub const SchedulerStateRecord = sqlite.SchedulerStateRecord;
pub const Catalog = catalog.Catalog;
pub const ResolvedScheduler = catalog.ResolvedScheduler;
pub const OwnedDueCard = catalog.OwnedDueCard;
pub const SchedulerState = catalog.SchedulerState;
pub const Report = report.Report;
pub const DeckSummary = report.DeckSummary;
pub const Stats = report.Stats;
pub const OwnedHistories = report.OwnedHistories;

pub const IntegrityResult = recovery.IntegrityResult;

pub fn checkIntegrity(allocator: std.mem.Allocator, db: *Db) !IntegrityResult {
    return recovery.check(allocator, db);
}

test {
    std.testing.refAllDecls(@This());
}
