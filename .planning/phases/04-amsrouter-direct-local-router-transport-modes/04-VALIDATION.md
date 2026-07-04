---
phase: 4
slug: amsrouter-direct-local-router-transport-modes
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-07-04
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | dart test (installed) |
| **Config file** | dart_test.yaml (unit/integration/golden tags) |
| **Quick run command** | `dart test -x integration` |
| **Full suite command** | `dart test` |
| **Estimated runtime** | ~20 s unit; ~2.5 min full |

---

## Sampling Rate

- **After every task commit:** `dart test -x integration`
- **After every plan wave:** full `dart test`
- **Before `/gsd:verify-work`:** full suite green
- **Max feedback latency:** 150 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (planner) | — | — | ROUTE-01 | — | Same command sequence through both modes, zero command-code change | integration | `dart test test/integration/router_transport_modes_test.dart` | ❌ W0 | ⬜ pending |
| (planner) | — | — | ROUTE-02 | T-4-01 | NetId→connection map; port alloc 30000..30127, exhaustion → 0/typed error | unit | `dart test test/unit/router/ams_router_test.dart` | ❌ W0 | ⬜ pending |
| (planner) | — | — | ROUTE-03 | — | setLocalAddress + route table; unrouted NetId → GLOBALERR_MISSING_ROUTE (0x0007) pre-I/O | unit | `dart test test/unit/router/ams_router_test.dart` | ❌ W0 | ⬜ pending |
| (planner) | — | — | ERR-02 | T-4-02 | Direct-mode timeout → AdsException code 0x745 naming source NetId, never bare timeout | unit+integration | `dart test --name '1861|missing.route'` | ❌ W0 | ⬜ pending |
| (planner) | — | — | TEST-05 (slice) | — | 5 router parity ports named 1:1 | unit/integration | `dart test test/unit/router_parity_test.dart` (or integration file) | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `AdsTransport.localAddress` seam (research gap: socket local IP needed for `<ip>.1.1` auto-derive) — SocketTransport + FakeTransport impls
- [ ] `AmsNetId`/`AmsAddr` Comparable ordering (lexicographic bytes; netId-then-port)
- [ ] `lib/src/router/` files + test files created by plan tasks

---

## C++ Test-Parity Targets (Phase 4 slice of TEST-05)

testAmsAddrCompare, testAmsRouterAddRoute (incl. 0x0506 same-NetId/different-host), testAmsRouterDelRoute, testAmsRouterSetLocalAddress, testAdsPortOpenEx (adapted: router port open/close semantics).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real TwinCAT local-router interop | ROUTE-01 | No TwinCAT install available | Tracked as known limitation; mock stands in (framing-identical) |
| CI green on GitHub | — | Needs remote (01-HUMAN-UAT) | Push; confirm jobs |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 150s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
