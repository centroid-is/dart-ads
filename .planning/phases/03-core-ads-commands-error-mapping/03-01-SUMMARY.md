---
phase: 03-core-ads-commands-error-mapping
plan: 01
subsystem: testing
tags: [cpp, mock-server, ads, ams-tcp, cmake, error-injection]

# Dependency graph
requires:
  - phase: 01-framing-and-mock-harness
    provides: "mock_server.cpp, wrapResponse/sendResponse helpers, AoEHeader/AmsTcpHeader framing structs, --selftest golden gate"
  - phase: 02-tcp-transport
    provides: "live accept loop + LISTENING readiness handshake the new command handlers answer over"
provides:
  - "Mock ADS server answers all six core commands (ReadDeviceInfo, Read, Write, ReadWrite, ReadState, WriteControl)"
  - "Connection-scoped (indexGroup,indexOffset) data store with write-back persisting within a session"
  - "Stateful WriteControl -> ReadState (a WriteControl(state) is observable via a later ReadState)"
  - "Two magic-index-group error fixtures: payload-result level (0xE7700000) and AMS-header-errorCode level (0xE7700001)"
  - "wrapResponse amsError param for injecting AMS-header errorCodes"
affects: [03-04-ads-client, 03-05-integration-tests, 03-06-parity-tests, 09-parity-audit]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Magic-index-group error injection: request indexOffset becomes the emitted ADS error code (offset->code trick), one fixture covers every code"
    - "Bounds-checked little-endian request-payload readers (getU16/getU32) mirroring putU16/putU32"
    - "Connection-scoped mock state for per-test isolation (declared inside the accept-loop body)"

key-files:
  created: []
  modified:
    - "test_harness/mock_server.cpp"

key-decisions:
  - "Magic sentinel groups 0xE7700000 (payload result) / 0xE7700001 (AMS errorCode) — synthetic high range, collision-free with real ADS groups"
  - "Store is connection-scoped, not process-global, so write-back never leaks across integration tests"
  - "Read/ReadWrite requested length capped at kMaxFrameBytes to prevent a hostile length triggering a multi-GB allocation"

patterns-established:
  - "Response dispatch sets res/haveRes then a single shared send path applies --delay-ms/--fragment/--coalesce, keeping ReadDeviceInfo byte-identical"
  - "wrapResponse patches optional AMS errorCode additively, same technique as the stateFlags patch, so the default path stays golden-identical"

requirements-completed: [CMD-01, CMD-02, CMD-03, CMD-04, CMD-05, ERR-01]

# Metrics
duration: 12min
completed: 2026-07-04
---

# Phase 3 Plan 01: Mock Core-Command & Error-Fixture Extension Summary

**C++ mock ADS server now answers all six core commands with connection-scoped write-back, stateful WriteControl/ReadState, and two magic-index-group fixtures that inject real ADS errors at both the payload-result and AMS-header-errorCode levels — with `--selftest` still byte-identical to the committed golden.**

## Performance

- **Duration:** ~12 min
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 1 (`test_harness/mock_server.cpp`)

## Accomplishments
- Read/Write/ReadWrite operate on a per-connection `std::map<(group,offset), bytes>` store; a Read after a Write to the same key returns the written bytes.
- ReadState reflects `curAdsState`/`curDeviceState`; WriteControl mutates them, so `WriteControl(STOP)` is observable via a later ReadState.
- Two magic sentinel index groups inject genuine error frames end-to-end: `0xE7700000` sets the ADS payload `result` to the request offset, `0xE7700001` sets the AMS-header `errorCode` (wire offset 24) to the request offset.
- Bounds-checked little-endian payload readers guard every field read against `tcp.length()` (threat T-3-03 / ASVS V5), so a short or hostile frame can never overread `inbuf`.
- ReadDeviceInfo and the `--selftest` golden gate remain byte-identical (all new logic is additive; the single shared `wrapResponse` change is a defaulted param).

## Task Commits

Each task was committed atomically:

