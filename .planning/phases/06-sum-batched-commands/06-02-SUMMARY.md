---
phase: 06-sum-batched-commands
plan: 02
subsystem: testing
tags: [cpp, mock-server, ads, sumup, readwrite, batched-commands]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: C++ CMake mock server, store, magic error groups, wrapResponse/getU32/putU32 helpers
  - phase: 03-ads-commands
    provides: READ_WRITE (0x09) mock dispatch + kErrResultGroup magic error fixture reused per item
provides:
  - "Mock SUMUP sub-handler answering 0xF080/0xF081/0xF082 by replaying the per-connection store per item"
  - "Per-item error injection via kErrResultGroup (failed item = its offset as result word + 0 data bytes)"
  - "N-vs-write-buffer validation with break-on-mismatch (no response) mirroring hostile-input discipline"
  - "The frozen 0-data-bytes-on-failure mid-batch alignment contract that the Dart decoder + goldens must match"
affects: [sum-commands-dart-codec, dump-golden-sum-emit, sum-integration-tests]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "SUMUP handled as a sub-branch of the existing READ_WRITE case keyed on outer indexGroup"
    - "Per-item error sentinel = whole-frame kErrResultGroup magic trick applied per item"
    - "Response = err-region THEN concatenated data (F080/F082 add per-item retLen for F082)"

key-files:
  created: []
  modified:
    - test_harness/mock_server.cpp

key-decisions:
  - "Failed item occupies its result-word slot but emits 0 data bytes — frozen contract shared with Dart decoder + goldens"
  - "Trust outer indexOffset as N and validate against write-buffer size (break/no-response on mismatch)"
  - "Cap total response size against kMaxFrameBytes before allocating (T-6-02)"

patterns-established:
  - "SUMUP dispatch lives at the ReadWrite level, not the magic intercept, since 0xF08x is never a magic sentinel"
  - "Write-payload cursor must consume the write-buffer exactly; F080 headers must fill it exactly"

requirements-completed: [SUM-01, SUM-02, SUM-03, SUM-04]

# Metrics
duration: 6min
completed: 2026-07-04
---

# Phase 06 Plan 02: SUMUP Mock Sub-Handler Summary

**C++ mock now answers batched SUMUP read/write/readwrite (0xF080/81/82) by replaying its per-connection store per item, injecting deterministic mid-batch failures via kErrResultGroup with the frozen 0-data-bytes convention.**

## Performance

- **Duration:** 6 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- SUMUP sub-handler added inside `case AoEHeader::READ_WRITE:`, branching on `group == 0xF080u || 0xF081u || 0xF082u` before the generic write-then-read.
- Per-item processing: parse each item header at the correct stride (12B READ/WRITE, 16B READWRITE), replay `store`, inject per-item errors through `kErrResultGroup`.
- Response assembly matches the pinned layouts: F080 → N×u32 errs then data at requested lengths; F081 → N×u32 errs only; F082 → N×(err,retLen) then data at returned lengths.
- N validated against the write-buffer size; any inconsistency or overrun `break`s with NO response, matching the existing hostile-input discipline. Total response size capped against `kMaxFrameBytes`.
- Rebuilt mock passes `--selftest` with exit 0 — no existing framing/fragment/coalesce/magic behavior regressed.

## Task Commits

1. **Task 1 + Task 2: SUMUP sub-handler + rebuild/selftest** - `e35f4c1` (feat)

_Task 2 (rebuild + `--selftest`) introduced no additional source change beyond Task 1's edit to `mock_server.cpp`, so both tasks landed in one atomic feature commit._

## Files Created/Modified
- `test_harness/mock_server.cpp` - Added the SUMUP sub-handler (~185 lines) inside the READ_WRITE case: item-count validation, per-item store replay, per-item kErrResultGroup error injection, per-group response assembly, and kMaxFrameBytes caps.

## Decisions Made
- **0-data-bytes-on-failure is the frozen contract** (06-RESEARCH A1): a failed item keeps its result-word (and, for F082, its `retLen=0`) slot but contributes zero data bytes, so successful items' data lands at correct offsets. Documented inline as the Phase 9 parity-audit note.
- **N = outer indexOffset, validated against the write-buffer:** for F080 the headers must fill `writeLength` exactly (`hdrBytes == writeLength`); for F081/F082 the write-payload cursor must consume `writeLength` exactly. Any mismatch/overrun => `break`, no response.
- **F082 returned length = min(requested readLen, stored bytes)** where stored bytes == the item's write payload length, producing genuine variable returned lengths (retLen < requested when write < read).
- **DoS caps:** F080 rejects a per-item requested length or running total exceeding `kMaxFrameBytes` before allocating; F082 caps the running returned-data total; final `sumData` re-checked against the cap.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. Baseline build was green before the change; the sum handler compiled first try and selftest stayed green.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Mock now emits all three SUMUP groups over its store with per-item error injection — unblocks the Dart sum codec (`protocol/sum_commands.dart`), the `dump_golden.cpp` sum-emit blocks, and the SUM-04 alignment integration tests.
- The mock's emission is now the byte-authoritative specification the Dart decoder and golden fixtures must match; the golden fixtures (Wave 0 gap) will freeze it.

## Self-Check: PASSED

- `test_harness/mock_server.cpp` exists and contains `0xF080`
- Commit `e35f4c1` present in git history
- `06-02-SUMMARY.md` created

---
*Phase: 06-sum-batched-commands*
*Completed: 2026-07-04*
