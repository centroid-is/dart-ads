---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
plan: 07
subsystem: protocol
tags: [public-api, barrel, ci, github-actions, cmake, dart]
requirements_completed: [TEST-01, TEST-02]
dependency_graph:
  requires:
    - "01-03: test_harness (mock_server --selftest, CMake build)"
    - "01-04: AmsTcpHeader, AmsHeader, AmsNetId/AmsAddr, MalformedFrameException, constants"
    - "01-05: six command encoders/decoders + sealed AdsResponse hierarchy"
    - "01-06: FrameAssembler"
  provides:
    - "lib/dart_ads.dart: curated public API barrel for the protocol codec"
    - ".github/workflows/ci.yml: 2-job CI (Dart matrix + Linux CMake harness) — the Phase 2 gate"
  affects:
    - "Phase 2 transport work imports the codec via package:dart_ads/dart_ads.dart"
    - "All future phases gate on green CI (both jobs)"
tech_stack:
  added: []
  patterns:
    - "Curated public barrel with intentional 'export ... show' clauses (internal helpers stay library-private)"
    - "2-job CI split: fast pure-Dart cross-platform matrix + Linux-only C++ harness integration"
    - "Golden reproducibility gate: regenerate from C++ source of truth + git diff --exit-code"
    - "Endian-safety grep gate: fail if any multi-byte ByteData accessor omits Endian.little"
key_files:
  created:
    - "lib/dart_ads.dart"
    - ".github/workflows/ci.yml"
    - "test/unit/public_api_test.dart"
  modified:
    - "lib/src/protocol/frame_assembler.dart"
    - "test/unit/frame_assembler_test.dart"
decisions:
  - "Barrel uses 'export ... show' with explicit symbol lists (T-1-EXP): only the intended codec surface is public; internal helpers (_frame, _cString, _require, _concat) remain library-private."
  - "CI endian gate greps for get/set{Uint,Int,Float}{16,32,64}( calls lacking Endian.little (assumes one accessor per line, which the codec observes) rather than the import-purity grep, whose literal form false-positives on doc prose."
  - "Windows runner has no C++ harness, so the Dart matrix job runs 'dart test -x integration' (unit + golden parity are pure Dart); the C++ harness build lives only in the Linux integration job."
  - "CI references no secrets — OIDC pub.dev publishing is deferred to a later phase."
metrics:
  duration: 4min
  completed: 2026-07-03
  tasks: 2
  files: 5
---

# Phase 01 Plan 07: Public Barrel & 2-Job CI Summary

Finalized the curated public API barrel (`lib/dart_ads.dart`) that re-exports the phase's protocol codec surface via intentional `show` clauses, and stood up the 2-job GitHub Actions CI — a fast cross-platform Dart matrix (format/analyze/endian-gate/unit) plus a Linux job that builds the CMake golden-frame harness, proves goldens are reproducible, self-tests the mock, and runs the full suite. Green CI on both jobs is the explicit Phase 2 gate. Closes TEST-01 (harness builds in CI) and TEST-02 (parity runs in CI).

## What Was Built

- **`lib/dart_ads.dart`** — the curated public barrel. Replaces the plan-01 export-free stub with intentional `export 'src/protocol/<file>.dart' show ...` clauses exposing exactly the intended surface: `AmsNetId`/`AmsAddr`, `AmsTcpHeader`, `AmsHeader`, the sealed `AdsResponse` hierarchy plus the six request encoders and six response decoders, `FrameAssembler`, `MalformedFrameException`, and the seven constant holders (`AdsCommandId`, `AmsStateFlags`, `AmsPort`, `AdsIndexGroup`, `AdsDeviceDataOffset`, `AdsState`, `AdsError`). Library-private helpers in `commands.dart`/`frame_assembler.dart` are never named and stay internal (T-1-EXP).
- **`test/unit/public_api_test.dart`** (tagged `unit`) — a consumer smoke test that reaches the codec **only** through `package:dart_ads/dart_ads.dart` (no `src/` reach-in): builds an `AmsHeader`/`AmsTcpHeader`, round-trips a `ReadDeviceInfo` frame through the encoder + `FrameAssembler`, catches a `MalformedFrameException`, and decodes an `AdsResponse` subtype. Dropping any symbol from the barrel would break analysis/compile — the behavioural assertion the acceptance criteria call for.
- **`.github/workflows/ci.yml`** — 2-job pipeline, no secrets:
  - **`dart`** (matrix `ubuntu-latest`/`macos-latest`/`windows-latest`, `fail-fast: false`): checkout → `setup-dart@v1` stable → `dart pub get` → `dart format --output=none --set-exit-if-changed .` → `dart analyze --fatal-infos` → **endian-safety gate** (`shell: bash` grep that fails if any `get/set{Uint,Int,Float}{16,32,64}(` call in `lib/src/protocol/` omits `Endian.little`, threat T-1-02) → `dart test -x integration`.
  - **`integration`** (`ubuntu-latest`): `checkout@v4` with `submodules: recursive` (T-1-SC) → `setup-dart@v1` stable → `apt-get install -y cmake g++ ninja-build` → `cmake -S test_harness -B test_harness/build` → `cmake --build test_harness/build` → regenerate goldens with `dump_golden test/golden/` + `git diff --exit-code test/golden` (reproducibility, T-1-SC) → `mock_server --selftest` → `dart pub get && dart test` (full suite incl. golden tag).
  - Adds a `concurrency` group (cancel-in-progress) and `permissions: contents: read`.

