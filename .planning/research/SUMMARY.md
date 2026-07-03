# Project Research Summary

**Project:** dart-ads
**Domain:** Pure-Dart industrial protocol client library (Beckhoff ADS / AMS-TCP) + operator CLI
**Researched:** 2026-07-03
**Confidence:** HIGH (protocol constants and API surface verified byte-for-byte against Beckhoff/ADS C++ source; Dart SDK idioms from official docs; MEDIUM on AdsLib CMake reuse surface for a server role and on the AddRoute UDP handshake)

## Executive Summary

dart-ads is a pure-Dart reimplementation of the Beckhoff C++ AdsLib — a byte-pushing, length-prefixed binary protocol client over raw TCP. The right approach is deliberately boring: the Dart SDK core libraries (`dart:io`, `dart:typed_data`, `dart:async`) are sufficient for the entire transport and codec; no runtime dependencies are needed or wanted beyond `args` for the CLI. The architecture mirrors AdsLib's own layering exactly — L2 socket transport, L3 framing codec, L4 connection with invoke-ID correlation, L5 AmsRouter, L6 typed client API, L7 CLI — but all of AdsLib's C++ threads collapse into Dart's single event loop, with `Completer` replacing condition variables and `StreamController` replacing the notification dispatcher thread. All four research streams agree on a strict bottom-up dependency chain; there is no shortcut to the correct build order.

The single biggest structural risk is the C++ mock ADS server that drives integration tests. AdsLib is a client library and ships no ready-made server; the project must hand-roll a minimal mock in C++ that reuses AdsLib's frame structs to produce byte-accurate responses. This mock needs to be online early — alongside the codec layer — so that golden-frame unit tests validate Dart encode/decode byte-for-byte against C++-produced frames from day one, not as an afterthought. The cross-platform CMake build (macOS dev, Linux CI) and the exact public-header surface of AdsLib usable from a server role are the least-certain technical areas and need hands-on verification in the first build phase.

Three areas carry elevated correctness risk that must be designed for up front rather than retrofitted: (1) notification handle lifecycle — every `AddDeviceNotification` consumes a PLC-side resource from a finite pool, and `StreamSubscription.cancel()` must fire `DeleteDeviceNotification` unconditionally, including on reconnect and disconnect; (2) the AmsRouter route-registration handshake — ADS error 1861 (0x745) is the most common real-world connectivity failure and results from a missing route on the target for the source AmsNetId, the AddRoute mechanism over UDP `:48899` is the least-documented part of the protocol, and surfacing 1861 as an actionable error is a hard UX requirement; (3) sum-command partial failure — the outer ADS error can be zero while individual sub-requests failed, and the per-item error array must always be parsed and surfaced as `List<Result<T>>`.

## Key Findings

### Recommended Stack

The stack is intentionally minimal. The library's `dependencies:` block should contain only `args` (CLI), `path` (CLI file I/O), and optionally `meta` (API annotations) — no framing packages, no binary-parsing libraries, no abstractions over `dart:typed_data`. AMS/TCP framing is a 6-byte header with a 32-bit little-endian length field followed by a 32-byte AMS header; implementing and owning this in ~100 lines of Dart is the correct call for a published protocol library. The `framer` package on pub.dev is big-endian/varint and low-adoption — reject it.

The C++ test harness builds with CMake 3.16+ and a C++14 compiler. Beckhoff/ADS should be vendored as a git submodule pinned to a specific commit. CI has two jobs: a fast analyze/format/unit job (all platforms, no CMake) and an integration job (Linux, installs CMake/Ninja/g++, builds the mock, runs `dart test -t integration`). Publishing uses OIDC automated publishing via `dart-lang/setup-dart` — no long-lived tokens.

