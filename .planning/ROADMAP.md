# Roadmap: dart-ads

## Overview

dart-ads is built bottom-up along a strict, technically load-bearing dependency chain: nothing above the wire codec compiles until framing is byte-correct, so the C++ golden-frame harness comes online first and validates every layer against the reference AdsLib. From there the stack grows one verifiable layer at a time — socket transport and invoke-ID correlation, the core ADS command set, the AmsRouter and transport-mode selection — then fans out to the two independent value-delivery features (notifications-as-Streams and sum-batched commands), converges at symbol-by-name access, and finishes with the operator CLI that exercises the whole library end-to-end before packaging for pub.dev.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Protocol Framing, Codecs & C++ Golden-Frame Harness** - Byte-accurate AMS codec + CMake mock/golden harness proving encode/decode parity (completed 2026-07-03)
- [x] **Phase 2: TCP Transport, Connection Lifecycle & Invoke-ID Correlation** - Live socket, request/response correlation, and disconnect fan-out (completed 2026-07-03)
- [x] **Phase 3: Core ADS Commands & Error Mapping** - Read/Write/ReadWrite/ReadState/WriteControl/ReadDeviceInfo with typed exceptions (completed 2026-07-04)
- [ ] **Phase 4: AmsRouter & Direct / Local-Router Transport Modes** - NetId routing, runtime transport selection, and actionable 1861 route errors
- [ ] **Phase 5: Device Notifications as Streams** - Subscribe/cancel as Dart Streams with nested stamp/sample demux and handle lifecycle
- [ ] **Phase 6: Sum (Batched) Commands** - Batched read/write/readwrite with per-item partial-failure results
- [ ] **Phase 7: Symbol Access, Browse & Typed Values** - Handle-by-name, symbol table browse, and scalar type conversion
- [ ] **Phase 8: Dart CLI** - browse/read/write/subscribe/pull/push/action operator tool over the full library
- [ ] **Phase 9: Packaging & Publishing** - Native-only platform declaration, .pubignore, and pub.dev publish readiness

## Phase Details

### Phase 1: Protocol Framing, Codecs & C++ Golden-Frame Harness
**Goal**: The Dart wire codec encodes and decodes AMS/TCP + AMS frames that match reference C++ AdsLib output byte-for-byte, and the CMake test harness that produces those reference frames is online from day one.
**Depends on**: Nothing (first phase)
**Requirements**: PROTO-01, PROTO-02, TEST-01, TEST-02, TEST-04
**Success Criteria** (what must be TRUE):
  1. The C++ mock/golden harness builds via CMake (vendored Beckhoff/ADS) on macOS dev and Linux CI, and emits reference request/response byte vectors to `test/golden/*.hex`
  2. The Dart codec encodes AMS/TCP (6-byte) and AMS (32-byte) headers, all fields little-endian, that match the C++ golden frames byte-for-byte
  3. The Dart codec decodes golden response frames back to typed values, giving round-trip parity for encode AND decode
  4. The FrameAssembler reassembles a deliberately fragmented and coalesced golden byte stream into complete AMS frames and rejects any frame exceeding the max-frame guard
**Plans**: 7 plans in 4 waves
  - [x] 01-01-PLAN.md — Package scaffold, pinned Beckhoff/ADS submodule, hex-fixture parser (wave 1)
  - [x] 01-02-PLAN.md — C++ CMake harness + dump_golden emitting 12 golden .hex frames (wave 2)
  - [x] 01-03-PLAN.md — C++ mock server (POSIX loop, fragment/coalesce, --selftest) (wave 3)
  - [x] 01-04-PLAN.md — Dart codec core: constants, NetId/Addr, AMS/TCP + AMS header codecs (wave 2)
  - [x] 01-05-PLAN.md — Per-command codecs + byte-for-byte golden parity tests (wave 3)
  - [x] 01-06-PLAN.md — FrameAssembler + fragment/coalesce/max-frame-guard tests (wave 3)
  - [x] 01-07-PLAN.md — Public API barrel + 2-job CI (Phase 2 gate) (wave 4)
**Research**: NEEDS RESEARCH — exact AdsLib public-header surface usable from a C++ server role (which structs are includable without private headers) and cross-platform CMake build correctness (macOS dev vs Linux CI) need hands-on verification before Phase 2.
**UI hint**: no

### Phase 2: TCP Transport, Connection Lifecycle & Invoke-ID Correlation
**Goal**: A live TCP connection to an ADS peer round-trips real frames through the FrameAssembler, correlates responses to requests by invoke-ID, enforces timeouts, and fails safely on disconnect.
**Depends on**: Phase 1
**Requirements**: TRANS-01, TRANS-02, TRANS-03, TRANS-04, PROTO-03, PROTO-04, TEST-03
**Success Criteria** (what must be TRUE):
  1. A Dart test opens and cleanly closes a TCP connection to the mock server on port 48898, launched via `Process.start` with an ephemeral port and stdout readiness handshake, torn down cleanly
  2. Concurrent in-flight requests each receive their correct response, correlated by a monotonic invoke-ID → Completer map, with no crossed responses
  3. A request that gets no reply fails with a typed timeout error after the configured per-request timeout
  4. On disconnect, all pending requests error out and all notification streams close (failure fan-out) with no hung Futures
  5. Unsolicited notification frames (cmd 0x0008, no invoke-ID) route to the demux path instead of the invoke-ID map, and connection/codec logic is unit-testable against a fakeable transport with no live socket
