# Requirements: dart-ads

**Defined:** 2026-07-03
**Core Value:** A Dart application can reliably connect to a Beckhoff PLC and read, write, and subscribe to variables over ADS — with wire behavior verified byte-for-byte against the reference C++ implementation.

## v1 Requirements

Requirements for initial release (full AdsLib parity). Each maps to roadmap phases.

### Protocol & Framing

- [ ] **PROTO-01**: Library encodes and decodes the AMS/TCP header (6-byte: reserved u16 + length u32) and the 32-byte AMS header, all fields little-endian
- [ ] **PROTO-02**: Library reassembles complete AMS frames from a fragmented or coalesced TCP byte stream via a stateful frame assembler (with a max-frame guard)
- [x] **PROTO-03**: Library correlates each response to its request by invoke-ID (monotonic counter → Completer) with a per-request timeout
- [x] **PROTO-04**: Library routes unsolicited notification frames (cmd 0x0008, no invoke-ID) to the notification demux instead of the request/response map

### Transport & Connection

- [x] **TRANS-01**: User can open and close a TCP connection to an ADS peer on port 48898
- [x] **TRANS-02**: Library enforces a configurable per-request timeout and fails the pending operation on expiry
- [x] **TRANS-03**: On disconnect, library errors all pending requests and closes all notification streams (failure fan-out)
- [x] **TRANS-04**: Library exposes a fakeable transport interface so codec and connection logic are unit-testable without a live socket

### Core ADS Commands

- [ ] **CMD-01**: User can Read bytes at (indexGroup, indexOffset, length) [ADS Read 0x0002]
- [ ] **CMD-02**: User can Write bytes at (indexGroup, indexOffset) [ADS Write 0x0003]
- [ ] **CMD-03**: User can ReadWrite (write-then-read in one round-trip) [ADS ReadWrite 0x0009]
- [ ] **CMD-04**: User can read device state (adsState + deviceState) [ADS ReadState 0x0004]
- [ ] **CMD-05**: User can set device state via WriteControl [ADS WriteControl 0x0005]
- [ ] **CMD-06**: User can read device info (name + version) [ADS ReadDeviceInfo 0x0001]

### Error Handling

- [ ] **ERR-01**: Library maps ADS error codes to typed Dart exceptions distinct from transport errors
- [ ] **ERR-02**: Library surfaces error 1861/0x745 (missing route) with an actionable message naming the source AmsNetId and suggesting a route/firewall check

### Routing & Transport Modes

- [ ] **ROUTE-01**: User can select transport at runtime — direct-to-peer or via a local TwinCAT router (127.0.0.1:48898)
- [ ] **ROUTE-02**: Embedded AmsRouter maps AmsNetId → connection and allocates local AMS ports
- [ ] **ROUTE-03**: User can configure the source AmsNetId and a local route table for direct mode

### Device Notifications (Streams)

- [ ] **NOTIF-01**: User can subscribe to a symbol's device notifications as a Dart Stream (AddDeviceNotification on first listen)
- [ ] **NOTIF-02**: Cancelling a subscription sends DeleteDeviceNotification (onCancel), and all handles are cleaned up on disconnect
- [ ] **NOTIF-03**: Library parses nested notification frames (stamps × samples) and converts FILETIME timestamps to Dart DateTime
- [ ] **NOTIF-04**: User can choose on-change or cyclic transmission with max-delay / cycle-time attributes

### Sum (Batched) Commands

- [ ] **SUM-01**: User can issue a batched SUMUP_READ (0xF080) returning per-item results as `List<Result<T>>`
- [ ] **SUM-02**: User can issue a batched SUMUP_WRITE (0xF081) returning per-item results
- [ ] **SUM-03**: User can issue a batched SUMUP_READWRITE (0xF082) returning per-item results
- [ ] **SUM-04**: Library parses the per-item error array so partial failures are surfaced per item, never as a whole-batch throw

### Symbols & Typed Values

- [ ] **SYM-01**: User can resolve a symbol handle by name, read/write by handle, and release the handle [0xF003/0xF005/0xF006], with automatic release
- [ ] **SYM-02**: User can browse the PLC symbol table (upload-info + blob), parsing variable-length symbol entries (name, type, size, iGroup, iOffset)
- [ ] **SYM-03**: Library converts PLC scalar types (BOOL, BYTE/USINT, WORD/UINT, INT, DWORD/UDINT, DINT, REAL, LREAL, STRING, WSTRING) to/from Dart values
- [ ] **SYM-04**: Library exposes a raw `Uint8List` escape hatch for values it does not type-convert

### CLI

- [ ] **CLI-01**: `browse` — list/filter PLC symbols with optional glob filter and `--json`
- [ ] **CLI-02**: `read` — read a variable by name or by `--group/--offset[/--len]`, typed by default or `--raw`
- [ ] **CLI-03**: `write` — write a variable by name or group/offset, value parsed to the PLC type or `--raw` hex
- [ ] **CLI-04**: `subscribe` — stream timestamped live notifications until interrupted, with `--on-change`/`--cycle`/`--max-delay`
- [ ] **CLI-05**: `pull` — snapshot symbols and/or current values to a file (JSON/CSV) using sum-read
- [ ] **CLI-06**: `push` — apply values from a file back to the PLC using sum-write, with `--dry-run` and per-item pass/fail
- [ ] **CLI-07**: `action` — issue a state change `--state=RUN|CONFIG|STOP` via WriteControl
- [ ] **CLI-08**: All commands share consistent connection flags (`--target`/`--host`/`--port`/`--timeout`), stable exit codes, and human-readable ADS error names

### Test Harness (C++ / CMake)

