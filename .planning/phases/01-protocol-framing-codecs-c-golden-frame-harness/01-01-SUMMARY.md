---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
plan: 01
subsystem: infra
tags: [dart, pub, package, git-submodule, beckhoff-ads, hex-fixture, testing]

# Dependency graph
requires: []
provides:
  - "dart_ads pub package skeleton (manifest, lints, test tags, pubignore, barrel stub)"
  - "third_party/ADS git submodule pinned to 57d63747271fca7881bec48417adb44876e67505"
  - "test/support/hex.dart readGolden() '#'-commented hex fixture parser"
affects:
  - "01-02 (golden-frame dumper / C++ harness — builds against pinned submodule sources)"
  - "01-04 (codec — golden parity tests call readGolden)"
  - "all Phase 1 waves (need resolvable package + hex parser)"

# Tech tracking
tech-stack:
  added:
    - "test ^1.31.0 (dev)"
    - "lints ^6.1.0 (dev)"
    - "third_party/ADS submodule (Beckhoff/ADS @57d63747, C++14 reference sources)"
  patterns:
    - "Pure test-support helpers under test/support (dart:io allowed there, not in lib/)"
    - "Golden fixtures are human-diffable text hex with inline '#' comments"

key-files:
  created:
    - "pubspec.yaml"
    - "analysis_options.yaml"
    - "dart_test.yaml"
    - ".pubignore"
    - ".gitignore"
    - ".gitmodules"
    - "lib/dart_ads.dart"
    - "test/support/hex.dart"
    - "test/unit/hex_support_test.dart"
    - "third_party/ADS (submodule gitlink)"
  modified: []

key-decisions:
  - "Pinned submodule to the RESEARCH-verified commit 57d63747 (not a tag) so the 4-source build recipe stays valid"
  - "Library package: pubspec.lock gitignored (consumer resolves fresh)"
  - "Barrel lib/dart_ads.dart left export-free until 01-07 to keep intermediate waves analyzer-clean"

patterns-established:
  - "Pattern 1: readGolden strips first-'#'-onward per line, joins, removes all whitespace, decodes nibble pairs into Uint8List"
  - "Pattern 2: dart_test.yaml tags (unit/integration/golden) enable `dart test -x integration` fast runs"

requirements-completed: [TEST-02]

# Metrics
duration: 2min
completed: 2026-07-03
---

# Phase 1 Plan 01: Foundation (Package Skeleton, ADS Submodule, Hex Parser) Summary

**`dart_ads` pub package resolves clean on the pinned SDK floor, Beckhoff/ADS is vendored as a submodule at the RESEARCH-verified commit, and the `readGolden()` hex-fixture parser passes a four-case self-test including the byte-exact 38-byte ReadDeviceInfo anchor.**

## Performance

- **Duration:** 2 min
- **Started:** 2026-07-03T17:37:26Z
- **Completed:** 2026-07-03T17:39:42Z
- **Tasks:** 3
- **Files modified:** 10 created

## Accomplishments
- `dart pub get` resolves with zero errors on `>=3.5.0 <4.0.0`; `dart analyze --fatal-infos` clean; `dart format` gate clean.
- Beckhoff/ADS reference sources on disk at the pinned commit `57d63747271fca7881bec48417adb44876e67505`, with the four build-recipe sources (`Frame.cpp`, `Log.cpp`, `AdsDef.cpp`, `standalone/AmsNetId.cpp`) and `AmsHeader.h` present — excluded from the published package via `.pubignore`.
- `readGolden()` turns a `#`-commented hex golden file into a `Uint8List`, verified by a passing unit test asserting the 38-byte anchor decodes to leading bytes `00 00 20 00`.

## Task Commits

Each task was committed atomically:

1. **Task 1: Dart package scaffold** - `5f78673` (feat)
2. **Task 2: Vendor Beckhoff/ADS submodule** - `0d1af2a` (chore)
3. **Task 3: Hex-fixture parser + self-test (TDD)**
   - RED: `efeea1b` (test — failing, parser absent)
   - GREEN: `0b47bbc` (feat — parser implemented, 4/4 pass)
   - Format fix: `672d9c7` (style — CI format gate)

