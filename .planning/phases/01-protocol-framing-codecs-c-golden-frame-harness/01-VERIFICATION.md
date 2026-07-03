---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
verified: 2026-07-03T22:00:00Z
status: human_needed
score: 4/4 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Push branch to GitHub and confirm both CI jobs (dart matrix + integration) pass"
    expected: "Both 'dart' (ubuntu/macos/windows) and 'integration' (ubuntu) jobs go green"
    why_human: "GitHub Actions cannot run locally; requires a push to evaluate the hosted runners"
  - test: "Before pushing: update the CI endian gate grep to suppress false positives from doc comments and multi-line calls"
    expected: |
      The gate should not flag:
        (a) lib/src/protocol/range_check.dart line 4 — the pattern `setUint16(` appears in a doc comment, not an accessor call
        (b) lib/src/protocol/commands.dart line 268 — the call `bd.setUint32(` wraps onto two lines (Endian.little is on line 269); dart format split this call
      One fix: add `| grep -v '^\s*//'` to filter comment lines, and pipe to `grep -l` or switch to a multi-line-aware check.
      The code IS endian-correct; only the gate definition is broken.
    why_human: "Confirming CI passes requires a push; gate correctness is locally verifiable but the fix must be applied before pushing"
---

# Phase 1: Protocol Framing, Codecs & C++ Golden-Frame Harness — Verification Report

**Phase Goal:** The Dart wire codec encodes and decodes AMS/TCP + AMS frames that match reference C++ AdsLib output byte-for-byte, and the CMake test harness that produces those reference frames is online from day one.
**Verified:** 2026-07-03T22:00:00Z
**Status:** human_needed — all 4 success criteria met in the codebase; 2 human items block CI green (the Phase 2 gate)
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (Success Criteria)

| #   | Truth                                                                                                                | Status     | Evidence                                                                                                                  |
| --- | -------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------- |
| 1   | C++ mock/golden harness builds via CMake on macOS dev and emits reference frames to `test/golden/*.hex`             | VERIFIED   | `cmake --build test_harness/build` exits 0; both `dump_golden` and `mock_server` built; 12 `.hex` files present and non-empty; `dump_golden && git diff --exit-code test/golden` clean (goldens reproducible); `mock_server --selftest` → OK |
| 1b  | Linux CI leg                                                                                                         | HUMAN      | Cannot run locally — requires push (see Human Verification section)                                                       |
| 2   | Dart codec encodes AMS/TCP (6-byte) and AMS (32-byte) headers, all fields little-endian, byte-for-byte C++ parity   | VERIFIED   | `golden_parity_test.dart` "encode(request) == committed golden" group: all 6 commands pass; ReadDeviceInfo anchor = `000020000000c0a8000101015303c0a800640101419c01000400000000000000000001000000` (38 bytes, AMS/TCP length = 0x20); 50/50 suite green |
| 3   | Dart codec decodes golden response frames back to typed values, round-trip parity for encode AND decode              | VERIFIED   | `golden_parity_test.dart` "decode(golden response) == expected typed values" group: all 6 commands pass; typed fields (version/revision/build/name, adsState/deviceState, readLength/data) assert correct values; WR-06 corrected addressing verified |
| 4   | FrameAssembler reassembles a deliberately fragmented and coalesced golden byte stream; rejects max-frame guard       | VERIFIED   | `frame_assembler_test.dart`: fragmentation (1-byte feed), coalescing (2 frames in 1 chunk), mixed streams, max-frame guard (5 MiB → MalformedFrameException before allocation), minimum-length guard (length < 32 rejected), poison-after-frame deferred throw, truncation wait — all pass |

**Score:** 4/4 truths VERIFIED (Linux CI leg is a human verification item per context note)

---

### Required Artifacts

