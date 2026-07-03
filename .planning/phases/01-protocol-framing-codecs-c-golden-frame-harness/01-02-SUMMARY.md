---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
plan: 02
subsystem: testing
tags: [cmake, cpp, ads, ams-tcp, golden-frames, beckhoff, fixtures]

# Dependency graph
requires:
  - phase: 01-01
    provides: Beckhoff/ADS vendored as a pinned submodule (commit 57d63747) with the 4-source build recipe verified
provides:
  - Self-owned CMake harness (test_harness/CMakeLists.txt) compiling AdsLib framing sources directly (3.16 floor, no add_subdirectory)
  - dump_golden C++ tool that layers AoEHeader + AmsTcpHeader via Frame::prepend to emit byte-authoritative frames
  - Twelve committed golden reference frames (req+res for ReadDeviceInfo/Read/Write/ReadState/WriteControl/ReadWrite)
  - The byte-exact 38-byte ReadDeviceInfo request anchor as the parity oracle for the Dart codec
affects: [01-05, dart-codec-parity, ci-integration-job, mock-server-01-03]

# Tech tracking
tech-stack:
  added: [CMake >=3.16, C++14, AppleClang/g++, Beckhoff AdsLib framing structs]
  patterns:
    - "Golden frames authoritative by construction: reuse AmsHeader.h #pragma pack(1) structs + Frame::prepend, never hand-typed"
    - "AMS/TCP wrapper length = 32 + payload (prepend AoEHeader then AmsTcpHeader{frame.size()})"
    - "Committed text-hex fixtures (# comments + lowercase hex) keep Dart unit tests hermetic (no C++ toolchain)"

key-files:
  created:
    - test_harness/CMakeLists.txt
    - test_harness/dump_golden.cpp
    - test/golden/read_device_info_req.hex
    - test/golden/read_device_info_res.hex
    - test/golden/read_req.hex
    - test/golden/read_res.hex
    - test/golden/write_req.hex
    - test/golden/write_res.hex
    - test/golden/read_state_req.hex
    - test/golden/read_state_res.hex
    - test/golden/write_control_req.hex
    - test/golden/write_control_res.hex
    - test/golden/read_write_req.hex
    - test/golden/read_write_res.hex
  modified: []

key-decisions:
  - "Response ADS payload bodies written as explicit LE scalars (AoEResponseHeader/AoEReadResponseHeader expose no value-setting ctor); the AMS/TCP + AMS headers still come from structs via Frame::prepend"
  - "Response stateFlags patched to 0x0005 after layering (AoEHeader ctor hardcodes AMS_REQUEST; upstream only ever builds requests)"
  - "Deterministic fixtures baked as constants: target 192.168.0.1.1.1:851, source 192.168.0.100.1.1:40001, invokeId 1"

patterns-established:
  - "Direct-source CMake compile of vendored AdsLib (Frame/Log/AdsDef/AmsNetId) with CONFIG_DEFAULT_LOGLEVEL=1"
  - "One frame per .hex file, leading #-comment naming the frame + fixture params"

requirements-completed: [TEST-02]

# Metrics
duration: 8min
completed: 2026-07-03
---

# Phase 01 Plan 02: C++ Golden-Frame Harness Summary

**CMake harness compiling vendored Beckhoff AdsLib framing sources directly, with a `dump_golden` tool that reuses AoEHeader/AmsTcpHeader + Frame::prepend to emit twelve byte-authoritative golden frames — ReadDeviceInfo request matching the verified 38-byte anchor exactly.**

## Performance

- **Duration:** ~8 min
- **Completed:** 2026-07-03
- **Tasks:** 3
- **Files modified:** 14 (2 harness sources + 12 golden fixtures)

