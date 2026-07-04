---
phase: 06-sum-batched-commands
verified: 2026-07-04T00:00:00Z
status: passed
score: 7/7
overrides_applied: 0
---

# Phase 6: Sum (Batched) Commands — Verification Report

**Phase Goal:** Users can batch multiple reads/writes into a single ADS request and receive per-item results, with partial failures surfaced per item rather than as a whole-batch throw.
**Verified:** 2026-07-04
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Batched SUMUP_READ (0xF080), SUMUP_WRITE (0xF081), SUMUP_READWRITE (0xF082) in one request | VERIFIED | `buildSumReadPayload`, `buildSumWritePayload`, `buildSumReadWritePayload` all present in `sum_commands.dart` (376 lines); `sumRead`/`sumWrite`/`sumReadWrite` methods wired in `ads_client.dart`; 5 live integration tests exercise all three commands against the mock |
| 2 | Each batched command returns per-item results as `List<SumResult<T>>` | VERIFIED | `decodeSumReadResponse` returns `List<SumResult<Uint8List>>`; `decodeSumWriteResponse` returns `List<SumResult<void>>`; `decodeSumReadWriteResponse` returns `List<SumResult<Uint8List>>`; client method signatures confirmed at `ads_client.dart` lines 142, 170, 196 |
| 3 | A batch where one item deliberately fails surfaces that item's error while returning the other items' data — partial failure never throws for the whole batch | VERIFIED | Unit test "SUM-04: mid-batch failure leaves OTHER items at correct offsets (no throw)" passes; integration test "partial failure alignment" (kErrResultGroup injection, item k=error, items≠k correct) passes; decoder never throws on non-zero error word |

**Score:** 3/3 roadmap success criteria verified

### Plan Frontmatter Must-Have Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 4 | Three pure builders produce the byte-exact inner write-buffer + readLength for 0xF080/81/82 | VERIFIED | `buildSumReadPayload` (N×12B, readLength=N×4+Σlen), `buildSumWritePayload` (N×12B headers + data, readLength=N×4), `buildSumReadWritePayload` (N×16B headers + writeData, readLength=N×8+ΣrLen) — all present; builder round-trip unit tests pass |
| 5 | Three pure decoders reconstruct per-item results as `List<SumResult<T>>` | VERIFIED | All three decoders exist and tested with round-trip tests; 14/14 unit tests pass |
| 6 | A mid-batch failed item leaves every OTHER item's data at the correct offset (SUM-04 alignment) | VERIFIED | Unit test at line 142 of `sum_commands_test.dart`: 3-item read, item[1] errors (0x0703), item[0] and item[2] carry correct bytes at correct offsets; cursor advances 0 for failed items; integration SUM-04 test confirms on live socket |
| 7 | Decoders throw MalformedFrameException on an over-run before slicing (T-6-01) | VERIFIED | `_requireBlock` checks `len > data.length - cursor` (subtraction-safe) before every slice; three separate over-run tests cover SUMUP_READ, SUMUP_READWRITE, and truncated headers — all throw `MalformedFrameException` |

