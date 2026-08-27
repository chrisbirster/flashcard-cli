const DeckId = @import("card.zig").DeckId;
const CardId = @import("card.zig").CardId;
const NoteId = @import("content.zig").NoteId;

/// Domain-level help topics retained by the application layer.
/// Command resolution and argument parsing live in thrawn_cli.zig.
pub const HelpTopic = enum {
    general,
    deck,
    nut,
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

/// Parsed Deez application commands. Thrawn owns CLI mechanics and translates
/// the selected command tree node into this domain command union.
pub const Command = union(enum) {
    help: HelpTopic,
    decks,
    cards: struct { deck_id: DeckId },
    deck_add: struct { name: []const u8 },
    deck_rename: struct { deck_id: DeckId, name: []const u8 },
    deck_delete: struct { deck_id: DeckId },
    deck_export: struct { deck_id: DeckId },
    deck_import: struct { path: []const u8 },
    nut_export: struct { deck_id: DeckId },
    nut_import: struct { path: []const u8 },
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
    stats: struct { deck_id: ?DeckId, json: bool },
    inspect: struct { card_id: CardId, json: bool },
    fsrs_optimize: struct { deck_id: ?DeckId, recency_half_life_days: ?f64 },
    fsrs_evaluate: struct { deck_id: ?DeckId },
    fsrs_simulate: struct { retention: ?f64 },
    fsrs_retention,
    scheduler_list,
};

pub const help_text =
    \\DEEZ — Drill, Evaluate, Encode, Zen
    \\
    \\Usage:
    \\  deez setup
    \\  deez help [deck|nut|note|card|study|stats|inspect|fsrs|scheduler]
    \\  deez decks
    \\  deez nuts
    \\  deez nut export <deck-id> > deck.nut
    \\  deez nut import <deck.nut>
    \\  deez cards <deck-id>
    \\  deez deck add <name>
    \\  deez deck rename <deck-id> <name>
    \\  deez deck delete <deck-id> --yes
    \\  deez deck export <deck-id> > deck.json
    \\  deez deck import <deck.json|deck.nut>
    \\  deez note add <deck-id> <basic|reverse|optional-reverse|cloze|type-answer> <fields...>
    \\  deez note edit <deck-id> <note-id> <fields...>
    \\  deez card add <deck-id> <question> <answer>
    \\  deez card edit <card-id> <question> <answer>
    \\  deez card delete <card-id> --yes
    \\  deez study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
    \\  deez stats [deck-id] [--json]
    \\  deez inspect <card-id> [--json]
    \\  deez fsrs optimize [deck-id] [--recency]
    \\  deez fsrs evaluate [deck-id]
    \\  deez fsrs simulate [--retention <0..1>]
    \\  deez fsrs retention
    \\  deez scheduler list
;

const deck_help =
    \\Deck commands:
    \\  deez decks
    \\  deez deck add <name>
    \\  deez deck rename <deck-id> <name>
    \\  deez deck delete <deck-id> --yes
    \\  deez deck export <deck-id> > deck.json
    \\  deez deck import <deck.json|deck.nut>
;

const nut_help =
    \\Nut commands:
    \\  deez nuts
    \\  deez nut export <deck-id> > deck.nut
    \\  deez nut import <deck.nut>
    \\
    \\`deez nuts` lists the same stored decks as `deez decks`.
    \\.nut files are line-oriented JSON deck files for sharing deck content.
;

const note_help =
    \\Note commands:
    \\  deez note add <deck-id> basic <front> <back>
    \\  deez note add <deck-id> reverse <front> <back>
    \\  deez note add <deck-id> optional-reverse <front> <back> <add-reverse>
    \\  deez note add <deck-id> cloze <text> <extra>
    \\  deez note add <deck-id> type-answer <front> <back>
    \\  deez note edit <deck-id> <note-id> <fields...>
;

const card_help =
    \\Card commands:
    \\  deez cards <deck-id>
    \\  deez card add <deck-id> <question> <answer>
    \\  deez card edit <card-id> <question> <answer>
    \\  deez card delete <card-id> --yes
;

const study_help =
    \\Study command:
    \\  deez study <deck-id> [--new-limit <count>] [--order due|reviews-first|new-first] [--shuffle]
    \\
    \\Defaults preserve timestamp order and do not limit new cards or shuffle.
;

const stats_help = "Usage: deez stats [deck-id] [--json]\n";
const inspect_help = "Usage: deez inspect <card-id> [--json]\n";

const fsrs_help =
    \\FSRS commands:
    \\  deez fsrs optimize [deck-id] [--recency]
    \\  deez fsrs evaluate [deck-id]
    \\  deez fsrs simulate [--retention <0..1>]
    \\  deez fsrs retention
;

const scheduler_help = "Usage: deez scheduler list\n";

pub fn helpText(topic: HelpTopic) []const u8 {
    return switch (topic) {
        .general => help_text,
        .deck => deck_help,
        .nut => nut_help,
        .note => note_help,
        .card => card_help,
        .study => study_help,
        .stats => stats_help,
        .inspect => inspect_help,
        .fsrs => fsrs_help,
        .scheduler => scheduler_help,
    };
}
