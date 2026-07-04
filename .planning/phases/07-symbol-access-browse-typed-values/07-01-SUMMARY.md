---
phase: 07-symbol-access-browse-typed-values
plan: 01
subsystem: api
tags: [ads, symbols, sym-upload, byte-parsing, typed-data, latin1]

# Dependency graph
requires:
  - phase: 06-sum-batched-commands
    provides: "sum_commands._requireBlock subtraction-safe bounds-check pattern; pure protocol-layer conventions (dart:typed_data + exceptions.dart, not barrel-exported)"
provides:
  - "AdsSymbolInfo pure value type (name/typeName/comment/indexGroup/indexOffset/size/dataTypeId/flags)"
  - "parseSymbolBlob(Uint8List, int nSymbols) -> List<AdsSymbolInfo> — pure SYM_UPLOAD (0xF00B) blob parser"
  - "Hostile-blob hardening: subtraction-safe guards throw MalformedFrameException, never RangeError"
affects: [symbol-browse-client, mock-symbol-table, symbol-golden-parity, cli-browse]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Variable-length record parse: advance cursor by declared entryLength, never by summed field sizes (forward-compat with padded/extended entries)"
    - "String length fields are authoritative; NUL is a skip-1 separator (read exactly N bytes, do NOT scan for NUL)"
    - "Per-field subtraction-safe bounds guard mirroring sum_commands._requireBlock, scoped to [cursor+30, cursor+entryLength)"

key-files:
  created:
    - lib/src/protocol/symbols.dart
    - test/unit/symbols_parse_test.dart
  modified: []

key-decisions:
  - "AdsSymbolInfo does NOT store entryLength — it is a parse-advancement detail, not public symbol metadata"
  - "Over-count (nSymbols > entries) breaks early cleanly (no throw) when the cursor reaches blob end; under-count stops after N leaving trailing bytes"
  - "Bounds checks are scoped to the entry window [cursor+30, cursor+entryLength), so a lying string length throws MalformedFrameException before any slice"

patterns-established:
  - "Pure SYM_UPLOAD parser lives in protocol/symbols.dart, imports only dart:typed_data + dart:convert(latin1) + exceptions.dart, NOT re-exported by the barrel"
  - "In-Dart byte-exact fixtures via a parameterized _entry() builder with padding/override hooks for hostile cases"

requirements-completed: [SYM-02]

# Metrics
duration: 6min
completed: 2026-07-04
---

# Phase 7 Plan 01: SYM_UPLOAD Blob Parser Summary

**Pure, socket-free `parseSymbolBlob` ports Beckhoff `SymbolEntry::Parse` 1:1 — turns an untrusted SYM_UPLOAD (0xF00B) byte blob into an ordered `List<AdsSymbolInfo>`, advancing by `entryLength` and bounds-checking every read into `MalformedFrameException`.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-07-04T16:26Z
- **Completed:** 2026-07-04T16:32Z
- **Tasks:** 2
- **Files modified:** 2 (both created)

## Accomplishments
- `AdsSymbolInfo` pure value type with all eight public fields (name, typeName, comment, indexGroup, indexOffset, size, dataTypeId, flags).
- `parseSymbolBlob` parses a multi-symbol blob byte-exactly from the 30-byte `#pragma pack(1)` header (six u32 + three u16) + Latin-1 name/type/comment strings.
- Cursor advances by `entryLength` (never summed field sizes), proven by a deliberately padded first entry whose successor still parses byte-exactly.
- Hostile-input hardening (T-7-02): `remaining >= 30`, `entryLength in [30, remaining]`, and every string length inside the entry are checked subtraction-safe BEFORE any slice, throwing `MalformedFrameException` — never `RangeError`, never an over-read.
- 9 unit tests green (clean 2-symbol, padded-entry advancement, over/under nSymbols, and 5 hostile cases).

## Task Commits

Each task was committed atomically:

1. **Task 1: AdsSymbolInfo value type + parseSymbolBlob parser** - `7f902bb` (feat)
2. **Task 2: SYM-02 parser unit tests (padded entry + hostile blobs)** - `206f1e0` (test)

_Note: Task 1 carried `tdd="true"`; the plan structurally splits the RED test file into Task 2, so the cycle lands as feat (Task 1) → test (Task 2). Tests pass GREEN against the Task 1 implementation with no post-hoc parser change required._

## Files Created/Modified
- `lib/src/protocol/symbols.dart` - `AdsSymbolInfo` value type + pure `parseSymbolBlob`; imports only `dart:typed_data`, `dart:convert` (latin1), `exceptions.dart`; not barrel-exported.
- `test/unit/symbols_parse_test.dart` - SYM-02 fixtures + tests: 2-symbol exact fields, padded-entry `entryLength` advancement proof, and hostile blobs (entryLength 0/29/past-remaining, nameLength overrun, truncated header).

## Decisions Made
- `AdsSymbolInfo` intentionally omits `entryLength` (parse detail only), per plan.
- Invalid-name terminator / handle wire shapes are out of this plan's scope (SYM-01, later plans); this plan is the pure parser only.
- Mock/golden byte-parity is deferred to later plan(s); fixtures here are hand-built byte-exact to the pinned AdsDef.h layout (no C++ AdsLibTest symbol scenario exists — flagged for the Phase 9 audit).

## Deviations from Plan

None - plan executed exactly as written. `dart analyze --fatal-infos` clean on both files; all parser tests pass first run.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `parseSymbolBlob` + `AdsSymbolInfo` are ready for the browse-client plan (issue Read 0xF00C then Read 0xF00B, feed the blob here).
- Ready for a golden-parity plan to cross-check against a C++-dumped 2-symbol blob (extend the existing golden pipeline).
- No blockers.

## Self-Check: PASSED
- FOUND: `lib/src/protocol/symbols.dart`
- FOUND: `test/unit/symbols_parse_test.dart`
- FOUND commit: `7f902bb` (feat 07-01 parser)
- FOUND commit: `206f1e0` (test 07-01 parser tests)

---
*Phase: 07-symbol-access-browse-typed-values*
*Completed: 2026-07-04*
