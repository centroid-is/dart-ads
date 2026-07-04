---
phase: 7
slug: symbol-access-browse-typed-values
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-07-04
---

# Phase 7 — Validation Strategy

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | dart test (installed) |
| **Quick run command** | `dart test -x integration -x slow` |
| **Full suite command** | `dart test -x slow` |
| **Estimated runtime** | ~35 s unit; ~4 min full |

## Sampling Rate

- **After every task commit:** `dart test -x integration -x slow`
- **After every plan wave:** `dart test -x slow` (+ selftest when C++ changed)
- **Max feedback latency:** 240 seconds

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (planner) | — | — | SYM-01 | T-7-01 | handle resolve/use/release + auto-release + leak proof | unit+integration | `dart test -n 'handle'` | ❌ W0 | ⬜ pending |
| (planner) | — | — | SYM-02 | T-7-02 | multi-symbol blob parse via entryLength advancement (padded entry) | unit+integration | `dart test -n 'browse|symbol'` | ❌ W0 | ⬜ pending |
| (planner) | — | — | SYM-03 | — | typed scalar round-trips (all 10+ types, STRING/WSTRING conventions) | unit | `dart test -n 'value|codec'` | ❌ W0 | ⬜ pending |
| (planner) | — | — | SYM-04 | — | raw Uint8List escape hatch documented+tested | unit | existing read paths | ✅ | ⬜ pending |

## Wave 0 Requirements

- [ ] protocol/symbols.dart (AdsSymbolEntry parser: 30B header, flags u32, entryLength advancement) + protocol/value_codec.dart (pure)
- [ ] Mock: symbol table + 0xF003 (NUL-tolerant lookup)/0xF005/0xF006/0xF00C/0xF00B dispatch + 0x710 errors + handle-count observability
- [ ] Goldens: handle req/res, uploadinfo res, 2-symbol blob (one padded entry)

## Layout Authority

AdsDef.h:459-469 pack(1): 6×u32 + 3×u16 = 30B header, then name\0 type\0 comment\0, advance by entryLength. Browse = 0xF00C {nSymbols,nSymSize} → 0xF00B nSymSize bytes. 0xF003 RW name→handle (client sends +NUL, mock strips); 0xF005 io=handle; 0xF006 Write io=0 data=handle. Invalid handle/unknown name → 0x710 (A4 frozen).

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CI on GitHub | — | Needs remote (01-HUMAN-UAT) | Push; confirm jobs |

**Approval:** pending
