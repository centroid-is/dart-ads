---
phase: 03-core-ads-commands-error-mapping
fixed_at: 2026-07-04T12:30:00Z
review_path: .planning/phases/03-core-ads-commands-error-mapping/03-REVIEW.md
iteration: 1
findings_in_scope: 3
fixed: 3
skipped: 0
status: all_fixed
---

# Phase 3: Code Review Fix Report

**Fixed at:** 2026-07-04T12:30:00Z
**Source review:** .planning/phases/03-core-ads-commands-error-mapping/03-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 3 (Warnings only — Info findings IN-01..IN-06 intentionally left open)
- Fixed: 3
- Skipped: 0

## Fixed Issues

### WR-01: WRITE / READ_WRITE bounds checks overflow on 32-bit `size_t`

**Files modified:** `test_harness/mock_server.cpp`
**Commit:** 10504a8
**Applied fix:** Rewrote both per-command length validations in overflow-free subtraction form — WRITE: `bodyLen < 12 || (size_t)length > bodyLen - 12`; READ_WRITE: `bodyLen < 16 || (size_t)writeLength > bodyLen - 16` — so a hostile length near 2^32 can no longer wrap the additive check on a 32-bit `size_t` and bypass rejection. READ_WRITE's `readLength > kMaxFrameBytes` cap (parity with READ) was already present and verified. The `kMaxFrameBytes` comment was extended to state precisely what the cap does and does not cover, removing the file's overclaimed 32-bit safety guarantee.
**Verification:** clean CMake rebuild; `mock_server --selftest` OK (golden byte-identical); full Dart suite green.

### WR-02: `testAdsReadReqEx2` parity port write-then-read loop is vacuous

**Files modified:** `test/integration/ads_parity_test.dart`
**Commit:** 60ccfac
**Applied fix:** Before the C++-mirroring zero write, the test now (1) reads never-written key `(0x4020, 0xBEEF)` and asserts zeros — documenting the mock's zero-fill semantics for missing keys; (2) writes sentinel `[0x5A, 0xA5, 0x5A, 0xA5]` and asserts the exact pattern reads back, proving the write-back store is live; (3) writes zeros, so the pre-existing ten-iteration zero-read loop now verifies the overwrite rather than the zero-fill default. A broken Write path can no longer pass this test.
**Verification:** `dart analyze --fatal-infos` clean; `dart format` clean; test passes against the rebuilt mock; full suite green.

### WR-03: ADS payload wire layout duplicated between `AdsClient` and `commands.dart` encoders

**Files modified:** `lib/src/protocol/commands.dart`, `lib/src/client/ads_client.dart`
**Commit:** 26dfb01
**Applied fix:** Implemented the review's preferred option (a). `commands.dart` gained four pure payload builders — `buildReadPayload`, `buildWritePayload`, `buildWriteControlPayload`, `buildReadWritePayload` (named-parameter style matching the encoders) — and the four full-frame encoders (`encodeReadRequest`, `encodeWriteRequest`, `encodeWriteControlRequest`, `encodeReadWriteRequest`) now delegate payload construction to them. `AdsClient.read/write/readWrite/writeControl` consume the same builders (the now-unused `range_check.dart` import was removed from the client). Each wire layout lives in exactly one place, transitively pinned by the golden byte fixtures. The builders are package-internal: deliberately NOT added to the `dart_ads.dart` barrel's `show` list. `protocol/` purity preserved (builders use only `dart:typed_data` + local pure helpers). No public signature changes, no test updates required.
**Verification:** `dart analyze --fatal-infos` clean; wire bytes unchanged — all 113 tests pass including golden parity tests byte-for-byte; `mock_server --selftest` OK.

## Skipped Issues

None — all in-scope findings were fixed.

## Notes

- **Pre-existing format drift (not introduced here):** `dart format --set-exit-if-changed` fails at the pre-fix HEAD for `lib/src/protocol/ads_error.dart` and `test/unit/ads_error_test.dart` under the locally installed Dart 3.11.5 (the project develops on 3.12.x, whose formatter output differs). Neither file was touched by these fixes, and reformatting them with an older SDK would churn against the project formatter, so they were left as-is. All files modified by this fix pass the format gate.
- Info findings IN-01 through IN-06 remain open by scope decision (`fix_scope: critical_warning`).

---

_Fixed: 2026-07-04T12:30:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
