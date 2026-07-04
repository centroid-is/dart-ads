---
phase: 07-symbol-access-browse-typed-values
plan: 03
subsystem: test-harness
tags: [mock-server, symbols, handle-lifecycle, cpp]
requirements-completed: [SYM-01, SYM-02]
requires:
  - "test_harness/mock_server.cpp (Phase 1-6 dispatch loop + store + notification handle-table pattern)"
provides:
  - "Mock server-side symbol dispatch: 0xF003 resolve, 0xF005 read/write by handle, 0xF006 release, 0xF00C upload-info, 0xF00B upload-blob"
  - "kSymHandleCountGroup (0xE7700005) magic Read for symbol-handle leak proofs"
  - "Byte-exact AdsSymbolEntry upload blob with one deliberately padded entry"
affects:
  - "Dart integration tests (handle_lifecycle_test) and symbol-upload golden fixtures in later Phase 7 waves"
tech-stack:
  added: []
  patterns:
    - "Per-connection symHandles map mirroring the notification `notes` handle-table (clean per connection, handle numbers never leak across tests)"
    - "Magic index-group sentinel for in-band handle-count observability (sibling of kNotifyCountGroup)"
key-files:
  created: []
  modified:
    - "test_harness/mock_server.cpp"
decisions:
  - "kSymHandleCountGroup = 0xE7700005 (plan suggested 0xE7700003, which collides with the existing kNotifyBurst2x2Group; picked the next free sentinel)"
  - "0x710 (ADSERR_DEVICE_SYMBOLNOTFOUND) for BOTH unknown name and invalid/released handle (A4 frozen)"
  - "Padded entry = index 0 (MAIN.counter): entryLength 62 rounded to 64, 2 trailing zero-pad bytes"
metrics:
  duration: 6min
  tasks: 2
  files: 1
  completed: 2026-07-04
---

# Phase 7 Plan 3: Mock Symbol Table & Dispatch Summary

Extended the C++ mock ADS server with a fixed 4-symbol table and byte-exact dispatch for the five symbol index groups (0xF003 resolve / 0xF005 read-write-by-handle / 0xF006 release / 0xF00C upload-info / 0xF00B upload-blob), NUL-tolerant name lookup, 0x710 errors on unknown name and invalid handle, and a sym-handle-count magic group for leak proofs — the server-side authority for the Phase 7 Dart client and integration tests.

## What Was Built

**Task 1 — Handle lifecycle (commit 003d3f1):**
- Fixed compile-time `kSymbolTable`: MAIN.counter DINT@0x4020:0x0 (size 4, ADST_INT32=3), MAIN.flag BOOL@0x4020:0x4 (size 1, ADST_BIT=33), MAIN.text STRING(80)@0x4020:0x8 (size 81, ADST_STRING=30), MAIN.temp LREAL@0x4020:0x60 (size 8, ADST_REAL64=5). Each is seeded into the per-connection value store at its {iGroup, iOffs}.
- Per-connection `symHandles` map (`handle -> {group,offset}`) + `nextSymHandle` (start 1), reset per connection like the notification `notes` table.
- 0xF003 (ReadWrite): parses writeData as the symbol name, strips one trailing NUL if present (A1), looks up the table — miss returns ADS result 0x710, hit allocates a fresh handle and replies a 4-byte LE handle.
- 0xF005 read (Read) and write (Write): indexOffset = handle → resolve via symHandles; unknown/released → 0x710 (never falls through to an arbitrary store entry, T-7-04); else route to the value store.
- 0xF006 (Write, iOffs=0, data=4-byte handle): erase from symHandles, idempotent success.
- `kSymHandleCountGroup` (0xE7700005) Read returns `symHandles.size()` as u32 LE for leak assertions.

**Task 2 — Upload info + blob (commit c42e155):**
- `buildSymbolUploadBlob()` serialises the table into a single blob: 30-byte pack(1) header (entryLength, iGroup, iOffs, size, dataTypeId, flags, nameLength, typeLength, commentLength) then name+NUL, typeName+NUL, comment+NUL. `entryLength = 30 + nameLen + typeLen + commentLen + 3`. Entry 0 is rounded up to a 4-byte boundary with trailing zero-pad to exercise advance-by-entryLength.
- 0xF00C (Read): 8-byte `{nSymbols, nSymSize}` where nSymSize = blob length.
- 0xF00B (Read): the blob bytes, truncated to the requested read length.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Magic group value collision**
- **Found during:** Task 1
- **Issue:** The plan suggested `kSymHandleCountGroup` "e.g. 0xE7700003u", but 0xE7700003 is already `kNotifyBurst2x2Group` (and 0xE7700004 is `kNotifyHostileGroup`).
- **Fix:** Used the next free sentinel, `0xE7700005u`. No existing Dart or C++ code referenced a sym-handle-count group, so the value is unconstrained.
- **Files modified:** test_harness/mock_server.cpp
- **Commit:** 003d3f1

## Verification

- `cmake --build . --target mock_server` — succeeds (both tasks)
- `./mock_server --selftest` — prints OK, exit 0 (ReadDeviceInfo golden still byte-identical; symbol dispatch is additive and left the existing command table untouched)

## Threat Mitigations Applied

- **T-7-04** (invalid handle info-disclosure): 0xF005 read/write return 0x710 on an unknown/released handle and never fall through to an arbitrary store entry.
- **T-7-01** (handle leak DoS): 0xF006 erases the handle; the kSymHandleCountGroup magic Read makes leaks observable (baseline 0 → N → 0).

## Notes for Later Waves

- The Dart integration tests should assert the sym-handle count via a Read on **0xE7700005** (not 0xE7700003 as the plan text suggested).
- Padded entry is index 0 (MAIN.counter): entryLength 62 → 64 with 2 pad bytes — the fixture that proves the parser advances by entryLength, not summed field sizes.

## Self-Check: PASSED
