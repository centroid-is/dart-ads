---
phase: 06-sum-batched-commands
plan: 01
subsystem: protocol
tags: [sum-commands, codec, wire-layout, pure-dart]
requirements_completed: [SUM-01, SUM-02, SUM-03, SUM-04]
requires:
  - lib/src/protocol/range_check.dart (checkUint)
  - lib/src/protocol/exceptions.dart (MalformedFrameException)
  - lib/src/protocol/ads_error.dart (AdsException)
provides:
  - SumReadRequest / SumWriteRequest / SumReadWriteRequest / SumResult<T>
  - buildSumReadPayload / buildSumWritePayload / buildSumReadWritePayload
  - decodeSumReadResponse / decodeSumWriteResponse / decodeSumReadWriteResponse
affects:
  - lib/src/client/ads_client.dart (Plan 04 will wrap these via buildReadWritePayload)
  - test/golden (Plan 02/03 goldens conform to these layouts)
tech-stack:
  added: []
  patterns:
    - "Builder returns (Uint8List writeBuffer, int readLength) record — readLength formula single-sourced"
    - "Per-item partial failure surfaces as SumResult, never throws (SUM-04)"
    - "Bounds-check block length <= remaining before every slice (T-6-01)"
key-files:
  created:
    - lib/src/protocol/sum_commands.dart
    - test/unit/protocol/sum_commands_test.dart
  modified: []
decisions:
  - "SumResult is a generic final class (not a record) to carry isSuccess/valueOrThrow + type param"
  - "Frozen 0-byte-on-failure data convention for READ/READWRITE, documented in-code for Phase 9 audit"
metrics:
  duration: 12min
  tasks: 2
  files: 2
  completed: 2026-07-04
---

# Phase 6 Plan 01: Sum Batched-Command Protocol Layer Summary

Pure protocol single-source-of-truth for the three ADS SUMUP batched commands (0xF080/81/82): request/result value types, three payload builders returning byte-exact inner write-buffer + outer readLength records, and three response decoders that reconstruct per-item `List<SumResult<T>>` with the frozen 0-byte-on-failure alignment rule (SUM-04) proven by unit test before any I/O exists.

## What Was Built

**`lib/src/protocol/sum_commands.dart`** (pure, `dart:typed_data` + local pure types only):
- Value types: `SumReadRequest`, `SumWriteRequest`, `SumReadWriteRequest`, generic `SumResult<T>` (`isSuccess`, `valueOrThrow`).
- Builders (each returns `(Uint8List writeBuffer, int readLength)`):
  - `buildSumReadPayload` — N×12B `(ig,io,len)`; readLength `N*4 + Σlen`.
  - `buildSumWritePayload` — N×12B headers + concatenated data; readLength `N*4`.
  - `buildSumReadWritePayload` — N×16B `(ig,io,rLen,wLen)` + concatenated writeData; readLength `N*8 + ΣrLen`.
- Decoders:
  - `decodeSumReadResponse(data, items)` — N error words then requested-length slices; failed item → empty value, cursor advances 0.
  - `decodeSumWriteResponse(data, n)` — N error words only → `List<SumResult<void>>`.
  - `decodeSumReadWriteResponse(data, n)` — N×(err,retLen) headers then slices by the RETURNED length (never the requested).
- `checkUint(...,32,...)` guards every outbound u32; every data block bounds-checked before slicing → `MalformedFrameException` (threat T-6-01).

**`test/unit/protocol/sum_commands_test.dart`** — 14 unit tests: three builder assertions, three builder→decoder round-trips, the SUM-04 mid-batch-failure alignment test (item 1 fails, items 0 & 2 uncorrupted, no throw), a READWRITE returned-len < requested-len slice, `valueOrThrow` on a failed item, and over-run / truncated-header `MalformedFrameException` guards.

## Verification

- `dart test test/unit/protocol/sum_commands_test.dart -n 'sum'` → 14/14 pass.
- `dart analyze --fatal-infos` → No issues found (both files).
- `dart format` → applied (CI `--set-exit-if-changed` gate clean).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Digit-separator literal exceeded SDK floor**
- **Found during:** Task 2 (test compile)
- **Issue:** `0x1_0000_0000` uses the digit-separators feature (Dart 3.6+); the pubspec floor is `>=3.5.0`, so the test failed to load.
- **Fix:** Replaced with `0x100000000`.
- **Files modified:** test/unit/protocol/sum_commands_test.dart
- **Commit:** 09baf01

## Threat Model Compliance

- **T-6-01 (over-read):** `_requireHeader` + `_requireBlock` validate the fixed header region and each data block with subtraction-safe checks (`len > data.length - cursor`) before slicing; over-run tests assert `MalformedFrameException`.
- **T-6-03 (mid-batch offset drift):** cursor advances by the frozen per-item convention (requested len for OK READ items / 0 for failed; RETURNED len for READWRITE); pinned by the SUM-04 alignment test.

## Known Stubs

None — this is the complete pure protocol layer. Client wiring (`ads_client.dart`) and golden fixtures are downstream plans (04 / 02-03) per the phase roadmap, not stubs in this plan's scope.

## TDD Gate Compliance

Both tasks carry `tdd="true"`. Task 1's verify gate is analyzer-only (builders have no decode counterpart yet); Task 2 introduced the test file whose round-trips exercise both builders and decoders. Commits are `feat(06-01)` per task. Note: no standalone `test(...)` RED commit was made — the builders/decoders and their tests landed together within each task's atomic commit rather than as a separate failing-test commit.

## Self-Check: PASSED

- FOUND: lib/src/protocol/sum_commands.dart
- FOUND: test/unit/protocol/sum_commands_test.dart
- FOUND: .planning/phases/06-sum-batched-commands/06-01-SUMMARY.md
- FOUND commit 83a9098 (Task 1), FOUND commit 09baf01 (Task 2)