**Plans**: 4 plans in 3 waves
  - [x] 02-01-PLAN.md — AdsTransport interface + SocketTransport + FakeTransport + transport exceptions (wave 1)
  - [x] 02-02-PLAN.md — C++ mock --delay-ms/--close-after modes + shared startMockServer launch helper (wave 1)
  - [x] 02-03-PLAN.md — AmsConnection: invoke-ID correlation, timeout, notification demux, single-shot disconnect fan-out (wave 2)
  - [x] 02-04-PLAN.md — Live integration tests: connect/round-trip/close + reorder (--delay-ms) + mid-request disconnect (--close-after) (wave 3)
**UI hint**: no

### Phase 3: Core ADS Commands & Error Mapping
**Goal**: Users can issue the full core ADS command set through an idiomatic async Dart API, with every ADS error surfaced as a typed exception.
**Depends on**: Phase 2
**Requirements**: CMD-01, CMD-02, CMD-03, CMD-04, CMD-05, CMD-06, ERR-01
**Success Criteria** (what must be TRUE):
  1. User can Read, Write, and ReadWrite bytes at (indexGroup, indexOffset, length) and get correct results verified against the mock server
  2. User can read device state (ReadState) and device info (ReadDeviceInfo), and set state via WriteControl
  3. Every ADS error code carried in a response maps to a typed Dart exception distinct from transport/timeout errors
  4. Each core command has an integration test passing against the mock server
**Plans**: 6 plans in 3 waves
  - [x] 03-01-PLAN.md — C++ mock: data store, stateful ReadState/WriteControl, two magic error-group fixtures (wave 1)
  - [x] 03-02-PLAN.md — Pure error assets: full ADS error table, AdsException, AdsState enum (wave 1)
  - [x] 03-03-PLAN.md — request() seam: surface AMS-header errorCode to the client (wave 1)
  - [x] 03-04-PLAN.md — AdsClient + AdsStateInfo/DeviceInfo + both-levels throw (FakeTransport unit tests) (wave 2)
  - [x] 03-05-PLAN.md — Live integration: per-command success + both error levels via magic groups (wave 3)
  - [x] 03-06-PLAN.md — C++ AdsLibTest parity ports (partial TEST-05): 10 named scenarios (wave 3)
**UI hint**: no

### Phase 4: AmsRouter & Direct / Local-Router Transport Modes
**Goal**: The AmsRouter maps AmsNetId to connection and stamps the source NetId, users can select direct-peer or local-TwinCAT-router transport at runtime, and the most common connectivity failure (error 1861) is surfaced actionably.
**Depends on**: Phase 3
**Requirements**: ROUTE-01, ROUTE-02, ROUTE-03, ERR-02
**Success Criteria** (what must be TRUE):
  1. User can select direct-to-peer or local-TwinCAT-router (127.0.0.1:48898) transport at runtime without changing command code
  2. The embedded AmsRouter maps AmsNetId → connection and allocates local AMS ports
  3. User can configure the source AmsNetId and a local route table for direct mode
  4. A missing-route failure surfaces as ADS error 1861/0x745 with an actionable message naming the source AmsNetId and suggesting a route/firewall check, never a bare timeout
**Plans**: 4 plans in 3 waves
  - [x] 04-01-PLAN.md — Transport localAddress seam (SocketTransport + FakeTransport) for <ip>.1.1 auto-derive (wave 1)
  - [x] 04-02-PLAN.md — AmsNetId/AmsAddr Comparable ordering + fromIpv4 + testAmsAddrCompare parity (wave 1)
  - [ ] 04-03-PLAN.md — AmsRouter registry: port allocator + route table + localAddr + 4 router parity ports (wave 2)
  - [ ] 04-04-PLAN.md — TransportTarget modes + connect() + ERR-02 1861 + dual-mode/ERR-02 integration (wave 3)
**Research**: NEEDS RESEARCH — the AmsRouter AddRoute handshake over UDP :48899 is the least-documented protocol area; confirm exact packet format, credential exchange, and whether programmatic route registration belongs in v1 or v1.x before committing scope.
**UI hint**: no