**Core technologies:**
- `dart:io` `Socket`: raw TCP transport for AMS/TCP port 48898; native-only by design (no web)
- `dart:typed_data` `ByteData`/`Uint8List`: zero-copy little-endian encode/decode for all wire fields; `Endian.little` must be explicit on every `getX`/`setX` call
- `dart:async` `Completer`/`StreamController`: request/response correlation by invoke-ID and notification fan-out; replaces AdsLib's threads entirely
- `args` ^2.7.0: `CommandRunner` + `Command` subclasses for the 7 CLI verbs
- Dart SDK 3.12.x, pubspec floor `>=3.5.0 <4.0.0`: sound null safety, records, sealed classes for typed ADS command/response variants
- `test` ^1.31.0 + `dart_test.yaml` tags: separate fast codec unit tests from integration tests that spawn the C++ mock
- CMake 3.16+ / C++14 + vendored Beckhoff/ADS submodule: C++ mock server and golden-frame dumper

### Expected Features

All four research files converge on the same priority ordering. Nothing works without the wire envelope; every feature above the codec layer is blocked until framing is correct. The dependency chain is strict and linear up through the connection layer, then fans out to notifications and sum commands in parallel (both depend on ReadWrite), then converges again at symbols and CLI.

**Must have (table stakes — v1):**
- AMS/TCP + AMS header framing: 6-byte wrapper + 32-byte AMS header, length-prefixed TCP reassembly via stateful `FrameAssembler`; tested byte-for-byte against C++ golden frames
- Invoke-ID correlation: monotonic `Map<int, Completer>` with timeout `Timer`; notifications (cmd 0x0008, invokeId=0) bypass this map entirely and route to the handle demux
- Core ADS commands: Read (0x02), Write (0x03), ReadWrite (0x09), ReadState (0x04), WriteControl (0x05), ReadDeviceInfo (0x01)
- ADS error-code mapping: every response carries `errorCode`; map the full table to typed exceptions; error 1861/0x745 (missing route) must produce an actionable message naming the source AmsNetId and suggesting route or firewall checks
- Connection lifecycle: explicit connect/close, per-request timeout, failure fan-out (error all pending Completers + close all notification StreamControllers on disconnect)
- Configurable transport: direct mode (embed minimal AmsRouter, connect to `<deviceIp>:48898`) and local-router mode (`127.0.0.1:48898` via installed TwinCAT); runtime-selectable via `TransportTarget` strategy
- Symbol handle-by-name: ReadWrite to `0xF003` for handle, Read/Write on `0xF005` with handle as offset, Write to `0xF006` on release; handles are session-scoped, never persisted, invalidated on PLC reload/error
- Symbol browse: ReadWrite to `0xF00C`/`0xF00F` for upload info, Read `0xF00B` for symbol blob; parse variable-length `AdsSymbolEntry` records
- Device notifications as Streams: `AddDeviceNotification` (0x0006) on first listen, `DeleteDeviceNotification` (0x0007) in `onCancel`, nested stamp/sample demux of 0x0008 frames, FILETIME to `DateTime` conversion
- Typed scalar conversion: BOOL, BYTE/USINT, WORD/UINT, INT, DINT, DWORD/UDINT, REAL (f32), LREAL (f64), STRING (fixed-length Latin-1 null-padded), WSTRING (UTF-16LE) plus raw `Uint8List` escape hatch
- Sum commands: SUMUP_READ `0xF080`, SUMUP_WRITE `0xF081`, SUMUP_READWRITE `0xF082` via ReadWrite; always parse per-item uint32 error array; return `List<Result<T>>` — partial failure is the normal case, not an edge case
- Route management: local route table (AmsNetId to IP) for direct mode; document that target TwinCAT router requires a reverse route for the source AmsNetId
- CLI: `browse`, `read`, `write`, `subscribe`, `pull`, `push`, `action` — all with `--target`, `--host`, `--port`, `--timeout` and consistent exit codes; `--json` on read-oriented commands

**Should have (competitive — v1.x):**
- Reconnect with notification re-subscription: backoff reconnect, replay `AddDeviceNotification` for live streams, emit connection-state events
- Type-system upload (`SYM_DT_UPLOAD` 0xF00E): parse `AdsDatatypeEntry` for STRUCT/ARRAY/enum decoding; enables reading whole FB instances
- Typed `AdsSymbol<T>` wrapper: bind name to handle to type to conversion to notification in one object
- Remote AddRoute helper (UDP :48899): programmatic route registration; surface as CLI `addroute`
- Structured wire-trace hook: optional hex-dump of frames for debugging against Wireshark

