---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
plan: 04
subsystem: api
tags: [ads, ams, tcp, codec, dart-typed-data, endianness, wire-protocol]

# Dependency graph
requires:
  - phase: 01-01
    provides: package scaffold (pubspec, analysis_options, dart_test.yaml, lib/dart_ads.dart barrel), test/support/hex.dart, committed golden .hex fixtures
provides:
  - AmsCommandId / AmsStateFlags / AmsPort / AdsIndexGroup / AdsDeviceDataOffset / AdsState / AdsError constants (authoritative, from AdsDef.h)
  - MalformedFrameException (framing error type, distinct from ADS device errors)
  - AmsNetId (6-byte value type) + AmsAddr (NetId + port) value type
  - AmsTcpHeader (6-byte wrapper) encode/decode codec
  - AmsHeader (32-byte AMS header) encode/decode codec
  - header round-trip + offset + anchor-byte unit tests
affects: [01-05 per-command codecs, 01-06 FrameAssembler, 01-07 CI grep gate, phase-02 transport]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Immutable header value class with encode()/decode() over ByteData.sublistView"
    - "Endian.little explicitly passed on every ByteData accessor"
    - "abstract final class namespaces of static const int for wire constants"
    - "Value types own an unmodifiable defensive copy (asUnmodifiableView) with value equality"

key-files:
  created:
    - lib/src/protocol/constants.dart
    - lib/src/protocol/exceptions.dart
    - lib/src/protocol/ams_net_id.dart
    - lib/src/protocol/ams_tcp_header.dart
    - lib/src/protocol/ams_header.dart
    - test/unit/ams_header_test.dart
  modified: []

key-decisions:
  - "AmsNetId rejects wrong-length input via MalformedFrameException (ties validation to the framing error hierarchy and threat T-1-VAL), not ArgumentError"
  - "Wire constants organized as abstract final class namespaces of static const int (AdsCommandId, AmsStateFlags, AdsIndexGroup, AdsError, AdsState) rather than top-level consts or enums"
  - "Header value classes carry value equality (==/hashCode) to make round-trip assertions and future dedup trivial"

patterns-established:
  - "Pattern 1: immutable header value class — typed fields, Uint8List encode(), decode(ByteData,[offset]) factory; all offset math localized"
  - "Pattern 2: Endian.little on every get/set accessor, enforced by a grep gate"
  - "Pattern 3: pure protocol subtree — dart:typed_data only, zero dart:async/dart:io"

requirements-completed: [PROTO-01]

# Metrics
duration: 12min
completed: 2026-07-03
---

# Phase 01 Plan 04: Protocol Core Types & Header Codecs Summary

**AMS/TCP (6B) + AMS (32B) header codecs with Endian.little on every accessor, AmsNetId/AmsAddr value types, and authoritative ADS constants — encoding byte-for-byte to the RESEARCH-verified anchor frame with full round-trip fidelity.**

## Performance

- **Duration:** ~12 min
- **Completed:** 2026-07-03
- **Tasks:** 3
- **Files created:** 6

## Accomplishments
- `constants.dart`: nine ADS command IDs, request/response state flags, AMS ports, symbol/device index groups, device-data offsets, ADS run states, and common ADS error codes — all transcribed verbatim from the vendored `AdsDef.h`.
- `exceptions.dart`: `MalformedFrameException` carrying a message plus optional `length`/`offset`, deliberately distinct from ADS protocol (device) errors.
- `ams_net_id.dart`: immutable `AmsNetId` (defensive unmodifiable 6-byte copy, byte constructor, `AmsNetId.parse` dotted-string factory, value equality) and `AmsAddr` (NetId + u16 port).
- `ams_tcp_header.dart` + `ams_header.dart`: the two fixed-layout codecs with `encode()`/`decode()` at every verified offset, `Endian.little` on every scalar accessor.
- `test/unit/ams_header_test.dart`: 17 tests — anchor encodes to the verified 32 bytes, AMS/TCP wrapper round-trip, full AMS-header field round-trip, offset-honoring decode, little-endian byte-order assertions, and AmsNetId round-trip/parse/rejection/equality.

## Task Commits

Each task was committed atomically (Task 3 followed the TDD RED→GREEN gate):

1. **Task 1: constants.dart + exceptions.dart** - `a6dbe5c` (feat)
2. **Task 2: ams_net_id.dart — AmsNetId + AmsAddr** - `c8bb269` (feat)
3. **Task 3 (RED): failing header + AmsNetId tests** - `dba16ca` (test)
4. **Task 3 (GREEN): AmsTcpHeader + AmsHeader codecs** - `9a4bdf8` (feat)

