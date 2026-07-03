---
phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation
reviewed: 2026-07-03T21:49:36Z
re_reviewed: 2026-07-03T22:08:54Z
re_review_iteration: 2
depth: standard
files_reviewed: 8
files_reviewed_list:
  - lib/src/transport/transport.dart
  - lib/src/transport/socket_transport.dart
  - lib/src/transport/fake_transport.dart
  - lib/src/connection/ams_connection.dart
  - lib/src/connection/pending_request.dart
  - lib/src/connection/exceptions.dart
  - test/support/mock_server.dart
  - test_harness/mock_server.cpp
findings:
  critical: 1
  warning: 5
  info: 11
  total: 17
resolved:
  critical: 1
  warning: 5
  info: 0
fixed_at: 2026-07-03T22:40:00Z
fix_report: 02-REVIEW-FIX.md
status: clean
---

# Phase 2: Code Review Report

**Reviewed:** 2026-07-03T21:49:36Z
**Re-reviewed:** 2026-07-03T22:08:54Z (iteration 2 — fix verification)
**Depth:** standard
**Files Reviewed:** 8
**Status:** clean — all Critical + Warning findings verified fixed (commits `8e71415..6270fd9`, see `02-REVIEW-FIX.md`); Info findings remain open by scope decision (IN-01..IN-09 from iteration 1, IN-10/IN-11 added in iteration 2)

## Re-Review (Iteration 2) — Fix Verification

Re-reviewed `lib/src/connection/ams_connection.dart` and `test/support/mock_server.dart` (plus `pending_request.dart`, `fake_transport.dart`, `socket_transport.dart`, and `test/unit/ams_connection_test.dart` for context) against the six resolved findings. Verification was empirical where possible, not trust-the-report: `dart analyze --fatal-infos` → "No issues found!"; `dart format --set-exit-if-changed` → 0 changed; unit suite → 65/65 green including the four new regression tests; the WR-04 lock primitive (`File.create(exclusive: true)` → `PathExistsException` on contention) confirmed by a standalone probe on this platform.

