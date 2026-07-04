---
phase: 08-dart-cli
plan: 06
subsystem: cli
tags: [cli, pull, push, sum-commands, snapshot, lossless]
requirements_completed: [CLI-05, CLI-06]
requires:
  - "AdsClient.sumRead / sumWrite (Phase 6)"
  - "browseSymbols (Phase 7)"
  - "CLI connect->guarded backbone + value_parsing (08-01)"
provides:
  - "ads pull: browse + sumRead -> lossless dart-ads/pull/1 JSON snapshot"
  - "ads push: snapshot -> sumWrite with --dry-run + per-item pass/fail report"
affects:
  - "lib/src/cli/commands/pull_command.dart"
  - "lib/src/cli/commands/push_command.dart"
tech_stack:
  added: []
  patterns:
    - "Lossless 0x-hex value encoding makes a pull snapshot a byte-for-byte valid push input"
    - "Untrusted snapshot parsed + validated inside guarded() BEFORE any connect (exit 2, never crash)"
key_files:
  created:
    - "test/integration/cli_pull_push_test.dart"
  modified:
    - "lib/src/cli/commands/pull_command.dart"
    - "lib/src/cli/commands/push_command.dart"
decisions:
  - "Snapshot schema dart-ads/pull/1: header {schema, generatedAt, target, symbols[]}; each symbol carries name/type/size/indexGroup/indexOffset and (with --values) value(0x-hex)/ok/error"
  - "push skips value-less items (symbols-only pull or failed-read item) — nothing to write"
  - "item-count cap _maxItems=100000 bounds a hostile huge symbols array (T-8-09)"
metrics:
  duration: 6min
  tasks: 3
  files: 3
  completed: 2026-07-04
---

# Phase 08 Plan 06: Pull/Push Snapshot-and-Apply Summary

The batched whole-PLC verb pair — `pull` browses the symbol table and (with
`--values`) sum-reads every value into a lossless `dart-ads/pull/1` JSON
snapshot; `push` reads that file back and sum-writes the values with a
`--dry-run` preview and a per-item pass/fail report — proving the sum-read /
sum-write path end-to-end and the project's headline lossless round-trip.

## What Was Built

- **Task 1 — `pull`** (`pull_command.dart`): connect -> `browseSymbols()` ->
  optional `--filter` glob -> ONE `sumRead` over all symbols when `--values` ->
  each value attached as lossless `formatHex` plus per-item `ok`/`error`.
  Documented schema header; writes to `--out <file>` or stdout via pretty JSON.
- **Task 2 — `push`** (`push_command.dart`): parses + validates the untrusted
  `--in` snapshot inside `guarded()` (schema tag, `symbols` is a list, per-item
  int fields, `parseHex(value)` bounded to declared `size`, item-count cap) so a
  malformed/hostile file exits 2 without crashing or dialing. `--dry-run` lists
  intended writes and touches nothing; otherwise ONE `sumWrite`, a per-item
  OK/FAIL report, and exit 1 if any item failed (SUM-04, never throws the batch).
- **Task 3 — integration test** (`cli_pull_push_test.dart`): 5 subprocess cases —
  snapshot shape/4-hex-values, `--dry-run` no-op, lossless pull->push->pull
  round-trip with all-pass report, malformed-JSON->2, non-hex-value->2.

## Verification

- `dart analyze --fatal-infos lib/src/cli/commands` — clean.
- `dart test -t integration test/integration/cli_pull_push_test.dart` — 5/5 pass.

## Threat Model Coverage

- **T-8-02** (hostile snapshot): jsonDecode + schema/shape validation guarded ->
  FormatException (exit 2); `parseHex` bounded to declared `size`.
- **T-8-08** (wrong values pushed): `--dry-run` preview; per-item report; exit 1
  on any failed item (failures never silent).
- **T-8-09** (huge hostile array): `_maxItems` cap before batching; one bounded
  sumWrite round-trip.
- **T-8-SC**: no new packages.

## Deviations from Plan

None — plan executed as written. (Mock value store is connection-scoped, so the
round-trip is proven across subprocesses via the deterministic per-connection
seed: pull1 and pull3 both read the fresh seed and push writes those seed bytes
back all-pass — noted in the test's header comment.)

## Self-Check: PASSED

- FOUND: lib/src/cli/commands/pull_command.dart
- FOUND: lib/src/cli/commands/push_command.dart
- FOUND: test/integration/cli_pull_push_test.dart
- FOUND commit 5249b3e (pull), 23582bc (push), bf8f0d2 (test)
