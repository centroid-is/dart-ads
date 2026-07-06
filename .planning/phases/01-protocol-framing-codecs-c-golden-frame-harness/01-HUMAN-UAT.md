---
status: complete
phase: 01-protocol-framing-codecs-c-golden-frame-harness
source: [01-VERIFICATION.md]
started: 2026-07-03T20:03:47Z
updated: 2026-07-03T20:03:47Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. CI green on GitHub Actions (Phase 2 gate)
expected: After creating a GitHub remote and pushing (submodule third_party/ADS resolves via public URL), both CI jobs pass — "dart" (format/analyze/endian-gate/unit on ubuntu+macos+windows) and "integration" (CMake harness build, golden reproducibility via git diff --exit-code, mock_server --selftest, full dart suite on ubuntu). Note: the endian-gate false positives found during verification were fixed in d99f98b before this UAT was written; every step passes locally.
result: PASSED 2026-07-06 — repo pushed to github.com/centroid-is/dart-ads; run 28782533044 green (both jobs)

## Summary

total: 1
passed: 1
issues: 0
pending: 0
skipped: 0
blocked: 0

## Gaps
