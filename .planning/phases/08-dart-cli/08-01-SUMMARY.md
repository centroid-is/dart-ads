---
phase: 08-dart-cli
plan: 01
subsystem: cli
tags: [args, command-runner, cli, exit-codes, ads, dart]

# Dependency graph
requires:
  - phase: 04-transport-router
    provides: AmsRouter + TransportTarget (DirectTarget/LocalRouterTarget) connect/close
  - phase: 03-ads-commands
    provides: AdsClient + AdsException + adsErrorName/adsErrorText
  - phase: 02-connection
    provides: AdsTimeoutException / AdsConnectionException transport family
provides:
  - "AdsCliRunner (CommandRunner<int>) with shared global connection flags"
  - "Seven registered verb stubs (browse/read/write/subscribe/pull/push/action)"
  - "connectFromGlobals -> AdsSession shared bootstrap + idempotent teardown"
  - "BaseAdsCommand.guarded exit-code + human-readable ADS-error contract (CLI-08)"
  - "Stable exit codes 0/1/2/3 and bin/ads.dart entrypoint + executables: ads"
affects: [08-02, 08-03, 08-04, 08-05, 08-06, 08-07, 09-publishing]

# Tech tracking
tech-stack:
  added: ["args ^2.7.0 (CommandRunner/Command)"]
  patterns:
    - "One Command subclass per verb; downstream plans replace only its run() body"
    - "Global connection flags on the runner, per-verb flags on each command"
    - "guarded() maps typed exception families -> stable exit codes"

key-files:
  created:
    - bin/ads.dart
    - lib/src/cli/exit_codes.dart
    - lib/src/cli/runner.dart
    - lib/src/cli/connection.dart
    - lib/src/cli/base_command.dart
    - lib/src/cli/commands/browse_command.dart
    - lib/src/cli/commands/read_command.dart
    - lib/src/cli/commands/write_command.dart
    - lib/src/cli/commands/subscribe_command.dart
    - lib/src/cli/commands/pull_command.dart
    - lib/src/cli/commands/push_command.dart
    - lib/src/cli/commands/action_command.dart
    - test/integration/cli_contract_test.dart
  modified:
    - pubspec.yaml

key-decisions:
  - "Verb stubs dial via connectFromGlobals before throwing UnimplementedError so the 'unreachable host -> exit 3' must-have is provable now"
  - "Dropped the planned 'abbr h' on --host (collides with CommandRunner's built-in -h help)"
  - "connectFromGlobals throws UsageException/FormatException for bad/missing flags -> exit 2 (T-8-02a)"

patterns-established:
  - "Per-verb command file owns exactly one file; runner.dart is churn-free for downstream verb plans"
  - "Transport family caught before ADS family in guarded() so a refused dial is exit 3, not 1"

requirements-completed: [CLI-08]

# Metrics
duration: 12min
completed: 2026-07-04
---

# Phase 8 Plan 01: CLI Backbone Summary

**`args`-based `AdsCliRunner` with shared global connection flags, a `connectFromGlobals` router bootstrap, a `guarded()` exit-code contract (0/1/2/3 with human-readable ADS names), and seven registered verb stubs — proven by a subprocess exit-code contract test.**

## Performance

- **Duration:** ~12 min
- **Completed:** 2026-07-04
- **Tasks:** 3
- **Files modified:** 13 (12 created, 1 modified)

## Accomplishments

- `AdsCliRunner` (`CommandRunner<int>`) declares the seven shared global connection flags (`--host/--port/--target/--ams-port/--source/--timeout/--mode`) and registers all seven verbs; `ads --help` lists them and exits 0.
- `connectFromGlobals` centralises the `AmsRouter` bootstrap, source-NetId policy (explicit `--source` / derived `<ip>.1.1` in direct mode), dial via `DirectTarget`/`LocalRouterTarget`, and an idempotent `AdsSession.close()`.
- `BaseAdsCommand.guarded()` maps transport errors → 3, `AdsException` (incl. `AdsRoutingException`) → 1 rendered as `ads error 0x<hex> <NAME>: <text>`, usage errors → 2; never bare hex alone.
- Seven verb stubs each own exactly one file with per-verb flags per 08-CONTEXT, so downstream plans replace only their `run()` body — zero runner churn.
- Integration contract test drives `bin/ads.dart` as a subprocess: unknown flag → 2, refused loopback endpoint → 3 (not 1).

## Task Commits

1. **Task 1: pubspec + entrypoint + CommandRunner shell + exit codes** — `b11a9e2` (feat)
2. **Task 2: shared connection bootstrap + BaseAdsCommand + seven stubs** — `19b8ffe` (feat); format touch-up `e4f3ed9` (style)
3. **Task 3: exit-code contract integration test** — `484f5c2` (test)

