---
phase: 07-symbol-access-browse-typed-values
plan: 02
subsystem: protocol
tags: [codec, typed-values, iec61131, string, wstring, little-endian]
requirements_completed: [SYM-03, SYM-04]
dependency_graph:
  requires: []
  provides:
    - "value_codec.dart: pure LE scalar + STRING/WSTRING encode/decode"
  affects:
    - "AdsClient typed convenience methods (future plan) delegate to this codec"
tech_stack:
  added: []
  patterns:
    - "ByteData.sublistView + explicit Endian.little on every accessor"
    - "checkUint/checkInt-style fail-fast range guards (no silent truncation)"
    - "latin1 codec for single-byte STRING; UTF-16LE u16 loop for WSTRING"
key_files:
  created:
    - lib/src/protocol/value_codec.dart
    - test/unit/value_codec_test.dart
  modified: []
decisions:
  - "decodeWString uses ByteData+Endian.little (not host-endian Uint16List.sublistView) for guaranteed LE on all platforms"
  - "Added a signed-range _checkInt guard so SINT/INT/DINT fail fast rather than silently truncate (mirrors existing checkUint convention)"
metrics:
  duration: 6min
  completed: 2026-07-04
  tasks: 2
  files: 2
---

# Phase 7 Plan 02: Typed Value Codec Summary

Pure, stateless little-endian codec (`value_codec.dart`) mapping every Phase-7
IEC 61131 scalar (BOOL…LREAL) plus TwinCAT STRING (fixed Latin-1, NUL-padded)
and WSTRING (UTF-16LE, 0x0000-terminated) to/from bytes, with overflow throwing
`ArgumentError` and the raw `Uint8List` escape hatch (SYM-04) documented.

## What Was Built

- **Scalars (all `Endian.little`):** `encode/decode` for BOOL(1), BYTE/USINT(1
  unsigned), SINT(1 signed), WORD/UINT(2), INT(2 signed), DWORD/UDINT(4),
  DINT(4 signed), REAL(f32), LREAL(f64). BOOL decodes `byte != 0`, encodes 1/0.
- **STRING:** `encodeString(value, size)` writes Latin-1 into a fixed-size
  zero-filled (NUL-padded) buffer; `decodeString(buf)` returns Latin-1 up to the
  first NUL. Content that leaves no room for the terminator throws
  `ArgumentError` — never truncates into a fixed PLC buffer (T-7-03).
- **WSTRING:** `encodeWString(value, sizeBytes)` writes UTF-16LE code units +
  `0x0000` terminator, padded; `decodeWString(buf)` reads u16 LE units stopping
  at the first `0x0000`. Overflow throws `ArgumentError`.
- **SYM-04 escape hatch:** documented in the library doc-comment — there is
  intentionally no "raw" codec; not calling a codec leaves bytes untouched, and
  the codec never gates on `dataTypeId`.
- Pure: imports only `dart:typed_data` + `dart:convert`. Not barrel-wired
  (Plan 05 owns the barrel).

## Verification

- `dart analyze --fatal-infos lib/src/protocol/value_codec.dart` → No issues.
- `dart analyze --fatal-infos test/unit/value_codec_test.dart` → No issues.
- `dart test test/unit/value_codec_test.dart` → 18 tests, all pass.
- `dart format` clean on both files.

## Deviations from Plan

### Auto-fixed / adjusted

**1. [Rule 1 - Correctness] decodeWString uses ByteData + explicit Endian.little**
- **Found during:** Task 1
- **Issue:** The plan suggested `Uint16List.sublistView`, which reads u16 units
  in *host* endianness — non-deterministic on a hypothetical big-endian host and
  contrary to the project convention "always pass `Endian.little` explicitly."
- **Fix:** Read each u16 via `ByteData.getUint16(i*2, Endian.little)`; assemble
  code units with `String.fromCharCodes`. Byte-exact and platform-independent.
- **Files modified:** lib/src/protocol/value_codec.dart
- **Commit:** cdb9f16

**2. [Rule 2 - Missing critical functionality] Signed-range fail-fast guard**
- **Found during:** Task 1
- **Issue:** `range_check.dart` provides `checkUint` but no signed equivalent,
  and `ByteData.setInt8/16/32` silently truncate out-of-range input — the exact
  byte-corruption failure mode the project explicitly guards against.
- **Fix:** Added a private `_checkInt(value, bits, name)` mirroring `checkUint`,
  applied to SINT/INT/DINT encoders. (`checkUint` reused for unsigned types.)
- **Files modified:** lib/src/protocol/value_codec.dart
- **Commit:** cdb9f16

## Known Stubs

None. All functions are fully implemented; no placeholder/empty-return paths.

## Threat Flags

None. Surface matches the plan's `<threat_model>`; T-7-03 (STRING/WSTRING
overflow) is mitigated by `ArgumentError` on both encoders.

## Self-Check: PASSED

- FOUND: lib/src/protocol/value_codec.dart
- FOUND: test/unit/value_codec_test.dart
- FOUND commit: cdb9f16 (feat — codec)
- FOUND commit: 539d53e (test — codec tests)
