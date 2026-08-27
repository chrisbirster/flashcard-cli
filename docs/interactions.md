# Interactive built-in note types

Deez v0.2.0-rc.4.1 adds four built-in logical note types intended for richer study material while preserving the same content-only `.nut` v2 model.

The terminal client renders deterministic self-grade fallbacks. Future graphical clients can use the same structured fields to provide clickable choices, drag-and-drop ordering, and visual image masks without changing the deck format.

## Multiple choice

Slug:

```text
multiple-choice
```

Fields:

1. `Prompt`
2. `Choices`
3. `Correct`
4. `Explanation`

`Choices` is JSON. Each choice has a stable `id` and display `text`:

```json
[
  {"id":"array","text":"Array"},
  {"id":"hash-table","text":"Hash table"},
  {"id":"linked-list","text":"Linked list"}
]
```

`Correct` contains the stable ID, not a letter or array position:

```text
hash-table
```

Example `.nut` note:

```json
{"kind":"note","note_type":"multiple-choice","fields":["Which structure normally provides average O(1) key lookup?","[{\"id\":\"array\",\"text\":\"Array\"},{\"id\":\"hash-table\",\"text\":\"Hash table\"},{\"id\":\"linked-list\",\"text\":\"Linked list\"}]","hash-table","Hash tables use hashing to locate a bucket."],"tags_json":"[\"data-structures\"]"}
```

Choice IDs let a client randomize presentation order without changing which answer is correct.

## Multiple select

Slug:

```text
multiple-select
```

Fields:

1. `Prompt`
2. `Choices`
3. `Correct`
4. `Explanation`

`Choices` uses the same stable-ID JSON objects as multiple choice.

`Correct` is a JSON array of choice IDs:

```json
["push","pop"]
```

Example:

```json
{"kind":"note","note_type":"multiple-select","fields":["Which operations are normally O(1) on a stack?","[{\"id\":\"push\",\"text\":\"Push\"},{\"id\":\"pop\",\"text\":\"Pop\"},{\"id\":\"search\",\"text\":\"Search arbitrary item\"}]","[\"push\",\"pop\"]","A stack exposes constant-time operations at one end."],"tags_json":"[\"data-structures\",\"stack\"]"}
```

Correct IDs must exist in `Choices` and may not be duplicated.

## Ordering

Slug:

```text
ordering
```

Fields:

1. `Prompt`
2. `Items`
3. `Explanation`

`Items` is a JSON array in the canonical correct order. Each item has a stable ID and display text:

```json
[
  {"id":"hash","text":"Hash the key"},
  {"id":"bucket","text":"Choose the bucket"},
  {"id":"compare","text":"Compare candidate keys"},
  {"id":"return","text":"Return the matching value"}
]
```

The stored order is authoritative. Presentation order is deliberately not part of the note identity, so clients are free to shuffle the items during study.

## Image occlusion

Slug:

```text
image-occlusion
```

Fields:

1. `Image`
2. `Masks`
3. `Extra`

`Image` must be an existing Deez content-addressed media reference:

```text
deez-media://sha256:<64 lowercase hex characters>
```

`Masks` is JSON. Coordinates are normalized from `0.0` to `1.0` relative to the image dimensions:

```json
[
  {
    "id": 1,
    "x": 0.10,
    "y": 0.15,
    "width": 0.25,
    "height": 0.10,
    "answer": "Root node",
    "prompt": "Name this part of the tree"
  },
  {
    "id": 2,
    "x": 0.10,
    "y": 0.40,
    "width": 0.25,
    "height": 0.10,
    "answer": "Left child"
  }
]
```

Each mask produces one generated card. The stable generation key is:

```text
note:<note-id>:occlusion:<mask-id>
```

Mask IDs must be positive and unique within the note. Reordering the masks does not change card identities. This is important because review history stays attached to the same semantic mask rather than to its array position.

The terminal fallback prints the media reference and normalized rectangle. A graphical client can use the same fields to draw the mask directly over the image.

## CLI examples

Multiple choice:

```bash
deez note add 1 multiple-choice \
  "Which structure normally provides average O(1) lookup?" \
  '[{"id":"array","text":"Array"},{"id":"hash","text":"Hash table"}]' \
  "hash" \
  "Hash tables use hashing."
```

Ordering:

```bash
deez note add 1 ordering \
  "Put hash lookup in order" \
  '[{"id":"hash","text":"Hash the key"},{"id":"bucket","text":"Choose the bucket"},{"id":"return","text":"Return the value"}]' \
  ""
```

Image occlusion normally starts by importing media:

```bash
deez media add tree.png
```

Then use the returned `deez-media://sha256:...` reference in the note. Export the deck as `.sack` when the media must travel with the nut.

## Data safety

These note types do not alter scheduling semantics. Generated cards still own immutable review history, and content edits update cards by stable generation identity rather than replacing reviewed cards solely because their rendered text changed.