## Files Created/Modified

- `pubspec.yaml` — added `args ^2.7.0` dep and `executables: { ads: ads }`.
- `bin/ads.dart` — thin entrypoint; maps runner result to `exitCode`, top-level `UsageException` → 2.
- `lib/src/cli/exit_codes.dart` — `exitOk/exitAdsError/exitUsage/exitTransport` constants.
- `lib/src/cli/runner.dart` — `AdsCliRunner` with global flags + seven commands registered.
- `lib/src/cli/connection.dart` — `AdsSession` + `connectFromGlobals`.
- `lib/src/cli/base_command.dart` — `BaseAdsCommand.guarded()` exit-code/error contract.
- `lib/src/cli/commands/*.dart` — seven verb stubs.
- `test/integration/cli_contract_test.dart` — usage→2, unreachable→3 contract proof.

## Decisions Made

- **Stubs dial before throwing `UnimplementedError`.** The plan's Task 2 text described stubs that only throw `UnimplementedError`, but the plan's own must-have ("unreachable host exits 3, not 1") and the Task 3 contract test both require a real connection attempt to happen *through the CLI*. Since every verb in this plan is a stub, at least the tested verb must dial. All connection verbs therefore run `connectFromGlobals` inside `guarded` before throwing `UnimplementedError` — this makes the exit-3 contract provable now and matches the eventual verb bodies (which also dial). Downstream plans still replace only the `run()` body.
- **`--host` has no `abbr`.** `CommandRunner` reserves `-h` for `--help`; the planned `abbr: 'h'` would throw at construction.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Removed the `abbr h` from `--host`**
- **Found during:** Task 1 (runner construction)
- **Issue:** `CommandRunner` already registers `-h` for `--help`; adding `--host` with `abbr: 'h'` throws `ArgumentError` ("Abbreviation h is already used") at construction, so the runner would never build.
- **Fix:** Declared `--host` without an abbreviation.
- **Files modified:** lib/src/cli/runner.dart
- **Verification:** `dart run bin/ads.dart --help` builds and exits 0.
- **Committed in:** `b11a9e2` (Task 1 commit)

**2. [Rule 2 - Missing Critical] Verb stubs attempt the connection before throwing `UnimplementedError`**
- **Found during:** Task 2 (stub design) / confirmed in Task 3 (contract test)
- **Issue:** A stub that only throws `UnimplementedError` would exit 1 for a refused host — the plan's must-have and contract test require exit 3 to be observable through the CLI, which needs an actual dial.
- **Fix:** Each connection verb's `run()` calls `connectFromGlobals(globalResults!)` inside `guarded`, then throws `UnimplementedError`; a refused/timed-out dial surfaces via the transport family → exit 3, while a reachable endpoint reaches the `UnimplementedError` → exit 1.
- **Files modified:** lib/src/cli/commands/*.dart, lib/src/cli/connection.dart
- **Verification:** Contract test `refused endpoint exits 3, not 1` passes; manual `--mode bogus`→2, missing `--target`→2.
- **Committed in:** `19b8ffe` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 missing-critical)
**Impact on plan:** Both were necessary to satisfy the plan's own must-haves and keep the runner constructible. No scope creep — the stubs still delegate to a single per-verb `run()` body for downstream plans.

## Issues Encountered

- `dart format --set-exit-if-changed` (a CI gate) flagged long help strings/cascades in three files; reformatted in `e4f3ed9` (style). No behaviour change.

## Verification

- `dart analyze --fatal-infos lib/src/cli bin/ads.dart` — clean (also whole-project clean).
- `dart format --output=none --set-exit-if-changed` — clean on all CLI + test sources.
- `dart run bin/ads.dart --help` — lists seven verbs, exit 0.
- Manual: `--mode bogus`→2, `read --nope`→2, missing `--target`→2, refused host→3.
- `dart test -t integration test/integration/cli_contract_test.dart` — 2/2 pass.
- `dart test -x integration -x slow` — 256/256 pass (no regressions).

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- CLI-08 interface contract is fixed: runner, global flags, `connectFromGlobals`, exit codes, and `guarded()` error rendering are in place.
- Each verb plan (08-02..08-07) implements against a stable contract by replacing only its command's `run()` body and flag wiring — `runner.dart` needs no changes.

## Self-Check: PASSED

All 14 created files present on disk; all 4 task/style commits present in git history.

---
*Phase: 08-dart-cli*
*Completed: 2026-07-04*
