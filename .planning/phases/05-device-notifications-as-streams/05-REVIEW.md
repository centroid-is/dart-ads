---
phase: 05-device-notifications-as-streams
reviewed: 2026-07-04T00:00:00Z
re_reviewed: 2026-07-04T12:00:00Z
depth: standard
re_review_depth: quick
files_reviewed: 4
files_reviewed_list:
  - lib/src/protocol/notifications.dart
  - lib/src/connection/ams_connection.dart
  - lib/src/client/ads_client.dart
  - test_harness/mock_server.cpp
findings:
  critical: 1
  warning: 4
  info: 7
  total: 12
status: clean
fixed_at: 2026-07-04T00:00:00Z
fix_scope: critical_warning
fixed: [CR-01, WR-01, WR-02, WR-03, WR-04]
verified: [CR-01, WR-01, WR-02, WR-03, WR-04]
open: [IN-01, IN-02, IN-03, IN-04, IN-05, IN-06, IN-07]
fix_report: 05-REVIEW-FIX.md
---

# Phase 5: Code Review Report

**Reviewed:** 2026-07-04
**Re-reviewed:** 2026-07-04 (iteration 2, focused verification of fb1ad12..97afddd)
**Depth:** standard (iteration 1) / quick focused (iteration 2)
**Files Reviewed:** 4 (primary scope) + 8 context files (protocol tests, demux tests, subscribe tests, integration tests, goldens, `pending_request.dart`, `dart_ads.dart`, `dump_golden.cpp`)
**Status:** clean — CR-01 + WR-01..WR-04 fixed (`fb1ad12`, `43c57ff`, `9d28e44`, `4191d39`, `97afddd`) and independently VERIFIED in iteration 2 (see "Re-Review Verification" below); IN-01..IN-07 remain open (Info findings out of fix scope)

## Summary

Reviewed the Phase 5 device-notification stack: the pure protocol layer (`notifications.dart`), the connection demux with the `onResponseSync` synchronous-registration hook (`ams_connection.dart`), the `AdsClient.subscribe()` lifecycle state machine (`ads_client.dart`), and the mock-server notification support (`mock_server.cpp`). `dart analyze --fatal-infos` is clean.

The core designs hold up well under adversarial tracing:

- **onResponseSync hook safety verified.** A hook can never run for an already-timed-out request (`_pending.remove` on timeout wins; the late frame hits the `pending == null` branch and only bumps `droppedResponses`). A hook can never run after `_failClose` (pending map snapshot-cleared before fan-out; the inbound subscription is cancelled). Double registration is impossible (remove-wins means exactly one `_onFrame` per invoke-ID reaches the hook). A throwing hook is contained without breaking correlation, and both hook and await-side decode the same bytes with the same pure function, so they can never disagree. The command-mismatch path correctly skips the hook.
- **Parser bounds checking verified.** Every read in `parseNotificationStream` is bounds-checked before dereference; lying `stamps`/`sampleCount`/`size` fields all throw `MalformedFrameException` inside the contained 0x08 branch; Dart's 64-bit ints make `off + size` overflow-free on the native VM. The `FrameAssembler` enforces `length >= 32`, so `_onFrame`'s header decode and payload slice at offset 38 can never over-read.
- **The leak-proof test IS deterministic.** `StreamSubscription.cancel()` chains through `onCancel` → `_deleteQuietly` → the full Delete round-trip, and the mock is single-threaded and in-order, so `activeHandleCount == 0` after the cancel loop is a mechanical result, not a timing hope (the `waitUntil` is redundant belt-and-braces).

However, one **Critical** defect was found and **empirically confirmed with a scripted reproduction**: the asymmetry between `addNotification`'s synchronous map registration and `deleteNotification`'s post-`await` map removal lets a stale Delete continuation remove and close a brand-new subscription's controller when the server recycles the notification handle (CR-01). Four warnings and six info items follow. All Critical and Warning findings were fixed and the fixes verified in iteration 2; one additional Info-grade observation (IN-07) was recorded during verification.

## Critical Issues

### CR-01: Stale Delete continuation closes a new subscription registered under a recycled handle

**File:** `lib/src/connection/ams_connection.dart:274-275` (with `lib/src/connection/ams_connection.dart:239` as the interacting write)