1. **Task 1: Data store + stateful ReadState/WriteControl + ReadWrite** - `450cc24` (feat)
2. **Task 2: Two magic-index-group error fixtures via wrapResponse amsError param** - `48cfc1e` (feat)

## Files Created/Modified
- `test_harness/mock_server.cpp` - Added `<map>`/`<utility>` includes, bounds-checked `getU16`/`getU32` readers, connection-scoped store + `curAdsState`/`curDeviceState` (seeded with the read_req golden key), READ/WRITE/READ_WRITE/READ_STATE/WRITE_CONTROL switch cases, `wrapResponse` `amsError` param, `kAmsErrorCodeOffset`/`kErrResultGroup`/`kErrAmsGroup` constants, and the magic-group interception ahead of command dispatch.

## Decisions Made
- Chose `0xE7700000`/`0xE7700001` as the two sentinel groups (assumption A2 in RESEARCH; synthetic high range, no collision with real ADS groups).
- Kept the store connection-scoped so each `startMockServer()` in an integration test begins clean (RESEARCH Pitfall 3 / threat T-3-01).
- Response dispatch was refactored to a `res`/`haveRes` accumulator with a single shared send path — deduplicates the `--delay-ms`/`--fragment`/`--coalesce` handling and keeps ReadDeviceInfo behavior identical.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Capped Read/ReadWrite requested length at kMaxFrameBytes**
- **Found during:** Task 1 (Read / ReadWrite cases)
- **Issue:** The response echoes a client-supplied read `length`; an unbounded value (e.g. `0xFFFFFFFF`) would `std::vector<uint8_t> data(length, 0)` and attempt a multi-GB allocation — a DoS not explicitly covered by the inbound `kMaxFrameBytes` frame guard (which bounds received bytes, not the requested read length).
- **Fix:** Reject (`break`, no response) when the requested read length exceeds `kMaxFrameBytes`, consistent with the existing frame cap. WRITE/READ_WRITE write-data lengths are already implicitly bounded because the bytes must be physically present in the (already-capped) frame.
- **Files modified:** `test_harness/mock_server.cpp`
- **Verification:** Build clean (no warnings), `--selftest` OK, smoke test exercised all commands.
- **Committed in:** `450cc24` (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 missing-critical / DoS hardening)
**Impact on plan:** Extends the plan's own V5 input-validation intent to the read-length field; no scope creep.

## Issues Encountered
- None during planned work. (An initial local smoke test appeared to show write-back failing, but that was the test harness opening a fresh connection per request — expected, since the store is intentionally connection-scoped. Re-running write+read on a single connection confirmed write-back works; the server behaved correctly.)

## Verification
- `cmake -S test_harness -B test_harness/build && cmake --build test_harness/build` — succeeds, no warnings.
- `test_harness/build/mock_server --selftest` — prints `OK`, exit 0 (ReadDeviceInfo byte-identical to golden).
- Socket smoke test (single connection): ReadState=RUN(5), write-back round-trip (DEADBEEF), ReadWrite round-trip ("MAIN"), WriteControl(STOP)→ReadState=STOP(6), payload-result error 0x703, AMS-errorCode error 0x0007, and seeded-key read all pass.

## Next Phase Readiness
- The mock is ready for the Dart `AdsClient` (03-04) and the integration/parity suites (03-05, 03-06): live write-back, stateful state, and both error levels are all injectable over a real socket.
- Note: the CMD-*/ERR-01 requirements are only *enabled* on the mock side by this plan; the Dart client veneer, error table, and typed exceptions that fully satisfy them land in later Phase 3 plans.

## Self-Check: PASSED
- FOUND: test_harness/mock_server.cpp
- FOUND: .planning/phases/03-core-ads-commands-error-mapping/03-01-SUMMARY.md
- FOUND commit 450cc24 (Task 1)
- FOUND commit 48cfc1e (Task 2)

---
*Phase: 03-core-ads-commands-error-mapping*
*Completed: 2026-07-04*
