# Template rendering

Plandalf uses one deterministic template renderer for terminal and graphical clients.

The renderer operates on a `NoteTypeDefinition`, its field values, a template ordinal, and rendering options.

## Supported template syntax

### Fields

```text
{{Front}}
{{Back}}
```

A field token inserts the value of the named note field.

### FrontSide

```text
{{FrontSide}}
```

On a back template, `FrontSide` inserts the rendered front of the card.

### Conditional sections

Render when a field is non-empty:

```text
{{#Extra}}
{{Extra}}
{{/Extra}}
```

Render when a field is empty:

```text
{{^Extra}}
No extra information
{{/Extra}}
```

### Cloze

```text
{{cloze:Text}}
```

Cloze rendering requires an explicit cloze ordinal.

For:

```text
Paris is the capital of {{c1::France}}.
```

ordinal `1` renders a front with the answer hidden and a back with the answer revealed.

Cloze hints use:

```text
{{c1::France::country}}
```

which renders `[country]` on the front.

### Type in the answer

```text
{{type:Back}}
```

The rich renderer emits a type-answer placeholder and exposes the expected value through `RenderedCard.typed_answer`. Terminal/plain-text rendering removes the placeholder while retaining typed-answer metadata.

## Rendering modes

### `html`

Preserves supported presentation markup and returns note-type CSS for graphical clients.

### `plain_text`

Uses the same template evaluation first, then converts the result to terminal-safe text. The terminal is not a separate rendering implementation.

## Built-in card generation

Built-in note types flow through the same renderer:

```text
Note
  -> card_types.drafts()
  -> render.renderCard()
  -> CardDraft
  -> SQLite storage
```

Generated-card identity remains independent from presentation:

```text
note:<note-id>:template:<ordinal>
note:<note-id>:cloze:<ordinal>
note:<note-id>:occlusion:<mask-id>
```

Changing rendered presentation does not intentionally replace card IDs or immutable review history.

## Safety

Plandalf templates support presentation markup but not arbitrary executable code.

The renderer rejects constructs such as:

```text
<script
javascript:
expression(
onclick=
```

Custom templates are data, not executable JavaScript.

## Determinism

Given the same note type, field values, template ordinal, cloze ordinal, and rendering mode, the renderer must produce the same result regardless of whether it is called from the terminal or local web/API interface.

Golden tests in `src/render.zig` protect built-in rendering behavior.
