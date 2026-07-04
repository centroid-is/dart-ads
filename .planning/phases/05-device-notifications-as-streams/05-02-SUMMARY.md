---
phase: 05-device-notifications-as-streams
plan: 02
subsystem: testing
tags: [ads, notifications, mock-server, cpp, cmake, device-notification, 0x08]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: C++ mock server (wrapResponse, putU32/getU32, per-connection store, selftest gate)
  - phase: 03-ads-commands
    provides: WRITE/READ dispatch cases and magic index-group error fixtures (kErrResultGroup/kErrAmsGroup)
provides:
  - Mock ADD_DEVICE_NOTIFICATION handling (per-connection incrementing handle table)
  - Mock DEL_DEVICE_NOTIFICATION handling (result 0 / 0x752 for unknown)
  - Write-triggered serverOnChange 0x08 emission to watching handles
  - Magic write group 0xE7700003 emitting a 2-stamp x 2-sample crafted frame
  - Magic read group 0xE7700002 returning the active-handle count (in-band leak proof)
  - --notify-burst N flag emitting N single-sample frames per ADD (first-listen race exposure)
  - putU64 LE helper and emitNotification nested-frame builder
affects: [05-06 notification integration/parity tests, dump_golden notification goldens]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Magic synthetic index groups (0xE770000x) as deterministic, in-band test triggers/probes"
    - "Nested 0x08 frame built with self-describing length backfill, wrapped via existing wrapResponse"
    - "Per-connection notification table declared in the accept block so each test starts clean"

key-files:
  created: []
  modified:
    - test_harness/mock_server.cpp

key-decisions:
  - "Emission mechanics = write-triggered + burst + 2x2 magic group (all request-driven, no timers/threads) per CONTEXT discretion"
  - "notes table typed std::map<uint32_t, std::array<uint32_t,4>> ({group,offset,cbLength,transMode})"
  - "Notification frames emitted BEFORE their triggering command response (burst before ADD-resp exposes the race; write-triggered before WRITE-resp)"
  - "2x2 fixture uses synthetic handles 1/2, distinct data, timestamps multiple-of-10 for lossless FILETIME round-trip"

patterns-established:
  - "putU64 mirrors putU32 (8 shift iterations) — CLAUDE explicit-LE rule satisfied"
  - "emitNotification(fd, mode, fragmentN, coalesceBuf, addressing, stamps) reusable nested-frame builder"

requirements-completed: [NOTIF-01, NOTIF-02, TEST-05]

# Metrics
duration: 14min
completed: 2026-07-04
---

# Phase 05 Plan 02: Mock Notification Server Role Summary

**C++ mock now plays a deterministic ADS notification server: allocates/frees per-connection handles, emits nested 0x08 frames on write + burst + a 2x2 magic group, and exposes an in-band active-handle count for the leak proof — all thread-free and request-driven.**

## Performance

- **Duration:** ~14 min
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- ADD_DEVICE_NOTIFICATION: bounds-checked 40-byte parse, per-connection incrementing handle (from 1), response = result 0 + handle.
- DEL_DEVICE_NOTIFICATION: frees a known handle (result 0), returns ADSERR_CLIENT_REMOVEHASH (0x752) for an unknown one — never frees an unrelated entry.
- Write-triggered serverOnChange emission: a WRITE to a watched (group, offset) emits one 0x08 frame to every handle watching that exact region, data truncated/padded to cbLength.
- Magic write group 0xE7700003 emits one crafted frame with 2 stamps x 2 samples (distinct timestamps/handles/data) — the nested-parser fixture.
- Magic read group 0xE7700002 returns the current active-handle count as a u32 — the deterministic, in-band handle-leak proof.
- `--notify-burst N` emits N single-sample frames on each ADD, before the ADD response, to expose the first-listen race.
- `--selftest` remains byte-identical (ReadDeviceInfo path untouched).

## Task Commits

Each task was committed atomically:

1. **Task 1: putU64 helper + handle table + ADD/DEL dispatch** - `7ad3905` (feat)
2. **Task 2: Emission — write-triggered, burst, 2x2 magic frame, active-handle-count read** - `89dc907` (feat)

## Files Created/Modified
- `test_harness/mock_server.cpp` - putU64 helper; kNotifyCountGroup/kNotifyBurst2x2Group constants; per-connection notes table + nextHandle; ADD/DEL dispatch cases; emitNotification nested-frame builder; write-triggered + 2x2 + count-read + burst wiring; `--notify-burst` argv flag threaded through runServer.

## Decisions Made
- Emission mechanics chosen (per CONTEXT discretion): write-triggered + burst + 2x2 magic group — all request-driven, no timers or threads in the select loop.
- Notification frames are sent immediately (before the triggering command's response). For burst this is the whole point (race exposure); for write-triggered it is harmless since the Dart client demuxes 0x08 on commandId and correlates the WRITE response by invokeId independently.
- 2x2 fixture timestamps are whole microseconds (multiples of 10 in 100ns FILETIME units) so the Dart FILETIME->DateTime round-trip is lossless when this frame becomes a golden in 05-06.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Included `<array>` instead of `<tuple>`**
- **Found during:** Task 1 (handle table declaration)
- **Issue:** The plan's action step (2) said `#include <tuple>`, but action step (3) declares the table as `std::map<uint32_t, std::array<uint32_t,4>>` (std::array, not std::tuple). Including `<tuple>` alone would leave `std::array` without its header on some toolchains.
- **Fix:** Added `#include <array>` (alphabetically placed among the existing standard includes); did not add the unused `<tuple>`.
- **Files modified:** test_harness/mock_server.cpp
- **Verification:** Compiles clean under the CMake build; `--selftest` OK.
- **Committed in:** `7ad3905` (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking).
**Impact on plan:** The header correction matches the data structure the plan itself specified. No scope creep.

## Issues Encountered
None. Beyond the plan's compile + selftest + flag-acceptance gate, an out-of-band Python smoke client exercised the full wire behavior (ADD handle=1, count read=1, write-triggered 0x08 carrying the written bytes, 2x2 frame with 4 samples, DEL known=0 / unknown=0x752, count returns to 0) — all six must-have truths confirmed end-to-end.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The mock now provides a faithful, deterministic notification source for the Dart integration + parity tests (05-06): handle lifecycle, serverOnChange, nested 2x2 frame, leak-count probe, and the burst race trigger are all wired.
- `dump_golden` can now be extended (05-06) to emit the Add req/res, Del req/res, and the 2x2 `notification_stream.hex` goldens using the same framing helpers.

---
*Phase: 05-device-notifications-as-streams*
*Completed: 2026-07-04*

## Self-Check: PASSED
- FOUND: test_harness/mock_server.cpp
- FOUND: .planning/phases/05-device-notifications-as-streams/05-02-SUMMARY.md
- FOUND: commit 7ad3905 (Task 1)
- FOUND: commit 89dc907 (Task 2)
