---
phase: 05-device-notifications-as-streams
plan: 01
subsystem: protocol
tags: [ads, notifications, filetime, wire-codec, dart, typed-data, tdd]

# Dependency graph
requires:
  - phase: 01-framing-and-goldens
    provides: "checkUint range-check, MalformedFrameException, AdsCommandId constants, commands.dart builder/decoder pattern"
provides:
  - "AdsTransmissionMode enum (ADSTRANSMODE wire codes)"
  - "AdsNotification value type (handle, timestamp, data)"
  - "filetimeToDateTime / dateTimeToFiletime helpers (116444736000000000 epoch offset)"
  - "buildAddNotificationPayload (40-byte) + buildDeleteNotificationPayload (4-byte)"
  - "decodeAddNotificationResponse (result+handle) + decodeDeleteNotificationResponse"
  - "parseNotificationStream — doubly-nested, bounds-checked 0x08 parser"
affects: [05-02-mock, 05-03-goldens, 05-04-connection-demux, 05-05-client-subscribe]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure protocol layer (dart:typed_data + local pure helpers only; no dart:async/dart:io)"
    - "Bounds-check-before-dereference nested parser with defensive data copies"

key-files:
  created:
    - lib/src/protocol/notifications.dart
    - test/unit/protocol/notifications_test.dart
  modified: []

key-decisions:
  - "AdsNotification value type co-located with the parser in protocol/notifications.dart (parser constructs it; protocol/ stays pure) — resolves RESEARCH Open Question 1"
  - "decodeAddNotificationResponse tolerates a 4-byte error payload (handle absent -> 0), requiring 8 bytes only when result==0 (mirrors commands.dart check-result-before-reading guard)"
  - "FILETIME->DateTime truncates the sub-microsecond 100ns digit (~/10); round-trip is lossless only for multiple-of-10 FILETIMEs; getUint64 (unsigned) used throughout"

patterns-established:
  - "Payload builders mirror commands.dart: fixed Uint8List, ByteData.sublistView, checkUint on every u32 field, explicit Endian.little"
  - "Nested 0x08 parse guards every read (off+12 stamp header, off+8 sample header, off+size sample data) before dereference -> MalformedFrameException on overrun"

requirements-completed: [NOTIF-01, NOTIF-03, NOTIF-04]

# Metrics
duration: 12min
completed: 2026-07-04
---

# Phase 5 Plan 01: Notification Protocol Layer Summary

**Pure, golden-testable ADS notification wire layer — transmission-mode enum, FILETIME<->DateTime helpers, 40-byte Add / 4-byte Delete builders + response decoders, and a doubly-nested bounds-checked 0x08 stream parser — all transcribed byte-for-byte from the vendored Beckhoff C++.**

## Performance

- **Duration:** ~12 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 2 (both TDD)
- **Files modified:** 2 (both created)

## Accomplishments
- `lib/src/protocol/notifications.dart` (286 lines): the single source of truth for every notification wire layout, pure (`dart:typed_data` + local pure helpers only).
- `parseNotificationStream` implements the full doubly-nested stamp×sample loop (proven by the mandatory 2×2 fixture) with a bounds check before every field read — mitigates threats T-5-03 (sample-size tampering) and T-5-04 (lying stamp/sample counts).
- 22 unit tests (333 lines) covering the enum wire codes, FILETIME round-trip + truncation, 40-byte Add field order + reserved-zero bytes, both decoders, and the nested parse + every overrun-rejection path — all green, analyzer clean with `--fatal-infos`.

## Task Commits

Each task followed the RED → GREEN TDD cycle and was committed atomically:

1. **Task 1 RED: enum/value-type/FILETIME/builders/decoders tests** - `3e1a4a6` (test)
2. **Task 1 GREEN: enum, value type, FILETIME helpers, builders, decoders** - `2194ada` (feat)
3. **Task 2 RED: parseNotificationStream tests** - `158cc5b` (test)
4. **Task 2 GREEN: parseNotificationStream (nested, bounds-checked)** - `a513dfd` (feat)

_No REFACTOR commits were needed — GREEN implementations were clean on first pass._

## Files Created/Modified
- `lib/src/protocol/notifications.dart` - Pure notification protocol: `AdsTransmissionMode`, `AdsNotification`, FILETIME helpers, Add/Delete payload builders + response decoders, `parseNotificationStream`.
- `test/unit/protocol/notifications_test.dart` - Unit coverage for all of the above, including the 2×2 nested-parse proof and overrun rejection.

## Verification

- `dart analyze --fatal-infos lib/src/protocol/notifications.dart` — clean (No issues found).
- `dart test test/unit/protocol/notifications_test.dart` — 22/22 green.
- Full project suite (`dart test`) — 177/177 green; no regressions.
- Purity: only imports are `dart:typed_data`, `exceptions.dart`, `range_check.dart`. No `dart:async`/`dart:io` import (the doc comment mentions the strings — same benign pattern as the committed `commands.dart`/`exceptions.dart`; the import-scoped purity gate is satisfied).

## TDD Gate Compliance

Both tasks followed the mandatory RED/GREEN sequence, verified in git log:
- Task 1: `test(...)` `3e1a4a6` → `feat(...)` `2194ada`.
- Task 2: `test(...)` `158cc5b` → `feat(...)` `a513dfd`.

## Deviations from Plan

**1. [Rule 3 - Blocking] Removed digit-separator literals from tests**
- **Found during:** Task 1 GREEN verification.
- **Issue:** Test literals used `0x1_0000_0000` (digit separators), an experimental language feature not enabled on the project's Dart SDK floor (`>=3.5.0`); the test file failed to compile.
- **Fix:** Rewrote the two literals as `0x100000000`. No behavior change; the u32-overflow rejection assertions are unaffected.
- **Files modified:** `test/unit/protocol/notifications_test.dart`.
- **Committed with:** Task 1 GREEN (`2194ada`).

Otherwise the plan executed exactly as written.

## Known Stubs

None — every function is fully implemented and unit-proven. The connection-layer demux wiring, mock emission, goldens, and `subscribe()` orchestration are intentionally out of scope for this plan (delivered by plans 05-02 through 05-05).

## Threat Flags

None — no security surface beyond the plan's `<threat_model>` was introduced. The single trust boundary (untrusted 0x08 bytes → `parseNotificationStream`) is mitigated exactly as the register prescribes (T-5-03/T-5-04 bounds checks, T-5-05 40-byte layout with reserved bytes, T-5-06 unsigned FILETIME).

## Self-Check: PASSED

- FOUND: `lib/src/protocol/notifications.dart` (286 lines, contains `parseNotificationStream`)
- FOUND: `test/unit/protocol/notifications_test.dart` (contains `parseNotificationStream`)
- FOUND commit: `3e1a4a6` (Task 1 RED)
- FOUND commit: `2194ada` (Task 1 GREEN)
- FOUND commit: `158cc5b` (Task 2 RED)
- FOUND commit: `a513dfd` (Task 2 GREEN)