**Defer (v2+):**
- Symbol-table caching keyed on SYM_VERSION: correctness risk (stale cache after PLC download); only worth it if startup latency is proven painful in practice
- RPC method-call invocation: framing for TC3 PLC methods is MEDIUM-confidence and needs verification against a real TC3 target
- `netid` discovery, file access, license/rtime/ecat diagnostics: niche, outside the HMI core use case

### Architecture Approach

The Dart layering maps 1:1 onto AdsLib's component boundaries, with threading replaced by the event loop. The key insight is that AdsLib's two threads (receiver thread blocking on `recv()`, dispatcher thread for notification callbacks) are architectural artifacts of C++ blocking I/O — not ADS protocol requirements. In Dart, a single socket stream listener plus `Completer`/`StreamController` achieves the same structure with no synchronization primitives and no Isolates. The `protocol/` subtree (constants, headers, codecs, frame assembler) must have zero I/O dependencies so it can be unit-tested against golden byte vectors in complete isolation; everything with I/O lives above it.

**Major components:**
1. `SocketTransport` (L2) — owns the `dart:io` `Socket`; exposes `Future connect()`, `void add(bytes)`, `Stream<Uint8List> inbound`, `close()`; ADS-agnostic and fakeable for unit tests
2. `FrameCodec` + `FrameAssembler` (L3) — pure functions encoding requests / decoding responses; stateful accumulator reassembling TCP chunks into whole AMS frames; the `protocol/` subtree; no I/O
3. `AmsConnection` (L4) — one TCP peer; owns `Map<int, _Pending>` (Completer + timeout Timer) for invoke-ID correlation and `Map<int, StreamController>` for notification demux; branches on `commandId == 0x08` before looking up invoke-ID
4. `AmsRouter` (L5) — `Map<AmsNetId, AmsConnection>`; allocates local AMS ports; holds route table; resolves `TransportTarget` (direct IP vs `127.0.0.1`) without any layer below knowing which mode is active
5. `AdsClient` / `AdsDevice` (L6) — typed ergonomic API; composes raw commands for symbol resolution, browse, sum batching; returns `Future`/`Stream`
6. `AdsCli` (L7) — `args` `CommandRunner`; maps verbs to client calls; manages connection and subscription lifetime
7. C++ mock ADS server — CMake + vendored AdsLib framing; minimal accept loop with fixture-table responses; emits `LISTENING <port>` on stdout for Dart `Process.start` readiness handshake; parallel build track starting at framing phase

### Critical Pitfalls

1. **Two-header confusion (AMS/TCP 6B vs AMS 32B)** — model them as two distinct types; the AMS/TCP `length` field = 32 + dataLength, NOT including the 6-byte wrapper; write a byte-for-byte round-trip unit test against a C++ mock frame on day one; wrong offsets here corrupt every downstream decode
2. **TCP chunk not equal to AMS frame** — implement a stateful `FrameAssembler` accumulating bytes until `buffer.length >= 6 + length`; the naive "parse each chunk" approach passes loopback tests and shatters against real networks; make the C++ mock deliberately fragment and coalesce frames to force this early
3. **Notification handle leaks on the PLC** — TwinCAT has a finite notification handle pool per device; `StreamSubscription.cancel()` must unconditionally fire `DeleteDeviceNotification`; on disconnect, invalidate all handles and never attempt to delete them against a new session; leaked handles require a PLC power-cycle to recover
4. **Missing ADS route / error 1861 (0x745)** — TCP connects fine but every ADS request times out because the target PLC won't route replies to an unknown source AmsNetId; this is the most common real-world ADS failure; the library must surface 1861 with an actionable message (naming the source AmsNetId, suggesting `addroute` or TwinCAT route configuration) not a bare timeout; the source AmsNetId must always be explicitly configurable
5. **Sum-command partial failure silently returns garbage** — the outer ADS response `errorCode` can be 0 while individual sub-requests failed; always parse the leading array of N uint32 error codes before touching the data section; return `List<Result<T>>` with per-item errors; test a batch where item N deliberately fails so data-offset alignment is exercised

