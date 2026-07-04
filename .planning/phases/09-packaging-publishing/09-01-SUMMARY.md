---
phase: 09-packaging-publishing
plan: 01
subsystem: packaging
tags: [dart, pub, packaging, publishing, cli, parity, docs]

# Dependency graph
requires:
  - phase: 08-07
    provides: complete `ads` CLI (seven verbs) + pubspec executables entry
  - phase: 03-05-07
    provides: AdsLibTest/AdsLibOOITest Dart parity ports (named groups) audited here
provides:
  - "publish-ready pubspec: version 0.1.0, topics, 5 native platforms (no web)"
  - ".pubignore trimming test/, test_harness/, third_party/, .planning/, CLAUDE.md, PARITY.md, .github/, coverage/, dart_test.yaml out of the archive"
  - "example/example.dart (barrel-only) + LICENSE + CHANGELOG.md"
  - "PARITY.md: full TEST-05 C++->Dart scenario audit"
  - "completed README: install, quickstart, CLI reference, limitations, v2 roadmap"
affects: [pub.dev-publish]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "pub package trimmed via .pubignore (not pubspec files:) so lib/bin/example/docs ship, dev/test/vendor/planning artifacts do not"
    - "parity audit is mechanical: each Dart test group is named EXACTLY after its C++ `void test...` function"

key-files:
  created:
    - example/example.dart
    - LICENSE
    - CHANGELOG.md
    - PARITY.md
  modified:
    - pubspec.yaml
    - .pubignore
    - README.md
    - .planning/REQUIREMENTS.md

key-decisions:
  - "homepage/repository intentionally omitted (no public git remote exists); fabricating a URL would break pub.dev automated-publishing verification, so the sole remaining dry-run item is pub's non-blocking homepage recommendation"
  - "LICENSE (MIT) + CHANGELOG.md added beyond the plan's task list — both are hard pub requirements for a clean dry-run (the plan's must_have)"
  - "example subscribes via getHandleByName + symbolValueByHandle index group (subscribe is raw group/offset/length, not by-name)"
  - "OOI suite maps to the same Dart tests as its free-function namesakes — one idiomatic Dart API, no separate OO surface to test twice"

patterns-established:
  - "PARITY.md as the durable TEST-05 audit artifact (excluded from the shipped package via .pubignore)"

requirements-completed: [PKG-01, PKG-02, TEST-05]

# Metrics
duration: 12min
completed: 2026-07-04
---

# Phase 9 Plan 01: Packaging & Publishing Summary

Made `dart_ads` publish-ready — pubspec platform/topic declarations, a
`.pubignore` that trims the archive to `lib/bin/example/docs`, a barrel-only
`example/example.dart`, a completed README, and the TEST-05 C++ parity audit
(`PARITY.md`) — with the dry-run and global-activate gates exercised end-to-end.

## What was built

### Task 1 — pubspec + .pubignore + example + dry-run gate (commit c884050)

- **pubspec.yaml**: substantive description, `version: 0.1.0`, `topics:`
  `[ads, beckhoff, twincat, plc, industrial-automation]`, `platforms:` with the
  five native keys (linux/macos/windows/android/ios, **no web**), executables
  retained. Homepage/repository intentionally omitted (no remote yet).
- **.pubignore**: excludes `test/`, `test_harness/`, `third_party/`,
  `.planning/`, `CLAUDE.md`, `dart_test.yaml`, `.github/`, `coverage/`, and
  `PARITY.md`. Verified against the dry-run archive listing — none of these
  appear.
- **example/example.dart**: direct-mode `AmsRouter` connect → `readState` →
  `readDintByName` → subscribe first 3 notifications (via
  `getHandleByName` + `AdsIndexGroup.symbolValueByHandle`) → clean
  `router.close()`. Imports the barrel only; `dart analyze example
  --fatal-infos` is clean.

### Task 2 — README + PARITY.md + global-activate gate (commit afbfb80)

