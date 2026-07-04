---
phase: 06-sum-batched-commands
plan: 05
subsystem: testing
tags: [golden-parity, sumup, ads, wire-protocol, codec-binding]

# Dependency graph
requires:
  - phase: 06-sum-batched-commands (plan 01)
    provides: buildSum*Payload / decodeSum*Response + SumResult<T>
  - phase: 06-sum-batched-commands (plan 03)
    provides: six byte-authoritative SUMUP golden fixtures (req+res)
provides:
  - Byte-for-byte SUMUP request-encode parity assertions (0xF080/81/82)
  - SUMUP response-decode parity assertions binding the Dart codec to the goldens
  - Golden-pinned mid-batch READ failure alignment (SUM-04)
  - Golden-pinned READWRITE returned-length < requested slicing
affects: [phase-9 parity audit, sum decoder regression surface]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sum req parity: build inner write-buffer -> wrap via encodeReadWriteRequest -> assert == golden frame"
    - "Sum res parity: strip outer envelope via decodeReadWriteResponse -> feed inner region to decodeSum*Response"

key-files:
  created: []
  modified:
    - test/unit/golden_parity_test.dart

key-decisions:
  - "Response tests decode the outer result+readLength via decodeReadWriteResponse (single source of truth) rather than re-slicing 8 bytes by hand"
  - "kErrResultGroup (0xE7700000) declared locally in the test to make the mid-batch failure item self-documenting"

requirements-completed: [SUM-01, SUM-02, SUM-03, SUM-04]

# Metrics
duration: 4min
completed: 2026-07-04
---

# Phase 6 Plan 05: SUMUP Golden Parity Summary

**Byte-for-byte golden parity assertions added to `golden_parity_test.dart` binding the Dart sum builders/decoders to the six committed `sum_*.hex` fixtures — freezing the mid-batch READ failure alignment (SUM-04) and the READWRITE returned-length slicing rule.**

## What Was Built

Added a `group('sum batched-command goldens')` with six tests to `test/unit/golden_parity_test.dart`, reconstructing the exact item lists dump_golden baked into the fixtures:

- **REQUEST parity (3 tests):** each `buildSum*Payload` inner write-buffer is wrapped through `encodeReadWriteRequest` (indexGroup 0xF080/0xF081/0xF082, indexOffset = item count, readLength from the builder record) and asserted equal to `readGolden('test/golden/sum_*_req.hex')` byte-for-byte.
- **RESPONSE parity (3 tests):** each `sum_*_res.hex` is stripped by `_adsResponsePayload(..., AdsCommandId.readWrite)`, decoded through `decodeReadWriteResponse` (outer `result u32 + readLength u32`), and its `.data` inner region fed to the matching `decodeSum*Response`:
  - **READ:** item[1] fails (err `0x703`), carries empty data, and items 0/2 still decode to `11223344` / `aabbccddeeff0102` at the correct offsets — the frozen 0-data-bytes-on-failure alignment (SUM-04).
  - **WRITE:** all three per-item error codes are 0.
  - **READWRITE:** item[1] requested 8 bytes but only 2 came back — decoded to exactly 2 bytes (`aabb`) by the RETURNED length, never the requested `readLength`.

## Verification

- `dart test test/unit/golden_parity_test.dart -n 'sum'` → 6/6 pass.
- `dart test test/unit/golden_parity_test.dart` (full file) → 24/24 pass (no regression to the existing framing / notification goldens).
- `dart analyze --fatal-infos test/unit/golden_parity_test.dart` → No issues found.
- `dart format --set-exit-if-changed` → clean.

## Deviations from Plan

None — plan executed exactly as written. The one task compiled and passed on the first run; the six fixtures reproduce byte-for-byte and decode to the expected per-item results.

## Threat Model Compliance

- **T-6-03 (failed-item alignment regression):** the READ response test asserts item[1] failure + empty data AND items 0/2 exact bytes — any decoder offset drift fails the test.
- **T-6-06 (codec/golden divergence):** the three request tests assert byte-for-byte frame equality, binding the Dart encoder to the reference frames; the three response tests bind the decoders.
- **T-6-SC (package installs):** N/A — no packages installed.

## Known Stubs

None — this plan is test-only and adds no product code or placeholder data.

## Self-Check: PASSED

- FOUND: test/unit/golden_parity_test.dart (sum group present, 6 tests)
- FOUND commit e878a9f (Task 1: sum golden parity assertions)

---
*Phase: 06-sum-batched-commands*
*Completed: 2026-07-04*
