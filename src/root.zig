const std = @import("std");

pub const time = @import("time.zig");
pub const card = @import("card.zig");
pub const deck = @import("deck.zig");
pub const content = @import("content.zig");
pub const interaction = @import("interaction.zig");
pub const card_render = @import("card_render.zig");
pub const card_types = @import("card_types.zig");
pub const note_mutation = @import("note_mutation.zig");
pub const note_service = @import("note_service.zig");
pub const portable_content = @import("portable_content.zig");
pub const render = @import("render.zig");
pub const media = @import("media.zig");
pub const rich_cli = @import("rich_cli.zig");
pub const author_cli = @import("author_cli.zig");
pub const review = @import("review.zig");
pub const fsrs = @import("fsrs/root.zig");
pub const storage = @import("storage/root.zig");
pub const study = @import("study.zig");
pub const recovery = @import("recovery.zig");
pub const scheduler_migration = @import("scheduler_migration.zig");
pub const cli = @import("cli.zig");
pub const thrawn_cli = @import("cli_tree.zig");
pub const config = @import("config.zig");
pub const deck_file = @import("deck_file.zig");
pub const notes_cli = @import("notes_cli.zig");
pub const web = @import("web.zig");
pub const web_cli = @import("web_cli.zig");
pub const app = @import("app.zig");
pub const server = @import("server.zig");
pub const import = @import("import/root.zig");

pub const Card = card.Card;
pub const CardId = card.CardId;
pub const Deck = deck.Deck;
pub const DeckId = card.DeckId;
pub const NoteId = content.NoteId;
pub const NoteTypeId = content.NoteTypeId;
pub const Review = review.Review;
pub const ReviewId = review.ReviewId;
pub const Db = storage.Db;
pub const Study = study.Study;

test {
    std.testing.refAllDecls(@This());
    _ = @import("thrawn_cli_test.zig");
    _ = @import("cli_tree_lifetime_test.zig");
    _ = @import("interaction_roundtrip_test.zig");
    _ = @import("study_replay_tests.zig");
    _ = @import("terminal_acceptance_test.zig");
    _ = @import("fuzz_tests.zig");
}