**Issue:** `addNotification` registers its controller **synchronously** in the `onResponseSync` hook (inside `_onFrame`), but `deleteNotification` removes and closes the controller in an **await continuation** (a microtask that runs after the whole inbound chunk has been drained):

```dart
await request(AdsCommandId.deleteDeviceNotification, payload, timeout: timeout);
unawaited(_demuxControllers.remove(handle)?.close() ?? Future<void>.value());
```

Sequence: client pipelines `Delete(H)` then a new `Add`; the server frees `H` and (legitimately — real ADS servers reuse handles) assigns `H` to the new Add. When the Delete response and the Add response arrive in the **same TCP chunk**, `_onFrame` processes them back-to-back in one synchronous drain: the Delete completer is completed (continuation *scheduled*), then the Add hook synchronously maps `H → ctrlB`. Only *then* does the Delete continuation run — and `_demuxControllers.remove(H)` removes and **closes the new subscription's controller**. The new stream silently emits `done`, having received nothing, with no error; every notification for the recycled handle is silently dropped thereafter. This is silent data loss on a live subscription in an industrial-control client.

Confirmed by reproduction against `FakeTransport` (scratchpad script, coalesced `[DeleteResp][AddResp(H)]` chunk):

```
B acquired handle: 0x77
ctrlB.isClosed: true
B received: 0 sample(s)
B done (stream silently closed): true
```

The mock never triggers this (monotonic `nextHandle`), so no existing test catches it. The map-remove-wins discipline that protects `_pending` was not applied to `_demuxControllers`: for the demux map, the Delete's "remove" runs one microtask too late — the exact failure mode the `onResponseSync` hook was invented to prevent for Add.

**Fix:** Make the Delete's map removal identity-guarded (or move it into an `onResponseSync` hook, symmetric with Add). Identity guard is the minimal fix:

```dart
Future<void> deleteNotification(
  int handle,
  Uint8List payload, {
  Duration? timeout,
}) async {
  // Capture the controller this delete concerns BEFORE the round-trip, so a
  // same-chunk Add that recycles the handle (and synchronously re-maps it)
  // is never removed by this stale continuation.
  final victim = _demuxControllers[handle];
  await request(
    AdsCommandId.deleteDeviceNotification,
    payload,
    timeout: timeout,
  );
  if (identical(_demuxControllers[handle], victim)) {
    _demuxControllers.remove(handle);
  }
  unawaited(victim?.close() ?? Future<void>.value());
}
```

Add a regression test mirroring the reproduction: subscribe A (handle H) → pipeline Delete(H) + Add B → feed both responses in one chunk with B's response reusing H → assert B's controller is still registered, open, and receives a subsequent 0x08 sample for H.

**Resolution:** Fixed in `fb1ad12` — identity-guarded removal exactly as suggested (`victim` captured before the round-trip; `remove` only when `identical`). Regression test `recycled handle: a stale Delete continuation must not close a NEW subscription...` added to `notification_demux_test.dart` (verified to fail against the unfixed code, pass with the fix).

**Verified (iteration 2):** ✅ — see Re-Review Verification.

## Warnings

### WR-01: `deleteNotification` ignores both error levels and leaks the demux entry on request failure

**File:** `lib/src/connection/ams_connection.dart:260-276`

**Issue:** Two related gaps:

1. The Delete response's AMS-header `errorCode` and the decoded ADS `result` u32 are **never inspected** (`decodeDeleteNotificationResponse` exists in `notifications.dart` but has no production caller — only tests call it). A server that *refuses* the Delete (e.g. `0x752 ADSERR_CLIENT_REMOVEHASH`, or any AMS-level error) is indistinguishable from success: the client removes the handle locally while the server-side handle stays alive — a silent server-side handle leak that the phase's own leak-proof discipline exists to prevent. `AdsClient._deleteQuietly` swallows errors *by policy*, but that policy is only sound if the layer below actually surfaces them.
2. If `request` **throws** (per-request timeout being the realistic case on a live connection — `AdsConnectionException` paths are cleaned up by `_failClose`), the method exits before the map mutation: the handle stays in `_demuxControllers` and the controller is never closed. Inbound 0x08 samples keep being routed to a controller whose subscription is long cancelled, and the entry lives until disconnect. If the server *did* process the Delete and later recycles the handle, the stale entry is at least overwritten by the next Add's hook — but until then it is a zombie routing target.