Additional: always pass `Endian.little` explicitly on every `ByteData.getX/setX` call (ADS is little-endian, Dart defaults to big-endian); notification frame payload is a nested structure (stamps x samples) not a flat sample — parse the full nested loop and convert FILETIME (100 ns ticks since 1601-01-01) to `DateTime` explicitly; complete every Completer through an `if (!completer.isCompleted)` guard and flush the entire pending map on disconnect.

## Implications for Roadmap

Based on research, all four streams agree on a strict bottom-up dependency chain with two parallel branches at the notification/sum layer. The suggested phases follow this chain exactly; deviating from the order (e.g., building CLI before connection, or skipping golden frames) creates technical debt that is expensive to unwind.

### Phase 1: Protocol Framing, Codecs + C++ Golden-Frame Harness

**Rationale:** Nothing else in the stack compiles until the wire envelope is correct. This is also the highest-leverage testing moment: a C++ `dump_golden.cpp` tool (linked against vendored AdsLib) can produce authoritative request + response byte vectors for every command, giving the Dart codec layer byte-for-byte parity verification before a single socket is opened. The CMake build must come online here, not later.
**Delivers:** `protocol/` subtree (constants, `AmsNetId`/`AmsAddr`, `AmsTcpHeader`, `AmsHeader`, per-command payload codecs, `FrameAssembler`); C++ `dump_golden.cpp` producing `test/golden/*.hex`; golden-frame unit tests asserting encode AND decode round-trips
**Addresses:** AMS/TCP + AMS header framing; AMS addressing (all little-endian, byte-packed); command IDs and index-group constants
**Avoids:** Two-header confusion (Pitfall 1); endianness bugs (Pitfall 2); `ByteData` default-big-endian trap
**Research flag:** NEEDS RESEARCH — the exact AdsLib public-header surface usable from a C++ server role (which structs are public without private headers) needs hands-on verification; also CMake cross-platform build correctness on macOS dev vs Linux CI

### Phase 2: TCP Transport + Connection Lifecycle + Async Request/Response Correlation

**Rationale:** The `FrameAssembler` from Phase 1 is tested in isolation; now wire it to a real socket and validate the full round-trip path with the live mock server. Invoke-ID correlation and the failure-fan-out pattern on disconnect must be established here before any command layer relies on them.
**Delivers:** `SocketTransport` (interface + `dart:io` impl + `FakeTransport` for unit tests); `AmsConnection` with `Map<int, _Pending>` (Completer + timeout Timer) and full disconnect fan-out; `FrameAssembler` integrated into the inbound stream; first live round-trip (ping the mock server with ReadDeviceInfo)
**Addresses:** Connection lifecycle (connect/close/timeout); invoke-ID correlation; half-open connection detection; `FakeTransport` enables `AmsConnection` unit tests without a live socket
**Avoids:** Hung Futures (Pitfall 4); leaked Completers; stale state across reconnect; naive chunk-as-frame parsing (Pitfall 3)

### Phase 3: Core ADS Commands

**Rationale:** With a working connection and correlation layer, the core ADS command set is straightforward encoding — each is a fixed payload on top of the already-working frame layer. This is the first user-visible capability and the dependency gateway for everything above it (ReadWrite is the foundation of symbols and sum commands).
**Delivers:** `AdsClient` with `read()`, `write()`, `readWrite()`, `readState()`, `writeControl()`, `readDeviceInfo()`; full ADS error-code-to-typed-exception mapping including actionable message for error 1861/0x745; integration tests against the mock for each command
**Addresses:** All P1 core commands; ADS error mapping including 1861 missing-route UX requirement; typed Dart API (Futures)
**Avoids:** Bare timeout error messages (UX pitfall); missing error-code coverage

### Phase 4: Router / AmsRouter + Direct vs Local-Router Transport Modes