| Artifact                                          | Expected                                            | Status    | Details                                                                             |
| ------------------------------------------------- | --------------------------------------------------- | --------- | ----------------------------------------------------------------------------------- |
| `pubspec.yaml`                                    | `name: dart_ads`, SDK floor, dev deps only          | VERIFIED  | SDK `>=3.5.0 <4.0.0`; dev_dependencies: test ^1.31.0 + lints ^6.1.0; no runtime deps |
| `dart_test.yaml`                                  | Tags: unit/integration/golden                       | VERIFIED  | All 3 tags present; integration has `timeout: 30s`                                  |
| `.pubignore`                                      | Excludes test_harness/, third_party/, .planning/    | VERIFIED  | All three exclusions present                                                        |
| `third_party/ADS/AdsLib/AmsHeader.h`              | Vendored at pinned commit 57d63747                  | VERIFIED  | File exists; `git -C third_party/ADS rev-parse HEAD` = `57d63747271fca7881bec48417adb44876e67505` |
| `test/support/hex.dart`                           | `readGolden()` hex-fixture parser                   | VERIFIED  | Exports `Uint8List readGolden(String path)`; strips `#` comments + whitespace; throws FormatException on odd nibble count (WR-08) |
| `test_harness/CMakeLists.txt`                     | Self-owned CMake, VERSION 3.16, no add_subdirectory | VERIFIED  | `cmake_minimum_required(VERSION 3.16)`; lists Frame.cpp/Log.cpp/AdsDef.cpp/AmsNetId.cpp directly; `CONFIG_DEFAULT_LOGLEVEL=1`; no `add_subdirectory` directive |
| `test_harness/dump_golden.cpp`                    | AoEHeader/AmsTcpHeader + Frame::prepend, 12 goldens | VERIFIED  | Includes AmsHeader.h; uses `AoEHeader`/`AmsTcpHeader` structs; emits req+res for all 6 commands; WR-07 fixed (I/O errors propagate, exits 1 on failure) |
| `test/golden/*.hex` (12 files)                    | Byte-accurate reference frames committed            | VERIFIED  | 12 files present; anchor `read_device_info_req.hex` = `000020000000...01000000` (38B); WR-06 corrected: response goldens have swapped addressing; `dump_golden && git diff --exit-code` = clean |
| `test_harness/mock_server.cpp`                    | POSIX accept loop, LISTENING, fragment/coalesce     | VERIFIED  | Contains `LISTENING`; includes AmsHeader.h; handles `--fragment`, `--coalesce`, `--selftest`; POSIX `<sys/socket.h>`; CR-01 fixed (SIGPIPE ignored, EINTR retry); WR-05 fixed (4 MiB inbound guard); WR-06 fixed (response addressing inverted) |
| `lib/src/protocol/ams_tcp_header.dart`            | 6-byte wrapper codec, byteLength=6, Endian.little   | VERIFIED  | `static const int byteLength = 6`; `encode()` sets reserved u16=0 + length u32 LE; `decode()` reads length LE; all accessors use `Endian.little` |
| `lib/src/protocol/ams_header.dart`                | 32-byte AMS codec, byteLength=32, Endian.little     | VERIFIED  | `static const int byteLength = 32`; all 9 fields at correct offsets; `decode()` bounds-checked (WR-03 fixed); all scalars `Endian.little` |
| `lib/src/protocol/ams_net_id.dart`                | AmsNetId (6B) + AmsAddr value types                 | VERIFIED  | Byte ctor, dotted-string factory, `.bytes` getter, value equality, rejects != 6 bytes; AmsAddr couples NetId + port |
| `lib/src/protocol/constants.dart`                 | Command IDs, state flags, index groups, errors      | VERIFIED  | 9 command IDs (0x01..0x09 including ReadWrite 0x09); request 0x0004 / response 0x0005; AmsPort.plcTc3; no dart:async/dart:io |
| `lib/src/protocol/exceptions.dart`                | MalformedFrameException                             | VERIFIED  | `class MalformedFrameException implements Exception`; carries message, optional length+offset; no dart:async/dart:io |
| `lib/src/protocol/commands.dart`                  | 6 request encoders + 6 response decoders            | VERIFIED  | Sealed `AdsResponse` hierarchy; encoders compose AMS/TCP (6B) + AmsHeader (32B) + payload; AMS/TCP length = 32 + payload.length; all integer fields validated via `checkUint` (WR-04 fixed); response decoders validate readLength before slicing (T-1-03) |
| `lib/src/protocol/frame_assembler.dart`           | Stateful FrameAssembler, max-frame guard            | VERIFIED  | `class FrameAssembler`; default `maxFrameBytes = 4 * 1024 * 1024`; `List<Uint8List> add(Uint8List)`; rejects length < 32 (WR-02) or > maxFrameBytes (WR-01 deferred-throw semantics); no dart:async/dart:io |
| `lib/dart_ads.dart`                               | Public barrel exporting all protocol types          | VERIFIED  | Exports AmsNetId/AmsAddr, AmsTcpHeader, AmsHeader, sealed AdsResponse hierarchy + 6 encoders + 6 decoders, FrameAssembler, MalformedFrameException, 7 constant holders via `show` clauses |
| `.github/workflows/ci.yml`                        | 2-job CI; submodules recursive; cmake --build       | VERIFIED (with WARNING) | Valid YAML; 2 jobs: `dart` (matrix ubuntu/macos/windows) + `integration` (ubuntu); checkout with `submodules: recursive`; `cmake --build test_harness/build`; `mock_server --selftest`; `git diff --exit-code test/golden`; endian gate present — but gate has 2 false positives (see Human Verification #2) |
| `test/unit/golden_parity_test.dart`               | encode==golden AND decode(golden)==typed for 6 cmds | VERIFIED  | Both groups present; reads committed goldens via `readGolden()`; no Process/socket; asserts response addressing inversion (WR-06); 50/50 green |
| `test/unit/frame_assembler_test.dart`             | fragment/coalesce/guard/truncation adversarial tests| VERIFIED  | 5 adversarial cases (fragmentation, coalescing, mixed, max-frame guard, minimum-frame guard, poison-after-frame, truncation) using real golden bytes |

---

### Key Link Verification

| From                                         | To                                       | Via                                    | Status   | Details                                                     |
| -------------------------------------------- | ---------------------------------------- | -------------------------------------- | -------- | ----------------------------------------------------------- |
| `test/unit/hex_support_test.dart`            | `test/support/hex.dart`                  | import + `readGolden()` call           | VERIFIED | Pattern `readGolden(` present; test passes                  |
| `test_harness/dump_golden.cpp`               | `third_party/ADS/AdsLib/AmsHeader.h`     | `#include "AmsHeader.h"` + struct use  | VERIFIED | Include confirmed; `AoEHeader`/`AmsTcpHeader` used in emitters |
| `test_harness/CMakeLists.txt`                | `third_party/ADS/AdsLib/Frame.cpp` (+ 3) | Direct source listing in ads_framing   | VERIFIED | All 4 sources listed by path; no `add_subdirectory`         |
| `test_harness/mock_server.cpp`               | `third_party/ADS/AdsLib/AmsHeader.h`     | Include + inbound parse structs        | VERIFIED | Pattern `AmsHeader.h` + `AoEHeader(ptr)` construct-from-bytes |
| `test_harness/CMakeLists.txt`                | `mock_server` executable target          | `add_executable(mock_server ...)`      | VERIFIED | Target present; links `ads_framing`                         |
| `test/unit/golden_parity_test.dart`          | `test/golden/*.hex`                      | `readGolden()` comparisons             | VERIFIED | 12 `readGolden(...)` calls; byte-equal assertions           |
| `lib/src/protocol/commands.dart`             | `lib/src/protocol/ams_header.dart`       | `AmsHeader` + `AmsTcpHeader` compose   | VERIFIED | `_frame()` builds full wire frame using both codecs         |
| `lib/dart_ads.dart`                          | `lib/src/protocol/frame_assembler.dart`  | `export ... show FrameAssembler`       | VERIFIED | Export present; public_api_test.dart exercises it           |
| `.github/workflows/ci.yml`                   | `test_harness/CMakeLists.txt`            | `cmake --build test_harness/build`     | VERIFIED | Step present in integration job                             |

---

### Data-Flow Trace (Level 4)

Not applicable — this phase contains no components that render dynamic data from a remote source. The FrameAssembler is a synchronous push codec (input bytes → output frames); the golden parity tests consume static committed fixture files. There is no live fetch/query/store to trace.

---

### Behavioral Spot-Checks

| Behavior                                                       | Command                                                                         | Result                                                    | Status |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------- | --------------------------------------------------------- | ------ |
| CMake harness builds both binaries                             | `cmake -S test_harness -B test_harness/build && cmake --build test_harness/build` | All 3 targets (ads_framing, dump_golden, mock_server) built | PASS   |
| mock_server byte-accuracy selftest                             | `test_harness/build/mock_server --selftest`                                    | `OK` (exit 0)                                             | PASS   |
| Golden frames reproducible from source                         | `test_harness/build/dump_golden test/golden/ && git -C /Users/jonb/Projects/dart-ads diff --exit-code test/golden` | `goldens match` (exit 0, no diff)                         | PASS   |
| ReadDeviceInfo anchor byte match                               | `sed 's/#.*//' test/golden/read_device_info_req.hex \| tr -d '[:space:]'`        | `000020000000c0a8000101015303c0a800640101419c01000400000000000000000001000000` | PASS   |
| Full Dart unit suite (unit + golden parity, no integration)    | `dart test -x integration`                                                      | 50/50 passed                                              | PASS   |
| dart analyze clean                                             | `dart analyze --fatal-infos`                                                    | No issues found                                           | PASS   |
| dart format clean                                              | `dart format --output=none --set-exit-if-changed .`                             | 0 changed                                                 | PASS   |
| No dart:async/dart:io imports in protocol/                     | Grep import lines only                                                          | Only `dart:typed_data` imported; no dart:async/dart:io    | PASS   |
| Endian safety (code correctness)                               | Manual inspection of all accessor calls                                         | All `getUint`/`setUint` calls carry `Endian.little`       | PASS   |
| CI endian gate (grep-based, as written)                        | `grep -REn '(get\|set)(Uint\|Int\|Float)(16\|32\|64)\(' lib/src/protocol/ \| grep -v 'Endian.little'` | 2 false positives (doc comment + line-wrapped call)       | WARNING — see Human Verification #2 |

---

### Probe Execution

No `probe-*.sh` scripts declared or present. The `mock_server --selftest` probe is the closest equivalent and was run directly (see Behavioral Spot-Checks above → PASS).

---

### Requirements Coverage

| Requirement | Source Plan(s)     | Description                                                                                     | Status    | Evidence                                                                                 |
| ----------- | ------------------ | ----------------------------------------------------------------------------------------------- | --------- | ---------------------------------------------------------------------------------------- |
| PROTO-01    | 01-04, 01-05       | Library encodes/decodes AMS/TCP (6B) and AMS (32B) headers, all fields little-endian            | SATISFIED | `AmsTcpHeader` byteLength=6, `AmsHeader` byteLength=32; all accessors Endian.little; golden parity tests pass byte-for-byte for all 6 commands |
| PROTO-02    | 01-06              | Library reassembles complete AMS frames from fragmented/coalesced TCP stream, max-frame guard   | SATISFIED | `FrameAssembler.add()` accumulates across calls; emits each frame exactly once; 4 MiB guard + minimum 32B guard; adversarial test suite: fragment/coalesce/mixed/guard/truncation all pass |
| TEST-01     | 01-03, 01-07       | C++ mock ADS server built via CMake, responds with byte-accurate frames                         | SATISFIED | CMake build green; `mock_server --selftest` exits OK; WR-06 corrected response addressing; WR-05 inbound guard added; CR-01 SIGPIPE fixed |
| TEST-02     | 01-02, 01-05, 01-07| Golden-frame dump tool emits reference vectors; Dart codec tests assert encode AND decode parity | SATISFIED | 12 `.hex` goldens committed and reproducible from source; `golden_parity_test.dart` asserts encode==golden AND decode(golden)==typed for all 6 commands |
| TEST-04     | 01-03, 01-06       | Mock deliberately fragments and coalesces frames to exercise TCP stream reassembly               | SATISFIED | `mock_server` supports `--fragment N` (N-byte chunk sends) and `--coalesce` (buffered dual-frame emit); `frame_assembler_test.dart` proves Dart-side recovery using real golden bytes |

No orphaned requirements: REQUIREMENTS.md maps exactly PROTO-01, PROTO-02, TEST-01, TEST-02, TEST-04 to Phase 1. All 5 are SATISFIED.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| `lib/src/protocol/range_check.dart` | 4 | Doc comment containing `setUint16(0, 70000)` matches the CI endian gate grep | WARNING | False positive in CI endian gate grep — NOT an actual accessor; the grep does not filter comment lines |
| `lib/src/protocol/commands.dart` | 268 | `bd.setUint32(` split to 2 lines by `dart format`; `Endian.little` on line 269 | WARNING | False positive in CI endian gate grep — Endian.little IS present (line 269); the gate assumes one accessor per source line |

No TBD/FIXME/XXX markers. No TODO/HACK/PLACEHOLDER. No stub returns (`return null`, `return {}`, `return []`). No `dart:async` or `dart:io` imports in `lib/src/protocol/`.

The two anti-patterns above are false positives in the CI grep gate, not actual code defects. The code is endian-correct as proven by 50/50 green tests. However, they WILL cause the CI `dart` job to fail when pushed.

---

### Human Verification Required

#### 1. CI green on GitHub Actions (Phase 2 gate)

**Test:** Push branch to GitHub and confirm both CI jobs pass on the Actions tab.

**Expected:**
- `dart` job: analyze → format → endian gate → unit tests → green on ubuntu-latest, macos-latest, windows-latest
- `integration` job: checkout with submodules, cmake build, dump_golden reproducibility (git diff --exit-code), mock_server --selftest, full dart test suite → green on ubuntu-latest

**Why human:** GitHub Actions cannot be invoked locally. Every individual step has been verified locally (cmake build, selftest, golden reproducibility, dart analyze/format/test all pass), but the hosted runner matrix (especially macOS and Windows Dart + Linux apt toolchain) can only be confirmed on a real push.

#### 2. Fix CI endian gate before pushing (prerequisite for item 1)

**Test:** Update the CI endian gate grep in `.github/workflows/ci.yml` to eliminate the two false positives, then push.

**Expected:** After the fix, the gate step passes and does not flag the two identified false positives.

**Details of the two false positives (locally verified):**

Running the exact CI gate command locally:
```
grep -REn '(get|set)(Uint|Int|Float)(16|32|64)\(' lib/src/protocol/ | grep -v 'Endian.little'
```
produces:
```
lib/src/protocol/range_check.dart:4:/// the low bits (`setUint16(0, 70000)` writes 4464, `setUint16(0, -1)` writes
lib/src/protocol/commands.dart:268:  bd.setUint32(
```

(a) `range_check.dart:4` — the pattern appears inside a `///` doc comment illustrating what happens without range checks. It is not a ByteData accessor call. Fix: add `| grep -v '^\s*///'` to the pipeline to skip doc comment lines.

(b) `commands.dart:268` — the call `bd.setUint32(` was wrapped to two lines by `dart format`. `Endian.little` is present on line 269. The SUMMARY notes "assumes one accessor per line, which the codec observes" but the formatter split this specific call. Fix options: (i) keep the gate as-is and rewrite that one call to fit on one line, or (ii) replace the line-by-line grep with a multi-line-aware check (`grep -Pzo` or a small script).

**Why human:** Fixing the gate and confirming CI passes requires a push to trigger the runners.

---

### Gaps Summary

No blocking gaps. All four Success Criteria are met in the current codebase, with 50/50 Dart tests green and the macOS CMake harness fully operational. The two items in Human Verification are:

1. CI green on GitHub (the Phase 2 gate) — this is a standard push-gated check, not a code defect.
2. The CI endian gate has two false positives that must be fixed before pushing, or the `dart` matrix job will fail. The code itself is endian-correct. This is a one-line (or two-line) fix to the grep pipeline in `ci.yml`.

Both items are actionable and have clear resolution paths. They do not indicate incorrect encoding/decoding behavior or missing implementation.

---

_Verified: 2026-07-03T22:00:00Z_
_Verifier: Claude (gsd-verifier)_
