---
phase: 02-tcp-transport-connection-lifecycle-invoke-id-correlation
plan: 02
subsystem: integration-test-harness
tags: [mock-server, cpp, dart-io, process, integration, test-support]
requires:
  - "test_harness/mock_server.cpp (Phase 1 accept loop + framing)"
  - "test_harness/CMakeLists.txt (Phase 1 CMake harness)"
provides:
  - "mock --delay-ms N (first-response deferral → response reordering)"
  - "mock --close-after N (Nth-request drop → disconnect fan-out)"
  - "startMockServer launch helper + MockServer(proc, port) handle"
affects:
  - "Plan 02-04 live integration tests (reorder + mid-request disconnect)"
  - "all later-phase integration tests reusing startMockServer"
tech-stack:
  added: []
  patterns:
    - "Connection-scoped, thread-free mock behaviours (deferred first response, request counter)"
    - "Ephemeral-port + LISTENING stdout handshake, parsed with a bounded timeout"
    - "Staleness-driven CMake rebuild in the Dart launch helper"
key-files:
  created:
    - "test/support/mock_server.dart"
  modified:
    - "test_harness/mock_server.cpp"
decisions:
  - "--delay-ms defers response #1 and flushes it LAST (not an inline sleep) so two pipelined requests provably invert order"
  - "--close-after closes on the Nth complete request WITHOUT answering it, leaving a pending request to fan out"
  - "New modes kept orthogonal to --fragment/--coalesce; --selftest path untouched"
requirements-completed: [TEST-03]
metrics:
  duration: ~12min
  tasks: 2
  files: 2
  completed: 2026-07-03
---

# Phase 2 Plan 02: Integration-Test Harness Infrastructure Summary

Extended the C++ mock ADS server with two deterministic, thread-free modes — `--delay-ms N` (first-response deferral proving invoke-ID correlation under response reordering) and `--close-after N` (Nth-request drop proving disconnect failure fan-out) — and added the reusable `test/support/mock_server.dart` launcher (staleness rebuild, ephemeral-port `LISTENING` handshake, bounded readiness timeout, clean teardown) that every integration test in this and later phases depends on (TEST-03).

## What Was Built

### Task 1 — C++ mock modes (`test_harness/mock_server.cpp`, commit 594d506)
- `main()` argv parser now accepts `--delay-ms N` and `--close-after N`, each consuming an integer with a stderr error + exit 2 on a missing value, mirroring `--port`/`--fragment` style. Both ints are threaded into a widened `runServer(fixedPort, mode, fragmentN, delayMs, closeAfter)` (single call site updated).
- **`--delay-ms N`:** connection-scoped `deferred` / `haveDeferred` / `respCount` state declared outside the recv loop. Response #1 is stashed instead of sent; responses #2..N go immediately; once a later response has been sent, the deferred #1 is flushed LAST after `usleep(delayMs*1000)`. If only one request ever arrives, the still-deferred response is flushed at connection close so it is never lost. This inverts the order of two pipelined requests deterministically, without threads (RESEARCH Pitfall 4).
- **`--close-after N`:** connection-scoped `reqCount` increments on each COMPLETE inbound frame; on the Nth it `close(fd)`s and breaks out without answering, guaranteeing at least one pending client request must fan out. A `closedByCloseAfter` flag skips the teardown send/close so the socket is not double-closed; the outer accept loop keeps serving.
- Orthogonal to `--fragment`/`--coalesce` (timing/lifecycle vs segmentation); `--selftest` returns from `main()` before `runServer`, so neither new flag is parsed there. SIGPIPE handling and the `LISTENING <port>` readiness line are preserved.
- Verified: `cmake --build` clean; `--selftest` → `OK` exit 0 (golden byte-accuracy gate intact); both modes bind and emit `LISTENING`; missing-value error path returns exit 2.

### Task 2 — Dart launch helper (`test/support/mock_server.dart`, commit 5db9f8c)
- `Future<MockServer> startMockServer({List<String> args})` and `class MockServer { final Process proc; final int port; Future<void> stop(); }`.
- `_ensureBuilt()` staleness check: rebuilds via `cmake -S test_harness -B test_harness/build` then `cmake --build test_harness/build` when the binary is missing or older than `mock_server.cpp`/`CMakeLists.txt` (`lastModifiedSync`); throws a clear `StateError` naming the missing toolchain (translated from `ProcessException`) or surfacing build output on failure. No-op on CI where the binary is pre-built.
- `Process.start(bin, args)` with NO `--port` (ephemeral `:0`); stderr piped into a `StringBuffer` for failure diagnostics; port parsed via `proc.stdout.transform(utf8.decoder).transform(LineSplitter()).firstWhere(startsWith('LISTENING '))`, wrapped in a 10 s `.timeout` that kills the child and throws with captured stderr — never an unbounded hang.
- `stop()` documents/implements the `tearDownAll` teardown contract (`kill(SIGTERM)` + `await exitCode`) to guard against orphan processes.
- Verified: `dart analyze --fatal-infos` clean; `dart format` unchanged; end-to-end smoke test launched the mock, parsed the ephemeral port, connected a socket, and tore down cleanly (SIGTERM exit).

## Deviations from Plan

None — plan executed exactly as written. No auto-fixes (Rules 1-3) were required and no architectural decisions (Rule 4) arose.

## Threat Model Notes

Both mitigations from the plan's threat register were preserved/implemented:
- **T-2-06 (DoS, mock send to closed peer):** the new `--close-after` path only `close(fd)`s and continues the accept loop; existing `signal(SIGPIPE, SIG_IGN)` + `sendAll()` EPIPE handling unchanged.
- **T-2-07 (DoS, launcher waiting on LISTENING):** the `.timeout(10s)` on the stdout `firstWhere` kills the child and throws with captured stderr, so a mock that never binds fails fast.
- **T-2-SC (Tampering, package installs):** no new packages — the helper uses only Dart SDK libraries (`dart:io`, `dart:async`, `dart:convert`); the C++ mock links only the already-pinned Beckhoff/ADS submodule.

## Known Stubs

None. Both artifacts are complete, functional, and independently exercised.

## Self-Check: PASSED

- FOUND: test_harness/mock_server.cpp (modified)
- FOUND: test/support/mock_server.dart (created)
- FOUND commit 594d506 (feat 02-02 mock modes)
- FOUND commit 5db9f8c (feat 02-02 launch helper)
