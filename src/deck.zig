const DeckId = @import("card.zig").DeckId;

pub const Deck = struct {
    id: DeckId,
    name: []const u8,
};