**Fix:** Decode the response and surface non-zero `errorCode`/`result` as `AdsException` (the caller, `_deleteQuietly`, already swallows deliberately — but a direct `deleteNotification` caller deserves the truth), and perform the local map cleanup in a `finally`-style path (or on timeout as well), since local invalidation is safe regardless of server outcome:

```dart
({int errorCode, Uint8List payload}) resp;
try {
  resp = await request(AdsCommandId.deleteDeviceNotification, payload,
      timeout: timeout);
} finally {
  // Local invalidation must not depend on the round-trip outcome
  // (identity-guarded per CR-01).
  if (identical(_demuxControllers[handle], victim)) {
    _demuxControllers.remove(handle);
  }
  unawaited(victim?.close() ?? Future<void>.value());
}
if (resp.errorCode != 0) throw AdsException.fromCode(resp.errorCode);
final result = decodeDeleteNotificationResponse(resp.payload);
if (result != 0) throw AdsException.fromCode(result);
```

**Resolution:** Fixed in `43c57ff` — implemented as suggested: identity-guarded local invalidation moved into a `finally` (unconditional on success/refusal/timeout/disconnect), then both error levels checked and thrown as `AdsException`. `decodeDeleteNotificationResponse` gains its production caller. `AdsClient._deleteQuietly` still swallows by policy, so the cancel path never throws (locked decision). Three unit tests added: refused Delete (result `0x752`) throws but cleans up; AMS-level `errorCode` throws after cleanup; Delete timeout leaves no zombie demux entry.

**Verified (iteration 2):** ✅ — see Re-Review Verification.

### WR-02: Mock allocates attacker-controlled `cbLength` bytes per notification — unguarded up to 4 GiB

**File:** `test_harness/mock_server.cpp:759, 864, 889`

**Issue:** `AddDeviceNotification` stores the request's `cbLength` unvalidated (`notes[handle] = { group, offset, cbLength, transMode }`, line 864). Both emission paths then allocate a buffer of that size:

- burst path (line 889): `const std::vector<uint8_t> data(cbLength, 0);`
- write-trigger path (line 759): `std::vector<uint8_t> data(cb, 0);`

A single Add with `cbLength = 0xFFFFFFFF` makes the mock attempt a 4 GiB allocation on the next trigger — `std::bad_alloc` is uncaught, so the **whole mock process terminates** (listening socket included), wedging every subsequent integration test in the run. Even a "successful" large allocation produces a notification frame far above the Dart assembler's 4 MiB cap, poisoning the client connection. This contradicts the file's own documented discipline (lines 133-139: the `kMaxFrameBytes` guard note explicitly says per-command length fields are validated at their dispatch sites — WRITE and READ_WRITE are, ADD's `cbLength` is not, and READ's `length` guard at line 661 shows the intended pattern).

**Fix:** Reject oversized `cbLength` at the ADD dispatch site, mirroring the READ guard:

```cpp
if (!getU32(body, bodyLen, 8, cbLength) || cbLength > kMaxFrameBytes) {
    break; // malformed/hostile: no response
}
```

**Resolution:** Fixed in `9d28e44` — variant of the suggestion: `cbLength > kMaxFrameBytes` is rejected at the ADD dispatch site, but WITH a real ADS error response (result `0x705 ADSERR_DEVICE_INVALIDSIZE`, handle 0, nothing registered) instead of silence, so the Dart client fails fast rather than timing out. The `kMaxFrameBytes` doc note now covers ADD's `cbLength`. Integration regression test added: hostile Add (`length: 0xFFFFFFFF`) surfaces `AdsException(0x705)`, mock survives, handle count stays 0.

**Verified (iteration 2):** ✅ (with one residual Info-grade boundary nit, recorded as IN-07) — see Re-Review Verification.

### WR-03: Integration "first-listen race" test cannot fail when the race is lost

**File:** `test/integration/ads_notification_test.dart:187-220`

**Issue:** The test claims to prove the same-chunk race is won, but its assertions cannot detect a lost race:

