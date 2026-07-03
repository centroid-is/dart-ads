---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
plan: 05
subsystem: protocol
tags: [ads, ams, codec, golden-parity, typed-data, sealed-classes]

# Dependency graph
requires:
  - phase: 01-04
    provides: AmsHeader (32B), AmsTcpHeader (6B), AmsNetId/AmsAddr, protocol constants
  - phase: 01-02
    provides: twelve committed C++ golden reference frames (test/golden/*.hex)
  - phase: 01-01
    provides: readGolden() hex fixture parser (test/support/hex.dart)
provides:
  - Per-command request encoders for the six core ADS commands (ReadDeviceInfo, Read, Write, ReadState, WriteControl, ReadWrite)
  - Sealed AdsResponse hierarchy with typed per-command response decoders
  - Byte-for-byte encode parity + decode parity validated against the C++ goldens
affects: [transport, commands, notifications, sum-commands, symbols, cli]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sealed AdsResponse base + final subclasses for exhaustive switch over response variants"
    - "Top-level encode*/decode* functions taking AmsAddr target/source + invokeId"
    - "Length-before-slice validation on variable-length response payloads (T-1-03)"

key-files:
  created:
    - lib/src/protocol/commands.dart
    - test/unit/golden_parity_test.dart
  modified: []

key-decisions:
  - "Modeled response variants as a sealed AdsResponse class hierarchy (not records) for exhaustive switch handling in later phases"
  - "Encoders take AmsAddr target/source + invokeId as parameters (no hardcoded fixture identities) so the same codec drives production and golden tests"
  - "Read/ReadWrite decoders defensively copy the sliced data so returned bytes never alias the source buffer"

patterns-established:
  - "Every multi-byte ByteData accessor passes Endian.little explicitly (grep-gated)"
  - "Full frame = AmsTcpHeader(length = 32 + payload) ++ AmsHeader(dataLength = payload) ++ payload"
  - "Response decoders consume the ADS payload (bytes after the 32-byte AMS header) and return typed values"

requirements-completed: [PROTO-01, TEST-02]

# Metrics
duration: 14min
completed: 2026-07-03
---

# Phase 01 Plan 05: Per-Command Codecs & Golden Parity Summary

**Six ADS command encoders/decoders (sealed AdsResponse hierarchy) proven byte-for-byte identical to the reference C++ goldens in both directions.**

## Performance

- **Duration:** 14 min
- **Started:** 2026-07-03T18:00:00Z
- **Completed:** 2026-07-03T18:14:00Z
- **Tasks:** 2
- **Files modified:** 2 (both created)

## Accomplishments
- `commands.dart`: request encoders + response decoders for all six core commands (ReadDeviceInfo, Read, Write, ReadState, WriteControl, ReadWrite), composing full on-wire frames (6B AMS/TCP wrapper + 32B AMS header + ADS payload) with `AmsTcpHeader.length = 32 + payload` and `AmsHeader.dataLength = payload`.
- Sealed `AdsResponse` hierarchy (`ReadDeviceInfoResponse`, `ReadResponse`, `WriteResponse`, `ReadStateResponse`, `WriteControlResponse`, `ReadWriteResponse`) with typed fields.
- `golden_parity_test.dart`: for each of the six commands, `encode(request) == readGolden(..._req.hex)` byte-for-byte AND `decode(readGolden(..._res.hex))` yields the exact typed values dump_golden baked. 12 assertions, hermetic (no Process, no socket).
- Threat T-1-03 mitigated: Read/ReadWrite decoders validate declared `readLength` against bytes present before slicing, throwing `MalformedFrameException` on overrun.

## Task Commits

Each task was committed atomically:

1. **Task 1: commands.dart — request encoders + response decoders** - `2d21453` (feat)
2. **Task 2: golden_parity_test.dart — encode==golden AND decode(golden)==typed** - `88422a4` (test)

_Note: Task 1 was marked `tdd="true"`; see TDD Gate Compliance below for the feat-before-test ordering rationale._

## Files Created/Modified
- `lib/src/protocol/commands.dart` - Per-command request encoders + sealed AdsResponse decoders for the six core ADS commands; pure `dart:typed_data` + protocol imports only.
- `test/unit/golden_parity_test.dart` - Golden round-trip parity: encode==golden and decode(golden)==typed for all six commands (tagged `unit`, `golden`).

## Decisions Made
- Sealed `AdsResponse` base with `final` subclasses (over records) to enable exhaustive `switch` handling as the command surface grows in later phases.
- Encoders parameterize target/source `AmsAddr` + `invokeId` rather than baking fixture identities, so the same code path serves both the golden tests and future live transport.
- Variable-length response data is defensively copied (`Uint8List.fromList(sublist(...))`) so callers never receive a view aliasing the parse buffer.

## Deviations from Plan

None - plan executed exactly as written. (A routine `dart format` pass was applied to both new files before their commits to satisfy the CI format gate; this is standard hygiene, not a behavioral deviation.)

## TDD Gate Compliance

Task 1 carries `tdd="true"`, but the plan deliberately decomposes the work as Task 1 = `commands.dart` (verified by `dart analyze --fatal-infos` + the endian grep gate, with the note "Full golden-parity assertions run in Task 2") and Task 2 = `golden_parity_test.dart` (verified by `dart test`). The plan's per-task verification gates therefore prescribe an implementation-first, test-immediately-after flow — the golden parity test cannot meaningfully reach a RED state without both `commands.dart` and the committed goldens in place. Consequently the git log shows `feat(01-05)` (2d21453) before `test(01-05)` (88422a4). This ordering follows the plan's explicit task structure; the golden test is the definitive RED→GREEN validation and is green on first run against the byte-authoritative C++ fixtures.

## Issues Encountered
None. All 12 golden-parity assertions passed on first run; the full unit suite (33 tests) is green.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- PROTO-01 (encode + decode) and TEST-02 (golden parity both directions) are proven byte-for-byte against the reference C++ AdsLib output — the codec foundation is validated before any socket code exists.
- Ready for the transport phase: the encoders produce complete, correct on-wire frames and the sealed `AdsResponse` decoders are ready to consume real responses read off a socket.

## Self-Check: PASSED

- Files verified present: `lib/src/protocol/commands.dart`, `test/unit/golden_parity_test.dart`, `01-05-SUMMARY.md`
- Commits verified in history: `2d21453` (feat), `88422a4` (test), `acbd9ee` (docs)

---
*Phase: 01-protocol-framing-codecs-c-golden-frame-harness*
*Completed: 2026-07-03*