## Verification

- `dart analyze --fatal-infos` → no issues (whole package, through the barrel).
- `dart format --output=none --set-exit-if-changed .` → clean across all 14 files.
- `dart test -x integration` → 42/42 pass (38 prior + 4 new public-API cases).
- `.github/workflows/ci.yml` parses as valid YAML (`yaml.safe_load`); asserts present: matrix over the three OSes, `submodules: recursive`, `cmake --build`, `set-exit-if-changed`, `mock_server --selftest`, `git diff --exit-code test/golden`; no `secrets.*` references.
- Integration-job core steps validated locally against the already-built harness: `dump_golden test/golden/` + `git diff --exit-code test/golden` → no drift; `mock_server --selftest` → `OK`.
- Endian gate dry-run against `lib/src/protocol/` → no offenders (all multi-byte accessors carry `Endian.little`).

## Threat Model Coverage

| Threat ID | Category | Mitigation | Where |
|-----------|----------|------------|-------|
| T-1-SC | Tampering | `submodules: recursive` pulls the pinned commit only; goldens regenerated and `git diff --exit-code` proves no drift; no publish secrets in CI | integration job |
| T-1-02 | Tampering | CI grep gate fails the build if any multi-byte accessor in `lib/src/protocol/` omits `Endian.little` | dart job (endian gate) |
| T-1-EXP | Information Disclosure | Barrel uses intentional `export ... show` lists; internal helpers/raw buffers are not exported | lib/dart_ads.dart |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Reformatted two pre-existing files to satisfy the package-wide format gate**
- **Found during:** Task 2 (setting up the CI format gate)
- **Issue:** `dart format --set-exit-if-changed .` reported `lib/src/protocol/frame_assembler.dart` and `test/unit/frame_assembler_test.dart` as unformatted (minor line-wrap drift from a different formatter version used in plan 01-06). The CI `dart` job runs exactly this check, so leaving them would fail the Phase 2 gate — and package-wide format cleanliness is an explicit must-have truth of this plan.
- **Fix:** Ran `dart format` on the two files (whitespace/line-wrap only; no logic change). Verified the full package is now format-clean.
- **Files modified:** `lib/src/protocol/frame_assembler.dart`, `test/unit/frame_assembler_test.dart`
- **Commit:** 6b67ad1

## Manual Verification Outstanding

Per VALIDATION.md, the CI green state is a **manual** gate: push the branch and confirm both CI jobs pass on GitHub Actions. This is the Phase 2 gate. Local validation covered every step the runners execute (build, golden reproducibility, selftest, analyze/format/unit), but the hosted matrix (macOS/Windows Dart + Linux apt toolchain) can only be confirmed on a real push.

## Known Stubs

None — the barrel wires real exports and CI runs real build/test steps.

## Self-Check: PASSED

- `lib/dart_ads.dart` — FOUND
- `.github/workflows/ci.yml` — FOUND
- `test/unit/public_api_test.dart` — FOUND
- Commit 2b84657 (feat: barrel) — FOUND
- Commit 6b67ad1 (style: format) — FOUND
- Commit f203f19 (ci: workflow) — FOUND