**CR-01 — VERIFIED FIXED.** `request()` now orders: allocate ID → `_buildFrame` (which is where the synchronous `ArgumentError` from `AmsHeader.encode`'s range checks originates) → only then create the `Completer`/`Timer` and register in `_pending` (`ams_connection.dart:146-159`). A sync encode throw therefore leaves zero state behind (the only side effect is a skipped invoke-ID from `_allocInvokeId`, which is harmless). The optional hardening was also applied: `_transport.add(frame)` is wrapped in try/catch that removes the entry, cancels the timer, and rethrows (`:160-168`), so a synchronously-throwing transport also unwinds cleanly. The regression test (`encode throw` group) issues `request(0x10000)` with a 20 ms timeout, sleeps 60 ms past the window (where the old orphaned timer fired an unhandled async error), and asserts continued end-to-end usability. Correct and complete.

**WR-01 — VERIFIED FIXED.** `_allocInvokeId` (`:191-203`) skips in-flight IDs with the wrap `0xFFFFFFFF → 1` (never 0). Termination is sound: the guard rejects at `_pending.length >= 0xFFFFFFFE`, and since the key space is `1..0xFFFFFFFF` (0xFFFFFFFF values), any allowed map size leaves at least two free IDs, so the skip loop always terminates. `_nextInvokeId` is advanced from the *granted* ID with the same wrap rule. The `@visibleForTesting debugNextInvokeId` seam is annotation-only (`meta ^1.16.0` added — endorsed by STACK.md), and the regression test proves the exact prior failure (0xFFFFFFFF still pending → next allocation is 1, both futures resolve independently). Correct and complete.

**WR-02 — VERIFIED FIXED** for the finding as written: the `StateError` guard (`:105-110`) runs before `_transport.connect`, so a rejected sequential double-connect or connect-after-close can never open a socket; both regression tests pass and the post-guard connection stays usable. One narrow residual remains — the guard checks `_connected`, which is only set *after* `await _transport.connect(...)` returns, so two overlapping unawaited `connect()` calls both pass the guard (recorded as IN-10 below, consistent with the IN-04 precedent for transport-level double-connect).

**WR-03 — VERIFIED FIXED.** `_failClose` (`:291-320`) keeps the fan-out ordering intact — `_closed` set first, subscription cancelled, pending snapshot+clear, `completeError` on every pending, demux controllers errored+closed — and only then chains `_doneCompleter` off `_transport.close().whenComplete(...)`. Ordering vs. fan-out is correct: pending futures are errored before `done` completes. Single-shot holds: the `_closed` guard means `_transport.close()` is invoked exactly once, and the `isCompleted` check is redundant belt-and-braces, not a mask for a second path. The fixer-flagged interaction with `FakeTransport.close()` was checked explicitly: because `_subscription.cancel()` runs before `_inbound.close()`, the controller's close future completes promptly (cancellation finishes a single-subscription controller), and every current test that awaits `conn.close()`/`conn.done` over FakeTransport completes instantly (65/65, no timeouts). The only hang path is `close()` on a connection that never `connect()`ed over a FakeTransport (never-listened controller) — no current test or production path does this (`SocketTransport.close()` returns immediately on a null socket), so it stays latent under the existing open IN-05. One new latent nit recorded as IN-11: the future returned by `whenComplete` is discarded, so a hypothetical transport whose `close()` errors would surface an unhandled async error (both current transports are non-throwing).

**WR-04 — VERIFIED FIXED.** `_withBuildLock` (`mock_server.dart:127-153`) serializes the stale-check + configure + build behind an atomic `File.create(exclusive: true)` lock file. The primitive was probed on this platform: the contending `create` throws `PathExistsException`, exactly the type caught. The rejection of the review's original `RandomAccessFile.lock` suggestion is technically correct — POSIX advisory locks are per-process and would not exclude between `dart test` isolates. Stale-lock path: the 5-minute deadline turns a lock orphaned by a killed run into a `StateError` naming the exact file to delete (clear, actionable); the deadline throw happens *before* acquisition, so a timed-out waiter can never delete a live holder's lock; release is in `finally` with a best-effort swallow whose worst case is the documented timeout error. `test_harness/.build.lock` is gitignored (confirmed in `.gitignore`). Correct and complete.

**WR-05 — VERIFIED FIXED.** The dead `src/connection/ams_connection.dart` import is gone from `test/unit/ams_connection_test.dart` (the `src/transport/fake_transport.dart` import correctly remains — `FakeTransport` is not exported from the barrel). `dart analyze --fatal-infos` exits clean, verified directly.

**No new Critical or Warning issues found** in the fixed code. Two new Info findings (IN-10, IN-11) recorded below; per fix scope, Info findings remain open.

## Summary

Reviewed the Phase 2 async layer: the transport seam (`transport.dart` — the config's planned `ads_transport.dart` name; the file exists as `lib/src/transport/transport.dart`), the real socket and fake transports, the `AmsConnection` correlation core plus its `PendingRequest`/exception support types, the Dart mock-server launch helper, and the `--delay-ms` / `--close-after` additions to the C++ mock. Unit and integration test files were read for context.

Verified sound (traced, not assumed):

- **Map-remove-wins invariant** holds: `_pending.remove` is the sole completion claim on a single event loop; response, timeout, and fan-out paths cannot double-complete a `Completer`, and the response path cancels the timer before completing.
- **Codec-throw seam is safe**: `FrameAssembler.add` guarantees every emitted frame is at least 38 bytes and drops the poisoned remainder before throwing, and `AmsHeader.decode`'s only throw is `MalformedFrameException` — the `on MalformedFrameException` handler in `connect()` therefore covers every throw reachable from the onData callback, routing it into `_failClose`. No connection-poisoning path found.
- **Fan-out ordering** is correct: `_closed` set first, pending map snapshotted and cleared before any `completeError`, timers cancelled, `done` completed exactly once; re-entrant `close()`/late `onDone` after `onError` are no-ops.
- **C++ `--delay-ms` / `--close-after`** are deterministic and thread-free as claimed: the deferred first response is flushed only after a later response has been sent (or at connection close, so it is never lost); `--close-after` closes exactly once with `closedByCloseAfter` guarding both the double-close and the send-after-close paths; no fd leaks found on any path; the `--selftest` path is untouched by the additions.

The blocker was in `request()`: the pending entry and its armed `Timer` were registered *before* the frame was built, so a synchronous encode throw leaked an orphaned completer that fired an unhandled async error five seconds later. Warnings covered the invoke-ID wrap collision (hung Future), a missing `connect()` state guard (socket leak + `LateInitializationError`), `done` completing before transport teardown finishes, a concurrent-CMake-build race in the test launcher, and an analyzer info that failed the project's `--fatal-infos` CI gate. **All six were fixed and verified in iteration 2 (see Re-Review section above).**

## Critical Issues

### CR-01: `request()` registers the pending entry before building the frame — a sync encode throw leaks an armed Timer that later fires an unhandled async error

**File:** `lib/src/connection/ams_connection.dart:140-141`
**Issue:** The order is `_pending[id] = PendingRequest(completer, timer, commandId);` then `_transport.add(_buildFrame(commandId, id, payload));`. `_buildFrame` calls `AmsHeader(...).encode()`, whose `checkUint` throws `ArgumentError` for any `commandId` outside u16 (`request()` takes a raw `int` on the public API, so `conn.request(0x10000, ...)` or a negative value reaches it). When it throws:
1. The caller gets a synchronous `ArgumentError` — no Future is ever returned, so nothing listens to `completer.future`.
2. The `PendingRequest` stays in `_pending` with its `Timer` armed.
3. Five seconds later the timer fires, removes the entry, and calls `completer.completeError(AdsTimeoutException(...))` on a Future with no listener — an **unhandled async error**, which under the default error handler terminates the isolate (or fails an unrelated test) long after the caller already caught and "handled" the `ArgumentError`. If the connection disconnects first, `_failClose` completes the same orphaned completer with the same unhandled-error result.

**Fix:** Build (and validate) the frame before creating any pending state, so a throw leaves nothing behind:
```dart
final id = _allocInvokeId();
final frame = _buildFrame(commandId, id, payload); // may throw ArgumentError — nothing registered yet
final completer = Completer<Uint8List>();
final timer = Timer(timeout ?? _defaultTimeout, () {
  final pending = _pending.remove(id);
  pending?.completer.completeError(AdsTimeoutException(id, commandId));
});
_pending[id] = PendingRequest(completer, timer, commandId);
_transport.add(frame);
return completer.future;
```
Optionally also wrap `_transport.add(frame)` in a try/catch that removes the entry and cancels the timer, as defense against a future transport whose `add` can throw synchronously.

**Resolved:** fixed in `8e71415` — frame is built (and range-checked) before any pending state; a sync `_transport.add` throw also unwinds the registration. Regression test outlives the timeout window and asserts the connection stays usable.
**Verified (iteration 2):** ordering confirmed at `ams_connection.dart:146-159`; add()-throw unwind at `:160-168` removes the entry and cancels the timer before rethrowing; regression test passes and leaves no unhandled async error.

## Warnings

### WR-01: Invoke-ID wrap collision silently overwrites a live pending entry, permanently hanging the newer request's Future

**File:** `lib/src/connection/ams_connection.dart:140, 156-160`
**Issue:** `_allocInvokeId()` wraps `0xFFFFFFFF → 1` without checking `_pending`. If an ID is still in flight when the counter wraps back to it (long-lived request + very high request volume, or a caller-supplied multi-hour timeout), `_pending[id] = PendingRequest(...)` overwrites the old entry while the *old* Timer stays armed on the same `id`. When the old timer fires, `_pending.remove(id)` claims the **new** request's entry and completes the **old** completer — and the new request's completer is now unreachable by every completion path (its own timer's `remove(id)` returns `null`; fan-out drains a map that no longer contains it). The new caller's Future hangs forever — exactly the "no hung Futures" failure class this phase's fan-out is designed to prevent.
**Fix:** Skip in-flight IDs during allocation:
```dart
int _allocInvokeId() {
  var id = _nextInvokeId;
  while (_pending.containsKey(id)) {
    id = id == 0xFFFFFFFF ? 1 : id + 1;
  }
  _nextInvokeId = id == 0xFFFFFFFF ? 1 : id + 1;
  return id;
}
```

**Resolved:** fixed in `e30ce1c` — allocation skips in-flight IDs, with a sanity `StateError` if ~4 billion requests were ever simultaneously pending. `@visibleForTesting debugNextInvokeId` seam (new `meta` dep) + wrap-collision regression test.
**Verified (iteration 2):** skip loop and sanity bound are provably terminating (guard at `>= 0xFFFFFFFE` over a key space of 0xFFFFFFFF leaves ≥ 2 free IDs); wrap never yields 0; regression test asserts skip-not-overwrite and independent resolution.

### WR-02: `connect()` has no state guard — a second call opens a socket, then throws `LateInitializationError`, leaking the live socket unrecoverably

**File:** `lib/src/connection/ams_connection.dart:97-99`
**Issue:** `connect()` neither checks `_connected` nor `_closed`. On a second call (double-connect, or connect-after-close): `await _transport.connect(host, port)` succeeds and opens a real socket **first**, then `_assembler = FrameAssembler()` throws `LateInitializationError` because `_assembler` is `late final` and already assigned. The new socket is now live but unreachable: for the connect-after-close case `close()` is a no-op (`_closed` already true, `_failClose` returns immediately), so `_transport.close()` is never invoked — a leaked fd and an unhelpful error instead of the typed `StateError`/`AdsConnectionException` the rest of the API uses.
**Fix:** Guard before touching the transport:
```dart
Future<void> connect(String host, int port) async {
  if (_connected || _closed) {
    throw StateError('AmsConnection is single-use: already connected or closed');
  }
  await _transport.connect(host, port);
  ...
}
```

**Resolved:** fixed in `6e52f6d` — `StateError` guard runs before the transport is touched, so a rejected call can never open (and leak) a socket. Double-connect and connect-after-close regression tests added.
**Verified (iteration 2):** guard confirmed at `:105-110`, ahead of any transport call; both regression tests pass. Residual concurrent-call window recorded as IN-10.

### WR-03: `done` completes before the transport is actually torn down; `_transport.close()` is fire-and-forget

**File:** `lib/src/connection/ams_connection.dart:261-264` (with `lib/src/transport/socket_transport.dart:54-68`)
**Issue:** `_failClose` calls `_transport.close()` without awaiting it and completes `_doneCompleter` immediately. `SocketTransport.close()` awaits `socket.flush()` before `destroy()`, so when `await conn.close()` / `await conn.done` returns, the socket fd can still be open and mid-flush — contradicting the documented contract ("Completes when the connection is fully torn down", line 81). Consumers that reconnect immediately, assert fd closure, or tear down a test process right after `await close()` race the still-pending destroy. (No unhandled-error risk today — both `close()` implementations are non-throwing — but the ordering contract is broken.)
**Fix:** Chain `done` off the transport teardown:
```dart
_transport.close().whenComplete(() {
  if (!_doneCompleter.isCompleted) _doneCompleter.complete();
});
```
(`_failClose` stays synchronous and single-shot; only the `done` completion moves after teardown.)

**Resolved:** fixed in `7b08bcc` — `done` now chains off `_transport.close()` via `whenComplete`, exactly as suggested; `_failClose` remains synchronous and single-shot.
**Verified (iteration 2):** ordering (pending fan-out before `done`), single-shot idempotency, and the FakeTransport `close()`-completes-after-cancel interaction all confirmed; no current test or production path hangs (the never-listened FakeTransport case stays latent under IN-05). Discarded error future noted as IN-11.

### WR-04: `_ensureBuilt` races itself when integration suites run in parallel — two concurrent `cmake --build` invocations on the same build directory

**File:** `test/support/mock_server.dart:107-155`
**Issue:** `dart test` runs test suites concurrently by default, and both `test/integration/socket_transport_test.dart` (via `setUpAll`) and `test/integration/ams_connection_live_test.dart` (per-test) call `startMockServer()`. If the binary is missing or stale, both isolates enter the configure+build path simultaneously: two concurrent `cmake -S/-B` and `cmake --build` runs against `test_harness/build` with no locking. Concurrent CMake/Make/Ninja invocations on one build tree can corrupt the cache or fail spuriously — a first-run/local-dev flake (CI builds explicitly, per the doc comment, so CI is unaffected).
**Fix:** Serialize with an exclusive file lock around the stale-check + build:
```dart
final lock = await File('test_harness/build.lock').open(mode: FileMode.write);
await lock.lock(FileLock.blockingExclusive);
try {
  // stale check + cmake configure + build
} finally {
  await lock.unlock();
  await lock.close();
}
```

**Resolved:** fixed in `fabd644` — adapted from the suggestion: `RandomAccessFile.lock` is a POSIX advisory lock and does not exclude between isolates of the *same* process (which is `dart test`'s topology), so the stale-check + build is instead serialized behind an atomic `File.create(exclusive: true)` lock file with a wait loop and a stale-lock timeout error. Lock file gitignored.
**Verified (iteration 2):** `PathExistsException` on contention empirically confirmed; stale-lock deadline errors clearly and can never delete a live holder's lock; `.gitignore` entry present. The isolate-topology rationale for adapting the fix is correct.

### WR-05: `unnecessary_import` in `ams_connection_test.dart` fails the project's `dart analyze --fatal-infos` CI gate

**File:** `test/unit/ams_connection_test.dart:8`
**Issue:** `dart analyze --fatal-infos` (the CI gate mandated in CLAUDE.md's CI conventions) currently exits non-zero: `The import of 'package:dart_ads/src/connection/ams_connection.dart' is unnecessary because all of the used elements are also provided by the import of 'package:dart_ads/dart_ads.dart'` — `AmsConnection` is exported from the public barrel, so the `src/` import is dead. This blocks the analyze job for the whole phase.
**Fix:** Delete line 8 (`import 'package:dart_ads/src/connection/ams_connection.dart';`).

**Resolved:** fixed in `6270fd9` — import deleted (the `fake_transport` `src/` import stays: `FakeTransport` is intentionally not exported). `dart analyze --fatal-infos` now exits clean.
**Verified (iteration 2):** `dart analyze --fatal-infos` run directly — "No issues found!".

## Info

### IN-01: `droppedResponses` / `notificationFrames` are public mutable fields

**File:** `lib/src/connection/ams_connection.dart:84, 87`
**Issue:** Both diagnostics counters are `int x = 0;` public fields — any consumer can assign them (`conn.droppedResponses = 0;`), silently corrupting the connection's own bookkeeping.
**Fix:** Back each with a private field and expose a getter: `int _droppedResponses = 0; int get droppedResponses => _droppedResponses;`

### IN-02: Command-mismatch path increments `droppedResponses` although the response *was* delivered (as an error), contradicting the counter's documented meaning

**File:** `lib/src/connection/ams_connection.dart:217`
**Issue:** The doc on line 83 defines the counter as "responses that matched no pending request", but the wrong-command branch both increments it *and* completes the claimed pending with an error. A test asserting `droppedResponses == 0` on a mismatch-free run is fine, but the counter conflates two distinct conditions (late/unknown vs. protocol violation), weakening its diagnostic value.
**Fix:** Either stop incrementing on the mismatch path or add a separate `protocolErrors` counter; update the doc comment to match.

### IN-03: `_onFrame` never checks `stateFlags` — a request-flagged frame with a colliding invoke-ID is delivered as a response

**File:** `lib/src/connection/ams_connection.dart:198-230`
**Issue:** Correlation keys only on invoke-ID + command-ID. A frame carrying `AmsStateFlags.request` (e.g., an echoed/looped-back client frame, or a server-initiated request other than cmd 0x08) whose invoke-ID matches a pending entry is completed as if it were the response. Low risk against a well-behaved peer, but the response bit is on the wire and free to check.
**Fix:** In the lookup branch, treat `header.stateFlags & 0x0001 == 0` (request, not response) like the unknown-response case: count and return without claiming the pending entry.

### IN-04: `SocketTransport` error messages claim "before connect()" for the after-close state; double `connect()` leaks the first socket

**File:** `lib/src/transport/socket_transport.dart:38, 48` (and `26-32`)
**Issue:** `close()` nulls `_socket`, so `add()`/`inbound` after close throw `StateError('... before connect()')` — a misleading diagnosis. Separately, a second `connect()` call overwrites `_socket` without destroying the first socket (fd leak). Neither is reachable through `AmsConnection`'s guarded flow, but `SocketTransport` is exported on the public barrel.
**Fix:** Track a `_closed` flag for an accurate message ('used after close()'), and have `connect()` throw `StateError` if `_socket != null`.

### IN-05: `FakeTransport.close()` returns a Future that may never complete when `inbound` was never listened to

**File:** `lib/src/transport/fake_transport.dart:44`
**Issue:** `StreamController.close()`'s returned future completes only when the done event is delivered or the subscription is cancelled; for a single-subscription controller that was never listened to, it stays pending. `await fakeTransport.close()` in a test that never subscribed hangs until the test times out. (The `AmsConnection` path is unaffected: it always listens, and `_failClose` doesn't await the close.)
**Fix:** `Future<void> close() { final f = _inbound.close(); return _inbound.hasListener ? f : Future.value(); }` — or document the constraint on the method.
**Note (iteration 2):** with WR-03, `conn.done` now waits on `_transport.close()`, so this latent hang would additionally stall `conn.close()`/`conn.done` — but only on the close-before-connect-over-FakeTransport path, which no current test or production path exercises (`_failClose` always runs after `connect()` cancelled-subscription state in every existing flow, and `SocketTransport.close()` returns immediately on a null socket). Remains latent; still Info.

### IN-06: `startMockServer` fails with a bare "Bad state: No element" (stderr lost) when the child exits before printing `LISTENING`

**File:** `test/support/mock_server.dart:83-94`
**Issue:** If the mock exits immediately — e.g., an unknown flag makes it print to stderr and exit 2 — stdout closes with no matching line and `firstWhere` errors with `StateError('No element')` before the 10 s timeout. The captured `stderrBuffer` (which holds the actual diagnosis, e.g. `unknown argument: --close_after`) is only surfaced on the *timeout* path, so the launch failure is reported with a message that explains nothing.
**Fix:** Handle the empty-stream case with the same context as the timeout: `.firstWhere((l) => l.startsWith('LISTENING '), orElse: () => throw StateError('mock exited before LISTENING\n$stderrBuffer'))`.

### IN-07: Staleness check omits the vendored AdsLib headers the mock compiles against

**File:** `test/support/mock_server.dart:57-60`
**Issue:** `_mockSources` lists only `mock_server.cpp` and `CMakeLists.txt`; the binary also depends on `third_party/ADS` headers (`AmsHeader.h`, `AdsDef.h`, `Frame.h`). Bumping the submodule pin leaves a stale local binary that the helper considers fresh. Low impact (CI rebuilds explicitly; the submodule rarely moves).
**Fix:** Add the submodule pin indicator (e.g., `.gitmodules` or the relevant `third_party/ADS` header paths) to `_mockSources`.

### IN-08: `usleep` with `--delay-ms` >= 1000 is undefined per POSIX (EINVAL on some platforms) — the delay silently disappears

**File:** `test_harness/mock_server.cpp:437`
**Issue:** POSIX permits `usleep()` to fail with `EINVAL` for arguments >= 1,000,000 µs. `--delay-ms 1000` or more can therefore return immediately on some platforms, silently defeating the deterministic reordering the flag exists to produce. Current tests pass 80 ms, so this is latent.
**Fix:** Replace with `nanosleep` (or loop `usleep` in < 1 s slices):
```cpp
timespec ts{ delayMs / 1000, (delayMs % 1000) * 1000000L };
nanosleep(&ts, nullptr);
```

### IN-09: `std::atoi` silently maps garbage/negative flag values to a disabled flag

**File:** `test_harness/mock_server.cpp:497, 503, 512, 518`
**Issue:** `--delay-ms abc`, `--close-after -1`, or `--port junk` all `atoi` to 0/negative, which the runtime treats as "flag off" — the server starts happily in the wrong mode, and the test then fails (or worse, passes vacuously) far from the typo. This is inconsistent with the strict `unknown argument` handling one branch below.
**Fix:** Parse with `strtol` and reject non-numeric or out-of-range values with the same `return 2` used for unknown arguments.

### IN-10: Concurrent (unawaited) `connect()` calls both pass the WR-02 single-use guard — residual race window (new in iteration 2)

**File:** `lib/src/connection/ams_connection.dart:104-113`
**Issue:** The guard checks `_connected || _closed`, but `_connected` is only set *after* `await _transport.connect(host, port)` returns. Two overlapping calls — e.g., a caller that wraps `connect()` in `.timeout(...)` and retries while the first `Socket.connect` is still in flight — both pass the guard: the transport connects twice (over `SocketTransport` the second `_socket` assignment orphans the first fd, per IN-04), and the loser of the `_assembler = FrameAssembler()` race throws `LateInitializationError` from an async context (an unhandled async error if the original caller stopped listening after its timeout). This is the same failure signature WR-02 fixed, surviving only in a much narrower window; the sequential and connect-after-close cases are fully closed.
**Fix:** Set an in-progress flag before the first await so the guard covers the in-flight window:
```dart
if (_connecting || _connected || _closed) {
  throw StateError('AmsConnection is single-use: already ...');
}
_connecting = true;
await _transport.connect(host, port);
```

### IN-11: `_failClose` discards the future returned by `_transport.close().whenComplete(...)` — an erroring transport `close()` would surface as an unhandled async error (new in iteration 2)

**File:** `lib/src/connection/ams_connection.dart:315-319`
**Issue:** `whenComplete` runs its callback on error too (so `done` still completes — good), but the future it *returns* re-propagates the original error, and nothing listens to it. Both current transports are non-throwing (`SocketTransport.close()` swallows flush errors; `FakeTransport.close()` cannot error), so this is latent — but the `AdsTransport` contract does not forbid an erroring `close()`, and a future implementation that throws would crash the isolate during teardown.
**Fix:** Swallow teardown errors explicitly:
```dart
_transport.close().then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
  if (!_doneCompleter.isCompleted) _doneCompleter.complete();
});
```

---

_Reviewed: 2026-07-03T21:49:36Z_
_Re-reviewed: 2026-07-03T22:08:54Z (iteration 2)_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
