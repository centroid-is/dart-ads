# Phase 1: Protocol Framing, Codecs & C++ Golden-Frame Harness - Context

**Gathered:** 2026-07-03
**Status:** Ready for planning

<domain>
## Phase Boundary

The Dart wire codec encodes and decodes AMS/TCP + AMS frames that match reference C++ AdsLib output byte-for-byte, and the CMake test harness that produces those reference frames is online from day one. Delivers the `protocol/` subtree (constants, AmsNetId/AmsAddr, AmsTcpHeader, AmsHeader, per-command payload codecs, FrameAssembler), the C++ golden-frame dumper + minimal mock server built via CMake with vendored Beckhoff/ADS, golden-frame unit tests, and CI. No sockets, no live connections — that's Phase 2 (except the mock binary existing and being buildable).

Requirements: PROTO-01, PROTO-02, TEST-01, TEST-02, TEST-04.

</domain>

<decisions>
## Implementation Decisions

### Repo & Package Layout
- Package name: `dart_ads` (matches repo name; valid pub.dev lowercase_with_underscores style)
- C++ harness lives in `test_harness/` at the repo top level (CMakeLists + mock server + golden dumper), excluded from the published package via `.pubignore`
- Beckhoff/ADS vendored as a git submodule pinned to a specific commit (reproducible, updatable, no license duplication)
- Dart SDK floor: `>=3.5.0 <4.0.0` (sealed classes/records available, wide compatibility)

### Codec API Design
- Headers as immutable value classes (`AmsTcpHeader`, `AmsHeader`) with `encode()` methods and `decode()` factories — testable and self-documenting over raw ByteData views
- FrameAssembler is a pure synchronous push API: `add(Uint8List)` → emits complete frames; zero `dart:async`/`dart:io` imports anywhere in the `protocol/` subtree so it is unit-testable in complete isolation
- Max-frame guard defaults to 4 MiB, configurable (generous enough for symbol uploads, blocks OOM on corrupt length fields)
- Malformed frames throw typed exceptions (e.g. `MalformedFrameException`), distinct from ADS protocol errors

### Golden-Frame Harness & CI Scope
- Phase 1 C++ deliverables: golden-frame dumper (`dump_golden`) emitting reference request/response byte vectors, PLUS a minimal mock server binary that answers ReadDeviceInfo and supports configurable fragment/coalesce modes; the mock's command table grows in later phases
- Golden files are text hex: `test/golden/*.hex`, one frame per file, `#` comments allowed — human-diffable and git-friendly
- CMake compiles AdsLib sources directly from the pinned submodule into the harness targets (C++14, CMake >= 3.16) rather than depending on upstream's own build system
- CI set up in this phase: GitHub Actions with 2 jobs — fast Dart analyze/format/unit-test job (all platforms) and a Linux integration job that builds the CMake harness. Phase 2 is gated on this CI being green.

### Claude's Discretion
- Exact file naming within `lib/src/protocol/`, constant organization, and test file structure
- Which specific commands get golden frames in Phase 1 (minimum: ReadDeviceInfo request+response; more is better)
- Hex file parsing helper design for tests

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- None — greenfield repo (only `.planning/` and `CLAUDE.md` exist)

### Established Patterns
- Research docs in `.planning/research/` define the architecture: `protocol/` subtree must be pure (no I/O), all wire fields little-endian via explicit `Endian.little` on every ByteData accessor, `ByteData.sublistView` for zero-copy reads
- AMS/TCP header: 6 bytes (reserved u16 + length u32); AMS header: 32 bytes (targetNetId[6], targetPort u16, sourceNetId[6], sourcePort u16, cmdId u16, stateFlags u16, length u32, errorCode u32, invokeId u32)
- AMS/TCP length field = 32 + dataLength (includes AMS header, excludes the 6-byte wrapper itself) — the #1 pitfall

### Integration Points
- Phase 2 consumes: `FrameAssembler`, header codecs, `AmsNetId`/`AmsAddr` types
- Phase 2 gated on: Linux CI job building the CMake harness green

</code_context>

<specifics>
## Specific Ideas

- Golden-frame validation is the point of this phase: Dart codec unit tests must assert encode AND decode parity against C++-produced frames byte-for-byte (TEST-02)
- The mock must deliberately fragment and coalesce frames (TEST-04) so the FrameAssembler is exercised against realistic TCP behavior from day one
- Verify the C++ harness builds on macOS (dev machine) and Linux (CI) before Phase 2 begins — this is a research-flagged risk area (AdsLib server-role header surface + cross-platform CMake)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
