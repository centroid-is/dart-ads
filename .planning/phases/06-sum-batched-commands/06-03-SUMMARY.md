---
phase: 06-sum-batched-commands
plan: 03
subsystem: testing
tags: [golden-fixtures, sumup, ads, dump_golden, cpp, wire-protocol]

# Dependency graph
requires:
  - phase: 06-sum-batched-commands (plan 02)
    provides: mock_server.cpp SUMUP sub-handler + kErrResultGroup per-item error sentinel
provides:
  - Six byte-authoritative SUMUP golden fixtures (req+res for 0xF080/0xF081/0xF082)
  - dump_golden.cpp sum-emit blocks (kErrResultGroup mirrored from the mock)
  - Frozen mid-batch-failure alignment fixture (sum_read_res)
  - Frozen returned-length < requested-length fixture (sum_readwrite_res)
affects: [06-sum-batched-commands golden-parity plan, sum decoder unit tests, phase-9 parity audit]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "SUMUP goldens hand-built in dump_golden.cpp mirror mock_server.cpp emission byte-for-byte"
    - "0-data-bytes-on-failure per-item convention frozen across mock + goldens + (future) decoder"

key-files:
  created:
    - test/golden/sum_read_req.hex
    - test/golden/sum_read_res.hex
    - test/golden/sum_write_req.hex
    - test/golden/sum_write_res.hex
    - test/golden/sum_readwrite_req.hex
    - test/golden/sum_readwrite_res.hex
  modified:
    - test_harness/dump_golden.cpp

key-decisions:
  - "Goldens constructed to match mock_server.cpp's exact envelope: outer result u32 + inner readLength u32 + errRegion + dataRegion"
  - "sum_read failing item[1] uses ig=kErrResultGroup, io=0x703 so its err word = 0x703 and it emits 0 data bytes"
  - "sum_readwrite item[1] writes 2 bytes but requests rLen 8, so returned len 2 < requested 8 pins the returned-length slicing rule"

patterns-established:
  - "Pattern: every SUMUP writeHex return ANDed into `ok` so a silent I/O failure yields non-zero exit (CI reproducibility gate)"
  - "Pattern: req readLength uses the client-side upper bound (N*4+Sum(len)); res inner readLength reflects the mock's actual emission (failed items contribute 0 bytes)"

requirements-completed: [SUM-01, SUM-02, SUM-03, SUM-04]

# Metrics
duration: 7min
completed: 2026-07-04
---

# Phase 6 Plan 03: SUMUP Golden Fixtures Summary

**Six byte-authoritative SUMUP golden fixtures emitted from dump_golden.cpp — including a frozen mid-batch READ failure and a returned-length < requested READWRITE case — matching mock_server.cpp's wire emission byte-for-byte.**

## Performance

- **Duration:** ~7 min
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 7 (1 source + 6 fixtures)

## Accomplishments
- Added a `kErrResultGroup` sentinel to dump_golden.cpp mirroring `mock_server.cpp:124` so per-item failure fixtures use the identical magic group.
- Emitted six multi-item (N=3) SUMUP goldens: `sum_read`, `sum_write`, `sum_readwrite` (req + res each).
- `sum_read_res` freezes the mid-batch-failure alignment: item[1] targets `kErrResultGroup` (io 0x703) so its err word is 0x703 and it contributes 0 data bytes — items 0 and 2 still land at the correct offsets.
- `sum_readwrite_res` freezes the returned-length rule: item[1] requests rLen 8 but writes only 2 bytes, so its returned length header is 2 (< requested 8) and its data block is 2 bytes.
- Verified byte-stable regeneration (shasum identical across two runs) and a clean drift gate (`dump_golden test/golden && git diff --exit-code`).

## Task Commits

Each task was committed atomically:

1. **Task 1: Add six sum golden emit blocks to dump_golden.cpp** - `1556c8d` (feat)
2. **Task 2: Regenerate + commit the six golden fixtures, verify drift gate** - `49cd578` (feat)

## Files Created/Modified
- `test_harness/dump_golden.cpp` - Added `kErrResultGroup` constant + six SUMUP emit blocks mirroring the existing ReadWrite golden pattern.
- `test/golden/sum_read_req.hex` - 3-item batch req (item[1] targets kErrResultGroup, readLength 26).
- `test/golden/sum_read_res.hex` - result 0, inner readLength 24; errs [0, 0x703, 0]; data item0 `11223344`, item1 (failed, 0B), item2 `aabbccddeeff0102`.
- `test/golden/sum_write_req.hex` - 3-item batch req with concatenated distinct payloads (readLength 12).
- `test/golden/sum_write_res.hex` - result 0, inner readLength 12; N×u32 errs all 0 (no data region).
- `test/golden/sum_readwrite_req.hex` - 3-item batch req, 16B headers + payloads (readLength 39).
- `test/golden/sum_readwrite_res.hex` - result 0, inner readLength 33; headers (0,4)(0,2)(0,3); data `01020304` / `aabb` / `778899`.

## Decisions Made
- Constructed the res goldens to match the mock's exact response envelope (`mock_server.cpp:1018-1027`): outer ADS result u32, inner readLength u32 = `sumData.size()`, then errRegion followed by dataRegion. This keeps goldens + mock mutually consistent so golden-parity and live-mock tests agree.
- Chose distinctive, non-repeating data bytes per item so a mid-batch offset drift would produce a visibly wrong slice in a failing test.

## Deviations from Plan
None - plan executed exactly as written. Both tasks compiled/verified on first attempt; the six fixtures regenerate byte-identically and the drift gate is clean.

## Issues Encountered
None. Verified against the already-landed mock sum handler (plan 06-02) to guarantee byte-for-byte agreement before committing.

## Threat Model Coverage
- **T-6-04 (silent golden drift):** Every `writeHex` return ANDed into `ok`; byte-stable regeneration + `git diff --exit-code` drift gate confirmed clean.
- **T-6-03 (frozen failed-item convention):** `sum_read_res` encodes item[1] failure as err word 0x703 + 0 data bytes, freezing the alignment contract for the decoder.
- **T-6-SC (package installs):** N/A — no packages installed this phase.

## Next Phase Readiness
- The six SUMUP goldens are the arbiter for the Dart sum decoder and golden-parity tests (later plans in this phase).
- Mock emission, goldens, and the pending Dart decoder now share the identical 0-data-bytes-on-failure convention (06-RESEARCH A1).
- No blockers.

## Self-Check: PASSED

---
*Phase: 06-sum-batched-commands*
*Completed: 2026-07-04*
