---
phase: 03-core-ads-commands-error-mapping
plan: 05
subsystem: integration-tests
tags: [integration, ads-client, error-mapping, mock-server]
requirements_completed: [CMD-01, CMD-02, CMD-03, CMD-04, CMD-05, CMD-06, ERR-01]
requires:
  - "03-01: extended C++ mock (keyed store, stateful ReadState/WriteControl, magic error groups)"
  - "03-04: AdsClient + both-levels AdsException mapping + AmsConnection errorCode seam"
provides:
  - "live end-to-end coverage: one integration test per core command + both ADS error levels over a real loopback socket"
affects:
  - "test/integration/ads_client_test.dart"
tech_stack:
  added: []
  patterns:
    - "one mock + one connection per test (connection-scoped store/state → order-independent isolation)"
    - "long per-request timeout so a failure is provably an error result, never a timeout"
    - "@Tags(['integration']) with distinct single-substring test names for -N filtering"
key_files:
  created:
    - "test/integration/ads_client_test.dart"
  modified: []
decisions:
  - "read/write-back and write_control state tests share one connection per test since the mock's store and ADS-state are connection-scoped"
  - "ams_error test asserts NOT AdsTimeout/AdsConnection to prove the AdsException family is distinct from the transport family, live"
metrics:
  duration: 4min
  completed: 2026-07-04
  tasks: 2
  files: 1
---

# Phase 3 Plan 5: Live Per-Command + Both-Levels Error Integration Tests Summary

Proves every core `AdsClient` command and both ADS error levels round-trip end-to-end against the extended C++ mock over a live loopback socket — 8 integration tests, all green.

## What Was Built

`test/integration/ads_client_test.dart` (`@Tags(['integration'])`), eight named tests, each starting its own mock + connection and tearing both down:

**Per-command success (Task 1):**
- `read` — reads the seeded `(0xF005,0x123)` fixture and asserts the exact bytes (CMD-01).
- `write` — writes then reads back the same key on one connection, proving write-back (CMD-02/01).
- `read_write` — one-round-trip write-then-read returns the just-written bytes (CMD-03).
- `read_state` — a fresh connection reads `AdsState.run` / deviceState 0 (CMD-04).
- `write_control` — `writeControl(STOP)` then `readState()` observably returns STOP (CMD-05, stateful).
- `device_info` — returns the exact mock identity triple: `Dart ADS Mock`, v3.1, build 4024 (CMD-06).

**Live both-levels error cases (Task 2):**
- `result_error` — read at `(kErrResultGroup 0xE7700000, 0x703)` throws `AdsException` with `code == 0x703` and `name == 'ADSERR_DEVICE_INVALIDOFFSET'` (payload-result level).
- `ams_error` — read at `(kErrAmsGroup 0xE7700001, 0x007)` throws `AdsException` with `code == 0x0007` (GLOBALERR_MISSING_ROUTE), surfaced from the AMS header before payload decode, and asserted distinct from `AdsTimeoutException` / `AdsConnectionException` (AMS-errorCode level).

## How It Works

Each test uses a `connectClient()` helper that spawns a fresh mock via `startMockServer()`, opens an `AmsConnection` over `SocketTransport()` to `127.0.0.1:<port>`, and wraps it in an `AdsClient`. Both the server and connection are registered with `addTearDown`, so no orphan process or open socket survives a test. Because the mock's keyed store and ADS-state are connection-scoped, a fresh connection per test keeps write-back and state assertions order-independent (research Pitfall 3). Every request carries a 10s timeout so a failing assertion is provably a command/error result, never a timeout firing (threat T-3-07). Exercising both magic groups ensures an error-injection test cannot pass via the payload path alone (threat T-3-02 / research Pitfall 1).

## Deviations from Plan

None - plan executed exactly as written. (The Dart formatter reflowed a few `.having(...)` chains and one `expect(..., reason:)` call to its canonical layout; no behavioral change.)

## Verification

- `dart test test/integration/ads_client_test.dart -t integration` → `+8 All tests passed!`
- `dart analyze test/integration/ads_client_test.dart` → No issues found.
- `dart format --set-exit-if-changed` → clean.

## Self-Check: PASSED

- FOUND: test/integration/ads_client_test.dart
- FOUND commit e0e3275 (Task 1: per-command success tests)
- FOUND commit f4ed4d9 (Task 2: live both-levels error cases)