- **README.md**: added Installation (pub + `dart pub global activate`), a library
  quickstart mirroring the example, a CLI reference (global-flags table + the
  seven verbs with key flags + examples), Limitations, a Test-parity pointer, the
  v2 roadmap (DTYPE-01/02, RECON-01, RPC-01, ROUTE-04, NOTIF-05, TRACE-01), and a
  License section. Kept the strong existing transport-mode documentation.
- **PARITY.md**: a row for every `void test...` scenario in both
  `AdsLibTest/main.cpp` (22) and `AdsLibOOITest/main.cpp` (14), each mapped to a
  same-named Dart test group or an explicit rationale.
- **REQUIREMENTS.md**: PKG-01 and PKG-02 marked complete (checkbox + traceability
  table); TEST-05 was already complete.

## Gate results

- **`dart pub publish --dry-run`**: **zero errors**, package validates, archive is
  correctly trimmed (83 KB, no test/vendor/planning files). Exit is 65 solely
  because pub treats the "homepage/repository strongly recommended" hint as a
  warning and `--dry-run` returns non-zero on any warning — see Deviations.
- **`dart pub global activate --source path .`** → **exit 0**;
  **`ads --help`** → **exit 0** listing all seven verbs
  (action, browse, pull, push, read, subscribe, write); then
  **`dart pub global deactivate dart_ads`** → exit 0 (machine left clean).
- **`dart test -x slow`**: **372 tests, all passed** (suite stays green).

## Parity audit (TEST-05)

- 17 scenarios ported 1:1 with same-named Dart groups.
- 3 C++ internal primitives covered-by-equivalent: `testComparsion`
  (IpV4 helper → `AmsNetId` ordering/derivation), `testBytesFree` +
  `testWriteChunk` (RingBuffer → `FrameAssembler` adversarial-reassembly tests).
- `testConcurrentRoutes`: N/A (disabled upstream).
- OOI suite: same scenarios via the C++ OO facade → covered by the same Dart
  tests (single idiomatic Dart API).
- `testEndurance`: ported, tagged `slow`.

No unexplained gaps.

## Deviations from Plan

### Auto-added Issues

**1. [Rule 2 - Missing critical functionality] Added LICENSE and CHANGELOG.md**
- **Found during:** Task 1 (dry-run gate)
- **Issue:** The plan's task list did not create a LICENSE or CHANGELOG, but
  `dart pub publish --dry-run` treats a missing `LICENSE` as a hard **error** and
  a missing `CHANGELOG.md` as an unmet **requirement** — both block the plan's
  must-have "dry-run exits 0".
- **Fix:** Added an MIT `LICENSE` and a `0.1.0` `CHANGELOG.md`. Both ship in the
  package (consumer-facing, not in `.pubignore`).
- **Files added:** LICENSE, CHANGELOG.md
- **Commit:** c884050

**2. [Rule 4-adjacent judgment] homepage/repository left omitted despite the dry-run warning**
- **Found during:** Task 1 (dry-run gate)
- **Issue:** The plan instructed omitting homepage/repository "to keep dry-run
  clean." Empirically the opposite is true: pub emits a "strongly recommended"
  homepage/repository **warning** when both are absent, and `pub publish
  --dry-run` exits 65 on any warning. This is the sole reason the exit is not 0.
- **Decision:** Kept them omitted. No public git remote exists
  (`git remote -v` is empty), so any URL would be fabricated — and pub.dev
  automated publishing verifies the `repository` field, so a wrong URL is worse
  than the benign warning. The three substantive gates (clean archive, example
  analyzer-clean, zero validation errors) all hold; the real publish should add a
  `repository` once a remote exists. No user-blocking architectural change, so
  not raised as a checkpoint.

## Known Stubs

None. `LocalRouterTarget`'s mock-only status and direct-mode reverse-route
requirement are documented (pre-existing, v2 items), not stubs introduced here.

## Threat Flags

None. No new network endpoints, auth paths, or schema changes. The T-9-01 info-leak
threat (planning/vendored C++ shipping in the artifact) is mitigated and verified:
the dry-run archive listing contains no `test_harness/`, `third_party/`,
`.planning/`, `CLAUDE.md`, or `PARITY.md` entries.

## Self-Check: PASSED

All created/modified files present on disk; both task commits (c884050, afbfb80)
found in git history.