1. A sample for an **unregistered handle is silently ignored without touching `droppedNotifications`** (`ams_connection.dart:367` — `_demuxControllers[n.handle]?.add(n)`; the counter only counts parse failures). So `expect(client.connection.droppedNotifications, equals(0))` passes whether or not the first burst frame was dropped on the floor.
2. The mock sends the Add response and each of the 3 burst frames as **separate `send()` calls with TCP_NODELAY** (`mock_server.cpp:887-895`); the kernel is free to deliver them as separate chunks. With a hypothetically-broken (post-`await`) registration, bursts #2/#3 arriving in later chunks would still be delivered, `received` becomes non-empty, and the test passes.

Net: a regression that reintroduces the T-5-11 race would sail through this integration test — it provides false confidence in exactly the property it is named after. (The **unit** test `notification_demux_test.dart:149-195` does prove the race deterministically by hand-coalescing the chunk; the integration test's value is only "burst mode delivers something".)

**Fix:** Either (a) assert on delivery of *all* `notifyBurst` samples AND have the mock coalesce the Add response + first burst frame into a single `send()` (a `--notify-burst-coalesced` variant), making chunk boundaries deterministic; or (b) rename/re-document the test as "burst delivery works end-to-end" and leave the race proof to the unit test — do not keep an assertion (`droppedNotifications == 0`) that structurally cannot fail for the advertised reason.

**Resolution:** Fixed in `4191d39` — option (a), strengthened: (1) `AmsConnection` gains an `unregisteredNotifications` counter (parsed samples with no mapped handle are still ignored per C++ parity, but now observable — closing gap 1); (2) the mock's `--notify-burst` path sends the Add response + ALL burst frames in ONE `send()` (deterministic same-chunk, closing gap 2; `--notify-burst` combined with `--fragment`/`--coalesce`/`--delay-ms` is now rejected at argv, exit 2); (3) the test asserts ALL burst samples delivered AND `unregisteredNotifications == 0` — a post-`await` registration regression now fails both. Unit test for the counter added to the unregistered-handle case.

**Verified (iteration 2):** ✅ — see Re-Review Verification.

### WR-04: Mock coalesce-mode flush heuristic can strand notification frames and deadlock a client

**File:** `test_harness/mock_server.cpp:369-379` (interacting with the Phase-5 emission paths at 715, 738, 765, 887-895)

**Issue:** `sendResponse` in `Coalesce` mode buffers frames and flushes only when `coalesceBuf.size() >= frame.size() * 2` — a heuristic written in Phase 1 when all frames were identical ReadDeviceInfo responses. Phase 5 now routes **notification frames and Add responses of heterogeneous sizes** through the same path. With `--coalesce` active:

- a small notification frame following a large buffered frame (or vice versa) can leave the buffer below the threshold, stranding the frame until connection close (line 963's flush) — for the burst path (line 887) that strands the **Add response itself**, deadlocking the Dart client, which is awaiting it while holding the connection open;
- flag combinations that break the mode (`--coalesce` + notifications, `--notify-burst` + `--delay-ms` — the latter acknowledged only in a comment at line 884-886) are not rejected at argv parse time, so a future test author gets a hang instead of an error.

No current test combines these flags, so this is latent — but the harness advertises the modes as orthogonal (header comment, lines 22-35) and nothing enforces otherwise.

**Fix:** Reject unsupported combinations in `main()` argv parsing (`--notify-burst`/notification magic groups with `--coalesce` or `--delay-ms` → exit 2 with a message), or exempt notification/burst emission from coalescing by passing `TransmitMode::Normal` to `emitNotification`/the burst `sendResponse` call.

**Resolution:** Fixed in `97afddd` (argv guard landed with WR-03 in `4191d39`) — both halves: (1) `--notify-burst` with `--fragment`/`--coalesce`/`--delay-ms` exits 2 at argv parse with a message; (2) notification frames are exempt from the coalesce buffer via `sendNotificationFrame` — any buffered response is flushed FIRST (preserving wire order), then the 0x08 goes out in its own `send()`, so a write-triggered notification under `--coalesce` can never strand a response the client is awaiting. The header comment documents both restrictions (`--fragment` still applies to notifications: segmentation is a legitimate reassembly exercise).

**Verified (iteration 2):** ✅ — see Re-Review Verification.

## Info

### IN-01: `parseNotificationStream` accepts trailing junk after the last sample

**File:** `lib/src/protocol/notifications.dart:230-272`
**Issue:** After the stamp loop, `off` is never checked against `payload.length`. A frame whose `stamps`/`sampleCount` fields undercount (e.g. `stamps = 0` with kilobytes of trailing bytes) parses "successfully", silently discarding the remainder — a lying-count frame that the T-5-03/T-5-04 hardening narrative says should be rejected.
**Fix:** After the loop: `if (off != payload.length) throw MalformedFrameException('trailing bytes after last sample', offset: off);`

### IN-02: Redundant double copy of sample data

**File:** `lib/src/protocol/notifications.dart:266`
**Issue:** `Uint8List.fromList(payload.sublist(off, off + size))` copies twice — `sublist` already returns a fresh, non-aliasing `Uint8List` (even on a view). One allocation per sample is pure waste.
**Fix:** `final data = payload.sublist(off, off + size);` (the defensive-copy guarantee and the aliasing unit test still hold).

### IN-03: Hostile FILETIMEs with the high bit set produce silently wrong timestamps

**File:** `lib/src/protocol/notifications.dart:115-118, 252`
**Issue:** `ByteData.getUint64` returns values ≥ 2^63 as negative Dart ints; `(filetime - _filetimeEpochOffset)` then wraps below int64 min on the native VM. The result is a garbage-but-valid `DateTime` rather than an error. Unreachable for honest servers before year 30828, but this is the declared untrusted-input boundary.
**Fix:** Reject negative results of `getUint64` (i.e. wire values ≥ 2^63) with `MalformedFrameException`, or document the wrap explicitly alongside the existing truncation note.

### IN-04: `subscribe(timeout:)` is not applied to the cancel-path Delete

**File:** `lib/src/client/ads_client.dart:266-275`
**Issue:** The caller's `timeout` governs the Add, but `_deleteQuietly` calls `connection.deleteNotification` without a timeout, silently falling back to the connection default (5 s). A caller who set a short timeout for a slow link gets an inconsistent policy on cancel.
**Fix:** Thread the subscription's `timeout` into `_deleteQuietly(acquired, timeout: timeout)` and pass it through.

### IN-05: Doc claims the mock size-checks the 40-byte Add payload — it does not

**File:** `lib/src/protocol/notifications.dart:135-137` (vs `test_harness/mock_server.cpp:848-861`)
**Issue:** The `buildAddNotificationPayload` doc says "Omitting the reserved bytes is the classic off-by-16 bug (a real PLC and the mock both size-check)". The mock only requires the first 24 bytes via `getU32` bounds checks; a 24-byte Add (reserved bytes omitted) is accepted with a success response. The off-by-16 regression the comment invokes would pass every integration test (only the unit assertion `hasLength(40)` in `subscribe_test.dart:140` guards it).
**Fix:** Either add `if (bodyLen < 40) break;` to the mock's ADD case (making the doc true and the integration suite regression-proof), or correct the doc comment.

### IN-06: One throwing controller aborts dispatch of the remaining samples in a 0x08 frame

**File:** `lib/src/connection/ams_connection.dart:365-371`
**Issue:** The parse and the per-sample dispatch share one `try`. `parseNotificationStream` returns a fully-parsed list before any dispatch, so a parse failure loses nothing — but if `controller.add(n)` ever throws (e.g. a closed controller reaching the map through a future invariant break like CR-01's cousin), the remaining samples of that frame for *other healthy handles* are dropped, and the failure is miscounted as a `droppedNotifications` parse failure.
**Fix:** Parse inside the `try`; dispatch outside it (or wrap each `add` individually):

```dart
List<AdsNotification> parsed;
try {
  parsed = parseNotificationStream(notificationPayload);
} catch (_) {
  droppedNotifications++;
  return;
}
for (final n in parsed) {
  _demuxControllers[n.handle]?.add(n);
}
```

### IN-07: Mock `cbLength` cap leaves a 60-byte boundary window that passes the guard yet exceeds the client's frame cap (new, iteration 2)

**File:** `test_harness/mock_server.cpp:930` (guard) vs `lib/src/protocol/frame_assembler.dart:112` (client cap)
**Issue:** The WR-02 fix rejects `cbLength > kMaxFrameBytes` (4194304), and its comment claims this also prevents "a 'successful' giant frame would exceed the Dart assembler's 4 MiB cap and poison the client connection". Not quite: a single-sample notification frame's AMS/TCP `length` is `32 (AoE) + 28 (stream framing) + cbLength`, so any accepted `cbLength` in `[4194245, 4194304]` (60 values) produces frames the Dart `FrameAssembler` rejects (`length > maxFrameBytes` → `MalformedFrameException` → connection poisoned) on the next trigger. The mock itself survives (no `bad_alloc` — the WR-02 harness-wedging component is genuinely fixed); the residual failure mode is a hypothetical future test choosing a `cbLength` within 60 bytes of the cap and getting a poisoned client connection instead of a clean `0x705` refusal. No current test approaches this boundary.
**Fix:** Tighten the guard to account for framing overhead (e.g. `cbLength > kMaxFrameBytes - 64`), or correct the comment to say the cap bounds mock allocation only.

---

## Re-Review Verification (iteration 2, 2026-07-04)

Focused adversarial re-review of `fb1ad12..97afddd` against `ams_connection.dart`, `mock_server.cpp`, `notification_demux_test.dart`, `ads_notification_test.dart`, and `ads_client.dart` (WR-01's `_deleteQuietly` contract).

**1. CR-01 identity guard — VERIFIED complete.**
- `victim` is captured before the round-trip (`ams_connection.dart:296`); the `finally` removal (`:305`) fires only when `identical(_demuxControllers[handle], victim)`.
- All `_demuxControllers` mutation paths audited: the `finally` removal (guarded), `_failClose`'s clear (`:497` — intentionally unconditional: the connection is dead and every controller is error-closed first), and the `addNotification` hook write (`:249` — an overwrite, never a close of a delete victim). No unguarded removal path exists. Concurrent double-Delete of the same handle is safe (second `finally` finds no identical entry; `StreamController.close()` is idempotent).
- The regression test (`notification_demux_test.dart:298-377`) truly reproduces the coalesced recycled-handle scenario: Delete-response and Add-B-response (same handle) are fed as ONE chunk, so both frames dispatch in one synchronous assembler drain — Add-B's hook maps `ctrlB` BEFORE the Delete's await continuation runs. With an unguarded `remove(handle)`, `ctrlB.isClosed == false` and `receivedB == [0x42]` would both fail; with the guard they pass and `ctrlA` alone is closed.

**2. WR-01 both-levels check + finally-scoped invalidation — VERIFIED.**
- All five exits leave no zombie entry: success, refused Delete (result `0x752`), AMS-level `errorCode`, per-request timeout (`AdsTimeoutException` from `request` still runs the `finally`), and disconnect (`AdsConnectionException`; `_failClose` already cleared the map, so the identity check is a no-op and `victim.close()` is an idempotent re-close).
- Error-level ordering is correct: `errorCode` is checked (`:314`) BEFORE `decodeDeleteNotificationResponse` (`:317`), so a short/empty error payload can never trip the decoder (T-3-02 discipline preserved).
- `_deleteQuietly` never throws: `deleteNotification` is `async` (even `request`'s synchronous `not connected` throw becomes a future error), and `_deleteQuietly`'s `catch (_)` (`ads_client.dart:272`) swallows every exception family, including a `MalformedFrameException` from a hostile short Delete payload. The `finally` itself cannot throw (`identical` + `Map.remove` + idempotent `close()` behind `unawaited`).
- All three failure-path unit tests present (`notification_demux_test.dart:379-527`) and assert both cleanup AND the thrown code.

**3. WR-02 cbLength reject — VERIFIED placed before any allocation.**
- The `cbLength > kMaxFrameBytes` check (`mock_server.cpp:930`) precedes the `notes[handle]` registration (`:942`), the handle increment (`:941`), and both emission-allocation sites (burst `:973`, write-trigger `:816` — the latter only ever sees registered, i.e. capped, handles). The reject path allocates only an 8-byte error payload.
- Integration regression (`ads_notification_test.dart:288-325`) proves `AdsException(0x705)`, mock survival (in-band read over the same connection), and zero registered handles.
- One residual boundary nit recorded as IN-07 (Info): the guard's comment overclaims client-side protection for the top 60 bytes below the cap. Does not reintroduce any WR-02 failure mode (no allocation blow-up, no wedged harness).

**4. WR-03 burst determinism + counter assertions — VERIFIED a lost race now fails.**
- The mock concatenates the Add response and ALL burst frames into ONE `sendAll` (`mock_server.cpp:970-981`) on a TCP_NODELAY loopback socket — deterministic single inbound chunk.
- Failure analysis under a hypothetical post-`await` registration: all N same-chunk burst frames dispatch in the same synchronous drain BEFORE any microtask runs, so ALL would hit an unmapped handle — `received` stays empty, `waitUntil(received.length >= burst)` fails the test outright, and `unregisteredNotifications == 0` (`ads_notification_test.dart:221`) fails independently. The old false-confidence path (later-chunk bursts masking a dropped first sample) is structurally eliminated.
- The counter increments ONLY in the unmapped-handle branch (`ams_connection.dart:418`), never for parse failures (those bump `droppedNotifications` in the enclosing catch) — the two counters cannot cross-contaminate. Unit coverage at `notification_demux_test.dart:640-641`.

**5. WR-04 coalesce exemption + argv rejection — VERIFIED.**
- `sendNotificationFrame` (`mock_server.cpp:473-486`): under Coalesce, any buffered frame is flushed FIRST — the buffer can only contain frames queued temporally earlier, so wire order is preserved — then the 0x08 goes out in its own `send()`. Notification frames can no longer strand a response below the flush threshold. `--fragment` still segments notifications via the `sendResponse` fall-through (intentional, documented).
- Argv rejection (`:1133-1139`): `notifyBurst > 0 && (mode != Normal || delayMs > 0)` covers `--fragment`, `--coalesce`, and `--delay-ms`, runs after the full parse loop (flag order irrelevant), exits 2 with a message. Zero/negative `--notify-burst` values are benign (burst loop does not execute).

**6. New issues from the five commits:** the diff (`fb1ad12~1..97afddd`, 4 files, +491/−58) was re-read in full. No new Critical or Warning findings. One new Info-grade observation (IN-07, above). Open Info findings IN-01..IN-06 were not re-litigated per re-review scope.

**Verdict: all five fixes verified. Status → clean (open Info findings do not block).**

---

## Verified non-findings (adversarially traced, no defect)

- **Hook vs timeout/disconnect:** a timed-out or fanned-out request can never have its hook invoked (remove-wins claims verified at `ams_connection.dart:178, 375, 434-435`).
- **Cancel-during-pending-add:** the `cancelled` flag and `handle` variable are updated/read on a single event loop with `cancelled = true` set synchronously before any await in `onCancel`; no interleaving yields a double-Delete or a leaked handle (`ads_client.dart:214-255`).
- **`addError` after cancel:** events/errors added to a single-subscription controller after its subscription cancels are discarded by the SDK, not thrown; the `isClosed` guard at `ads_client.dart:242` is sufficient.
- **FILETIME epoch offset:** `11644473600 * 10^7 = 116444736000000000` verified; whole-microsecond round-trip and `~/ 10` truncation semantics correct.
- **`buildAddNotificationPayload`:** all six u32 fields range-checked; reserved 16 bytes present; layout matches the golden (`dump_golden.cpp:283-306`).
- **Leak-proof determinism:** `sub.cancel()` awaits the full Delete round-trip; mock is single-threaded/in-order → `testManyNotifications`' 0→N→0 count assertions are deterministic.
- **Mock handle-table lifetime:** `notes` is per-connection (per-test), erased only by a matching Delete; unknown-handle Delete returns 0x752 without freeing unrelated entries.
- **Mock fd-write failures during emission:** `SIGPIPE` ignored; `sendAll` fails with `EPIPE`, dropping only that connection; the accept loop survives.
- **(iteration 2) Hostile-Add cancel path:** `sub.cancel()` after a failed Add is a no-op Delete (`handle == null`), never throws; the failed Add's hook registered nothing (early return on `decoded.result != 0`).

_Reviewed: 2026-07-04_
_Re-reviewed: 2026-07-04 (iteration 2)_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard / quick (focused re-review)_