## Files Created/Modified
- `lib/src/protocol/constants.dart` - ADS command IDs, state flags, ports, index groups, device-data offsets, ADS states, error codes
- `lib/src/protocol/exceptions.dart` - `MalformedFrameException`
- `lib/src/protocol/ams_net_id.dart` - `AmsNetId` (6B) + `AmsAddr` value types
- `lib/src/protocol/ams_tcp_header.dart` - `AmsTcpHeader` 6-byte wrapper codec
- `lib/src/protocol/ams_header.dart` - `AmsHeader` 32-byte header codec
- `test/unit/ams_header_test.dart` - header round-trip/offset/anchor + AmsNetId behavior tests

## Decisions Made
- **NetId validation via `MalformedFrameException`** (not `ArgumentError`): aligns wrong-length rejection with the framing error hierarchy and threat T-1-VAL. The plan permitted either.
- **Constants as `abstract final class` namespaces** of `static const int` (Claude's discretion per CONTEXT): gives `AdsCommandId.readWrite`-style call sites, avoids top-level name collisions, and stays tree-shakeable.
- **Value equality on header classes**: makes the encode→decode round-trip assertions direct and supports future response/request de-duplication.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `UnmodifiableUint8ListView` removed in Dart 3**
- **Found during:** Task 2 (AmsNetId)
- **Issue:** The research-era idiom `UnmodifiableUint8ListView(copy)` no longer exists in the SDK (dev SDK 3.11.5); analyzer flagged `undefined_method`.
- **Fix:** Switched to the modern `Uint8List.asUnmodifiableView()` (available since Dart 3.3; within the `>=3.5.0` floor).
- **Files modified:** `lib/src/protocol/ams_net_id.dart`
- **Verification:** `dart analyze --fatal-infos` clean; the "`.bytes` view is unmodifiable" test passes.
- **Committed in:** `c8bb269` (Task 2 commit)

**2. [Rule 3 - Blocking] `dart format` non-compliance on `ams_tcp_header.dart`**
- **Found during:** Post-task wave verification
- **Issue:** The wrapped `operator ==` expression fit on one line; `dart format --set-exit-if-changed` (a CI gate per RESEARCH sampling) would have failed.
- **Fix:** Ran `dart format`; amended the GREEN commit with the reformatted file.
- **Files modified:** `lib/src/protocol/ams_tcp_header.dart`
- **Verification:** `dart format --output=none --set-exit-if-changed` clean across all touched files; endian grep gate re-checked and passes.
- **Committed in:** `9a4bdf8` (amended Task 3 GREEN commit)

---

**Total deviations:** 2 auto-fixed (both Rule 3 - blocking)
**Impact on plan:** Both were mechanical toolchain-compatibility fixes (SDK API rename, formatter compliance). No behavior changes, no scope creep.

## Issues Encountered
None beyond the two auto-fixed blocking issues above.

## Verification Results
- `dart analyze lib/src/protocol --fatal-infos` — clean.
- `dart test test/unit` — 21 tests pass (17 new in `ams_header_test.dart` + 4 pre-existing hex-support).
- Endian grep gate (`get/set(Uint|Int)(16|32|64)` lacking `Endian.little`) — zero hits in both header files.
- No `dart:async` / `dart:io` import statements anywhere in `lib/src/protocol/`.
- `dart format --set-exit-if-changed` — clean across all touched files.
- Anchor `AmsHeader` encodes to `c0a8000101015303c0a800640101419c010004000000000000000000 01000000` (offsets 6..37 of the verified 38-byte frame).

## Known Stubs
None. Every delivered type is fully implemented and exercised by tests.

## Next Phase Readiness
- The parity-critical header core is proven: plan 01-05 (per-command payload codecs) and plan 01-06 (FrameAssembler) can build directly on `AmsHeader`/`AmsTcpHeader`/`AmsNetId`.
- `AmsHeader.decode` reads fixed offsets only and never indexes past `byteLength` (threat T-1-03); the FrameAssembler in 01-06 owns the "enough bytes buffered" precondition.
- No blockers. The library barrel (`lib/dart_ads.dart`) intentionally stays export-free until the public surface is finalized in a later plan.

## Self-Check: PASSED

Created files verified present:
- lib/src/protocol/constants.dart — FOUND
- lib/src/protocol/exceptions.dart — FOUND
- lib/src/protocol/ams_net_id.dart — FOUND
- lib/src/protocol/ams_tcp_header.dart — FOUND
- lib/src/protocol/ams_header.dart — FOUND
- test/unit/ams_header_test.dart — FOUND

Commits verified in git log:
- a6dbe5c — FOUND
- c8bb269 — FOUND
- dba16ca — FOUND
- 9a4bdf8 — FOUND

---
*Phase: 01-protocol-framing-codecs-c-golden-frame-harness*
*Completed: 2026-07-03*
