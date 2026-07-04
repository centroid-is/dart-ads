# Phase 07 — Deferred / Out-of-Scope Items

## PHASE-GATE REGRESSION (found during 07-06 execution, 2026-07-04)

**Symptom:** `dart test -x slow` fails 6 pre-existing integration tests:
- `test/integration/ads_client_test.dart`: `read`
- `test/integration/ads_parity_test.dart`: `testAdsReadReqEx2LargeBuffer 8192-byte round-trip`
- `test/integration/ads_parity_test.dart`: `testAdsWriteReqEx write then read-back loop with a flipping value`
- `test/integration/ads_parity_test.dart`: `testLargeFrames 64 KiB payload round-trips with integrity`
- ...and 2 more (all in `ads_parity_test.dart`)

**Root cause (single, coherent):** These Phase 3 / Phase 6 tests use ADS index
group **`0xF005`** as a generic scratch key/value group (e.g. the Phase-3 seed
fixture at `(0xF005, 0x123)=42`, and parity read/write/large-frame tests at
`0xF005`). Plan **07-03** (commit `003d3f1`) correctly implemented the mock's
SYM_VALBYHND dispatch, which reserves group `0xF005` for **value-by-handle**
routing. A plain read/write at `0xF005` now resolves the `indexOffset` as a
device handle, finds no live handle, and returns `0x710`
(ADSERR_DEVICE_SYMBOLNOTFOUND) instead of the flat-store bytes those older tests
expect.

**Why this pre-dates 07-06:** Verified via `git diff --name-only HEAD~2 HEAD` —
the two 07-06 commits touch ONLY the two new test files
(`handle_lifecycle_test.dart`, `symbols_test.dart`). Neither touches
`mock_server.cpp` nor the failing test files. The regression was introduced when
07-03 repurposed `0xF005`; earlier plans validated only their own targeted test
files, so the full-suite gate regression was not caught until this final plan
ran it.

**Why deferred (out of 07-06 scope):** 07-06's declared `files_modified` are the
two new integration test files only. The fix must edit Phase 3/6 test files
(and/or the mock) to relocate their scratch group off the now-reserved `0xF005`
— a cross-plan, semantically-loaded change (Rule 4 territory). Per the executor
scope boundary, out-of-scope discoveries are logged, not silently fixed.

**Recommended fix (for the verifier / node-repair loop):** Relocate the
scratch/seed group in `ads_client_test.dart` and `ads_parity_test.dart` from
`0xF005` to a group the mock treats as a flat store and that no Phase-7 dispatch
reserves (e.g. `0x4020`-style data groups already used elsewhere, or another
unreserved group). Do NOT change the mock's `0xF005` handling — reserving
`0xF005` for SYM_VALBYHND is correct ADS-protocol behavior. After relocating,
re-run `dart test -x slow` to confirm green.
