---
phase: 08-dart-cli
plan: 04
subsystem: cli
tags: [dart, cli, args, ads, write, value-parsing]

# Dependency graph
requires:
  - phase: 08-01
    provides: WriteCommand stub, BaseAdsCommand guarded exit-code contract, connectFromGlobals session bootstrap
  - phase: 08-02
    provides: value_parsing seam (encodeTypedValue / parseHex)
  - phase: 08-03
    provides: read verb by-name/group-offset patterns (_resolveOrRaise / _normalizeType / _parseAnyInt), cli subprocess+mock test pattern
provides:
  - "write verb (CLI-03): by-name typed (--type or resolved symbol type) and group/offset raw (--raw hex)"
  - "subprocess write integration test proving exit 0 on success and exit 2 on hostile value/hex"
affects: [08-05, 08-06, 08-07, phase-09]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "name XOR group/offset AND value XOR raw guards, both mapped to UsageException -> exit 2"
    - "wasParsed() (not non-empty) to detect --value/--raw presence so empty-payload writes are honored"

key-files:
  created:
    - test/integration/cli_write_test.dart
  modified:
    - lib/src/cli/commands/write_command.dart

key-decisions:
  - "By-name + --type resolves the symbol size only for STRING/WSTRING; fixed scalars skip the browse"
  - "group/offset path requires --raw (typed writes need a symbol size the raw path lacks)"
  - "Cross-process write->read round-trip is not a mock guarantee (connection-scoped store); round-trip proven at library level in symbols_test.dart, subprocess test asserts write path + exit codes"

patterns-established:
  - "Confirmation line 'wrote <n> bytes to <target>' where target is the symbol name or 0x<group>:0x<offset>"

requirements-completed: [CLI-03]

# Metrics
duration: 6min
completed: 2026-07-04
---

# Phase 08 Plan 04: Write Verb Summary

**`ads write` mutates a PLC variable by name (typed via `--type` or the resolved symbol type) or by index-group/offset (`--raw` hex), with every hostile value/hex mapped to exit 2 through the 08-02 value-parsing seam.**

## Performance

- **Duration:** 6 min
- **Started:** 2026-07-04
- **Completed:** 2026-07-04
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Filled the 08-01 `WriteCommand.run()` stub: name XOR group/offset and value XOR raw guards, by-name typed encode via `encodeTypedValue`, group/offset raw via `parseHex`, and a `wrote <n> bytes to <target>` confirmation.
- Untyped by-name writes resolve the symbol's declared type/size via `browseSymbols`, so the operator need not restate the type.
- Six-case subprocess integration test proves the write path succeeds (exit 0) for typed/untyped/raw, and hostile value, garbage hex, and no-payload each map to exit 2 without crashing.

## Task Commits

Each task was committed atomically:

1. **Task 1: write verb (by-name typed / group-offset / --raw hex)** - `d521f15` (feat)
2. **Task 2: write -> read-back round-trip integration test** - `95f84b1` (test)

**Plan metadata:** committed with this SUMMARY (docs: complete plan)

## Files Created/Modified
- `lib/src/cli/commands/write_command.dart` - WriteCommand.run() body: target/payload guards, by-name typed + raw encode, group/offset raw write, confirmation line.
- `test/integration/cli_write_test.dart` - `@Tags(['integration'])` subprocess suite driving `bin/ads.dart write` against the C++ mock.

## Decisions Made
- **Payload-source guards use `wasParsed`** rather than a non-empty check, so an intentional empty write (e.g. `--value ""` clearing a STRING, or `--raw 0x`) is honored instead of misread as "no payload".
- **Symbol resolution is lazy:** a `--type dint` write encodes immediately (fixed scalar sizes itself); only STRING/WSTRING and the no-`--type` path pay a `browseSymbols` lookup for the declared size.
- **Round-trip proof placement:** because the mock's value store is connection-scoped and each subprocess is its own connection, the subprocess test asserts write success + exit codes and documents that the write+read-back round-trip is proven connection-scoped at library level in `test/integration/symbols_test.dart`.

## Deviations from Plan

None - plan executed exactly as written.

The plan's Task 1 was marked `tdd="true"` but its `<verify>` is `dart analyze` only, with the behavior proof living in Task 2's integration test; tasks were executed in plan order (implement, then test) accordingly. Both files passed `dart analyze --fatal-infos` and `dart format` clean on first run.

## Issues Encountered
- `dart analyze` flagged two `unnecessary_non_null_assertion` warnings on `groupOpt!`/`offsetOpt!`: the `hasGroup`/`hasOffset` boolean locals already promote those nullables to non-null via Dart flow analysis. Removed the redundant `!` operators; analyze then passed clean. (Resolved within Task 1, before its commit.)

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- write joins browse (08-03) and read (08-03) as a completed verb; subscribe/pull/push/action (CLI-04..07) remain for later Phase 8 plans and can reuse the same `_resolveOrRaise` / `_normalizeType` / `_parseAnyInt` helpers and the subprocess+mock test pattern.
- No blockers.

## TDD Gate Compliance

Task 1 is `tdd="true"` with an analyze-only verify; its behavioral RED/GREEN proof is the Task 2 integration test (`test(08-04)` commit `95f84b1`) which exercises the implemented verb. A `feat(08-04)` commit (`d521f15`) precedes it. Structure follows the plan's task ordering (implementation as Task 1, subprocess proof as Task 2) rather than a file-level RED-first cycle.

---
*Phase: 08-dart-cli*
*Completed: 2026-07-04*

## Self-Check: PASSED

- FOUND: lib/src/cli/commands/write_command.dart
- FOUND: test/integration/cli_write_test.dart
- FOUND: .planning/phases/08-dart-cli/08-04-SUMMARY.md
- FOUND commit: d521f15 (Task 1 feat)
- FOUND commit: 95f84b1 (Task 2 test)
