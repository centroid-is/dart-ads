---
phase: 08-dart-cli
plan: 07
subsystem: cli
tags: [cli, action, writecontrol, adsstate, control-verb]
requires:
  - "08-01: BaseAdsCommand.guarded + connectFromGlobals connect→exit-code backbone"
  - "AdsClient.readState / AdsClient.writeControl (Phase 3)"
  - "AdsState enum (protocol/constants.dart)"
provides:
  - "ads action --state <name>: WriteControl state change, prints old -> new"
affects:
  - "bin/ads.dart CLI (action verb now functional; last of the 7 verbs)"
tech-stack:
  added: []
  patterns:
    - "case-insensitive name→enum mapping against AdsState.values (exclude unknown sentinel)"
    - "connection-scoped readState→writeControl→readState to observe old→new in one process"
key-files:
  created:
    - test/integration/cli_action_test.dart
  modified:
    - lib/src/cli/commands/action_command.dart
decisions:
  - "Unknown --state name -> UsageException (exit 2) listing valid names; never AdsState.unknown silent no-op (T-8-10)"
  - "AdsState.unknown excluded from operator-selectable names (it is a tolerant wire-decode sentinel, not a target)"
  - "RPC/method-call invocation deferred to v2 (RPC-01) per 08-CONTEXT; action is WriteControl-only in v1"
metrics:
  duration: 4min
  completed: 2026-07-04
---

# Phase 8 Plan 07: Action Verb (WriteControl State Change) Summary

The `action` verb sets the PLC's ADS run state via WriteControl, selected by a case-insensitive `--state <name>` mapped through the `AdsState` enum, and prints the `old -> new` transition — the last of the seven CLI verbs, proving `readState` + `writeControl` from the terminal.

## What Was Built

**Task 1 — action verb (`lib/src/cli/commands/action_command.dart`, commit 774d711):**
Filled `ActionCommand.run()` over the shared `connect→guarded` backbone. A required `--state <name>` is matched case-insensitively against `AdsState.values` `.name` (excluding the `unknown` sentinel); an unmatched or missing name throws a `UsageException` (exit 2) listing the valid names. In `guarded(...)`: `readState()` for the OLD state, `writeControl(adsState: target)`, `readState()` for the NEW state, then `print("<old.name> -> <new.name>")`, `close()` in `finally`, return `exitOk`. No RPC/method-call mode.

**Task 2 — integration test (`test/integration/cli_action_test.dart`, commit 0369f0e):**
`@Tags(['integration'])` subprocess suite reusing the `runCli`/`startMockServer` pattern. The mock's `curAdsState` is connection-scoped and seeded to RUN, and the verb reads-old/writes/reads-new within one process, so old→new is observable per invocation. Cases: `--state CONFIG` → exit 0, stdout `run -> config`; `--state RUN` → exit 0, stdout `-> run`; `--state BOGUS` → exit 2. All 3 pass.

## Verification

- `dart analyze --fatal-infos lib/src/cli/commands/action_command.dart` → No issues found.
- `dart test -t integration test/integration/cli_action_test.dart` → All tests passed (3/3).

## Threat Model Coverage

- **T-8-10 (Tampering, --state parsing):** mitigated — unknown name → `UsageException` (exit 2), never `AdsState.unknown` or a silent no-op.
- **T-8-11 (Elevation, unintended transition):** accepted — operator-initiated; old→new printed for confirmation; RPC mode deferred (smaller surface).
- **T-8-SC (pub installs):** accepted — no new packages beyond 08-01's `args`.

## Deviations from Plan

None - plan executed exactly as written.

## Known Stubs

None. The prior stub (`throw UnimplementedError`) was fully replaced by the real body.

## Self-Check: PASSED

- FOUND: lib/src/cli/commands/action_command.dart
- FOUND: test/integration/cli_action_test.dart
- FOUND commit: 774d711 (feat)
- FOUND commit: 0369f0e (test)
