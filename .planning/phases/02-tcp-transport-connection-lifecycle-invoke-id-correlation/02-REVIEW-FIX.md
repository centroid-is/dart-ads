---
phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation
fixed_at: 2026-07-03T22:40:00Z
review_path: .planning/phases/02-tcp-transport-connection-lifecycle-invoke-id-correlation/02-REVIEW.md
iteration: 1
fix_scope: critical_warning
findings_in_scope: 6
fixed: 6
skipped: 0
status: all_fixed
---

# Phase 2: Code Review Fix Report

**Fixed at:** 2026-07-03T22:40:00Z
**Source review:** 02-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 6 (1 Critical + 5 Warning; Info findings intentionally left open)
- Fixed: 6
- Skipped: 0

**Verification (full gate, run after all fixes):**
- `dart analyze --fatal-infos` — clean (was failing on WR-05 before the fixes)
- `dart format --output=none --set-exit-if-changed .` — clean (26 files, 0 changed)
- `dart test` (full suite, unit + integration against the live C++ mock) — **69/69 green** (65 pre-existing + 4 new regression tests); no wire-behavior changes, `lib/src/protocol/` untouched
- Integration run in a fresh worktree exercised the new WR-04 build lock end-to-end (cold CMake build with both suites launching the mock concurrently)

## Fixed Issues

### CR-01: `request()` registered the pending entry before building the frame

**Files modified:** `lib/src/connection/ams_connection.dart`, `test/unit/ams_connection_test.dart`
**Commit:** `8e71415`
**Applied fix:** The frame is now built (and range-checked by the Phase-1 encoders) *before* any pending state exists, so a synchronous `ArgumentError` from encode leaves no orphaned completer and no armed timer. Also added the review's optional defense: if a transport's `add()` ever throws synchronously, the just-registered entry is removed and its timer cancelled before rethrowing. Regression test issues `request(0x10000, ...)` with a 20 ms timeout, waits past the timeout window (the old bug fires an unhandled async error there and fails the test), and asserts the connection remains fully usable.

### WR-01: Invoke-ID wrap collision silently overwrote a live pending entry

**Files modified:** `lib/src/connection/ams_connection.dart`, `test/unit/ams_connection_test.dart`, `pubspec.yaml`
**Commit:** `e30ce1c`
**Applied fix:** `_allocInvokeId()` now skips IDs still present in `_pending` (per the review's loop), guarded by a sanity `StateError` if ~4 billion requests were ever simultaneously in flight (bounds the skip loop). Added a `@visibleForTesting set debugNextInvokeId` seam so the wrap is testable without 2^32 requests — this required adding `meta ^1.16.0` (annotations only, zero runtime cost; STACK.md already endorses it). Regression test parks a request on invoke-ID `0xFFFFFFFF`, forces the counter back onto it, asserts the next allocation is `1` (skip, not overwrite), and confirms both requests resolve to their own responses.

### WR-02: `connect()` had no state guard — double-connect leaked a live socket

**Files modified:** `lib/src/connection/ams_connection.dart`, `test/unit/ams_connection_test.dart`
**Commit:** `6e52f6d`
**Applied fix:** `connect()` now throws `StateError('AmsConnection is single-use: already connected/closed')` *before* touching the transport, so a rejected call can never open (and then leak) a socket. Doc comment documents the single-use contract (reconnect is v2, per the locked decisions). Regression tests cover double-connect (connection stays usable end-to-end afterwards) and connect-after-close.

### WR-03: `done` completed before the transport was actually torn down

**Files modified:** `lib/src/connection/ams_connection.dart`
**Commit:** `7b08bcc`
**Applied fix:** Exactly the review's suggestion: `_failClose` now chains `_doneCompleter` off `_transport.close().whenComplete(...)` instead of completing it eagerly, so `await conn.close()` / `await conn.done` returns only after the socket flush/destroy finishes. `_failClose` itself stays synchronous and single-shot; fan-out ordering is unchanged. Existing `done`-semantics tests (unit + live disconnect) still pass.

### WR-04: `_ensureBuilt` raced itself under concurrent integration suites

**Files modified:** `test/support/mock_server.dart`, `.gitignore`
**Commit:** `fabd644`
**Applied fix:** Adapted from the review's suggestion rather than applied verbatim: `RandomAccessFile.lock` is a POSIX advisory lock, which does **not** exclude between isolates of the *same* process — and `dart test` runs both integration suites as isolates in one VM process, so the suggested lock would not have closed the race. The stale-check + configure + build is instead serialized behind an atomic `File.create(exclusive: true)` lock file (`test_harness/.build.lock`, gitignored) with a 200 ms wait loop; a stale lock left by a killed run surfaces after 5 minutes as a `StateError` naming the file to delete. Verified end-to-end: a fresh worktree cold-build with both suites launching the mock concurrently built once and passed.

### WR-05: `unnecessary_import` failed the `dart analyze --fatal-infos` CI gate

**Files modified:** `test/unit/ams_connection_test.dart`
**Commit:** `6270fd9`
**Applied fix:** Deleted the dead `package:dart_ads/src/connection/ams_connection.dart` import (`AmsConnection` comes from the public barrel). The `src/transport/fake_transport.dart` import stays — `FakeTransport` is intentionally not exported. `dart analyze --fatal-infos` now exits clean repo-wide.

## Skipped Issues

None — all in-scope findings fixed. The nine Info findings (IN-01 … IN-09) remain open by scope decision (`fix_scope: critical_warning`).

## Locked-Decision Compliance

- `AdsTransport` seam unchanged; `lib/src/protocol/` untouched (purity boundary intact)
- Invoke-ID scheme still monotonic u32 `1..0xFFFFFFFF..1`, 0 reserved — WR-01 only adds the in-flight skip
- 5 s default timeout + per-request override unchanged
- No auto-reconnect introduced (WR-02 makes single-use explicit via `StateError`)
- `AdsTimeoutException` / `AdsConnectionException` semantics, error-closed notification controllers, `isConnected` + `done`, and `droppedResponses` all preserved (WR-03 only *tightens* `done` to its documented contract)

---

_Fixed: 2026-07-03T22:40:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
