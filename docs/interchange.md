# Deez Interchange Format v1

Deez exports study data as a UTF-8, tab-separated, line-oriented archive. The first line is always:

```text
DEEZ	1
```

Fields containing arbitrary text or binary identifiers are lowercase hexadecimal. `-` represents a nullable field. Integers use base 10 and floating-point values use a round-trippable decimal representation.

Records are emitted in dependency order:

```text
DEEZ	1
PARAM	<id-hex>	<algorithm-family>	<algorithm-major>	<impl-major>	<impl-minor>	<impl-patch>	<source-hex>	<retention>	<min-days>	<max-days>	<created-ms>
WEIGHT	<parameter-id-hex>	<position>	<value>
DEFAULT	<algorithm-family>	<algorithm-major>	<parameter-id-hex-or-->
GROUP	<id>	<name-hex>	<algorithm-family-or-->	<algorithm-major-or-->	<parameter-id-hex-or-->	<created-ms>
DECK	<id>	<name-hex>	<group-id-or-->	<algorithm-family-or-->	<algorithm-major-or-->	<parameter-id-hex-or-->	<created-ms>
CARD	<id>	<deck-id>	<question-hex>	<answer-hex>	<created-ms>
REVIEW	<id>	<card-id>	<rating>	<reviewed-ms>	<algorithm-family-or-->	<algorithm-major-or-->	<impl-major-or-->	<impl-minor-or-->	<impl-patch-or-->	<parameter-id-hex-or-->	<scheduled-ms-or-->
```

`REVIEW` records are the source of truth. `scheduler_state` is deliberately not exported because it is derived data and must be reconstructable from review history plus the selected scheduler and parameter set.

## Compatibility rules

- Readers must reject an unsupported major archive version instead of guessing.
- Unknown record types may be skipped only when a future archive version explicitly marks them optional; v1 rejects unknown records.
- Parameter identifiers and review timestamps are preserved exactly.
- Import must be transactional. A malformed archive cannot partially mutate the destination database.
- Import never translates FSRS internal state between major versions. State is rebuilt from immutable review history.
