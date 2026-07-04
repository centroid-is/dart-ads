---
phase: 8
slug: dart-cli
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-04
---

# Phase 8 — Validation Strategy

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | dart test (installed) |
| **Quick run command** | `dart test -x integration -x slow` |
| **Full suite command** | `dart test -x slow` |
| **Estimated runtime** | ~40 s unit; ~5 min full (CLI subprocess tests add startup cost) |

## Sampling Rate

- **After every task commit:** `dart test -x integration -x slow`
- **After every plan wave:** `dart test -x slow`
- **Max feedback latency:** 300 seconds

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (planner) | — | — | CLI-01..03 | — | browse/read/write against live mock via subprocess | integration | `dart test -t integration test/integration/cli_test.dart` | ❌ W0 | ⬜ pending |
| (planner) | — | — | CLI-04 | T-8-01 | subscribe SIGTERM teardown, no handle leak (0xE7700005) | integration | subscribe test | ❌ W0 | ⬜ pending |
| (planner) | — | — | CLI-05..06 | — | pull→push lossless round-trip; --dry-run; per-item report | integration | round-trip test | ❌ W0 | ⬜ pending |
| (planner) | — | — | CLI-07 | — | action --state via WriteControl, old→new printed | integration | action test | ❌ W0 | ⬜ pending |
| (planner) | — | — | CLI-08 | T-8-02 | exit codes 0/1/2/3 contract; human-readable errors; --json | integration | exit-code tests | ❌ W0 | ⬜ pending |

## Wave 0 Requirements

- [ ] pubspec: args dep + executables entry
- [ ] bin/ads.dart + lib/src/cli/ commands
- [ ] test/integration/cli_test.dart subprocess harness (reuses startMockServer)

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CLI vs real TwinCAT PLC | — | No PLC available | Known limitation; mock-verified |
| CI on GitHub | — | Needs remote (01-HUMAN-UAT) | Push; confirm jobs |

**Approval:** pending
