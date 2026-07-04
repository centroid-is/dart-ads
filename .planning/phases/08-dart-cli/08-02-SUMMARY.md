---
phase: 08-dart-cli
plan: 02
subsystem: cli
tags: [cli, parsing, security, value-codec, hex]
requirements_completed: [CLI-02, CLI-03]
requires:
  - lib/src/protocol/value_codec.dart
provides:
  - "CLI value/hex parsing seam: parseHex, formatHex, encodeTypedValue, decodeTypedValue"
affects:
  - 08-03 (read verb)
  - 08-04 (write verb)
tech_stack:
  added: []
  patterns:
    - "Untrusted-input seam normalizes all hostile input to FormatException (T-8-01)"
    - "Explicit u8/u16/u32/i8/i16/i32 range checks before encode; length guard before decode"
key_files:
  created:
    - lib/src/cli/value_parsing.dart
    - test/cli/value_parsing_test.dart
  modified: []
decisions:
  - "Parser does its own range checks throwing FormatException rather than relying on the codec's ArgumentError; codec ArgumentError is also caught and normalized to FormatException as defense in depth."
  - "BOOL accepts true/false/1/0 (case-insensitive); decode displays true/false."
  - "STRING/WSTRING require an explicit size (symbol's declared byte size) or throw FormatException."
metrics:
  duration: 6min
  completed: 2026-07-04
  tasks: 2
  files: 2
---

# Phase 8 Plan 02: CLI value + hex parsing seam Summary

Type-name <-> value_codec bridge plus `--raw` hex parse/format, built TDD-first so
the CLI's primary untrusted-input surface provably surfaces every hostile input as
a clean `FormatException` (exit 2) instead of an isolate crash or a RangeError
leaking from a fixed-size codec (threat T-8-01).

## What Was Built

- `parseHex(String) -> Uint8List` — optional `0x`/`0X` prefix, whitespace-tolerant,
  requires even nibble count; empty/bare-prefix yields empty buffer; malformed hex
  (non-hex chars, odd length) throws `FormatException`.
- `formatHex(Uint8List) -> String` — lower-case, `0x`-prefixed, round-trips with
  `parseHex`.
- `encodeTypedValue(String typeName, String raw, {int? size}) -> Uint8List` —
  case-insensitive dispatch to the value_codec encoder for
  bool/byte/sint/word/int/dword/dint/real/lreal/string/wstring. Explicit range
  checks (u8/u16/u32/i8/i16/i32) throw `FormatException` before encoding (no silent
  truncation). STRING/WSTRING require `size`. Unknown type -> `FormatException`.
- `decodeTypedValue(String typeName, Uint8List bytes) -> String` — dispatches to the
  decoder and returns a display string. Buffer length is guarded BEFORE the codec
  runs, so a short buffer throws `FormatException` rather than letting a `RangeError`
  escape.

Pure (`dart:typed_data` only, no `dart:io`); all scalar conversion delegated to
`lib/src/protocol/value_codec.dart` as the single source of truth.

## TDD Gate Compliance

- RED: `test(08-02)` commit `ab019a4` — 44 tests failing (seam did not exist).
- GREEN: `feat(08-02)` commit `2d7ab07` — all 44 tests passing.
- REFACTOR: none needed (implementation clean on first pass; `dart format` applied
  in the GREEN commit).

## Verification

- `dart test test/cli/value_parsing_test.dart` — 44/44 passing, including every
  hostile-input case asserting `FormatException`.
- `dart analyze --fatal-infos lib/src/cli/value_parsing.dart` — No issues found.
- `dart format` applied to both files.

## Threat Model

- **T-8-01 (mitigate):** Satisfied. Bad hex, non-numeric/out-of-range ints,
  non-numeric reals, unknown types, missing STRING/WSTRING size, and short decode
  buffers all throw `FormatException`. Range checks run before encode; length guard
  runs before decode. The codec's `ArgumentError` (range/overflow) and any residual
  `RangeError` are also caught and normalized to `FormatException` as defense in
  depth — nothing but `FormatException` escapes the seam.
- **T-8-01b (accept):** Unchanged — no unbounded allocation; buffers bounded by the
  caller-supplied declared size.

## Deviations from Plan

None - plan executed exactly as written.

## Self-Check: PASSED

- FOUND: lib/src/cli/value_parsing.dart
- FOUND: test/cli/value_parsing_test.dart
- FOUND commit: ab019a4 (RED)
- FOUND commit: 2d7ab07 (GREEN)
