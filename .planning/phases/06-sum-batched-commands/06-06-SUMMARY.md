---
phase: 06-sum-batched-commands
plan: 06
subsystem: testing
tags: [integration, sum-commands, sumup, live-mock, SUM-04]
requires: ["06-02", "06-04"]
provides: ["live-sum-integration-proof"]
affects: ["test/integration/ads_client_test.dart"]
tech-stack:
  added: []
  patterns:
    - "per-test mock + connection (connection-scoped store isolation)"
    - "kErrResultGroup magic per-item error injection on the live path"
key-files:
  created: []
  modified:
    - "test/integration/ads_client_test.dart"
decisions:
  - "Seed surrounding keys via sumWrite in the SUM-04 test so alignment is proven against real distinct data, not zero-fill store misses"
metrics:
  duration: 4min
  completed: 2026-07-04
---

# Phase 6 Plan 6: Live Sum Integration Tests Summary

Live end-to-end proof that `sumRead`/`sumWrite`/`sumReadWrite` round-trip against the rebuilt C++ mock over a real socket, that read-after-sumWrite write-back lands per item, that a mid-batch failure surfaces item k's error while items != k stay aligned (SUM-04), and that a 100-item batch travels in one frame.

## What Was Built

Added a `group('sum', ...)` block to `test/integration/ads_client_test.dart` with five live tests, each starting its own mock + connection (connection-scoped store isolation, research Pitfall 3) under the 10s `requestTimeout`:

1. **read-after-write write-back** (SUM-02/01) — `sumWrite` 4 distinct keys, then `sumRead` the SAME keys; each item's data equals what was written, proving per-item write-back through the mock store.
2. **read batch** (SUM-01) — 3 keys seeded via single `write`, then a pure `sumRead` returns per-item success + correct bytes.
3. **read_write batch** (SUM-03) — `sumReadWrite` of 3 items; one requests fewer bytes back than it writes, proving the decoder slices by the RETURNED per-item length, not the requested one.
4. **partial failure alignment** (SUM-04, threat T-6-03) — item k targets `kErrResultGroup` (inner offset = 0x703); item k surfaces as `SumResult(isSuccess: false, errorCode: 0x703)` with no data while items != k carry correct seeded data at correct offsets, and the batch never throws.
5. **large 100-item single frame** (threat T-6-02) — a 100-item `sumRead` (keys pre-seeded via a 100-item `sumWrite`) returns exactly 100 correct results from one ReadWrite frame.

## Verification

- `dart test test/integration/ads_client_test.dart -n 'sum'` — 5/5 green.
- `dart test test/integration/ads_client_test.dart -n 'sum.*(partial|large)'` — 2/2 green (Task 2 gate).
- `dart analyze --fatal-infos` — no issues.
- Full suite `dart test -x slow` — 246/246 green.

## Deviations from Plan

None — plan executed exactly as written.

## Must-Haves Coverage

- Live sumRead/sumWrite/sumReadWrite round-trip over a real socket — tests 1-3.
- Read-after-sumWrite proves per-item write-back landed in the mock store — test 1.
- Mid-batch failure surfaces item k's error while items != k carry correct data, no batch throw — test 4.
- 100-item batch in a single frame — test 5.

## Threat Flags

None — no new security surface introduced (tests only; live boundary already modeled T-6-02/T-6-03).

## Self-Check: PASSED

- FOUND: test/integration/ads_client_test.dart (modified, `group('sum'` present)
- FOUND commit acfb572 (Task 1)
- FOUND commit e6454a4 (Task 2)
</content>
</invoke>
