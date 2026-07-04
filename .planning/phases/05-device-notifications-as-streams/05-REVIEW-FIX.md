---
phase: 05-device-notifications-as-streams
fixed_at: 2026-07-04T00:00:00Z
review_path: .planning/phases/05-device-notifications-as-streams/05-REVIEW.md
iteration: 1
fix_scope: critical_warning
findings_in_scope: 5
fixed: 5
skipped: 0
status: all_fixed
---

# Phase 5: Code Review Fix Report

**Fixed at:** 2026-07-04
**Source review:** `05-REVIEW.md` (1 Critical, 4 Warning, 6 Info)
**Iteration:** 1
**Scope:** CR-01 + WR-01..WR-04 (Info findings IN-01..IN-06 intentionally not fixed — out of scope)

**Summary:**

- Findings in scope: 5
- Fixed: 5
- Skipped: 0

**Verification (full):** `dart analyze --fatal-infos` clean; `dart format --set-exit-if-changed` clean on every touched Dart file; `dart test -x slow` full suite green (+211, includes 5 new regression/behaviour tests); CMake mock rebuild + `--selftest` OK; goldens byte-identical (untouched, selftest confirms wire bytes).

## Fixed Issues

### CR-01: Stale Delete continuation closes a new subscription registered under a recycled handle

**Files modified:** `lib/src/connection/ams_connection.dart`, `test/unit/connection/notification_demux_test.dart`
**Commit:** `fb1ad12`
**Applied fix:** Identity-guarded removal, exactly per the review's minimal fix: `deleteNotification` captures the controller (`victim`) BEFORE the Delete round-trip and removes the map entry only when `identical(_demuxControllers[handle], victim)`; the close targets `victim`, never a recycled-handle successor. Added the FakeTransport reproduction as a regression test (pipelined Delete(H) + Add, both responses coalesced into one chunk with the Add recycling H): asserts the new controller stays open, stays registered, and receives a subsequent 0x08 sample. The test was verified to FAIL against the pre-fix code and pass with the fix.

### WR-01: `deleteNotification` ignores both error levels and leaks the demux entry on request failure

**Files modified:** `lib/src/connection/ams_connection.dart`, `test/unit/connection/notification_demux_test.dart`
**Commit:** `43c57ff`
**Applied fix:** The Delete round-trip now runs in a `try` whose `finally` performs the identity-guarded local invalidation (remove + fire-and-forget close) on EVERY outcome — success, server refusal, per-request timeout, dead connection — so no zombie routing target can survive a failed Delete. After the round-trip, a non-zero AMS `errorCode` and a non-zero decoded ADS `result` (via `decodeDeleteNotificationResponse`, which thereby gains its production caller) each throw `AdsException`. The locked decision holds: `AdsClient._deleteQuietly` still swallows on the cancel path, so `StreamSubscription.cancel()` never throws — but a direct `deleteNotification` caller now sees the truth. Three unit tests added (refused `0x752` Delete, AMS-level error, timeout leak-proofing).

### WR-02: Mock allocates attacker-controlled `cbLength` bytes per notification — unguarded up to 4 GiB

**Files modified:** `test_harness/mock_server.cpp`, `test/integration/ads_notification_test.dart`
**Commit:** `9d28e44`
**Applied fix:** The ADD dispatch site rejects `cbLength > kMaxFrameBytes` — with a real ADS error response (result `0x705 ADSERR_DEVICE_INVALIDSIZE`, handle 0, nothing registered) rather than the review's suggested silent `break`, so the Dart client fails fast instead of timing out (chosen per fix directive: reject-with-error). The `kMaxFrameBytes` note now documents ADD's `cbLength` alongside READ's `length` as the direct-cap dispatch guards. Integration regression test added: an Add with `length: 0xFFFFFFFF` surfaces `AdsException(0x705)` on the stream, the mock stays alive (proven by an in-band handle-count read on the same connection), and no handle is registered.

### WR-03: Integration "first-listen race" test cannot fail when the race is lost

**Files modified:** `lib/src/connection/ams_connection.dart`, `test_harness/mock_server.cpp`, `test/integration/ads_notification_test.dart`, `test/unit/connection/notification_demux_test.dart`
**Commit:** `4191d39`
**Applied fix:** Review fix option (a), strengthened, closing both observability gaps:

1. `AmsConnection.unregisteredNotifications` — a parsed 0x08 sample whose handle matches no controller is still ignored (C++ parity, `droppedNotifications` semantics unchanged) but now counted, so a lost registration race is observable instead of vanishing.
2. The mock's `--notify-burst` path concatenates the Add response and ALL burst frames into ONE `send()` on the TCP_NODELAY socket (via a new `buildNotificationFrame` builder), so response + first notification provably share one inbound TCP chunk — chunk boundaries no longer depend on kernel timing. `main()` rejects `--notify-burst` combined with `--fragment`/`--coalesce`/`--delay-ms` (exit 2), since those reshape the promised single chunk.
3. The integration test now requires ALL burst samples delivered AND `unregisteredNotifications == 0` (plus the original `droppedNotifications == 0`) — under a post-`await` registration regression, burst #1 hits an unmapped handle: delivery caps at N-1 and the counter goes non-zero, so the test fails for the advertised reason. The unit-level unregistered-handle test asserts the new counter.

### WR-04: Mock coalesce-mode flush heuristic can strand notification frames and deadlock a client

**Files modified:** `test_harness/mock_server.cpp`
**Commit:** `97afddd` (argv combo guard landed with WR-03 in `4191d39`)
**Applied fix:** Both halves of the review's fix:

1. **Argv rejection:** `--notify-burst` with `--fragment`/`--coalesce`/`--delay-ms` exits 2 with a message at parse time — a future test author gets an error, not a hang.
2. **Coalesce exemption:** notification frames route through a new `sendNotificationFrame` that never enters the coalesce buffer — under `Coalesce` it flushes any buffered response FIRST (preserving wire order) and sends the 0x08 in its own `send()`. Write-triggered notifications under `--coalesce` (which cannot be argv-rejected — any connection can trigger them) can therefore never strand an Add/Write response the client is awaiting. `--fragment` still applies to notifications (segmenting an unsolicited frame is a legitimate reassembly exercise). The header comment and the flush-heuristic comment document the restrictions.

## Skipped Issues

None — all five in-scope findings were fixed.

(IN-01..IN-06 were out of the requested fix scope and remain open; see `05-REVIEW.md`.)

## Constraint compliance

- **Locked decisions intact:** always-Delete cancel still never throws at the client layer (`_deleteQuietly` swallows; the connection layer now tells the truth beneath it); synchronous Add registration untouched; hostile containment untouched (WR-02/WR-04 extend it to the harness).
- **Wire behavior unchanged:** goldens byte-identical (no golden touched; `--selftest` OK); no encoder/decoder layout changed — only error *checking*, counting, and mock emission *packaging*.
- **Full verification:** `dart analyze --fatal-infos` clean; `dart format --set-exit-if-changed` clean on touched files; `dart test -x slow` full suite +211 green; CMake rebuild + `mock_server --selftest` OK.

---

_Fixed: 2026-07-04_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