- [x] **TEST-01**: A C++ mock ADS server built via CMake (vendored Beckhoff/ADS) responds with byte-accurate ADS frames
- [x] **TEST-02**: A golden-frame dump tool emits reference request/response byte vectors, and Dart codec unit tests assert encode AND decode parity against them
- [x] **TEST-03**: Dart integration tests launch the mock via `Process.start` with an ephemeral port + stdout readiness handshake and tear it down cleanly
- [ ] **TEST-04**: The mock deliberately fragments and coalesces frames to exercise TCP stream reassembly

### Packaging & Publishing

- [ ] **PKG-01**: Package declares native-only platforms (linux/macos/windows/android/ios, no web) and excludes the vendored C++ harness via `.pubignore`; `dart pub publish --dry-run` passes
- [ ] **PKG-02**: CLI is installable via `dart pub global activate` (pubspec `executables:` entry)

## v2 Requirements

Deferred to future release. Tracked but not in the current roadmap.

### Advanced Symbols & Types

- **DTYPE-01**: Type-system upload (SYM_DT_UPLOAD 0xF00E) → STRUCT/ARRAY/enum decoding
- **DTYPE-02**: Typed `AdsSymbol<T>` wrapper binding name → handle → type → conversion → notification

### Reliability

- **RECON-01**: Reconnect with automatic notification re-subscription and connection-state events
- **NOTIF-05**: Batched subscription via SUMUP_ADDDEVNOTE / SUMUP_DELDEVNOTE (0xF085/0xF086)

### Extended Operations

- **RPC-01**: RPC / method-call invocation (TC3 methods) powering CLI `action` RPC mode
- **ROUTE-04**: Remote AddRoute over UDP :48899 with credentials, surfaced as CLI `addroute`
- **TRACE-01**: Structured wire-trace / hex-dump hook for protocol debugging

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Web/browser (`dart:html`) support | ADS is raw TCP; browsers have no socket API. Native VM + Flutter desktop/mobile only |
| FFI to TcAdsDll / native AdsLib | Defeats the purpose (portability, no native toolchain); pure-Dart reimplementation validated against the C++ mock |
| ADS server / device role | Different problem domain (full server semantics); this is a client library. The C++ mock fills the test-double role |
| Reimplement/replace TwinCAT router or runtime | Local-router mode interoperates with real TwinCAT; a full router replacement is a separate product |
| Auto-discovery / broadcast scan of all PLCs | UDP :48899 broadcast scanning is fragile across VLANs and security-sensitive; explicit target config instead |
| Bundled GUI / dashboard | Couples a protocol lib to a UI framework; the first consumer is itself the HMI. Library stays UI-agnostic |
| On-disk symbol-table caching (v2+ at earliest) | Stale cache after PLC download = silent wrong reads; only an optional in-session cache keyed on SYM_VERSION is acceptable later |
| CLI expression/scripting DSL | Turns an operator tool into a language; emit JSON and pipe to `jq` instead |

## Traceability

Which phases cover which requirements. Populated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PROTO-01 | Phase 1 | Pending |
| PROTO-02 | Phase 1 | Pending |
| TEST-01 | Phase 1 | Complete |
| TEST-02 | Phase 1 | Complete |
| TEST-04 | Phase 1 | Pending |
| TRANS-01 | Phase 2 | Complete |
| TRANS-02 | Phase 2 | Complete |
| TRANS-03 | Phase 2 | Complete |
| TRANS-04 | Phase 2 | Complete |
| PROTO-03 | Phase 2 | Complete |
| PROTO-04 | Phase 2 | Complete |
| TEST-03 | Phase 2 | Complete |
| CMD-01 | Phase 3 | Pending |
| CMD-02 | Phase 3 | Pending |
| CMD-03 | Phase 3 | Pending |
| CMD-04 | Phase 3 | Pending |
| CMD-05 | Phase 3 | Pending |
| CMD-06 | Phase 3 | Pending |
| ERR-01 | Phase 3 | Pending |
| ROUTE-01 | Phase 4 | Pending |
| ROUTE-02 | Phase 4 | Pending |
| ROUTE-03 | Phase 4 | Pending |
| ERR-02 | Phase 4 | Pending |
| NOTIF-01 | Phase 5 | Pending |
| NOTIF-02 | Phase 5 | Pending |
| NOTIF-03 | Phase 5 | Pending |
| NOTIF-04 | Phase 5 | Pending |
| SUM-01 | Phase 6 | Pending |
| SUM-02 | Phase 6 | Pending |
| SUM-03 | Phase 6 | Pending |
| SUM-04 | Phase 6 | Pending |
| SYM-01 | Phase 7 | Pending |
| SYM-02 | Phase 7 | Pending |
| SYM-03 | Phase 7 | Pending |
| SYM-04 | Phase 7 | Pending |
| CLI-01 | Phase 8 | Pending |
| CLI-02 | Phase 8 | Pending |
| CLI-03 | Phase 8 | Pending |
| CLI-04 | Phase 8 | Pending |
| CLI-05 | Phase 8 | Pending |
| CLI-06 | Phase 8 | Pending |
| CLI-07 | Phase 8 | Pending |
| CLI-08 | Phase 8 | Pending |
| PKG-01 | Phase 9 | Pending |
| PKG-02 | Phase 9 | Pending |

**Coverage:**
- v1 requirements: 45 total
- Mapped to phases: 45 ✓
- Unmapped: 0

*Note: an earlier draft stated "39 total"; the actual v1 requirement count across all 11 categories is 45 (NOTIF-05 and ROUTE-04 are v2, not counted here).*

---
*Requirements defined: 2026-07-03*
*Last updated: 2026-07-03 after roadmap creation (traceability populated)*
