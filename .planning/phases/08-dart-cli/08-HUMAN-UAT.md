---
status: partial
phase: 08-dart-cli
source: [08-VERIFICATION.md]
started: 2026-07-04T18:36:51Z
updated: 2026-07-04T18:36:51Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. GitHub CI green (also tracked from Phase 1)
expected: Push to remote; analyze/format/unit+integration jobs pass (Linux CMake mock build).
result: [pending]

### 2. All 7 CLI verbs against a real Beckhoff/TwinCAT PLC
expected: browse/read/write/subscribe/pull/push/action behave as mock-verified (known limitation: mock-only so far; LocalRouterTarget needs the v2 0x1000 registration for a real local router — use direct mode with a route configured on the PLC).
result: [pending]

## Summary

total: 2
passed: 0
issues: 0
pending: 2
skipped: 0
blocked: 0

## Gaps