## Accomplishments
- Self-owned `test_harness/CMakeLists.txt` builds `ads_framing` (STATIC) from exactly four AdsLib sources and links `dump_golden` — 3.16 floor, C++14, `CONFIG_DEFAULT_LOGLEVEL=1`, no `add_subdirectory` of upstream.
- `dump_golden.cpp` layers the 32-byte AMS header and 6-byte AMS/TCP wrapper with the reference `#pragma pack(1)` structs via `Frame::prepend`, so golden bytes are authoritative by construction.
- Twelve `test/golden/*.hex` fixtures (request + response for all six core commands) generated and committed; unit tests stay hermetic with no C++ toolchain needed.
- The ReadDeviceInfo request golden decodes byte-for-byte to the RESEARCH-verified anchor `000020000000c0a8000101015303c0a800640101419c01000400000000000000000001000000` (AMS/TCP length 0x20=32).

## Task Commits

Each task was committed atomically:

1. **Task 1: Self-owned CMakeLists building ads_framing + dump_golden** - `7fc7631` (feat)
2. **Task 2: dump_golden.cpp emitting six commands (request + response)** - `95d9fdc` (feat)
3. **Task 3: Build harness, generate + commit goldens, assert anchor** - `40edc09` (feat)

## Files Created/Modified
- `test_harness/CMakeLists.txt` - Direct-source CMake build of the four AdsLib framing sources into `ads_framing`; links `dump_golden`.
- `test_harness/dump_golden.cpp` - Reference-frame emitter; reuses AmsHeader.h structs + `Frame::prepend`; deterministic fixtures; argv[1] output dir (default `test/golden/`).
- `test/golden/*.hex` (12 files) - Byte-authoritative request+response frames for ReadDeviceInfo, Read, Write, ReadState, WriteControl, ReadWrite.

## Decisions Made
- **Response bodies as explicit LE scalars:** `AoEResponseHeader` / `AoEReadResponseHeader` only expose a default (all-zero) constructor or a `memcpy`-from-frame constructor — no way to set `result`/`readLength` to a chosen value. Since upstream never builds responses (it only parses them), response ADS payload bodies are written as explicit little-endian scalars via local `putU16`/`putU32` helpers. The parity-critical AMS/TCP + AMS headers are still produced by the structs through `Frame::prepend`.
- **Response stateFlags patched post-layering:** the `AoEHeader` constructor hardcodes `leStateFlags = AMS_REQUEST (0x0004)`. Response frames patch the single stateFlags field (absolute offset 24 = 6-byte wrapper + 18) to `AMS_RESPONSE (0x0005)` after serialization. Verified: every `*_res.hex` carries `0500`, every `*_req.hex` carries `0400`.
- **Deterministic fixtures** baked as constants so goldens are reproducible and git diffs are meaningful.

## Deviations from Plan

None - plan executed exactly as written.

The plan's Task 1 automated verify (`! grep -q 'add_subdirectory'`) initially tripped on a code comment that referenced the term in prose; the comment was reworded so the file contains no `add_subdirectory` token at all. This was a wording fix within the same task before its commit, not a functional deviation.

## Issues Encountered
- None. The harness compiled cleanly on macOS/AppleClang (validated via a throwaway scratchpad compile before committing the source, then again via the real CMake build in Task 3). `Frame` is move-only (unique_ptr member) but its implicit move constructor is generated, so returning `Frame` by value from the `payloadFrame` helper works under C++14.

## User Setup Required

None - no external service configuration required. The build depends only on CMake >=3.16 and a C++14 compiler, both present on the dev machine (and installed in the CI integration job).

## Next Phase Readiness
- The golden fixtures are the trusted parity oracle for the Dart codec unit tests in plan 01-05 (TEST-02).
- The `test_harness/` CMake project is ready for plan 01-03 to add the `mock_server` target alongside `dump_golden` (the two share the `ads_framing` static lib).
- No blockers. `test_harness/build/` is gitignored; only source + fixtures are committed.

## Self-Check: PASSED

All 14 created files verified present on disk; all 4 commits (7fc7631, 95d9fdc, 40edc09, 0d2ee2f) verified in git log.

---
*Phase: 01-protocol-framing-codecs-c-golden-frame-harness*
*Completed: 2026-07-03*