### Phase 5: Device Notifications as Streams
**Goal**: Users can subscribe to PLC device notifications as Dart Streams, with correct nested frame parsing and disciplined handle lifecycle so PLC-side notification handles never leak.
**Depends on**: Phase 4
**Requirements**: NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04
**Success Criteria** (what must be TRUE):
  1. User can subscribe to a symbol's device notifications as a Dart Stream, with AddDeviceNotification sent on first listen
  2. Cancelling a subscription sends DeleteDeviceNotification, and all handles are cleaned up on disconnect (no PLC handle leak)
  3. Nested notification frames (stamps × samples) parse correctly and FILETIME timestamps convert to Dart DateTime
  4. User can choose on-change or cyclic transmission with max-delay / cycle-time attributes
**Plans**: TBD
**Research**: NEEDS RESEARCH — notification handle lifecycle on reconnect (when to invalidate, whether to auto re-subscribe, how to signal the consumer) is the subtlest correctness area; the onCancel + disconnect + reconnect state machine needs explicit design before implementation.
**UI hint**: no

### Phase 6: Sum (Batched) Commands
**Goal**: Users can batch multiple reads/writes into a single ADS request and receive per-item results, with partial failures surfaced per item rather than as a whole-batch throw.
**Depends on**: Phase 4
**Requirements**: SUM-01, SUM-02, SUM-03, SUM-04
**Success Criteria** (what must be TRUE):
  1. User can issue a batched SUMUP_READ (0xF080), SUMUP_WRITE (0xF081), and SUMUP_READWRITE (0xF082) in one request
  2. Each batched command returns per-item results as `List<Result<T>>`
  3. A batch where one item deliberately fails surfaces that item's error while returning the other items' data — partial failure never throws for the whole batch
**Plans**: TBD
**UI hint**: no

### Phase 7: Symbol Access, Browse & Typed Values
**Goal**: Users can access PLC variables by name, browse the symbol table, and exchange typed Dart values — the HMI's primary access pattern.
**Depends on**: Phase 4
**Requirements**: SYM-01, SYM-02, SYM-03, SYM-04
**Success Criteria** (what must be TRUE):
  1. User can resolve a symbol handle by name, read/write by handle, and release it, with automatic release on scope exit
  2. User can browse the PLC symbol table and get parsed variable-length entries (name, type, size, iGroup, iOffset)
  3. PLC scalar types (BOOL, BYTE/USINT, WORD/UINT, INT, DWORD/UDINT, DINT, REAL, LREAL, STRING, WSTRING) convert to/from Dart values
  4. Values with no type conversion are accessible via a raw `Uint8List` escape hatch
**Plans**: TBD
**UI hint**: no

### Phase 8: Dart CLI
**Goal**: An operator can drive a PLC entirely from the terminal through all seven CLI verbs, exercising the full library end-to-end.
**Depends on**: Phases 5, 6, 7
**Requirements**: CLI-01, CLI-02, CLI-03, CLI-04, CLI-05, CLI-06, CLI-07, CLI-08
**Success Criteria** (what must be TRUE):
  1. User can run `browse`, `read`, `write`, `subscribe`, `pull`, `push`, and `action` against a PLC (or the mock) from the terminal
  2. All commands share `--target`/`--host`/`--port`/`--timeout` flags, with `--json` on read-oriented commands and `--raw` where applicable, and every command returns stable exit codes with human-readable ADS error names
  3. `subscribe` streams timestamped notifications until interrupted and tears down handles cleanly on SIGINT; `action` changes state via `--state=RUN|CONFIG|STOP`
  4. `pull` snapshots symbols/values to a file (JSON/CSV) via sum-read, and `push` applies values back via sum-write with `--dry-run` and per-item pass/fail
**Plans**: TBD
**UI hint**: no

### Phase 9: Packaging & Publishing
**Goal**: dart-ads is a clean, publishable pure-Dart package with an installable CLI and no C++ harness leaking into the published artifact.
**Depends on**: Phase 8
**Requirements**: PKG-01, PKG-02
**Success Criteria** (what must be TRUE):
  1. The package declares native-only platforms (linux/macos/windows/android/ios, no web) and excludes the vendored C++ harness via `.pubignore`
  2. `dart pub publish --dry-run` passes with no errors or warnings that block publishing
  3. The CLI installs and runs via `dart pub global activate` (pubspec `executables:` entry)
**Plans**: TBD
**UI hint**: no

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9

(Phases 5 and 6 are independent branches on top of Phase 4 and may be planned/executed in parallel.)

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Protocol Framing, Codecs & Golden-Frame Harness | 7/7 | Complete   | 2026-07-03 |
| 2. TCP Transport, Lifecycle & Correlation | 4/4 | Complete   | 2026-07-03 |
| 3. Core ADS Commands & Error Mapping | 6/6 | Complete   | 2026-07-04 |
| 4. AmsRouter & Transport Modes | 2/4 | In Progress|  |
| 5. Device Notifications as Streams | 0/TBD | Not started | - |
| 6. Sum (Batched) Commands | 0/TBD | Not started | - |
| 7. Symbol Access, Browse & Typed Values | 0/TBD | Not started | - |
| 8. Dart CLI | 0/TBD | Not started | - |
| 9. Packaging & Publishing | 0/TBD | Not started | - |
