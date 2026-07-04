---
phase: 05-device-notifications-as-streams
verified: 2026-07-04T00:00:00Z
status: passed
score: 4/4
overrides_applied: 0
---

# Phase 5: Device Notifications as Streams — Verification Report

**Phase Goal:** Users can subscribe to PLC device notifications as Dart Streams, with correct nested frame parsing and disciplined handle lifecycle so PLC-side notification handles never leak.
**Verified:** 2026-07-04
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | subscribe() returns a Stream; AddDeviceNotification fires on first listen | VERIFIED | `ads_client.dart:217` — `StreamController(onListen: () async { ... await connection.addNotification(...) })`. No Add is sent before listen; the controller is only created on `subscribe()` and the Add payload is issued inside `onListen`. |
| 2 | Cancel sends DeleteDeviceNotification; all handles cleaned on disconnect | VERIFIED | `ads_client.dart:247` — `onCancel` calls `_deleteQuietly(acquired)`, which swallows errors (cancel never throws, threat T-5-12). `ams_connection.dart:479-507` — `_failClose` error-closes every `_demuxControllers` entry and clears the map unconditionally. Identity-guarded removal (CR-01) prevents stale continuations from closing a recycled-handle successor. |
| 3 | Nested frames (stamps × samples) parse correctly; FILETIME converts to DateTime | VERIFIED | `notifications.dart:230-272` — `parseNotificationStream` implements the two-level loop: outer `stamps`, inner `sampleCount`. Per-stamp `filetimeToDateTime` (line 252) converts the `u64` FILETIME via `(filetime - 116444736000000000) ~/ 10` microseconds. All 8 bounds-checks present before each dereference (`off + 12`, `off + 8`, `off + size`). MalformedFrameException thrown on any overrun. Defensive `Uint8List.fromList` copy at line 266. |
| 4 | On-change or cyclic transmission with max-delay / cycle-time attributes | VERIFIED | `AdsTransmissionMode` enum (`notifications.dart:33-62`) exposes all 8 modes with wire codes: noTrans(0), clientCycle(1), clientOnChange(2), serverCycle(3), serverOnChange(4), serverCycle2(5), serverOnChange2(6), client1Req(10). `subscribe()` accepts `mode`, `maxDelay`, `cycleTime` params (`ads_client.dart:203-211`) and converts durations to 100ns units (`inMicroseconds * 10`) before building the 40-byte payload. |

**Score:** 4/4 truths verified

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/src/protocol/notifications.dart` | Pure protocol: AdsTransmissionMode, AdsNotification, FILETIME helpers, Add/Delete builders + decoders, parseNotificationStream | VERIFIED | 286 lines. Imports only `dart:typed_data`, `exceptions.dart`, `range_check.dart` — no `dart:async`/`dart:io`. All declared exports present. |
| `lib/src/connection/ams_connection.dart` | Connection layer with addNotification, deleteNotification, 0x08 demux, _failClose fan-out | VERIFIED | 517 lines. `addNotification` (line 230), `deleteNotification` (line 280), `_onFrame` 0x08 routing (line 404), `_failClose` fan-out (line 479). |
| `lib/src/client/ads_client.dart` | AdsClient.subscribe() returning Stream with lazy Add / always-Delete cancel | VERIFIED | `subscribe()` at line 203. Handles lazy-Add, cancel-during-pending-add (`cancelled` flag), and Add-failure-to-listener paths. `_deleteQuietly` swallows at line 266. |
| `test/unit/protocol/notifications_test.dart` | Unit coverage: builders, FILETIME round-trip, 2x2 nested parse, overrun rejection | VERIFIED | 333 lines, 84 test/group/expect occurrences. Covers `parseNotificationStream`, `filetimeToDateTime`, `buildAddNotificationPayload`, decoders, and overrun cases. |
| `test/integration/ads_notification_test.dart` | Integration: subscribe, cancel, disconnect fan-out, race, cbLength guard | VERIFIED | 35 test/group/expect occurrences. Covers notification streaming, WR-02 cbLength guard (0xFFFFFFFF), WR-03 burst race, and disconnect fan-out. |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/src/protocol/notifications.dart` | `lib/src/protocol/range_check.dart` | `checkUint` on every u32 payload field | VERIFIED | Lines 151-156 and 166: `checkUint` called on all 6 Add fields and on Delete handle. |
| `parseNotificationStream` | `filetimeToDateTime` | per-stamp timestamp conversion | VERIFIED | `notifications.dart:252` — `filetimeToDateTime(bd.getUint64(off, Endian.little))` inside stamp loop. |
| `lib/src/connection/ams_connection.dart` | `lib/src/protocol/notifications.dart` | import + `parseNotificationStream` + `decodeAddNotificationResponse` + `decodeDeleteNotificationResponse` | VERIFIED | Import at line 28. `parseNotificationStream` at line 411, `decodeAddNotificationResponse` at line 245, `decodeDeleteNotificationResponse` at line 317. |
| `lib/src/client/ads_client.dart` | `lib/src/protocol/notifications.dart` | `buildAddNotificationPayload`, `AdsTransmissionMode`, `AdsNotification` | VERIFIED | Import at line 32. `buildAddNotificationPayload` at line 220, `AdsTransmissionMode.serverOnChange` default at line 207, `AdsNotification` as stream type. |
| `AdsClient.subscribe` | `AmsConnection.addNotification` | onListen Add round-trip | VERIFIED | `ads_client.dart:228` — `await connection.addNotification(payload, controller, timeout: timeout)`. Synchronous registration hook in `addNotification` closes the first-listen race (WR-03). |
| `AdsClient._deleteQuietly` | `AmsConnection.deleteNotification` | onCancel Delete round-trip | VERIFIED | `ads_client.dart:268` — `await connection.deleteNotification(handle, buildDeleteNotificationPayload(handle: handle))`. |

