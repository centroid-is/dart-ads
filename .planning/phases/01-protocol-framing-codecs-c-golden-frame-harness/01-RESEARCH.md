# Phase 1: Protocol Framing, Codecs & C++ Golden-Frame Harness - Research

**Researched:** 2026-07-03
**Domain:** Binary wire-protocol codec (Beckhoff AMS/TCP) in pure Dart + a C++/CMake golden-frame harness vendoring Beckhoff/ADS
**Confidence:** HIGH (wire layouts, struct packing, and the C++ build recipe were verified hands-on this session by cloning Beckhoff/ADS at a pinned commit and compiling a working golden dumper on macOS/AppleClang that emitted a byte-exact ReadDeviceInfo frame)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Repo & Package Layout**
- Package name: `dart_ads` (matches repo name; valid pub.dev lowercase_with_underscores style)
- C++ harness lives in `test_harness/` at the repo top level (CMakeLists + mock server + golden dumper), excluded from the published package via `.pubignore`
- Beckhoff/ADS vendored as a git submodule pinned to a specific commit (reproducible, updatable, no license duplication)
- Dart SDK floor: `>=3.5.0 <4.0.0` (sealed classes/records available, wide compatibility)

**Codec API Design**
- Headers as immutable value classes (`AmsTcpHeader`, `AmsHeader`) with `encode()` methods and `decode()` factories — testable and self-documenting over raw ByteData views
- FrameAssembler is a pure synchronous push API: `add(Uint8List)` → emits complete frames; zero `dart:async`/`dart:io` imports anywhere in the `protocol/` subtree so it is unit-testable in complete isolation
- Max-frame guard defaults to 4 MiB, configurable (generous enough for symbol uploads, blocks OOM on corrupt length fields)
- Malformed frames throw typed exceptions (e.g. `MalformedFrameException`), distinct from ADS protocol errors

**Golden-Frame Harness & CI Scope**
- Phase 1 C++ deliverables: golden-frame dumper (`dump_golden`) emitting reference request/response byte vectors, PLUS a minimal mock server binary that answers ReadDeviceInfo and supports configurable fragment/coalesce modes; the mock's command table grows in later phases
- Golden files are text hex: `test/golden/*.hex`, one frame per file, `#` comments allowed — human-diffable and git-friendly
- CMake compiles AdsLib sources directly from the pinned submodule into the harness targets (C++14, CMake >= 3.16) rather than depending on upstream's own build system
- CI set up in this phase: GitHub Actions with 2 jobs — fast Dart analyze/format/unit-test job (all platforms) and a Linux integration job that builds the CMake harness. Phase 2 is gated on this CI being green.

### Claude's Discretion
- Exact file naming within `lib/src/protocol/`, constant organization, and test file structure
- Which specific commands get golden frames in Phase 1 (minimum: ReadDeviceInfo request+response; more is better)
- Hex file parsing helper design for tests

### Deferred Ideas (OUT OF SCOPE)
- None — discussion stayed within phase scope.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PROTO-01 | Encode/decode the AMS/TCP header (6-byte: reserved u16 + length u32) and the 32-byte AMS header, all fields little-endian | Exact struct byte layout verified from `AmsHeader.h` (`AmsTcpHeader`, `AoEHeader`); byte-exact golden frame reproduced via compiled C++ dumper (see Code Examples). Every field offset and endianness documented in Byte Layouts. |
| PROTO-02 | Reassemble complete AMS frames from a fragmented/coalesced TCP byte stream via a stateful frame assembler (with a max-frame guard) | Length-prefix algorithm verified against upstream `AmsConnection::Receive`; max-frame guard pattern documented; FrameAssembler is a pure sync push API per locked decision. |
| TEST-01 | A C++ mock ADS server built via CMake (vendored Beckhoff/ADS) responds with byte-accurate ADS frames | Minimal source set + include dirs + one compile define verified to build on macOS/AppleClang this session; mock accept-loop design + AdsLib framing reuse documented. |
| TEST-02 | A golden-frame dump tool emits reference request/response byte vectors, and Dart codec unit tests assert encode AND decode parity | `dump_golden` recipe compiled and run this session producing exact bytes; hex file format + Dart parser approach documented. |
| TEST-04 | The mock deliberately fragments and coalesces frames to exercise TCP stream reassembly | Fragment/coalesce mode design documented; drives FrameAssembler validation (PROTO-02). |
</phase_requirements>

## Summary

This phase is the load-bearing foundation of the entire library: a pure-Dart codec for the AMS/TCP + AMS wire envelope, validated byte-for-byte against frames produced by the reference Beckhoff C++ AdsLib, with the CMake harness that produces those reference frames online from day one. The wire format is small, fixed-layout, and fully specified — a 6-byte AMS/TCP wrapper (`reserved u16` + `length u32`) followed by a 32-byte AMS header (`targetNetId[6]`, `targetPort u16`, `sourceNetId[6]`, `sourcePort u16`, `cmdId u16`, `stateFlags u16`, `length u32`, `errorCode u32`, `invokeId u32`), all little-endian, all `#pragma pack(1)`, followed by a per-command ADS payload. This is a few hundred lines of `dart:typed_data` code and must have zero I/O dependencies so it is unit-testable in isolation against golden byte vectors.

