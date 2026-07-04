---
phase: 3
slug: core-ads-commands-error-mapping
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-04
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | dart test (package:test, installed) |
| **Config file** | dart_test.yaml (exists — unit/integration/golden tags) |
| **Quick run command** | `dart test -x integration` |
| **Full suite command** | `dart test` (uses startMockServer helper; builds harness if stale via build lock) |
| **Estimated runtime** | ~15 s unit; ~2 min full incl. C++ rebuild on first run |

---

## Sampling Rate

- **After every task commit:** `dart test -x integration`
- **After every plan wave:** full `dart test` (+ `mock_server --selftest` when C++ changed)
- **Before `/gsd:verify-work`:** full suite green
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (planner) | — | — | CMD-01..03 | T-3-01 | Read/Write/ReadWrite round-trip + write-back | integration | `dart test test/integration/ads_client_live_test.dart` | ❌ W0 | ⬜ pending |
| (planner) | — | — | CMD-04..06 | — | State/DeviceInfo/WriteControl typed results | integration | `dart test test/integration/ads_client_live_test.dart` | ❌ W0 | ⬜ pending |
| (planner) | — | — | ERR-01 | T-3-02 | Both error levels (AMS errorCode + payload result) → AdsException | unit+integration | `dart test test/unit/ads_error_test.dart` + magic-group live test | ❌ W0 | ⬜ pending |
| (planner) | — | — | TEST-05 (partial) | — | C++ AdsLibTest command-suite scenarios ported | integration | `dart test -t integration` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] Mock data store + magic error groups in `test_harness/mock_server.cpp` (Read/Write/ReadWrite write-back; stateful WriteControl→ReadState; amsError patch at offset 24; --selftest byte-identical)
- [ ] `AmsConnection.request` seam change surfacing AMS header errorCode (single existing caller updated)
- [ ] `lib/src/protocol/ads_error.dart` (or similar) — full error table, pure
- [ ] AdsClient + tests files

---

## C++ Test-Parity Targets (Phase 3 slice of TEST-05)

Port from `third_party/ADS/AdsLibTest/main.cpp` (adapted to mock-server fixtures):
testAdsReadReqEx2, testAdsReadReqEx2LargeBuffer, testAdsReadDeviceInfoReqEx, testAdsReadStateReqEx, testAdsReadWriteReqEx2, testAdsWriteReqEx, testAdsWriteControlReqEx, testAdsTimeout, testLargeFrames, testParallelReadAndWrite (port open/close semantics adapted — Dart has connection lifecycle instead of port handles).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CI green on GitHub | — | Needs remote/push (tracked in 01-HUMAN-UAT) | Push; confirm both jobs |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
