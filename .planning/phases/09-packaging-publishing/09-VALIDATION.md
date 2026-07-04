---
phase: 9
slug: packaging-publishing
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-07-04
---

# Phase 9 — Validation Strategy

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Quick run command** | `dart test -x integration -x slow` |
| **Full suite command** | `dart test -x slow` |
| **Package gate** | `dart pub publish --dry-run` |
| **Activate gate** | `dart pub global activate --source path . && ads --help` |

## Per-Task Verification Map

| Requirement | Secure Behavior | Automated Command |
|-------------|-----------------|-------------------|
| PKG-01 | platforms declared, no web, no C++ in artifact | `dart pub publish --dry-run` exit 0; package file list contains no test_harness/ or third_party/ |
| PKG-02 | CLI installable | `dart pub global activate --source path .` then `ads --help` exit 0 |
| TEST-05 | parity audit complete | PARITY doc exists; every C++ scenario row has a Dart test name or N/A rationale |

## Manual-Only Verifications

| Behavior | Why Manual |
|----------|-----------|
| Actual pub.dev publish | needs remote + credentials (human item) |
| CI on GitHub | 01-HUMAN-UAT |

**Approval:** pending
