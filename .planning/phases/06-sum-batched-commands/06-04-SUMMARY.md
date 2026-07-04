---
phase: 06-sum-batched-commands
plan: 04
subsystem: api
tags: [ads, sumup, batched-commands, readwrite, dart, fake-transport]

# Dependency graph
requires:
  - phase: 06-01
    provides: buildSum*Payload builders, decodeSum*Response decoders, SumReadRequest/SumWriteRequest/SumReadWriteRequest/SumResult value types
  - phase: 03
    provides: AdsClient, buildReadWritePayload, decodeReadWriteResponse, the two-layer _command/_throwOnResult throw sites
provides:
  - AdsClient.sumRead / sumWrite / sumReadWrite public methods (SUM-01/02/03)
  - Two-layer throw enforcement at the client boundary (outer throws, per-item never does — SUM-04)
  - Public barrel exports for the four sum types
  - FakeTransport unit tests proving partial-failure no-throw, empty-batch short-circuit, and outer-error throw
affects: [symbol-access, cli]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sum method = empty-batch guard → buildSum*Payload → buildReadWritePayload envelope (indexOffset=N) → _command (outer AMS throw) → decodeReadWriteResponse + _throwOnResult (outer ADS-result throw) → decodeSum*Response (per-item, no throw)"

key-files:
  created:
    - test/unit/client/sum_client_test.dart
  modified:
    - lib/src/client/ads_client.dart
    - lib/dart_ads.dart
    - test/unit/public_api_test.dart

key-decisions:
  - "Sum builders/decoders stay package-private; only the four value types (requests + SumResult) are exported, mirroring how notification builders/decoders are kept off the public surface"
  - "Empty-batch guard returns [] with no wire call — a zero-item ReadWrite envelope is meaningless"

patterns-established:
  - "Two-layer throw at the client: outer AMS errorCode and outer ADS result throw AdsException before any list is returned; per-item error words surface via SumResult.errorCode and never throw the batch (SUM-04)"

requirements-completed: [SUM-01, SUM-02, SUM-03, SUM-04]

# Metrics
duration: 8min
completed: 2026-07-04
---

# Phase 6 Plan 04: AdsClient Sum Methods + Public Exports Summary

**Three AdsClient sum methods (sumRead/sumWrite/sumReadWrite) wiring the Plan-01 builders/decoders through the ReadWrite envelope with two-layer throw semantics — outer errors throw, per-item failures surface via SumResult (SUM-04) — plus public barrel exports and FakeTransport unit tests.**

## Performance

- **Duration:** ~8 min
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 4 (1 created, 3 modified)

## Accomplishments
- `AdsClient.sumRead`, `sumWrite`, `sumReadWrite` — each issues ONE ReadWrite to its SUMUP index group (0xF080/0xF081/0xF082) with `indexOffset == N`, returning `List<SumResult<T>>` in request order.
- Two-layer error model enforced at the client boundary: a non-zero AMS `errorCode` or outer ADS `result` throws `AdsException` before any list is returned; a per-item error word never throws (SUM-04).
- Empty-batch guard returns `[]` immediately with zero bytes on the wire.
- `SumReadRequest`, `SumWriteRequest`, `SumReadWriteRequest`, `SumResult` exported from the public barrel (builders/decoders stay package-private).
- 9 FakeTransport unit tests + 1 public-barrel reachability test proving clean batches, mid-batch partial-failure no-throw with correct offset alignment, outer-result throw, and empty-batch short-circuit across all three methods.

## Task Commits

Each task was committed atomically:

1. **Task 1: Three AdsClient sum methods** - `3e28a75` (feat)
2. **Task 2: Barrel exports + FakeTransport unit tests** - `57273d7` (test)

_Note: Plan tasks are TDD-flagged; here Task 1 delivered the implementation (analyzer-gated) and Task 2 delivered the exports and the proving unit tests that exercise it._

## Files Created/Modified
- `lib/src/client/ads_client.dart` - Added the three sum methods (import of sum_commands.dart, empty-batch guards, ReadWrite envelope wrapping, two-layer throw, per-item decode).
- `lib/dart_ads.dart` - New `export 'src/protocol/sum_commands.dart' show SumReadRequest, SumWriteRequest, SumReadWriteRequest, SumResult;` clause.
- `test/unit/client/sum_client_test.dart` - Created: FakeTransport-driven unit tests for all three methods (two-layer semantics, partial-failure no-throw, empty-batch short-circuit).
- `test/unit/public_api_test.dart` - Added a public-barrel reachability test for the four sum types.

## Decisions Made
- Kept the `buildSum*Payload` / `decodeSum*Response` helpers package-private and exported only the four value types, matching the existing notification-surface convention (T-1-EXP) so internal wire helpers do not leak into the pub.dev contract.
- Empty batch short-circuits before any builder call, guaranteeing no meaningless zero-item ReadWrite frame reaches the wire.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Added a sum-types reachability test to public_api_test.dart**
- **Found during:** Task 2 (barrel exports + unit tests)
- **Issue:** The Task-2 verify command runs `test/unit/public_api_test.dart -n 'sum'`, but that file had no sum-named test, so the public-surface behavior ("import exposes the four sum types") the plan's Task-2 behavior block calls for was unproven.
- **Fix:** Added a `sum (batched) command types are reachable through the barrel` test constructing all three request types and both `SumResult` states purely through the public import.
- **Files modified:** test/unit/public_api_test.dart
- **Verification:** `dart test ... -n 'sum'` runs and passes the new test; `dart analyze --fatal-infos` clean.
- **Committed in:** `57273d7` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical test coverage)
**Impact on plan:** The added test makes the plan's own verify command meaningful and asserts the public surface behavior. No production-code scope creep.

## Issues Encountered
- `dart format` reflowed one long test declaration in `sum_client_test.dart`; re-ran the suite after formatting to confirm all 10 tests still pass.

## TDD Gate Compliance
Both plan tasks carry `tdd="true"`. The plan decomposes the feature so that Task 1 supplies the implementation (gated by `dart analyze`, its only specified verify) and Task 2 supplies the proving FakeTransport unit tests. The final `test(...)` commit (`57273d7`) lands the full behavioral proof for both tasks; the RED/GREEN separation is folded into the plan's own task ordering rather than into separate per-task test/feat commits. All 10 sum tests are green and the analyzer is clean.

## Verification
- `dart test test/unit/client/sum_client_test.dart test/unit/public_api_test.dart -n 'sum'` → 10 passing.
- `dart analyze --fatal-infos` → No issues found.

## Next Phase Readiness
- The three sum methods and their public types are on the surface, ready for the CLI phase and any symbol-access batching.
- The 0-byte-on-failure convention (Plan 01) remains FLAGGED for the Phase 9 C++ parity audit — no AdsLibTest sum scenario cross-validates it yet.

## Self-Check: PASSED

All created/modified files present on disk; both task commits (`3e28a75`, `57273d7`) exist in git history.

---
*Phase: 06-sum-batched-commands*
*Completed: 2026-07-04*
