---
phase: 05-device-notifications-as-streams
plan: 03
subsystem: testing
tags: [golden-fixtures, notifications, ads-protocol, cpp-parity, dump_golden, filetime]

# Dependency graph
requires:
  - phase: 05-01
    provides: buildAddNotificationPayload, buildDeleteNotificationPayload, decodeAddNotificationResponse, decodeDeleteNotificationResponse, parseNotificationStream, AdsTransmissionMode, filetimeToDateTime
  - phase: 01
    provides: dump_golden.cpp harness (wrap/writeHex/putU16/putU32 idioms), golden_parity_test.dart (_adsResponsePayload, readGolden)
provides:
  - Five committed byte-authoritative notification goldens (Add/Del req+res, nested 2x2 stream)
  - putU64 (8-byte LE) helper in dump_golden.cpp
  - _adsRequestPayload helper (strips prefix + validates request addressing) in golden_parity_test.dart
  - Byte-for-byte parity assertions pinning the 05-01 notification codec against C++-produced frames
affects: [05-04, 05-05, 05-06, symbol-access, sum-commands]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Notification req goldens compared payload-to-payload (builders emit ADS payload only, not full frames) via a request-side prefix stripper mirroring _adsResponsePayload"
    - "0x08 stream golden emitted response-direction (inverted addressing) and stripped with the response helper"

key-files:
  created:
    - test/golden/add_notification_req.hex
    - test/golden/add_notification_res.hex
    - test/golden/del_notification_req.hex
    - test/golden/del_notification_res.hex
    - test/golden/notification_stream.hex
  modified:
    - test_harness/dump_golden.cpp
    - test/unit/golden_parity_test.dart

key-decisions:
  - "Reused the existing _adsResponsePayload for the 0x08 stream golden since dump_golden emits it response-direction; added a symmetric _adsRequestPayload for the Add/Del request goldens"
  - "Both stream stamp timestamps are whole-microsecond FILETIMEs (multiples of 10) so FILETIME->DateTime is lossless and per-stamp binding is provable by exact-equality"

patterns-established:
  - "Request-golden parity: strip the 38-byte prefix, validate request addressing/state, compare the trailing payload against the pure builder output"

requirements-completed: [NOTIF-01, NOTIF-03]

# Metrics
duration: 10min
completed: 2026-07-04
---

# Phase 05 Plan 03: Notification Golden Fixtures Summary

**Five C++-emitted notification goldens (Add/Delete req+res + a nested 2-stamp x 2-sample 0x08 stream) pin the pure-Dart notification codec from 05-01 byte-for-byte, including the doubly-nested parser.**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 7 (2 modified, 5 created)

## Accomplishments
- Added a `putU64` (8-byte little-endian) helper to `dump_golden.cpp` and five deterministic, byte-reproducible fixture blocks.
- Emitted the 40-byte `add_notification_req` from explicit LE scalars in the exact `buildAddNotificationPayload` field order (group 0x4020, offset 4, cbLength 1, SERVERCYCLE, maxDelay 0, cycleTime 1000000, reserved[16]=0), doubling as the parity anchor.
- Emitted a nested `notification_stream` golden: 2 stamps x 2 samples with distinct per-stamp FILETIMEs and distinct handle/size/data per sample (including a 0-byte sample) to exercise the full nested loop.
- Extended `golden_parity_test.dart` with a `device notification goldens` group proving `buildAddNotificationPayload`/`buildDeleteNotificationPayload`/`decodeAddNotificationResponse`/`decodeDeleteNotificationResponse`/`parseNotificationStream` against the C++ frames — the parser yields 4 notifications with the golden timestamps, handles, and data.
- Confirmed the golden-reproducibility gate holds (`dump_golden && git diff --exit-code test/golden/*.hex` clean) and the full unit suite stays green (156 tests).

## Task Commits

1. **Task 1: Emit the five notification goldens from dump_golden.cpp** - `747daf7` (feat)
2. **Task 2: Byte-for-byte parity assertions against the goldens** - `83f87ad` (test)

_Note: Task 2 is a test-only task (no source files under test/`<files>`), so it exempts the TDD behavior-adding gate; the 05-01 codec already existed, so the new assertions passed on first run as a pure parity pin._

## Files Created/Modified
- `test_harness/dump_golden.cpp` - Added `putU64` helper + five notification fixture emitters
- `test/golden/add_notification_req.hex` - 40-byte AddDeviceNotification request layout
- `test/golden/add_notification_res.hex` - result 0 + handle 0x0A0B0C0D
- `test/golden/del_notification_req.hex` - handle 0x0A0B0C0D
- `test/golden/del_notification_res.hex` - result 0
- `test/golden/notification_stream.hex` - nested 2 stamps x 2 samples 0x08 frame
- `test/unit/golden_parity_test.dart` - `_adsRequestPayload` helper + `device notification goldens` group

## Decisions Made
- Reused `_adsResponsePayload` for the 0x08 stream golden (dump_golden emits it response-direction, so it inverts addressing like any response) and added a symmetric `_adsRequestPayload` for the Add/Delete request goldens, since the 05-01 builders emit the ADS payload only (not a full frame).
- Chose whole-microsecond FILETIMEs for both stamps (`132000000000000000` and `132000000010000000`, 1s apart) so the FILETIME->DateTime conversion is lossless and per-stamp timestamp binding is assertable by exact equality.

## Deviations from Plan
None - plan executed exactly as written.

## Issues Encountered
- An initial `dart format --output=none --set-exit-if-changed` run flagged the new test file as needing reformatting (multi-line `expect` wrapping). Ran `dart format` to write the canonical layout, re-verified all 18 tests pass, and amended the Task 2 commit. No behavior change.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The notification wire layouts (Add/Delete codecs + nested 0x08 parser) are now pinned against C++-produced frames, so the remaining Phase 05 plans (subscription plumbing, mock emission, lifecycle) can build on a byte-verified codec.
- No blockers. The golden-reproducibility gate is wired into the same `dump_golden` harness the rest of the phase uses.

## Self-Check: PASSED

---
*Phase: 05-device-notifications-as-streams*
*Completed: 2026-07-04*