**Combined score:** 7/7 truths verified

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/src/protocol/sum_commands.dart` | SumReadRequest/SumWriteRequest/SumReadWriteRequest/SumResult + 3 builders + 3 decoders; contains `buildSumReadPayload`; min 120 lines | VERIFIED | 376 lines; all types and functions present; `buildSumReadPayload` at line 160; pure (only `dart:typed_data` + local protocol types) |
| `test/unit/protocol/sum_commands_test.dart` | Round-trip + SUM-04 alignment unit tests; contains "partial" | VERIFIED | 257 lines; 14 unit tests: 3 builder tests, 4 read-decoder tests (including SUM-04 alignment), 2 write-decoder tests, 4 readWrite-decoder tests; "partial" appears in the integration test file; SUM-04 alignment test at line 142 is explicit and load-bearing |
| `test/integration/ads_client_test.dart` | Live sum integration tests (5 scenarios) | VERIFIED | `group('sum', ...)` block with 5 live tests: read-after-write writeback (SUM-02/01), read batch (SUM-01), readWrite batch (SUM-03), partial failure alignment (SUM-04), 100-item single frame |
| `lib/src/client/ads_client.dart` | `sumRead`, `sumWrite`, `sumReadWrite` methods | VERIFIED | All three methods present at lines 142, 170, 196 returning `Future<List<SumResult<T>>>` |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `buildSumReadPayload` | `decodeSumReadResponse` | requested `length_i` drives data slicing | VERIFIED | Decoder at line 285 reads `items[i].length` (the original request object) to advance cursor; builder encodes that same length into the wire buffer |
| `decodeSumReadWriteResponse` | returned len header | slice by RETURNED length via `getUint32` | VERIFIED | Lines 324-325: `lens[i] = bd.getUint32(i * 8 + 4, Endian.little)` reads the server-returned length; line 331 slices by `lens[i]`, never by the requested `readLength` |

---

## Data-Flow Trace (Level 4)

Not applicable — `sum_commands.dart` is a pure protocol layer (no async, no UI, no state). Client methods wire it to the network via `buildReadWritePayload`. The integration tests confirm real data flows from the C++ mock through the decoders to the caller.

---

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Unit test suite — 14 tests including SUM-04 alignment | `dart test test/unit/protocol/sum_commands_test.dart` | `+14: All tests passed!` | PASS |
| Full test suite — 246 tests | `dart test -x slow` | `+246: All tests passed!` | PASS |
| Analyzer — no issues | `dart analyze --fatal-infos lib/src/protocol/sum_commands.dart` | `No issues found!` | PASS |

---

## Requirements Coverage

| Requirement | Description | Status | Evidence |
|-------------|-------------|--------|----------|
| SUM-01 | User can issue a batched SUMUP_READ (0xF080) returning per-item results as `List<Result<T>>` | SATISFIED | `buildSumReadPayload` + `decodeSumReadResponse` + `AdsClient.sumRead` + 2 unit round-trip tests + 2 integration tests |
| SUM-02 | User can issue a batched SUMUP_WRITE (0xF081) returning per-item results | SATISFIED | `buildSumWritePayload` + `decodeSumWriteResponse` + `AdsClient.sumWrite` + 2 unit tests + integration write-back test |
| SUM-03 | User can issue a batched SUMUP_READWRITE (0xF082) returning per-item results | SATISFIED | `buildSumReadWritePayload` + `decodeSumReadWriteResponse` + `AdsClient.sumReadWrite` + 4 unit tests + integration readWrite batch test |
| SUM-04 | Library parses the per-item error array so partial failures are surfaced per item, never as a whole-batch throw | SATISFIED | `SumResult.errorCode` carries non-zero without throwing; cursor-advance-0-on-failure convention enforced in `decodeSumReadResponse`; SUM-04 alignment unit test + integration partial-failure test both pass |

---

## Anti-Patterns Found

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| `sum_commands.dart` | None found — 0 TBD/FIXME/XXX markers | — | — |
| `sum_commands_test.dart` | None found | — | — |

The Phase 9 audit flag in `sum_commands.dart` doc-comment (frozen 0-byte-on-failure convention; no C++ AdsLibTest sum cross-validation) is explicitly documented and accepted per the context notes. It is tracked in REQUIREMENTS.md (TEST-05, Phase 9). Not a blocker.

---

## Human Verification Required

None. All required behaviors are verifiable programmatically. The CI-on-GitHub item is a Phase 1 human-UAT carry-forward (documented in `01-HUMAN-UAT.md`) and is out of scope for this phase.

---

## Gaps Summary

No gaps. All roadmap success criteria, plan must-have truths, required artifacts, key links, and requirements (SUM-01 through SUM-04) are fully verified. The test suite is 246/246 green and the analyzer reports no issues.

---

_Verified: 2026-07-04_
_Verifier: Claude (gsd-verifier)_
