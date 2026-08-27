# Getting started with Deez

This page is the shortest path from installing Deez to studying a real deck.

## The five things to understand

Think of Deez like a box of study cards:

```text
Deck
  -> Notes
      -> generated Cards
          -> Reviews
```

### Deck

A **deck** is a collection of material you want to study, such as `Data Structures`.

```bash
deez deck add "Data Structures"
deez decks
```

`deez nuts` is intentionally an alias for `deez decks`.

### Note

A **note** is the source material you create or import.

For example, this is one Basic note:

```text
Question: What is a stack?
Answer:   A LIFO data structure.
```

Add it with:

```bash
deez note add 1 basic \
  "What is a stack?" \
  "A LIFO data structure."
```

The `1` is the deck ID shown by `deez decks`.

### Card

A **card** is what Deez actually schedules and shows during study.

One note can generate one or more cards.

For example, a reverse note:

```bash
deez note add 1 reverse "LIFO" "Last in, first out"
```

generates both directions:

```text
LIFO -> Last in, first out
Last in, first out -> LIFO
```

A cloze note can also generate multiple cards from one logical note.

Compare the source notes with generated cards using:

```bash
deez notes 1
deez cards 1
```

This distinction matters because review history belongs to the generated card identity while the note remains the editable source content.

### `.nut`

A **`.nut` file** is Deez's human-readable, shareable representation of a deck.

It contains the deck name and logical notes, but not your personal study history.

The easiest workflow for a large deck is usually:

```text
Author deck
   -> data-structures.nut
       -> deez nut import data-structures.nut
           -> deez study <deck-id>
```

Import a nut with:

```bash
deez nut import data-structures.nut
deez nuts
```

Export a deck you already have:

```bash
deez nut export 1 > data-structures.nut
```

### `.sack`

A **`.sack` file** is a rich-media bundle.

It packages:

```text
deck.nut
+ images/audio/video used by the deck
```

Use `.nut` when the deck is text-only. Use `.sack` when the deck needs media.

```bash
deez sack import data-structures.sack
deez sack export 1 data-structures.sack
```

## First run

Run:

```bash
deez setup
```

For the simplest local setup, choose SQLite or press Enter when SQLite is the default.

The default database is stored at:

```text
~/.local/share/deez/deez.db
```

You can switch to MongoDB later without changing the deck-authoring concepts described here.

## Your first Data Structures deck

Create a deck:

```bash
deez deck add "Data Structures"
deez decks
```

Assume the new deck ID is `1`.

Add a Basic note:

```bash
deez note add 1 basic \
  "What is a stack?" \
  "A data structure that follows last-in, first-out (LIFO) order."
```

Add a reverse note:

```bash
deez note add 1 reverse \
  "LIFO" \
  "Last in, first out"
```

Add a cloze note:

```bash
deez note add 1 cloze \
  "A {{c1::stack}} follows last-in, first-out order." \
  "Data Structures"
```

Add a typed-answer note:

```bash
deez note add 1 type-answer \
  "What does LIFO stand for?" \
  "Last in, first out"
```

Inspect what you created:

```bash
deez notes 1
deez cards 1
```

Then study:

```bash
deez study 1
```

During review:

```text
1 Again
2 Hard
3 Good
4 Easy
```

Deez uses those ratings with FSRS to decide when the card should appear again.

## Built-in note types

The original built-ins are:

```text
basic
basic-reverse / reverse
optional-reverse
cloze
type-answer
```

RC4.1 adds:

```text
multiple-choice
multiple-select
ordering
image-occlusion
```

The interactive types use structured data so future graphical clients can render buttons, multi-select controls, drag ordering, and image masks without guessing from plain text.

For interactive notes, prefer generating a `.nut` file rather than typing JSON-heavy fields manually at the shell.

## Recommended authoring workflow

For a serious deck such as Data Structures:

1. Design the curriculum first.
2. Generate the logical notes as a `.nut` file.
3. Import the file into Deez.
4. Inspect `deez notes` and `deez cards`.
5. Study the deck and improve weak or ambiguous cards.
6. Re-export the polished deck for sharing.

Example:

```bash
deez nut import data-structures.nut
deez nuts
deez notes 1
deez cards 1
deez study 1
```

This is generally easier than authoring hundreds of notes individually through shell commands.

## `.nut` is not your backup

A `.nut` deliberately does **not** include:

- your review history
- due dates
- difficulty
- stability
- FSRS parameter state

That is what makes a nut safe to share with someone else: they get the content and start with fresh study history.

Use Deez backup/restore when the goal is to preserve your own complete study database.

## Quick command cheat sheet

```bash
# Configure storage
deez setup

# Decks
deez deck add "Data Structures"
deez decks
deez nuts

# Content
deez notes 1
deez cards 1

# Study
deez study 1

# Share a text deck
deez nut export 1 > data-structures.nut
deez nut import data-structures.nut

# Share a deck with media
deez sack export 1 data-structures.sack
deez sack import data-structures.sack
```

For the precise file format, see `docs/nut-format.md`. For media bundles, see `docs/sack-format.md`. For the interactive note schemas added in RC4.1, see `docs/interactions.md`.
