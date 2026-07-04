---
phase: 07-symbol-access-browse-typed-values
plan: 06
subsystem: integration-tests
tags: [symbols, handles, integration, sym-01, sym-02, sym-03, sym-04]
requires:
  - 07-03 (mock symbol table + 0xF003/5/6/B/C dispatch + count magic group)
  - 07-05 (AdsClient handle/browse/typed methods + AdsHandle + barrel exports)
provides:
  - Live SYM-01 leak proof + auto-release + staleness evidence
  - Live SYM-02 browse of the 4-symbol table (padded entry)
  - Live SYM-03 typed round-trips + SYM-04 raw escape hatch
affects:
  - test/integration/ (two new integration suites)
tech-stack:
  added: []
  patterns:
    - "Per-test own-mock + own-connection (connection-scoped store) for isolation"
    - "Magic index-group readback (0xE7700005) as the leak-proof observable"
key-files:
  created:
    - test/integration/handle_lifecycle_test.dart
    - test/integration/symbols_test.dart
  modified: []
decisions:
  - "Assert exact per-field equality for all 4 browsed symbols (incl. padded entry 0) rather than a name-only smoke check"
  - "Prove staleness on BOTH the raw path (readByHandle -> 0x710) and the AdsHandle path (0x710 -> invalid -> StateError)"
metrics:
  duration: 3min
  completed: 2026-07-04
  tasks: 2
  files: 2
---

# Phase 7 Plan 6: Symbol Integration (Handle Lifecycle + Browse + Typed) Summary

End-to-end acceptance evidence for SYM-01/02/03/04 against the C++ mock: two new
integration suites prove handle lifecycle (leak proof + RAII auto-release +
stale-handle rejection), symbol-table browse (incl. the deliberately padded
entry), typed scalar round-trips (DINT/BOOL/STRING/LREAL), and the raw
`Uint8List` escape hatch — all green.

## What Was Built

**Task 1 — `test/integration/handle_lifecycle_test.dart` (SYM-01, 5 tests):**
- Full raw lifecycle: resolve `MAIN.counter` → write DINT → read-back matches → release.
- **Leak proof (T-7-01):** read the mock's live-handle count via the magic
  group `0xE7700005`, run 25 resolve/release cycles asserting the count sits at
  `baseline+1` mid-cycle and returns exactly to baseline afterward.
- **AdsHandle auto-release:** `create` → read/write → `close()` returns the count
  to baseline; `close()` is idempotent (second call is a no-op, no underflow).
- Unknown name → `AdsException(0x710)`.
- **Staleness (T-7-05):** a released raw handle reused → `0x710`; through an
  `AdsHandle`, `0x710` marks it invalid and every subsequent op throws
  `StateError` (no silent wire reuse).

**Task 2 — `test/integration/symbols_test.dart` (SYM-02/03/04, 3 tests):**
- `browseSymbols` returns exactly the 4-symbol table with every field asserted
  per entry (name/typeName/comment/iGroup/iOffs/size/dataTypeId/flags) —
  entry 0 is 4-byte-padded in the mock blob, so a correct parse proves
  advance-by-`entryLength`.
- Typed round-trips via the client's typed methods: DINT (`MAIN.counter`), BOOL
  (`MAIN.flag`, both true/false), STRING (`MAIN.text`, a short value that
  NUL-terminates inside the 81-byte buffer), LREAL (`MAIN.temp`).
- SYM-04: a raw `readByHandle` on `MAIN.temp` returns the unparsed 8-byte
  `Uint8List` matching the little-endian LREAL encoding.

Both suites are tagged `@Tags(['integration'])`, each test starts its own mock +
connection, and both carry the required Phase-9 parity-audit header note (no C++
AdsLibTest symbol scenario exists; this is not TEST-05 coverage).

## Verification

- `dart test -t integration test/integration/handle_lifecycle_test.dart` — 5/5 green.
- `dart test -t integration test/integration/symbols_test.dart` — 3/3 green.

## Deviations from Plan

None in the plan's own scope — both tasks executed exactly as written, no
auto-fixes needed inside the two new files.

## Deferred Issues (out of 07-06 scope — see deferred-items.md)

**Phase-gate regression pre-dating this plan:** `dart test -x slow` fails 6
older integration tests (`ads_client_test.dart: read`; 5 in `ads_parity_test.dart`).
Root cause: those Phase 3/6 tests use index group **`0xF005`** as a generic
scratch key/value group, but plan **07-03** (commit `003d3f1`) correctly
reserved `0xF005` for SYM_VALBYHND (value-by-handle) dispatch — so a plain
read/write at `0xF005` now resolves `indexOffset` as an unknown handle and
returns `0x710`. Verified via `git diff HEAD~2 HEAD` that 07-06's two commits
touch ONLY the two new test files; the regression was introduced by 07-03 and
missed because earlier plans validated only their own targeted files. This is a
cross-plan fix (relocate the scratch group in the Phase 3/6 test files off the
now-reserved `0xF005`; do NOT change the mock's correct `0xF005` handling),
logged for the verifier / node-repair loop. Details in
`deferred-items.md`.

## Threat Coverage

- **T-7-01 (DoS / handle leak):** mitigated — leak proof asserts count returns to
  baseline after N cycles and after `AdsHandle.close()`.
- **T-7-05 (Tampering / stale handle reuse):** mitigated — released-handle reuse
  asserts `0x710` + `AdsHandle` invalidation (`StateError` on next op).

No new threat surface introduced (test-only additions).

## Self-Check: PASSED
- FOUND: test/integration/handle_lifecycle_test.dart
- FOUND: test/integration/symbols_test.dart
- FOUND commit d721dcc (Task 1)
- FOUND commit 456acbe (Task 2)
