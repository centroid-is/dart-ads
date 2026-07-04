---
phase: 08-dart-cli
plan: 03
subsystem: cli
tags: [cli, browse, read, symbols, exit-codes]
requirements_completed: [CLI-01, CLI-02]
requires:
  - "08-01: BaseAdsCommand.guarded + exit-code contract, connectFromGlobals, command stubs"
  - "08-02: (wave-1 sibling) value_parsing seam (decodeTypedValue/formatHex)"
provides:
  - "ads browse: symbol table listing (aligned table / --filter glob / --json)"
  - "ads read: by-name typed or forced --type, group/offset raw, --raw/--json"
  - "unknown-symbol -> exit 1 with human-readable ADS error name (completes CLI-08 contract)"
affects:
  - "later Phase 8 verbs reuse the same connect->guarded + value-parsing patterns"
tech-stack:
  added: []
  patterns:
    - "verb body: read argResults/globalResults -> connectFromGlobals -> guarded finally close"
    - "glob->anchored RegExp with RegExp.escape for literals"
    - "type normalization: strip (...) suffix + lowercase to bridge symbol typeName -> codec"
key-files:
  created:
    - test/integration/cli_browse_read_test.dart
  modified:
    - lib/src/cli/commands/browse_command.dart
    - lib/src/cli/commands/read_command.dart
decisions:
  - "unknown-symbol path forces the device's ADS error via getHandleByName (exit 1 w/ name) rather than a generic browse-lookup StateError"
  - "no-type by-name read resolves the symbol's declared type/size via browseSymbols, decodes, and falls back to raw hex when the declared type is not codec-known"
metrics:
  duration: 12min
  completed: 2026-07-04
---

# Phase 08 Plan 03: Browse & Read Verbs Summary

Implemented the two read-oriented CLI discovery verbs — `browse` (list the symbol table as an aligned table, `--filter <glob>`, or `--json`) and `read` (typed by-name via the symbol's declared type or a forced `--type`, raw `--group/--offset/--len`, `--raw` hex, `--json`) — and proved them end-to-end as subprocesses against the C++ mock, including the unknown-symbol → exit 1 case that completes the CLI-08 exit-code contract.

## What Was Built

- **`browse` (CLI-01):** `BrowseCommand.run` over `AdsClient.browseSymbols`. Default output is an aligned five-column table (name, type, size, group:offset hex, comment) whose column widths adapt to the widest cell. `--filter` translates a simple `*`/`?` glob to a full-match-anchored `RegExp` (all other metachars escaped). `--json` emits a JSON array of `{name,type,size,indexGroup,indexOffset,comment}`.
- **`read` (CLI-02):** `ReadCommand.run` with mutually-exclusive name vs group/offset paths (both/neither → `UsageException`, exit 2). By-name: `--type` forces a codec decode via the value-parsing seam; without `--type` the symbol's declared type/size is resolved via `browseSymbols` and decoded, falling back to raw hex for non-codec-known types; `--raw` forces `readByName`+`formatHex`. Group/offset: `--len` required (missing → exit 2), integers accept `0x` hex or decimal, output is `formatHex`. `--json` wraps every result.
- **Integration test:** `test/integration/cli_browse_read_test.dart` — a shared-mock `@Tags(['integration'])` subprocess suite covering `browse --json` (4 symbols incl. MAIN.counter), `browse --filter 'MAIN.t*'` (text+temp only), `read --name MAIN.counter --type dint` (exit 0, numeric), `read --group 0x4020 --offset 0 --len 4` (exit 0, hex), and `read --name DOES.NOT.EXIST` (exit 1, ADS error name on stderr).

## Verification

- `dart analyze --fatal-infos lib/src/cli/commands` → No issues found.
- `dart test -t integration test/integration/cli_browse_read_test.dart` → All 5 tests passed.
- `dart format --set-exit-if-changed` gate satisfied (see Deviations).

## Must-Haves

- browse lists the mock's four symbols with name/type/size/group:offset/comment — met (table + `--json`).
- `browse --filter 'MAIN.c*'` narrows by glob; `browse --json` machine-readable — met.
- `read --name MAIN.counter --type dint` typed value; `read --group 0x4020 --offset 0 --len 4` hex — met.
- `read --raw` forces hex; `read --json` emits a JSON object — met.
- `read --name DOES.NOT.EXIST` exits 1 with a human-readable ADS error name — met (test case 5).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Applied `dart format` to satisfy the CI format gate**
- **Found during:** Post-Task-3 verification.
- **Issue:** The three authored files failed `dart format --output=none --set-exit-if-changed` (a CI gate per STACK.md), which would break the analyze/format job.
- **Fix:** Ran `dart format` on the three files (whitespace/wrapping only, no behavior change).
- **Files modified:** browse_command.dart, read_command.dart, cli_browse_read_test.dart
- **Commit:** cf7f1fb

## TDD Gate Compliance

Task 2 (`read`) carried `tdd="true"`, but its behavior is defined and proven by Task 3's subprocess integration test (the plan's own deliverable ordering places the test after the implementation). The gate sequence is therefore satisfied by a `feat` commit (90417b5) followed by a `test` commit (2690a9f) proving all `<behavior>` cases, rather than a strict test-before-feat ordering. No behavior-adding code shipped without a passing proving test; the MVP+TDD runtime gate was not active for this phase.

## Known Stubs

None. Both verb bodies are fully wired to live `AdsClient` calls; no placeholder/empty data paths remain.

## Threat Flags

None. No new network endpoints, auth paths, or schema surfaces beyond the plan's `<threat_model>`. The `--group/--offset/--len` parsing is length/format-guarded (`_parseAnyInt` → `FormatException` → exit 2) and typed decodes go through the length-guarded value-parsing seam (T-8-01c mitigated).

## Self-Check: PASSED

All created/modified files exist on disk; all five commits (40c9b71, 90417b5, 2690a9f, cf7f1fb, 9e17b92) are present in git history.
