---
phase: 2
slug: tcp-transport-connection-lifecycle-invoke-id-correlation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-07-03
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | dart test (package:test, already installed) |
| **Config file** | dart_test.yaml (exists — `unit`/`integration`/`golden` tags) |
| **Quick run command** | `dart test -x integration` |
| **Full suite command** | `dart test` (builds/uses the CMake mock via test/support/mock_server.dart helper) |
| **Estimated runtime** | ~10 s (unit); ~90 s full incl. harness rebuild on first run |
| **C++ harness build** | `cmake -S test_harness -B test_harness/build && cmake --build test_harness/build` |

---

## Sampling Rate

- **After every task commit:** Run `dart test -x integration`
- **After every plan wave:** Full suite: rebuild harness (if C++ changed), `dart test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 90 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (filled by planner) | — | — | TRANS-01 | — | N/A | integration | `dart test -t integration test/integration/connection_test.dart` | ❌ W0 | ⬜ pending |
| (filled by planner) | — | — | TRANS-02 | T-2-01 | Timeout resolves pending Future; no hang | unit | `dart test test/unit/ams_connection_test.dart` | ❌ W0 | ⬜ pending |
| (filled by planner) | — | — | TRANS-03 | T-2-02 | Fan-out errors all pending + error-closes controllers | unit | `dart test test/unit/ams_connection_test.dart` | ❌ W0 | ⬜ pending |
| (filled by planner) | — | — | TRANS-04 | — | N/A | unit | `dart test test/unit/ams_connection_test.dart` (FakeTransport) | ❌ W0 | ⬜ pending |
| (filled by planner) | — | — | PROTO-03 | — | Correlation under reordering (mock --delay-ms) | integration | `dart test -t integration test/integration/correlation_test.dart` | ❌ W0 | ⬜ pending |
| (filled by planner) | — | — | PROTO-04 | — | 0x08 frames bypass invoke-ID map | unit | `dart test test/unit/ams_connection_test.dart` | ❌ W0 | ⬜ pending |
| (filled by planner) | — | — | TEST-03 | — | Ephemeral port + LISTENING handshake + teardown | integration | `dart test -t integration` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `test/support/mock_server.dart` — launch helper (staleness check, Process.start, LISTENING parse, tearDownAll)
- [ ] `test_harness/mock_server.cpp` — `--delay-ms N` (defer FIRST response, flush LAST) + `--close-after N` modes; `--selftest` intact
- [ ] `test/unit/ams_connection_test.dart` — FakeTransport-driven unit tests
- [ ] `test/integration/` — integration-tagged live-mock tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CI integration job green on GitHub | TEST-03 | Requires push/remote | Push branch; confirm integration job runs `dart test` including integration-tagged tests |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
