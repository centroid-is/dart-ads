---
phase: 07-symbol-access-browse-typed-values
plan: 04
subsystem: testing
tags: [golden, symbols, parseSymbolBlob, dump_golden, cpp-parity, ads]

# Dependency graph
requires:
  - phase: 07-01
    provides: parseSymbolBlob + AdsSymbolInfo (pure SYM_UPLOAD blob parser)
provides:
  - Four committed symbol golden fixtures (handle req/res, uploadinfo res, 2-symbol upload blob)
  - Byte-for-byte Dart-vs-C++ parity test for parseSymbolBlob on a padded-entry blob
  - dump_golden symbol-blob serializer (byte-identical twin of the mock's Plan-03 blob)
affects: [07 symbol client, 07 integration, CLI browse]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Golden symbol blob emitted by dump_golden is the byte-identical twin of the mock's buildSymbolUploadBlob (first two entries)"
    - "Padded entry 0 (entryLength 62 -> 64) pins the parser's advance-by-entryLength contract in a frozen reference"

key-files:
  created:
    - test/golden/sym_handle_req.hex
    - test/golden/sym_handle_res.hex
    - test/golden/sym_uploadinfo_res.hex
    - test/golden/sym_upload_blob.hex
    - test/unit/symbols_golden_test.dart
  modified:
    - test_harness/dump_golden.cpp

key-decisions:
  - "Handle golden uses handle 0x00000123 (deterministic, mirrors the 0x123 SYM_VALBYHND offset in read_req)"
  - "Golden blob covers 2 symbols (MAIN.counter padded, MAIN.flag) — the mock's first two entries — sufficient to prove padded advance"

patterns-established:
  - "Symbol goldens reuse golden_parity_test's response-frame strip helper (invert addressing, verify cmd id + dataLength)"

requirements-completed: [SYM-01, SYM-02]

# Metrics
duration: 9min
completed: 2026-07-04
---

# Phase 7 Plan 04: Symbol Golden Parity Summary

**Four committed symbol golden fixtures (handle req/res, SYM_UPLOADINFO, 2-symbol upload blob with a padded entry) plus a Dart test proving parseSymbolBlob reproduces the padded blob byte-for-byte.**

## Performance

- **Duration:** ~9 min
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 6 (5 created, 1 modified)

## Accomplishments
- Extended `dump_golden` with a byte-identical twin of the mock's `buildSymbolUploadBlob`, emitting a 2-symbol AdsSymbolEntry blob whose entry 0 (MAIN.counter) is padded from entryLength 62 to 64 with 2 trailing zero bytes.
- Emitted three additional symbol fixtures: 0xF003 handle ReadWrite req (writeData `MAIN.counter\0`), 0xF003 handle res (4-byte LE handle 0x00000123), and 0xF00C SYM_UPLOADINFO res (`{nSymbols=2, nSymSize=110}`).
- Added `test/unit/symbols_golden_test.dart` proving `parseSymbolBlob(blob, 2)` yields the exact expected AdsSymbolInfo list — the second entry is only reachable if the parser advanced by entry 0's padded entryLength (64), not its summed field sizes (62).
- Verified reproducibility: re-running the dumper touched only the four new fixtures; no existing golden changed.

## Task Commits

1. **Task 1: dump_golden symbol fixtures** - `d0d669b` (feat)
2. **Task 2: Byte-for-byte Dart parity test** - `04aca81` (test)

## Files Created/Modified
- `test_harness/dump_golden.cpp` - Added `SymEntry`/`buildSymbolUploadBlob` twin + four symbol fixture emit blocks
- `test/golden/sym_handle_req.hex` - 0xF003 ReadWrite handle request (readLen 4, writeData `MAIN.counter\0`)
- `test/golden/sym_handle_res.hex` - 0xF003 ReadWrite response carrying the 4-byte LE handle 0x00000123
- `test/golden/sym_uploadinfo_res.hex` - 0xF00C Read response `{nSymbols=2, nSymSize=110}`
- `test/golden/sym_upload_blob.hex` - 0xF00B Read response with the 110-byte 2-symbol blob (entry 0 padded)
- `test/unit/symbols_golden_test.dart` - Byte-for-byte parity assertions for the blob + handle + uploadinfo goldens

## Decisions Made
- Handle golden uses a deterministic handle `0x00000123`, mirroring the `0x123` SYM_VALBYHND offset already baked into `read_req`, so the fixtures tell a coherent name→handle→value story.
- The upload blob covers the mock table's first two symbols (MAIN.counter padded, MAIN.flag) — the minimum that exercises the padded advance while staying byte-identical to the mock's serialization.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. `dart format` and `dart analyze` both clean; the parity test passed on first run after byte-level verification of the emitted blob.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The symbol wire contract (handle + upload blob) is now pinned independently of the mock and client, matching every prior codec's golden guarantee.
- Ready for the symbol client + integration plans to build on `parseSymbolBlob` against these frozen references.

## Self-Check: PASSED

All 5 created files present; both task commits (d0d669b, 04aca81) exist in git history.

---
*Phase: 07-symbol-access-browse-typed-values*
*Completed: 2026-07-04*