---

## Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `AmsConnection._onFrame` | `_demuxControllers[n.handle]` | `parseNotificationStream(notificationPayload)` from inbound TCP frame | Yes — real wire bytes from socket/mock | FLOWING |
| `AdsClient.subscribe` stream | `AdsNotification` items | `_demuxControllers` → `controller.add(n)` in `_onFrame` | Yes — demuxed from real notification frames | FLOWING |

---

## Behavioral Spot-Checks

Step 7b: SKIPPED — no live server available in this environment; integration tests run against the mock server (`test_harness/build/mock_server`). The REVIEW-FIX.md documents `dart test -x slow` ran 211/211 green after all fixes were applied (commits fb1ad12..97afddd).

---

## Probe Execution

No `probe-*.sh` scripts are declared for this phase. Integration tests against the mock server serve as the equivalent verification; the REVIEW-FIX.md confirms `mock_server --selftest` passed and goldens are byte-identical.

---

## Requirements Coverage

| Requirement | Description | Status | Evidence |
|-------------|-------------|--------|----------|
| NOTIF-01 | User can subscribe to a symbol's device notifications as a Dart Stream (AddDeviceNotification on first listen) | SATISFIED | `AdsClient.subscribe()` returns a lazy `Stream<AdsNotification>`; Add fires in `onListen`. |
| NOTIF-02 | Cancelling a subscription sends DeleteDeviceNotification; all handles cleaned on disconnect | SATISFIED | `onCancel` → `_deleteQuietly`; `_failClose` drains `_demuxControllers` with error-close. Identity-guarded removal (CR-01) prevents recycled-handle close. Finally-block local invalidation (WR-01) covers timeout and server-refusal paths. |
| NOTIF-03 | Library parses nested notification frames (stamps × samples) and converts FILETIME timestamps to Dart DateTime | SATISFIED | `parseNotificationStream` in `notifications.dart` implements full doubly-nested parse with per-stamp `filetimeToDateTime`. `getUint64` (unsigned) used correctly. Bounds-checked before every dereference. |
| NOTIF-04 | User can choose on-change or cyclic transmission with max-delay / cycle-time attributes | SATISFIED | `AdsTransmissionMode` enum exposes 8 modes. `subscribe()` accepts `mode`, `maxDelay`, `cycleTime`; converts to 100ns units for the 40-byte Add payload. |
| TEST-05 (notification slice) | Dart notification tests covering Beckhoff AdsLibTest parity | SATISFIED | Integration test file covers: subscribe / first-listen race / burst delivery / many-notifications / disconnect fan-out / cbLength guard. Unit tests cover: FILETIME round-trip, 2x2 nested parse, builders, decoders, overrun rejection. |

---

## Anti-Patterns Found

No debt markers (TBD, FIXME, XXX) found in any phase-5 source files. No stubs, placeholder returns, or empty handlers. No `return null` / `return {}` / `return []` patterns in notification-path code.

---

## Human Verification Required

None. All four success criteria are verifiable from code and test evidence. Live-PLC smoke testing is a v2 / deployment concern (RECON-01 deferred), not a success criterion for this phase.

---

## Gaps Summary

No gaps. All four roadmap success criteria are fully implemented and connected end-to-end:

1. Protocol layer (`notifications.dart`) is pure, complete, and unit-proven.
2. Connection layer (`ams_connection.dart`) registers handlers synchronously (closing the first-listen race), performs identity-guarded identity-safe deletion, and fans out disconnect errors to all demux controllers.
3. Client layer (`ads_client.dart`) presents a lazy `Stream<AdsNotification>` with always-Delete cancel and cancel-during-pending-add safety.
4. Post-review fixes (CR-01 through WR-04) were applied and verified clean at 211/211 suite passes.

---

_Verified: 2026-07-04_
_Verifier: Claude (gsd-verifier)_