_TDD task has RED → GREEN commits; no REFACTOR needed (implementation minimal and clean)._

## Files Created/Modified
- `pubspec.yaml` - Package manifest: `name: dart_ads`, SDK `>=3.5.0 <4.0.0`, dev deps test+lints, no runtime deps
- `analysis_options.yaml` - `include: package:lints/recommended.yaml`
- `dart_test.yaml` - Tags `unit`, `integration` (timeout 30s), `golden`
- `.pubignore` - Excludes `test_harness/`, `third_party/`, `.planning/`
- `.gitignore` - Dart artifacts, gitignored library lockfile, harness build output
- `.gitmodules` - Submodule entry for `third_party/ADS`
- `lib/dart_ads.dart` - Export-free barrel stub with library doc comment
- `test/support/hex.dart` - `Uint8List readGolden(String path)`
- `test/unit/hex_support_test.dart` - Four behavior cases (`@Tags(['unit'])`)
- `third_party/ADS` - Submodule gitlink at pinned commit

## Decisions Made
- Pinned submodule to the exact RESEARCH-verified commit `57d63747` rather than a tagged release; per plan/threat register T-1-SC, the 4-source build recipe must be re-verified before any re-pin.
- Added a `.gitignore` (not enumerated in the plan) that gitignores `pubspec.lock` (library convention) and `.dart_tool/` — required so `dart pub get` artifacts aren't committed.
- Added a fourth test case (interleaved `#` comments across a multi-line annotated anchor) beyond the three plan-listed behaviors, to lock the human-diffable golden format contract.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added `.gitignore` for pub/CMake artifacts**
- **Found during:** Task 1 (scaffold)
- **Issue:** `dart pub get` produces `.dart_tool/` and `pubspec.lock`; with no `.gitignore` these would land as untracked/committed noise, and the harness build output (`test_harness/build/`) would too.
- **Fix:** Created `.gitignore` covering `.dart_tool/`, `pubspec.lock` (library convention), `coverage/`, and `test_harness/build/`.
- **Files modified:** `.gitignore`
- **Verification:** `git status --short` shows no stray generated files after `dart pub get`.
- **Committed in:** `5f78673` (Task 1 commit)

**2. [Rule 3 - Blocking] Applied `dart format` to the test file**
- **Found during:** Plan-level verification
- **Issue:** CI runs `dart format --output=none --set-exit-if-changed`; the hand-authored test file was not canonically formatted (exit 1).
- **Fix:** Ran `dart format lib test`; only test formatting adjusted, tests still 4/4 green.
- **Files modified:** `test/unit/hex_support_test.dart`
- **Verification:** `dart format --set-exit-if-changed lib test` exits 0; `dart test` green.
- **Committed in:** `672d9c7`

---

**Total deviations:** 2 auto-fixed (both Rule 3 - blocking/CI-hygiene)
**Impact on plan:** Both necessary to keep the tree CI-clean (analyze + format gates). No scope creep; no functional change to the deliverables.

## Issues Encountered
None — all three tasks executed as specified. Dev Dart is 3.11.5, which satisfies the `>=3.5.0` floor (RESEARCH assumption A5).

## User Setup Required
None - no external service configuration required. (`git submodule update --init --recursive` is needed on a fresh clone to materialize `third_party/ADS`, but that is standard submodule hygiene, not service config.)

## Next Phase Readiness
- Resolvable package + pinned reference sources + hex parser are all in place — the foundation wave is complete.
- 01-02 (C++ golden dumper / CMake harness) can now compile the four submodule sources directly.
- 01-04 (codec) can call `readGolden()` for byte-for-byte golden parity assertions.
- No blockers.

## Self-Check: PASSED

- All 10 declared files exist on disk (verified).
- All 5 task commits present in git history (`5f78673`, `0d1af2a`, `efeea1b`, `0b47bbc`, `672d9c7`).

---
*Phase: 01-protocol-framing-codecs-c-golden-frame-harness*
*Completed: 2026-07-03*
