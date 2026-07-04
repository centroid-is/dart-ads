---
phase: 5
slug: device-notifications-as-streams
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-04
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | dart test (installed) |
| **Config file** | dart_test.yaml — NOTE: add `slow` tag declaration this phase (testEndurance port) |
| **Quick run command** | `dart test -x integration -x slow` |
| **Full suite command** | `dart test -x slow` (endurance runs manually only) |
| **Estimated runtime** | ~25 s unit; ~3 min full |

---

## Sampling Rate

- **After every task commit:** `dart test -x integration -x slow`
- **After every plan wave:** `dart test -x slow` (+ mock selftest when C++ changed)
- **Before `/gsd:verify-work`:** full suite (minus slow) green
- **Max feedback latency:** 180 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (planner) | — | — | NOTIF-01 | — | subscribe → Stream; Add on first listen | integration | `dart test -t integration -n 'notif'` | ❌ W0 | ⬜ pending |
| (planner) | — | — | NOTIF-02 | T-5-01 | onCancel → Delete always; disconnect invalidates handles; leak count 0 | integration | handle-leak test via magic read group | ❌ W0 | ⬜ pending |
| (planner) | — | — | NOTIF-03 | T-5-02 | Nested 2-stamp×2-sample frame parses; FILETIME→DateTime correct; malformed 0x08 dropped+counted, connection alive | unit | `dart test test/unit/protocol/notification_stream_test.dart` | ❌ W0 | ⬜ pending |
| (planner) | — | — | NOTIF-04 | — | serverCycle + serverOnChange modes; Duration→100ns conversion | unit+integration | golden Add req/res parity + live mode tests | ❌ W0 | ⬜ pending |
| (planner) | — | — | TEST-05 (slice) | — | testAdsNotification, testManyNotifications 1:1; testEndurance tagged slow | integration | `dart test -t integration test/integration/notification_parity_test.dart` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `dart_test.yaml`: declare `slow` tag
- [ ] Golden frames: add_device_notification req/res, delete_device_notification req/res, notification stream frame (incl. one 2×2 nested) via dump_golden
- [ ] Mock: ADD/DEL_DEVICE_NOTIFICATION, write-triggered + burst emission, magic read group for active-handle count
- [ ] Hostile-frame containment: 0x08 parse errors must NOT hit _failClose (droppedNotifications counter)

---

## C++ Test-Parity Targets (Phase 5 slice of TEST-05)

testAdsNotification (lifecycle/error codes: 1024 registers, 512 deletes, port-close cleanup — adapted to connection-close cleanup), testManyNotifications (adapted to deterministic leak-proof), testEndurance (tagged `slow`, manual).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| testEndurance long-run | TEST-05 | Blocks by design | `dart test -t slow` manually |
| CI on GitHub | — | Needs remote (01-HUMAN-UAT) | Push; confirm jobs |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity maintained
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 180s

**Approval:** pending