**Rationale:** The `AmsConnection` from Phase 2 knows nothing about routing; the router layer adds NetId-to-connection mapping, local port allocation, and the direct/local-router mode selection. This is also where the route table lives and where error 1861 gets its full context (source AmsNetId is stamped here).
**Delivers:** `AmsRouter` with `Map<AmsNetId, AmsConnection>` and local port counter; `TransportTarget` strategy (`DirectTarget` vs `LocalRouterTarget`); local AMS route table for direct mode; configurable source AmsNetId; explicit 1861 error surfacing with source NetId in the message
**Addresses:** Configurable transport (direct vs local-router); AMS port vs TCP port distinction; route management
**Avoids:** Routing confusion (Pitfall 8); hard-coded source NetId (technical debt); silently wrong 1861 as a bare timeout
**Research flag:** NEEDS RESEARCH — the AmsRouter AddRoute handshake over UDP `:48899` is the least-documented area of the protocol; the exact packet format, credentials exchange, and whether it needs to be in v1 or can be deferred to v1.x needs verification against Beckhoff InfoSys and AdsLib source before committing to scope

### Phase 5: Notifications-as-Streams + Sum Commands

**Rationale:** These two features are independent of each other but both depend on ReadWrite (Phase 3) and can be built in parallel. Notifications are the core value proposition of the project (HMI live values); sum commands are the performance foundation for the CLI's `pull`/`push`. Both depend on the same router/connection foundation and both feed Phase 6.
**Delivers:** Notification demux in `AmsConnection` (`Map<int, StreamController<AdsNotification>>`); `AddDeviceNotification`/`DeleteDeviceNotification` command codecs; nested stamp/sample parser with FILETIME conversion; `Stream<AdsNotification>` API with `onCancel` cleanup; `SUMUP_READ`/`SUMUP_WRITE`/`SUMUP_READWRITE` via ReadWrite; `List<Result<T>>` return type enforcing per-item error surfacing; partial-failure integration test (deliberate mid-batch item failure)
**Addresses:** Device notifications as Streams; sum commands with partial failure; `StreamSubscription.cancel()` to `DeleteDeviceNotification` lifecycle
**Avoids:** Notification handle leaks on PLC (Pitfall 5); flat notification parser missing multi-stamp/sample batches (Pitfall 6); sum-command outer-success/inner-failure silent data corruption (Pitfall 9)
**Research flag:** NEEDS RESEARCH — notification handle lifecycle on reconnect (when to invalidate, whether to re-subscribe automatically, how to signal the consumer) has subtle correctness requirements that need explicit design; the `onCancel` + disconnect + reconnect interaction is the subtlest correctness area in the whole codebase

### Phase 6: Symbol Access + Browse

