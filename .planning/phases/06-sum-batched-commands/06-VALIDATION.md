---
phase: 6
slug: sum-batched-commands
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-04
---

# Phase 6 — Validation Strategy

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | dart test (installed) |
| **Config file** | dart_test.yaml (unit/integration/golden/slow tags) |
| **Quick run command** | `dart test -x integration -x slow` |
| **Full suite command** | `dart test -x slow` |
| **Estimated runtime** | ~30 s unit; ~3.5 min full |

## Sampling Rate

- **After every task commit:** `dart test -x integration -x slow`
- **After every plan wave:** `dart test -x slow` (+ selftest when C++ changed)
- **Max feedback latency:** 200 seconds

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (planner) | — | — | SUM-01 | T-6-01 | sumRead N items, per-item results, golden parity | unit+integration | `dart test -n 'sum'` | ❌ W0 | ⬜ pending |
| (planner) | — | — | SUM-02 | — | sumWrite write-back proven by read-after | integration | live test | ❌ W0 | ⬜ pending |
| (planner) | — | — | SUM-03 | T-6-02 | sumReadWrite variable-length (err,len) headers | unit+integration | golden + live | ❌ W0 | ⬜ pending |
| (planner) | — | — | SUM-04 | T-6-03 | Mid-batch failure: item k errors, others' data at correct offsets, no batch throw | unit+integration | alignment test | ❌ W0 | ⬜ pending |

## Wave 0 Requirements

- [ ] protocol/sum_commands.dart builders/decoders (pure)
- [ ] Mock sum dispatch in READ_WRITE case (0xF080/81/82) reusing store + kErrResultGroup
- [ ] 6 golden fixtures (req+res per variant, multi-item incl. one mid-batch failure)

## Layout Authority

AdsDef.h:68-88 doc-comments (vendored): READ res = N×u32 errs + data at requested lengths; WRITE res = N×u32; READWRITE res = N×(err u32, len u32) + variable data. readLength: N*4+Σlen / N*4 / N*8+ΣrLen. indexOffset = N. Failed item contributes 0 data bytes (frozen by golden, noted for Phase 9 audit).

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CI on GitHub | — | Needs remote (01-HUMAN-UAT) | Push; confirm jobs |

**Approval:** pending
