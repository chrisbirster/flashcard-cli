pub const CardId = u64;
pub const DeckId = u64;

pub const Card = struct {
    id: CardId,
    deck_id: DeckId,
    question: []const u8,
    answer: []const u8,
};