**Rationale:** Symbol-by-name handle resolution and symbol browse both depend on ReadWrite (Phase 3) and the typed client. Browse is HIGH complexity (variable-length `AdsSymbolEntry` records) but is the prerequisite for CLI `browse` and `pull`. Handle staleness after PLC reload must be designed for here.
**Delivers:** Symbol handle-by-name (`readByName`, `writeByName`, auto-release); symbol browse (upload-info + blob parsing for name/type/size/iGroup/iOffset per symbol); handle invalidation on ADS error 1808/1809 or state-change detection; typed scalar conversion (BOOL/INT/DINT/REAL/LREAL/STRING/WSTRING + raw escape hatch)
**Addresses:** Named variable access (the HMI's primary access pattern); symbol discoverability; typed value conversion; handle staleness after PLC reload
**Avoids:** Symbol handle staleness from PLC reload (Pitfall 7); STRING/WSTRING codec confusion; never-release handle leak

### Phase 7: CLI

**Rationale:** The CLI is a thin `args` + `CommandRunner` veneer over the typed client API established in Phases 3-6. It is the end-to-end exercise of the entire stack and the first real-world operator tool. With the library fully functional, CLI implementation is fast. The `subscribe` verb is the only interesting lifetime management (long-lived Stream until SIGINT); `pull`/`push` test sum commands under realistic conditions.
**Delivers:** `bin/ads.dart` with `CommandRunner` and all 7 commands (`browse`, `read`, `write`, `subscribe`, `pull`, `push`, `action`); consistent `--target`/`--host`/`--port`/`--timeout` flags across all subcommands; `--json` on read-oriented commands; stable exit codes; human-readable ADS error names; `subscribe` SIGINT teardown with `DeleteDeviceNotification`; `pull`/`push` round-trip correctness; `pubspec.yaml` `executables:` for `dart pub global activate`
**Addresses:** CLI browse/read/write/subscribe/pull/push/action; operator UX (error messages, exit codes, `--json`); `action --state=RUN|CONFIG|STOP` via WriteControl
**Avoids:** CLI exposing raw ADS error numbers without names; `subscribe` orphaning notification handles on exit

### Phase 8: Publishing + Polish

**Rationale:** pub.dev platform declarations, `dart pub publish --dry-run`, and `.pubignore` to exclude the C++ test harness from the published package must be done explicitly. Reconnect with notification re-subscription is the key reliability feature for long-running HMI deployments. Type-system upload and `AdsSymbol<T>` wrapper round out parity with AdsLib's high-level API surface.
**Delivers:** `platforms:` declaration (linux/macos/windows/android/ios, no web); `.pubignore` excluding vendored AdsLib and C++ harness; `example/main.dart` for pub.dev scoring; `public_member_api_docs` lint; OIDC automated publishing workflow; reconnect with handle/subscription re-registration; `SYM_DT_UPLOAD` parsing for STRUCT/ARRAY/enum; `AdsSymbol<T>` convenience wrapper
**Addresses:** pub.dev native-only platform declaration; pub.dev score (docs, example, analysis); reconnect stability for HMI deployments; type-system upload for composite types
**Avoids:** pub.dev falsely inferring web support; C++ source shipping in the published package

### Phase Ordering Rationale

- **Bottom-up strict dependency chain:** framing to transport to commands to router to notifications/sum to symbols to CLI is the only valid order; each layer's API is a prerequisite for the one above it
- **C++ mock server online at Phase 1:** golden-frame byte verification must happen before any socket code exists; verifying codec correctness later via live round-trips pushes parity bugs downstream where they are expensive to root-cause
- **Notifications and sum commands parallel in Phase 5:** both depend on ReadWrite (Phase 3) and neither depends on the other; grouping them accelerates Phase 6 (which needs sum commands for `pull`/`push`)
- **Symbols before CLI:** CLI browse/read/write/subscribe/pull all require symbols; CLI can only be the final integration exercise, not an intermediate validation
- **Router before typed client commands:** source NetId stamping happens in the router; commands that depend on correct AMS addressing with real PLCs need the router working first

### Research Flags

Phases needing `/gsd-research-phase` during planning:
- **Phase 1 (CMake mock server):** exact AdsLib public-header surface usable for a C++ server role; which structs can be included without private headers; cross-platform CMake build differences between macOS and Linux CI need hands-on verification
- **Phase 4 (AddRoute / UDP :48899):** the AmsRouter route-registration handshake is the least-documented, highest-risk protocol area; confirm exact UDP packet format, credential exchange, and whether it belongs in v1 or v1.x before committing scope
- **Phase 5 (notification handle lifecycle):** design the reconnect/re-subscribe interaction explicitly before implementation; the `onCancel` + disconnect + reconnect state machine is the subtlest correctness area in the codebase

Phases with well-documented, standard patterns (skip or minimize research):
- **Phase 2 (transport + Completer correlation):** Dart `Socket`/`Completer`/`StreamController` idioms are well-established; the pattern is direct and verified
- **Phase 3 (core ADS commands):** command payload layouts are verified byte-for-byte from AdsLib source; encoding is mechanical once the codec layer exists
- **Phase 7 (CLI):** `args` + `CommandRunner` is the Dart-team standard; verb-to-client mapping is straightforward given the library API

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Core Dart SDK APIs and `args`/`test`/`lints` versions verified from pub.dev and dart.dev; MEDIUM on exact CMake/AdsLib build surface for server role |
| Features | HIGH | Protocol constants, command IDs, index groups, header layouts verified byte-for-byte against Beckhoff/ADS `master` source (`AdsDef.h`, `AmsHeader.h`, `AdsDevice.h`); MEDIUM on `pull`/`push`/`action` CLI semantics (project-defined verbs) |
| Architecture | HIGH | AdsLib component structure verified from C++ source; Dart event-loop mapping is standard idiom; C++ threading to Dart collapse is a known pattern; MEDIUM on mock server implementation details |
| Pitfalls | HIGH | Wire-format facts verified from AdsLib source, Beckhoff InfoSys, and independent TS implementations (jisotalo); Dart socket semantics from `dart:io` behavior |

**Overall confidence:** HIGH for core protocol and architecture; MEDIUM for two specific gaps (AddRoute handshake, CMake server-role reuse surface)

### Gaps to Address

- **AddRoute UDP :48899 handshake:** the exact packet format and credential exchange for programmatic route registration is MEDIUM-confidence; validate against AdsLib `AmsRouter.cpp`/`AdsTool/main.cpp` `addroute` implementation before scoping Phase 4 — must be resolved during Phase 4 planning
- **AdsLib server-role public API surface:** AdsLib is a client library; which headers and structs are public enough to reuse for serializing responses in the C++ mock without pulling in private headers is not clear from README/docs alone — verify hands-on in Phase 1 and document which headers are used
- **CMake cross-platform (macOS dev + Linux CI):** Beckhoff/ADS uses platform-conditional socket code (POSIX vs WinSock); pinning a specific upstream commit and testing the CMake build on both platforms early is essential — gate on Phase 1 CI job before proceeding to Phase 2
- **Notification re-subscription on reconnect:** whether the library should automatically re-register active subscriptions after reconnect (and how to surface connection-state to consumers) is a design decision with correctness implications — needs explicit API design in Phase 5 planning before implementation
- **RPC method-call marshalling:** TC3 PLC method invocation framing (CLI `action` RPC mode) is MEDIUM-confidence; defer to v1.x and validate against a real TC3 target rather than speculating on struct layouts

## Sources

### Primary (HIGH confidence)
- https://github.com/Beckhoff/ADS — AdsLib `master` source: `AmsHeader.h`, `AdsDef.h`, `AdsDevice.h`, `AdsTool/main.cpp`, `AmsRouter.h`, `AmsConnection.h`, `NotificationDispatcher.h` — protocol constants, component structure, command IDs, index groups, header layouts
- https://api.dart.dev — `dart:typed_data` (`ByteData`/`Endian`), `dart:io` (`Socket`/`RawSocket`), `dart:async` (`Completer`/`StreamController`) — SDK APIs
- https://pub.dev/packages/args — args 2.7.0 `CommandRunner`/`Command`
- https://pub.dev/packages/test — test 1.31.2
- https://pub.dev/packages/lints — lints 6.1.0
- https://dart.dev/get-dart — Dart stable 3.12.2
- https://dart.dev/tools/pub/automated-publishing — OIDC automated pub.dev publishing
- https://infosys.beckhoff.com/content/1033/tcadscommon/12440282379.html — AMS/TCP Header + AMS Header specification
- https://infosys.beckhoff.com/content/1033/tcadscommon/12440299147.html — ADS Device Notification stream layout (AdsStampHeader/AdsNotificationSample)

### Secondary (MEDIUM confidence)
- https://github.com/jisotalo/ads-server and ads-client — independent TS implementations confirming header offsets, state flags, command IDs, error codes
- https://www.rugu.dev/en/blog/sockets-and-message-framing/ — length-prefix framing over `dart:io` sockets
- https://github.com/Beckhoff/ADS/issues/68 — "Create handle failed with 0x745 (1861)" route/timeout semantics
- https://infosys.beckhoff.com/content/1033/twincat_bsd/12459254539.html — ADS route creation
- https://flowfuse.com/blog/2026/03/how-to-connect-to-twincat-using-ads/ — routing layer is the usual failure point
- http://soup01.com/en/2021/12/14/beckhoffads-error-18610x745-solution/ — ADS error 1861 causes/solutions
- https://pub.dev/packages/framer — framer 1.0.1 `LengthPrefixedCodec` (confirmed big-endian/varint, rejected for this project)

---
*Research completed: 2026-07-03*
*Ready for roadmap: yes*