The single research-flagged risk — "can we actually build a server-role C++ dumper against AdsLib's public headers, cross-platform?" — was **resolved hands-on this session and is now HIGH confidence**. Cloning `github.com/Beckhoff/ADS` (HEAD `57d63747271fca7881bec48417adb44876e67505`), I compiled a minimal `dump_golden` on this macOS/AppleClang dev machine using exactly four upstream `.cpp` files (`Frame.cpp`, `Log.cpp`, `AdsDef.cpp`, `standalone/AmsNetId.cpp`), two include dirs (`AdsLib/`, `AdsLib/standalone/`), one compile define (`-DCONFIG_DEFAULT_LOGLEVEL=1`), and `-std=c++14`. It emitted a byte-exact 38-byte ReadDeviceInfo request frame (`00002000...`) that decodes field-for-field to the spec. No sockets, no threads, no TwinCAT DLL, no upstream build system needed for the dumper. The `AmsHeader.h` structs (`AmsTcpHeader`, `AoEHeader`, `AoERequestHeader`, `AoEReadWriteReqHeader`, `AdsWriteCtrlRequest`, `AoEResponseHeader`, `AoEReadResponseHeader`) are the entire public serialization surface required — they are plain header-only packed structs, reusable directly.

**Primary recommendation:** Build the `protocol/` subtree as immutable value classes over `ByteData` with `Endian.little` on every accessor; reuse upstream `AmsHeader.h` structs + `Frame.cpp` prepend-serialization in the C++ `dump_golden` (so golden bytes are authoritative by construction, not by hand); compile the harness with a self-owned `CMakeLists.txt` that lists specific submodule sources directly (do NOT `add_subdirectory` upstream — it requires CMake 3.23 via `FILE_SET`, and pulls in sockets/threads you don't need). Generate golden `.hex` for ReadDeviceInfo, Read, Write, ReadState, WriteControl, and ReadWrite in Phase 1.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| AMS/TCP + AMS header encode/decode | Codec (`lib/src/protocol/`, pure) | — | Fixed-layout byte manipulation; no I/O; the parity-critical core |
| Per-command payload codecs (ReadDeviceInfo/Read/Write/ReadState/WriteControl/ReadWrite) | Codec (`lib/src/protocol/`) | — | Each is a fixed struct on top of the AMS header |
| TCP frame reassembly (FrameAssembler) | Codec (`lib/src/protocol/`, pure sync) | Transport (Phase 2 feeds bytes in) | Stateful byte accumulator; pure so it's testable without sockets; Phase 2 wires it to the socket stream |
| Max-frame guard / malformed-frame rejection | Codec (`lib/src/protocol/`) | — | Input validation belongs at the parse boundary |
| Reference frame generation (`dump_golden`) | C++ harness (`test_harness/`) | — | C++ AdsLib is the source of truth for bytes |
| Mock ADS server (accept loop + canned responses) | C++ harness (`test_harness/`) | — | Fills the server-role test-double AdsLib does not provide |
| Golden-frame parity assertions | Dart unit tests (`test/unit/`) | — | Hermetic, no process launch; compares codec output to `test/golden/*.hex` |
| CI orchestration (analyze/format/test + CMake build) | GitHub Actions | — | 2 jobs per locked decision |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Dart SDK | pubspec floor `>=3.5.0 <4.0.0`; dev machine has 3.11.5 | Language + core libs | Records/sealed classes/patterns model command variants and fixed headers cleanly [CITED: dart.dev] |
| `dart:typed_data` (SDK) | — | `Uint8List`, `ByteData`, `Endian.little` | Canonical Dart wire-codec primitive; `ByteData.getUint32(o, Endian.little)` maps 1:1 to ADS fields [CITED: api.dart.dev] |
| CMake | `cmake_minimum_required(VERSION 3.16)` (self-owned; do NOT inherit upstream's 3.23) | Build the C++ harness | Locked decision; verified present on dev machine (Homebrew) |
| C++14 + AppleClang (dev) / g++ (CI) | — | Compile `dump_golden` + `mock_server` | Upstream AdsLib is C++14; both compilers verified/planned |

**Zero runtime Dart dependencies in Phase 1.** The `protocol/` subtree imports only `dart:typed_data`. `args`/`path`/`meta` are for later phases (CLI/transport) and need not appear in Phase 1 code.

### Supporting (dev_dependencies)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `test` | ^1.31.0 (latest 1.31.2) | Unit + integration test runner | All codec and harness tests [VERIFIED: pub.dev] |
| `lints` | ^6.1.0 (latest 6.1.0) | Official Dart lint rules | `analysis_options.yaml` baseline [VERIFIED: pub.dev] |
| `meta` | ^1.16.0 (latest 1.18.3) | `@immutable`, `@internal`, `@visibleForTesting` | Optional: mark header value classes immutable/internal [VERIFIED: pub.dev] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Own `ByteData` codec | `framer` / `binary` / `buffer` packages | Rejected in project research: `framer` is big-endian/varint and low-adoption; a published protocol lib must own its ~few-hundred-line hot path |
| `add_subdirectory(third_party/ADS)` | List submodule sources directly in own CMakeLists | Upstream root CMake requires **3.23** (`FILE_SET HEADERS`) and pulls sockets/threads/TcAdsDll probing; direct-source compile needs only 3.16 and 4 files (locked decision, verified this session) |
| CMake "Unix Makefiles" generator | Ninja | Ninja is NOT installed on the dev machine; default Makefiles generator needs only `make`. Recommend Makefiles for dev; either works in CI (install ninja there or use Makefiles) |
| Hand-rolled POSIX sockets in `mock_server.cpp` | AdsLib `Sockets.cpp` | macOS+Linux are both POSIX; a small `<sys/socket.h>` accept loop avoids WinSock conditionals and extra AdsLib sources. Reuse AdsLib only for *framing* structs, not transport |

**Installation (Dart side):**
```bash
dart pub add --dev test lints
dart pub add --dev meta   # optional
```

**Submodule pinning (C++ side):**
```bash
git submodule add https://github.com/Beckhoff/ADS.git third_party/ADS
cd third_party/ADS && git checkout 57d63747271fca7881bec48417adb44876e67505
# NOTE: this is the commit verified this session. The planner may pin a tagged
# release instead; re-verify the 4-source build recipe if a different commit is chosen.
```

**Version verification performed this session:**
- `test` 1.31.2, `lints` 6.1.0, `args` 2.7.0, `path` 1.9.1, `meta` 1.18.3, `collection` 1.19.1 — all confirmed via `pub.dev/api/packages/<name>` [VERIFIED: pub.dev]
- Beckhoff/ADS cloned at HEAD `57d63747271fca7881bec48417adb44876e67505` [VERIFIED: git clone this session]

## Package Legitimacy Audit

> Phase 1 installs no external runtime packages. Dev-dependencies are Dart-team-maintained official packages. slopcheck was unavailable this session (`pip install slopcheck` not run/available), so per protocol these are tagged with their provenance below.

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| `test` | pub.dev | mature (Dart team) | very high | github.com/dart-lang/test | unavailable | Approved [CITED: pub.dev/packages/test] |
| `lints` | pub.dev | mature (Dart team) | very high | github.com/dart-lang/lints | unavailable | Approved [CITED: pub.dev/packages/lints] |
| `meta` | pub.dev | mature (Dart team) | very high | github.com/dart-lang/sdk | unavailable | Approved [CITED: pub.dev/packages/meta] |

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

*slopcheck was unavailable at research time. These three are first-party Dart-team packages published by `dart.dev` verified publishers; their identity is confirmed by the pub.dev "Publisher: dart.dev" badge and dart-lang GitHub source. The planner may still add a `checkpoint:human-verify` before `dart pub add` if it wants strict conformance, but the risk here is negligible.*

## Architecture Patterns

### System Architecture Diagram

```
                 ┌────────────────────────────────────────────────────┐
   test/golden/  │  C++ HARNESS  (test_harness/, CMake, C++14)         │
   *.hex   ◄─────┤  dump_golden.cpp                                    │
   (committed)   │    reuse AmsHeader.h structs + Frame.cpp prepend    │
                 │    → serialize request+response frames → stdout/hex │
                 │                                                     │
                 │  mock_server.cpp  (Phase 2 uses; built here)        │
                 │    POSIX accept loop → parse AMS hdr → switch(cmd)  │
                 │    → canned response; --fragment / --coalesce modes │
                 └───────────────┬────────────────────────────────────┘
                                 │ authoritative bytes
                                 ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  DART CODEC  lib/src/protocol/   (PURE — no dart:async / dart:io)  │
   │                                                                    │
   │  constants.dart ── cmd IDs, index groups, state flags, error codes │
   │  ams_net_id.dart ─ AmsNetId(6B) / AmsAddr(NetId+port) value types   │
   │        │                                                           │
   │        ▼                                                           │
   │  ams_tcp_header.dart (6B)   ams_header.dart (32B)                   │
   │        encode()->Uint8List   decode(ByteData,off)->factory         │
   │        │                                                           │
   │        ▼                                                           │
   │  commands.dart ── per-command request encode / response decode     │
   │        (ReadDeviceInfo, Read, Write, ReadState, WriteControl, RW)  │
   │                                                                    │
   │  bytes in ─► frame_assembler.dart ─► complete AMS frames out       │
   │              add(Uint8List) push API; buffer until 6+length;       │
   │              MalformedFrameException on > maxFrame (4 MiB)          │
   └───────────────┬────────────────────────────────────────────────────┘
                   │ compared byte-for-byte
                   ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │  DART UNIT TESTS  test/unit/                                       │
   │   encode(knownReq)  == readGolden('read_device_info_req.hex')      │
   │   decode(readGolden('..._resp.hex')) == expectedTypedValue         │
   │   FrameAssembler( fragmented+coalesced golden stream ) == [frames] │
   │   FrameAssembler( length > 4 MiB ) throws MalformedFrameException  │
   └──────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure
```
dart-ads/
├── pubspec.yaml                    # name: dart_ads, sdk >=3.5.0 <4.0.0
├── analysis_options.yaml           # include: package:lints/recommended.yaml
├── dart_test.yaml                  # tags: { integration: { timeout: 30s } }
├── .pubignore                      # excludes test_harness/ and third_party/
├── lib/
│   ├── dart_ads.dart               # barrel: exports public protocol types
│   └── src/
│       └── protocol/               # PURE — zero dart:async / dart:io imports
│           ├── constants.dart      # cmd IDs, index groups, state flags, errors
│           ├── ams_net_id.dart     # AmsNetId (6B), AmsAddr
│           ├── ams_tcp_header.dart # AmsTcpHeader (6B) encode/decode
│           ├── ams_header.dart     # AmsHeader (32B) encode/decode
│           ├── commands.dart       # per-command request/response codecs
│           ├── frame_assembler.dart# stateful reassembly + max-frame guard
│           └── exceptions.dart     # MalformedFrameException
├── test/
│   ├── golden/                     # *.hex produced by dump_golden (committed)
│   ├── support/
│   │   └── hex.dart                # parse '#'-commented hex → Uint8List
│   └── unit/                       # codec + assembler tests (no I/O)
├── test_harness/                   # C++/CMake (excluded from published package)
│   ├── CMakeLists.txt              # lists submodule sources directly; 3.16 floor
│   ├── dump_golden.cpp
│   └── mock_server.cpp
├── third_party/
│   └── ADS/                        # git submodule, pinned commit
└── .github/workflows/ci.yml        # 2 jobs
```

### Pattern 1: Immutable header value class with encode()/decode()
**What:** Model each header as an immutable class holding typed fields, with an `encode()` returning a `Uint8List` and a `decode(ByteData, [offset])` factory. Localizes all offset math and endianness in one tested place.
**When to use:** Every fixed-layout wire struct (`AmsTcpHeader`, `AmsHeader`, and each command payload).
**Example (shape — offsets verified from `AmsHeader.h`):**
```dart
// Source: byte offsets verified from Beckhoff/ADS AdsLib/AmsHeader.h (AoEHeader)
class AmsHeader {
  static const int byteLength = 32;
  final AmsNetId targetNetId;   // offset 0,  6 bytes
  final int targetPort;         // offset 6,  u16
  final AmsNetId sourceNetId;   // offset 8,  6 bytes
  final int sourcePort;         // offset 14, u16
  final int commandId;          // offset 16, u16
  final int stateFlags;         // offset 18, u16  (0x0004 req, 0x0005 resp)
  final int dataLength;         // offset 20, u32  (ADS payload length)
  final int errorCode;          // offset 24, u32
  final int invokeId;           // offset 28, u32
  const AmsHeader({...});

  Uint8List encode() {
    final out = Uint8List(byteLength);
    final bd = ByteData.sublistView(out);
    out.setRange(0, 6, targetNetId.bytes);
    bd.setUint16(6, targetPort, Endian.little);
    out.setRange(8, 14, sourceNetId.bytes);
    bd.setUint16(14, sourcePort, Endian.little);
    bd.setUint16(16, commandId, Endian.little);
    bd.setUint16(18, stateFlags, Endian.little);
    bd.setUint32(20, dataLength, Endian.little);
    bd.setUint32(24, errorCode, Endian.little);
    bd.setUint32(28, invokeId, Endian.little);
    return out;
  }

  factory AmsHeader.decode(ByteData bd, [int o = 0]) => AmsHeader(
        targetNetId: AmsNetId(bd.buffer.asUint8List(bd.offsetInBytes + o, 6)),
        targetPort: bd.getUint16(o + 6, Endian.little),
        // ... remaining fields
      );
}
```

### Pattern 2: Full-frame assembly = AMS/TCP length excludes its own 6-byte wrapper
**What:** A complete on-wire frame is `[6B AMS/TCP][32B AMS][payload]`. The AMS/TCP `length` field = `32 + payload` (= everything after the 6-byte wrapper). To encode a full request: encode payload, encode 32-byte AMS header with `dataLength = payload.length`, then prepend the 6-byte wrapper with `length = 32 + payload.length`. This exactly mirrors upstream `AmsConnection::Write` (`prepend<AoEHeader>` then `prepend<AmsTcpHeader>{frame.size()}`).
**Verified:** The compiled dumper produced AMS/TCP length `0x20 = 32` for a zero-payload ReadDeviceInfo request. Off-by-6 or off-by-32 here corrupts every downstream decode (Pitfall 1).

### Pattern 3: Stateful FrameAssembler as a pure synchronous push API
**What:** `add(Uint8List chunk)` appends to an internal buffer, then loops: if buffered ≥ 6, read AMS/TCP `length`; if `length > maxFrame` throw `MalformedFrameException`; if buffered ≥ `6 + length`, slice one complete frame, emit it (return in a list or via callback), advance; else keep remainder and wait. No `dart:async`. Phase 2 pumps `socket.listen` chunks into `add()`.
**When to use:** Any length-prefixed message protocol over a byte stream.
**Anti-pattern it prevents:** Parsing each socket chunk as one frame — passes loopback tests, shatters on real TCP segmentation (Pitfall 3).

### Anti-Patterns to Avoid
- **`ByteData.getUint32(o)` without `Endian.little`:** Dart defaults to big-endian; ADS is little-endian. A single omission byte-swaps one field intermittently. Consider a CI grep gate for endian-less accessors.
- **Treating the 38 bytes as one header:** They are two distinct headers with different semantics; the 2 reserved bytes are not payload.
- **`add_subdirectory(third_party/ADS)`:** Inherits upstream's CMake 3.23 requirement and drags in sockets/threads/TcAdsDll probing. Compile the 4 needed sources directly.
- **Sleeping to wait for the mock server (Phase 2):** Use a `LISTENING <port>` stdout readiness line, not `Future.delayed`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Reference "correct" frame bytes | Hand-typed expected byte arrays in Dart tests | `dump_golden.cpp` reusing `AmsHeader.h` structs + `Frame::prepend` | Hand-typed bytes just re-encode your own assumptions; the whole point is an *independent* C++ source of truth. Verified this session that upstream structs serialize correctly. |
| AMS header serialization in C++ | Manual `memcpy`/offset code in the dumper | Upstream `AoEHeader` / `AmsTcpHeader` constructors + `Frame::prepend<T>` | These are the exact structs AdsLib puts on the wire; reuse guarantees byte-identical layout including `#pragma pack(1)` |
| Little-endian helpers in C++ | Custom byte-swapping | `bhf::ads::htole` / `letoh` (`wrap_endian.h`, header-only) | Already correct and portable (has a big-endian fallback branch) |
| Dart binary framing | `framer` / `binary` packages | `dart:typed_data` `ByteData` directly | Fixed layout; a published lib should own ~200 lines, not depend on a low-adoption package |
| Cross-platform C++ sockets in the mock | Pull in AdsLib `Sockets.cpp` (+WinSock conditionals) | Small POSIX `<sys/socket.h>` accept loop | Targets are macOS+Linux (both POSIX); avoids Windows socket complexity you don't need in this phase |

**Key insight:** The golden frame is only trustworthy if it is generated by code that shares the reference implementation's byte layout. Reuse `AmsHeader.h` + `Frame.cpp` in the dumper — do not re-derive layouts by hand on either side.

## Verified C++ Header Surface (answers Priority Research Q1)

All structs needed to build any Phase-1 frame live in **`AdsLib/AmsHeader.h`** (header-only, `#pragma pack(push,1)`), plus `AmsNetId`/`AmsAddr` from **`AdsLib/standalone/AdsDef.h`**:

| Struct (AmsHeader.h) | Bytes | Fields (all little-endian on wire) | Used for |
|----------------------|-------|-------------------------------------|----------|
| `AmsTcpHeader` | 6 | `reserved u16=0`, `leLength u32` | Frame wrapper; `length = 32 + payload` |
| `AoEHeader` | 32 | `targetNetId[6]`,`leTargetPort`,`sourceNetId[6]`,`leSourcePort`,`leCmdId`,`leStateFlags`,`leLength`,`leErrorCode`,`leInvokeId` | The AMS header (aka `AmsHeader` in our Dart naming) |
| `AoERequestHeader` | 12 | `leGroup u32`,`leOffset u32`,`leLength u32` | Read (0x02) req; Write (0x03) req (+ write data) |
| `AoEReadWriteReqHeader` | 16 | `AoERequestHeader` + `leWriteLength u32` | ReadWrite (0x09) req (+ write data) |
| `AdsWriteCtrlRequest` | 8 | `leAdsState u16`,`leDevState u16`,`leLength u32` | WriteControl (0x05) req (+ data) |
| `AdsAddDeviceNotificationRequest` | 40 | group/offset/length/mode/maxDelay/cycleTime + 16 reserved | (Phase 5) |
| `AoEResponseHeader` | 4 | `leResult u32` | Response result for Write/WriteControl/ReadState/ReadDeviceInfo/AddNote/DelNote |
| `AoEReadResponseHeader` | 8 | `AoEResponseHeader` + `leReadLength u32` | Read/ReadWrite response result + length, then data |

**Command IDs** (`AoEHeader::*` / `ADSSRVID_*`): `0x01` ReadDeviceInfo, `0x02` Read, `0x03` Write, `0x04` ReadState, `0x05` WriteControl, `0x06` AddDeviceNotification, `0x07` DeleteDeviceNotification, `0x08` DeviceNotification, `0x09` ReadWrite. **State flags:** `0x0004` request, `0x0005` response.

**Per-command byte layouts to implement in Dart (answers Priority Research Q3)** — request payload / response payload (both follow the 32-byte AMS header; response payloads begin with the `result u32` since AdsLib's receive path consumes `AoEResponseHeader` before the client sees data):

| Command | Request ADS payload | Response ADS payload |
|---------|---------------------|----------------------|
| ReadDeviceInfo 0x01 | *(none — 0 bytes)* | `result u32` + `version u8` + `revision u8` + `build u16` + `name[16]` = 24 B |
| Read 0x02 | `group u32`,`offset u32`,`length u32` = 12 B | `result u32` + `readLength u32` + `data[readLength]` |
| Write 0x03 | `group u32`,`offset u32`,`length u32` + `data[length]` | `result u32` = 4 B |
| ReadState 0x04 | *(none)* | `result u32` + `adsState u16` + `deviceState u16` = 8 B |
| WriteControl 0x05 | `adsState u16`,`devState u16`,`length u32` + `data[length]` | `result u32` = 4 B |
| ReadWrite 0x09 | `group u32`,`offset u32`,`readLen u32`,`writeLen u32` + `writeData[writeLen]` | `result u32` + `readLength u32` + `data[readLength]` |

*(ReadDeviceInfo response layout confirmed from `AdsSyncReadDeviceInfoReqEx`: `version=buffer[0]`, `revision=buffer[1]`, `build=letoh<u16>(buffer+offsetof(build))`, `name=buffer+sizeof(AdsVersion)`, 16 bytes. ReadState from `AdsSyncReadStateReqEx`: two u16. `AdsVersion` = `{u8 version, u8 revision, u16 build}`.)*

## CMake Harness Build Recipe (answers Priority Research Q2 — VERIFIED this session)

**Minimal source set to build `dump_golden` (no sockets, no threads):**
```cmake
cmake_minimum_required(VERSION 3.16)
project(dart_ads_harness CXX)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ADS third_party/ADS/AdsLib)   # relative to repo root; adjust for -S test_harness
add_library(ads_framing STATIC
    ${ADS}/Frame.cpp
    ${ADS}/Log.cpp
    ${ADS}/AdsDef.cpp
    ${ADS}/standalone/AmsNetId.cpp
)
target_include_directories(ads_framing PUBLIC ${ADS} ${ADS}/standalone)
target_compile_definitions(ads_framing PUBLIC CONFIG_DEFAULT_LOGLEVEL=1)  # REQUIRED

add_executable(dump_golden dump_golden.cpp)
target_link_libraries(dump_golden PRIVATE ads_framing)

add_executable(mock_server mock_server.cpp)         # POSIX sockets, hand-rolled
target_link_libraries(mock_server PRIVATE ads_framing)
```

**Verified build command that worked on macOS/AppleClang this session:**
```bash
g++ -std=c++14 -DCONFIG_DEFAULT_LOGLEVEL=1 \
    -I third_party/ADS/AdsLib -I third_party/ADS/AdsLib/standalone \
    dump_golden.cpp \
    third_party/ADS/AdsLib/Frame.cpp \
    third_party/ADS/AdsLib/Log.cpp \
    third_party/ADS/AdsLib/AdsDef.cpp \
    third_party/ADS/AdsLib/standalone/AmsNetId.cpp \
    -o dump_golden
```

**Critical gotchas discovered:**
1. `CONFIG_DEFAULT_LOGLEVEL` **must** be defined (upstream sets it globally via `add_compile_definitions`; a direct compile fails without it — `Log.cpp:33` references it). This is the one non-obvious flag.
2. Upstream root `CMakeLists.txt` requires **CMake 3.23** (`FILE_SET HEADERS`). By listing sources directly (locked decision) you set your own **3.16** floor and sidestep this entirely.
3. `AdsDef.cpp` provides `operator<<`/`operator<`/`make_AmsNetId`; the `AmsNetId(std::string)` and `AmsNetId(u8...)` constructors live in `standalone/AmsNetId.cpp`. Include both.
4. `Frame.cpp` depends on `Log.h` → include `Log.cpp`. No socket/thread dependency in this set.
5. For `mock_server`: use a hand-rolled POSIX `<sys/socket.h>` accept loop; parse inbound with `AmsTcpHeader(ptr)` / `AoEHeader(ptr)` constructors and build responses with the same structs + `Frame::prepend`. Emit `LISTENING <port>\n` on stdout after binding an ephemeral port (bind `:0`) for the Phase-2 readiness handshake. Support `--fragment N` (send responses in N-byte chunks with a flush between) and `--coalesce` (buffer two responses into one write) to satisfy TEST-04.
6. CMake generator: dev machine has **no ninja** — use default "Unix Makefiles" (`cmake -S test_harness -B build && cmake --build build`). In CI install ninja OR use Makefiles.

## Runtime State Inventory

> Greenfield repo — omitted. No stored data, live-service config, OS-registered state, secrets, or build artifacts pre-exist. Only `.planning/` and `CLAUDE.md` exist (verified: `ls` of repo root and phase dir). The one external state introduced is the git submodule pin, covered under Standard Stack.

## Common Pitfalls

### Pitfall 1: AMS/TCP length field off by 6 or 32
**What goes wrong:** The 6-byte AMS/TCP `length` is set to include its own wrapper, or to exclude the 32-byte AMS header.
**Why it happens:** The two headers are documented separately; the length semantics are non-obvious.
**How to avoid:** `length = 32 + payloadBytes` (everything after the wrapper). Encode by prepending the wrapper last with `frame.size()` as the value — exactly what the verified golden frame does (`0x20` for zero payload).
**Warning signs:** Server drops connection after first frame; response `dataLength` doesn't match remaining bytes; value off by exactly 6 or 32.

### Pitfall 2: Missing `Endian.little` on a ByteData accessor
**What goes wrong:** One field (e.g. index group `0xF003`) arrives byte-swapped (`0x03F0`) while others are fine.
**Why it happens:** Dart `ByteData` defaults to big-endian; ADS is little-endian.
**How to avoid:** Pass `Endian.little` on **every** `getX`/`setX`. Centralize accessors in the header value classes. Add a CI grep for `getUint`/`setUint`/`getInt`/`setInt` calls lacking `Endian`.
**Warning signs:** Works for zero/symmetric small values, breaks for large or asymmetric ones.

### Pitfall 3: Parsing each socket chunk as one frame (surfaces Phase 2, prevent now)
**What goes wrong:** A chunk may hold a partial frame, one frame, or several coalesced; naive per-chunk parsing corrupts under real segmentation.
**How to avoid:** The pure `FrameAssembler` buffers until `6 + length` bytes are present; the mock's `--fragment`/`--coalesce` modes force this in tests (TEST-04). Build the assembler and its adversarial tests in Phase 1 even though the socket arrives in Phase 2.
**Warning signs:** Passes loopback, `RangeError` under load or with large payloads.

### Pitfall 4: Unbounded allocation from a hostile/corrupt length field
**What goes wrong:** A corrupt `length` (e.g. `0xFFFFFFFF`) triggers a huge allocation / OOM.
**How to avoid:** Enforce the 4 MiB max-frame guard (locked default) **before** allocating; throw `MalformedFrameException`. Test with a golden stream whose length field exceeds the guard.

### Pitfall 5: Mock server too lenient → false confidence
**What goes wrong:** A mock that never fragments and always succeeds hides Pitfall 3.
**How to avoid:** The mock must exercise fragmentation/coalescing from day one (TEST-04). Reuse AdsLib framing so the bytes are faithful.

## Code Examples

### Verified golden ReadDeviceInfo request frame (produced by the compiled dumper this session)
```
# read_device_info_req.hex  (38 bytes; target 192.168.0.1.1.1:851, source 192.168.0.100.1.1:40001, invokeId 1)
# Source: compiled test_harness/dump_golden equivalent against Beckhoff/ADS @57d63747
0000 20000000                         # AMS/TCP: reserved u16=0, length u32=0x20=32
c0a8000101 01                         # AMS: targetNetId 192.168.0.1.1.1
5303                                  #      targetPort u16=0x0353=851
c0a8006401 01                         #      sourceNetId 192.168.0.100.1.1
419c                                  #      sourcePort u16=0x9c41=40001
0100                                  #      cmdId u16=0x0001 ReadDeviceInfo
0400                                  #      stateFlags u16=0x0004 request
00000000                              #      dataLength u32=0 (no ADS payload)
00000000                              #      errorCode u32=0
01000000                              #      invokeId u32=1
```
Raw: `000020000000c0a8000101015303c0a800640101419c01000400000000000000000001000000`
Every field decodes to the spec — this is the anchor test for PROTO-01/TEST-02.

### C++ dumper core (shape, reusing upstream structs)
```cpp
// Source: mirrors AdsLib/standalone/AmsConnection.cpp Write(): prepend payload,
// prepend<AoEHeader>, prepend<AmsTcpHeader>{frame.size()}
#include "AmsHeader.h"
#include "AdsDef.h"
#include "Frame.h"
Frame buildReadDeviceInfoReq(const AmsNetId& tgt, const AmsNetId& src, uint32_t id) {
    Frame f(0);                                              // no ADS payload
    const AoEHeader aoe(tgt, AMSPORT_R0_PLC_TC3, src, 40001,
                        AoEHeader::READ_DEVICE_INFO, f.size(), id);
    f.prepend<AoEHeader>(aoe);
    f.prepend<AmsTcpHeader>(AmsTcpHeader{ (uint32_t)f.size() });  // length = 32
    return f;                                                // f.data()/f.size() → hex
}
```

### Dart hex fixture parser (test support)
```dart
// test/support/hex.dart — strips '#' comments and whitespace, returns bytes
Uint8List readGolden(String path) {
  final cleaned = File(path).readAsLinesSync()
      .map((l) => l.split('#').first)          // drop inline comments
      .join()
      .replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Upstream CMake `install(TARGETS)` with plain headers | `target_sources(... FILE_SET HEADERS)` requiring CMake **3.23** | Recent AdsLib | Don't `add_subdirectory` upstream; compile sources directly with a 3.16 floor |
| `find_package(TcAdsDll)` for router build | `standalone/` variant needs no TcAdsDll | Standalone split | The standalone tree is exactly what a non-Windows harness needs |
| Long-lived pub.dev publish tokens | OIDC automated publishing (later phase) | Dart tooling | Not Phase 1, but keep CI secret-free now |

**Deprecated/outdated:** The project research assumed harness path `tool/mock_server/` and `third_party/ADS/`; the locked decision uses `test_harness/` at repo root with the submodule under `third_party/ADS/`. Follow the locked layout.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Pinning submodule to HEAD `57d6374...` is acceptable; planner may prefer a tagged release | Standard Stack | Low — build recipe re-verifiable against any recent commit; re-run the 4-source compile if a tag is chosen |
| A2 | A hand-rolled POSIX socket loop in `mock_server.cpp` is preferred over AdsLib `Sockets.cpp` | Alternatives / Q2 | Low — both work on macOS+Linux; POSIX is simpler and this phase's mock is minimal |
| A3 | Ninja not required; "Unix Makefiles" generator suffices for dev | Environment Availability | Low — Makefiles is CMake's default on Unix; CI can install ninja if preferred |
| A4 | Golden set should cover 6 commands (ReadDeviceInfo/Read/Write/ReadState/WriteControl/ReadWrite) | Phase Requirements | Low — CONTEXT makes command breadth Claude's discretion (min ReadDeviceInfo); more coverage is strictly better |
| A5 | The dev machine's Dart 3.11.5 is fine against the `>=3.5.0` floor | Environment Availability | None — floor is satisfied; CI uses `dart-lang/setup-dart` stable |

## Open Questions (RESOLVED)

1. **Exact golden-frame command breadth for Phase 1** — RESOLVED: all 6 commands (ReadDeviceInfo/Read/Write/ReadState/WriteControl/ReadWrite), request + response, per plan 01-02 Task 2 (12 golden .hex files).
   - What we know: minimum is ReadDeviceInfo req+resp; the 6 core command layouts are fully specified and verified.
   - Resolution: generate all 6 now — the dumper is trivial once one command works, and it front-loads parity coverage cheaply.

2. **Which AmsNetId/port values to bake into golden fixtures** — RESOLVED: target `192.168.0.1.1.1:851`, source `192.168.0.100.1.1:40001`, invokeId 1, baked as constants in dump_golden.cpp per plan 01-02 Task 2.
   - What we know: the dumper takes any NetId/port; the verified example used `192.168.0.1.1.1:851` / `192.168.0.100.1.1:40001` / invokeId 1.
   - Resolution: fixed deterministic values in the dumper (constants) so golden `.hex` are reproducible and diffs are meaningful.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Dart SDK | Codec + tests | ✓ | 3.11.5 (floor >=3.5.0 satisfied) | — |
| CMake | Harness build | ✓ | Homebrew (>=3.16 needed; upstream direct-source avoids 3.23) | — |
| g++ / AppleClang (C++14) | dump_golden + mock_server | ✓ | AppleClang (verified compiled this session) | g++ present at /usr/bin/g++ |
| git | Submodule vendoring | ✓ | /usr/bin/git | — |
| ninja | CMake generator (optional) | ✗ | — | Use default "Unix Makefiles" generator (recommended) |
| slopcheck | Package legitimacy gate | ✗ | — | Dev-deps are first-party Dart-team packages; marked with CITED provenance |
| ctx7 (Context7 CLI) | Doc lookup | ✗ | — | Not needed — protocol facts came from upstream source directly |

**Missing dependencies with no fallback:** none — the full Phase-1 build chain (Dart, CMake, C++14 compiler, git) is present and the golden dumper was actually compiled and run this session.
**Missing dependencies with fallback:** ninja (use Makefiles); slopcheck (first-party packages, CITED provenance).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `package:test` ^1.31.0 (latest 1.31.2) |
| Config file | `dart_test.yaml` (create in Wave 0) with `tags: { integration: { timeout: 30s } }` |
| Quick run command | `dart test test/unit` (pure codec + assembler; no I/O, sub-second) |
| Full suite command | `dart test` (unit) + Linux CI: build harness then `dart test -t integration` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PROTO-01 | Encode AMS/TCP + AMS headers match golden bytes | unit | `dart test test/unit/ams_header_test.dart -x` | ❌ Wave 0 |
| PROTO-01 | Decode golden response frame → typed values (round-trip) | unit | `dart test test/unit/decode_test.dart -x` | ❌ Wave 0 |
| PROTO-02 | Reassemble fragmented + coalesced golden stream → complete frames | unit | `dart test test/unit/frame_assembler_test.dart -x` | ❌ Wave 0 |
| PROTO-02 | Reject frame whose length > 4 MiB guard → MalformedFrameException | unit | `dart test test/unit/frame_assembler_test.dart -x` | ❌ Wave 0 |
| TEST-01 | Mock server builds via CMake and answers ReadDeviceInfo byte-accurately | integration | `cmake --build build && dart test -t integration` | ❌ Wave 0 |
| TEST-02 | Codec encode==golden AND decode(golden)==typed for each command | unit | `dart test test/unit/golden_parity_test.dart -x` | ❌ Wave 0 |
| TEST-04 | Mock fragments/coalesces; assembler recovers full frames | integration/unit | `dart test test/unit/frame_assembler_test.dart -x` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `dart test test/unit` (fast, hermetic — the golden parity + assembler suite)
- **Per wave merge:** `dart analyze --fatal-infos && dart format --output=none --set-exit-if-changed . && dart test test/unit`
- **Phase gate:** Linux CI builds the CMake harness, regenerates/validates golden frames, and runs full `dart test` green before `/gsd:verify-work`; Phase 2 is gated on this job being green.

### Wave 0 Gaps
- [ ] `dart_test.yaml` — declare `integration` tag
- [ ] `analysis_options.yaml` — `include: package:lints/recommended.yaml`
- [ ] `test/support/hex.dart` — `'#'`-commented hex → `Uint8List` parser
- [ ] `test/golden/*.hex` — generated by first `dump_golden` build (the anchor `read_device_info_req.hex` bytes are already known/verified above)
- [ ] `test/unit/` suite — header encode/decode, golden parity, frame assembler (fragment/coalesce + max-frame guard)
- [ ] `test_harness/CMakeLists.txt` + `dump_golden.cpp` + `mock_server.cpp`
- [ ] Framework install: `dart pub add --dev test lints`
- [ ] `.github/workflows/ci.yml` — 2 jobs (see Security/CI notes)

## Security Domain

> `security_enforcement` not set in config → treated as enabled. This phase is a codec + local test harness (no network exposure, no auth, no secrets), so most ASVS categories are N/A; input validation at the parse boundary is the live concern.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | No auth surface in a codec |
| V3 Session Management | no | No sessions |
| V4 Access Control | no | No access decisions |
| V5 Input Validation | **yes** | Bound-check the AMS/TCP `length` field against the 4 MiB max-frame guard **before** allocating; validate `dataLength` against bytes actually present; throw `MalformedFrameException` on violation |
| V6 Cryptography | no | ADS is plaintext by design; no crypto in scope |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Corrupt/hostile length prefix → huge allocation | Denial of Service | Reject `length > maxFrame (4 MiB)` before allocating; typed exception, not a crash |
| Coalesced/fragmented frames misread → data corruption | Tampering | Stateful FrameAssembler; buffer to exact `6 + length`; adversarial fragment/coalesce tests |
| Out-of-bounds read on short/truncated frame | Information Disclosure / DoS | Verify buffered ≥ needed length before every `ByteData` access; never index past `dataLength` |
| Supply chain: unpinned vendored C++ | Tampering | Submodule pinned to an exact commit; harness excluded from published package via `.pubignore` |

*(CI note for the planner: the Linux integration job checks out submodules with `submodules: recursive`, installs `cmake`/`g++` (and optionally `ninja`), builds `test_harness`, then runs `dart test -t integration`. The fast job runs `dart format --set-exit-if-changed`, `dart analyze --fatal-infos`, `dart test test/unit` on ubuntu+macos+windows. Windows lacks the C++ harness — that's fine; unit tests are pure Dart and platform-independent.)*

## Sources

### Primary (HIGH confidence)
- Beckhoff/ADS @ `57d63747271fca7881bec48417adb44876e67505` (cloned + compiled this session): `AdsLib/AmsHeader.h` (all frame structs, packing), `AdsLib/standalone/AdsDef.h` (AmsNetId/AmsAddr, cmd IDs, index groups, error codes, ADSSTATE, AdsVersion), `AdsLib/wrap_endian.h` (htole/letoh), `AdsLib/Frame.h`+`Frame.cpp` (prepend serialization), `AdsLib/standalone/AmsConnection.cpp` (send order: prepend AoEHeader then AmsTcpHeader), `AdsLib/standalone/AdsLib.cpp` (ReadDeviceInfo/ReadState/Read/Write/WriteControl/ReadWrite request+response layouts), `AdsLib/CMakeLists.txt` + root `CMakeLists.txt` (source sets, 3.23 requirement, CONFIG_DEFAULT_LOGLEVEL)
- Hands-on compile: `g++ -std=c++14 -DCONFIG_DEFAULT_LOGLEVEL=1` against 4 sources produced a byte-exact 38-byte ReadDeviceInfo frame (decoded field-for-field in Code Examples)
- pub.dev API (`/api/packages/<name>`): test 1.31.2, lints 6.1.0, args 2.7.0, path 1.9.1, meta 1.18.3, collection 1.19.1
- api.dart.dev — `dart:typed_data` `ByteData`/`Endian`

### Secondary (MEDIUM confidence)
- Project research `.planning/research/{SUMMARY,STACK,PITFALLS,ARCHITECTURE}.md` (2026-07-03) — corroborated header offsets, pitfall catalog, layering
- Beckhoff InfoSys AMS/TCP + AMS header spec (via project research) — corroborates struct field order

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — pub.dev versions verified live; C++ recipe compiled and run
- Byte layouts / codec: HIGH — read directly from upstream structs + a byte-exact golden frame reproduced
- CMake harness / cross-platform build (the research flag): HIGH — the risk was resolved by actually compiling on the macOS/AppleClang dev machine with the minimal source set; Linux/g++ is a strict superset (POSIX) and lower-risk
- Pitfalls: HIGH — wire-format facts from source; Dart endianness trap is well-established

**Research date:** 2026-07-03
**Valid until:** ~2026-08-03 for pub.dev versions; the AdsLib struct layouts are stable across releases (pinned commit removes drift entirely)
