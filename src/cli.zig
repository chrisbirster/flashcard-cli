const DeckId = @import("card.zig").DeckId;
const CardId = @import("card.zig").CardId;
const NoteId = @import("content.zig").NoteId;

pub const HelpTopic = enum {
    general,
    deck,
    note,
    card,
    study,
    stats,
    inspect,
    fsrs,
    scheduler,
};

pub const StudyOrder = enum {
    due,
    reviews_first,
    new_first,
};

pub const StatsWindow = enum {
    all,
    today,
    week,
    month,
    year,
};

/// Parsed Plandalf application commands. Thrawn owns CLI mechanics and
/// translates the selected command tree node into this domain command union.
pub const Command = union(enum) {
    help: HelpTopic,
    decks,
    cards: struct { deck_id: DeckId },
    deck_add: struct { name: []const u8 },
    deck_rename: struct { deck_id: DeckId, name: []const u8 },
    deck_delete: struct { deck_id: DeckId },
    deck_export: struct { deck_id: DeckId },
    deck_import: struct { path: []const u8 },
    note_add: struct {
        deck_id: DeckId,
        note_type: []const u8,
        fields: []const []const u8,
    },
    note_edit: struct {
        deck_id: DeckId,
        note_id: NoteId,
        fields: []const []const u8,
    },
    card_add: struct { deck_id: DeckId, question: []const u8, answer: []const u8 },
    card_edit: struct { card_id: CardId, question: []const u8, answer: []const u8 },
    card_delete: struct { card_id: CardId },
    study: struct {
        deck_id: DeckId,
        new_limit: ?usize,
        order: StudyOrder,
        shuffle: bool,
    },
    stats: struct { deck_id: ?DeckId, json: bool, window: StatsWindow },
    inspect: struct { card_id: CardId, json: bool },
    fsrs_optimize: struct { deck_id: ?DeckId, recency_half_life_days: ?f64 },
    fsrs_evaluate: struct { deck_id: ?DeckId },
    fsrs_simulate: struct { retention: ?f64 },
    fsrs_retention,
    scheduler_list,
};

pub const help_text =
    \\Plandalf — spaced repetition that arrives precisely when it means to.
    \\
    \\Usage:
    \\  plandalf setup
    \\  plandalf help [deck|note|card|study|stats|inspect|fsrs|scheduler]
    \\  plandalf add [deck-id]
    \\  plandalf decks
    \\  plandalf cards <deck-id>
    \\  plandalf deck add <name>
    \\  plandalf deck rename <deck-id> <name>
    \\  plandalf deck delete <deck-id> --yes
    \\  plandalf deck export <deck-id> > deck.deck
    \\  plandalf deck import <deck.deck>
    \\  plandalf note add [deck-id]
    \\  plandalf note add <deck-id> <note-type> <fields...>
    \\  plandalf note edit <deck-id> <note-id> <fields...>
    \\  plandalf card add <deck-id> <question> <answer>
    \\  plandalf card edit <card-id> <question> <answer>
    \\  plandalf card delete <card-id> --yes
    \\  plandalf study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
    \\  plandalf stats [deck-id] [--period all|today|week|month|year] [--json]
    \\  plandalf inspect <card-id> [--json]
    \\  plandalf fsrs optimize [deck-id] [--recency]
    \\  plandalf fsrs evaluate [deck-id]
    \\  plandalf fsrs simulate [--retention <0..1>]
    \\  plandalf fsrs retention
    \\  plandalf scheduler list
;

const deck_help =
    \\Deck commands:
    \\  plandalf decks
    \\  plandalf deck add <name>
    \\  plandalf deck rename <deck-id> <name>
    \\  plandalf deck delete <deck-id> --yes
    \\  plandalf deck export <deck-id> > deck.deck
    \\  plandalf deck import <deck.deck>
    \\
    \\.deck is Plandalf's shareable line-oriented JSON deck format.
;

const note_help =
    \\Note commands:
    \\  plandalf add [deck-id]                         Guided note authoring
    \\  plandalf note add [deck-id]                    Guided note authoring
    \\  plandalf note add <deck-id> basic <front> <back>
    \\  plandalf note add <deck-id> reverse <front> <back>
    \\  plandalf note add <deck-id> cloze <text> <extra>
    \\  plandalf note add <deck-id> type-answer <front> <back>
    \\  plandalf note add <deck-id> multiple-choice <prompt> <choices-json> <correct> <explanation>
    \\  plandalf note add <deck-id> multiple-select <prompt> <choices-json> <correct-json> <explanation>
    \\  plandalf note add <deck-id> ordering <prompt> <items-json> <explanation>
    \\  plandalf note add <deck-id> image-occlusion <image-ref> <masks-json> <extra>
    \\  plandalf note edit <deck-id> <note-id> <fields...>
;

const card_help =
    \\Card commands:
    \\  plandalf cards <deck-id>
    \\  plandalf card add <deck-id> <question> <answer>
    \\  plandalf card edit <card-id> <question> <answer>
    \\  plandalf card delete <card-id> --yes
;

const study_help =
    \\Study command:
    \\  plandalf study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
    \\
    \\Defaults preserve timestamp order and do not limit new cards or shuffle.
;

const stats_help =
    \\Stats command:
    \\  plandalf stats [deck-id] [--period all|today|week|month|year] [--json]
    \\
    \\The summary keeps current deck/card/due totals and adds immutable review-history metrics.
;
const inspect_help = "Usage: plandalf inspect <card-id> [--json]\n";

const fsrs_help =
    \\FSRS commands:
    \\  plandalf fsrs optimize [deck-id] [--recency]
    \\  plandalf fsrs evaluate [deck-id]
    \\  plandalf fsrs simulate [--retention <0..1>]
    \\  plandalf fsrs retention
;

const scheduler_help = "Usage: plandalf scheduler list\n";

pub fn helpText(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .general => help_text,
        .deck => deck_help,
        .note => note_help,
        .card => card_help,
        .study => study_help,
        .stats => stats_help,
        .inspect => inspect_help,
        .fsrs => fsrs_help,
        .scheduler => scheduler_help,
    };
}
