# Feature Research

**Domain:** Industrial automation protocol client library (Beckhoff ADS / AMS over TCP) — pure-Dart port of Beckhoff C++ AdsLib, plus operator CLI
**Researched:** 2026-07-03
**Confidence:** HIGH (protocol constants and API surface verified byte-for-byte against Beckhoff/ADS `master` source: `AdsDef.h`, `AmsHeader.h`, `AdsDevice.h`, `AdsTool/main.cpp`). MEDIUM on some CLI UX interpretations (pull/push/action are project-defined verbs, not standard ADS terms).

---

## Protocol Surface Reference (source of truth)

These are the primitives every feature below is built from. Verified from `AdsLib/AmsHeader.h` and `AdsLib/standalone/AdsDef.h`.

### AoE / ADS command IDs (`leCmdId` in AMS header)

| Command | ID | Purpose | Dart consumer needs |
|---------|-----|---------|--------------------|
| INVALID | 0x0000 | — | never sent |
| ReadDeviceInfo | 0x0001 | Name + `AdsVersion` (version/revision/build) | `Future<DeviceInfo>` |
| Read | 0x0002 | Read `length` bytes at (indexGroup, indexOffset) | `Future<Uint8List>` |
| Write | 0x0003 | Write bytes at (indexGroup, indexOffset) | `Future<void>` |
| ReadState | 0x0004 | Returns (adsState, deviceState) | `Future<AdsState>` |
| WriteControl | 0x0005 | Set adsState + deviceState (+opt data) | `Future<void>` (drives `action`) |
| AddDeviceNotification | 0x0006 | Register notification, returns handle | internal → `Stream` |
| DeleteDeviceNotification | 0x0007 | Cancel by handle | `StreamSubscription.cancel()` |
| DeviceNotification | 0x0008 | **Server→client push** (no response) | demux → `Stream` events |
| ReadWrite | 0x0009 | Write then read in one round-trip | `Future<Uint8List>`; basis for symbols + sum |

### AMS header (32 bytes, all fields little-endian)

`targetNetId[6]`, `targetPort u16`, `sourceNetId[6]`, `sourcePort u16`, `cmdId u16`, `stateFlags u16`, `length u32`, `errorCode u32`, `invokeId u32`. State flags: `AMS_REQUEST=0x0004`, `AMS_RESPONSE=0x0005`, `AMS_UDP=0x0040`. Prefixed by AMS/TCP header: `reserved u16` + `length u32`.

### Index groups (from `AdsDef.h`)

Symbol access: `SYM_HNDBYNAME 0xF003`, `SYM_VALBYNAME 0xF004`, `SYM_VALBYHND 0xF005`, `SYM_RELEASEHND 0xF006`, `SYM_INFOBYNAME 0xF007`, `SYM_VERSION 0xF008`, `SYM_INFOBYNAMEEX 0xF009`, `SYM_UPLOAD 0xF00B`, `SYM_UPLOADINFO 0xF00C`, `SYM_DT_UPLOAD 0xF00E`, `SYM_UPLOADINFO2 0xF00F`.
Sum/batched: `SUMUP_READ 0xF080`, `SUMUP_WRITE 0xF081`, `SUMUP_READWRITE 0xF082`, `SUMUP_READEX 0xF083`, `SUMUP_READEX2 0xF084`, `SUMUP_ADDDEVNOTE 0xF085`, `SUMUP_DELDEVNOTE 0xF086`.

### Notification attribute + transmission modes

`AdsNotificationAttrib { cbLength u32, nTransMode u32, nMaxDelay u32, {nCycleTime | dwChangeFilter} u32 }`. Times in 100 ns units.
Modes: `NOTRANS 0`, `CLIENTCYCLE 1`, `CLIENTONCHA 2`, `SERVERCYCLE 3`, `SERVERONCHA 4`, `SERVERCYCLE2 5`, `SERVERONCHA2 6`, `CLIENT1REQ 10`. In practice servers use **SERVERONCHA (4)** (push on value change, `maxDelay` batches) and **SERVERCYCLE (3)** (push every `cycleTime`).
Notification wire frame (cmd 0x0008 payload): `length u32`, `stamps u32`, then per stamp `{ timestamp u64 (FILETIME, 100ns since 1601), sampleCount u32, then per sample: notificationHandle u32, sampleSize u32, data[] }`.

### ADS states (`ADSSTATE_*`): INVALID 0, IDLE 1, RESET 2, INIT 3, START 4, RUN 5, STOP 6, SAVECFG 7, LOADCFG 8, CONFIG 15, RECONFIG 16 ... (RUN/CONFIG are the operator-relevant ones).

---

## Feature Landscape

### Table Stakes (Users Expect These)

Missing any of these makes the library not a credible AdsLib parity port.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| AMS/TCP + AMS header framing (encode/decode) | Nothing works without the wire envelope | MEDIUM | Fixed 6-byte AMS/TCP header + 32-byte AMS header; length-prefixed stream reassembly over `dart:io` `Socket`. Foundation for everything. |
| Invoke-ID request/response correlation | TCP multiplexes many in-flight requests on one socket | MEDIUM | Map `invokeId → Completer`; monotonic counter; timeout per request. Command 0x0008 (notification) has no invokeId and must bypass this map. |
| Read (0x0002) | Core operation | LOW | (indexGroup, indexOffset, length) → bytes. |
| Write (0x0003) | Core operation | LOW | (indexGroup, indexOffset, bytes) → void. |
| ReadWrite (0x0009) | Needed for symbols + sum commands | LOW | write-buffer then read-buffer in one frame; server returns actual read length. |
| ReadState (0x0004) | Health/mode check; used by CLI `state`/`action` | LOW | Returns adsState + deviceState. |
| WriteControl (0x0005) | Switch PLC RUN/CONFIG/STOP | LOW | Drives `action` state changes. |
| ReadDeviceInfo (0x0001) | Identify the target (name + version) | LOW | Trivial once framing exists; good first smoke test. |
| ADS error-code mapping | Every response carries `errorCode`; users need meaningful failures | LOW-MEDIUM | Map the ADS global error table (0x700–0x7xx etc.) to typed Dart exceptions. Distinct from AMS transport errors. |
| Connection lifecycle (open/close/timeout) | Sockets fail; PLCs reboot | MEDIUM | Explicit `connect()`/`close()`, per-request timeout, surface disconnect. |
| Symbol handle by name (SYM_HNDBYNAME→VALBYHND→RELEASEHND) | Users address `MAIN.fbAxis.rPos`, not raw offsets | MEDIUM | ReadWrite `0xF003` (write name string, read u32 handle); then Read/Write `0xF005` with indexOffset=handle; release with Write `0xF006`. **Must release handles** or the PLC leaks them. Depends on ReadWrite. |
| Symbol browse (SYM_UPLOADINFO + SYM_UPLOAD) | "What variables exist?" is the first thing an operator asks | HIGH | Read `0xF00C`/`0xF00F` for (symCount, symByteLength[, dtCount, dtLength]); then Read `0xF00B` for the blob; parse variable-length `AdsSymbolEntry` records (entryLen, iGroup, iOffs, size, dataType, flags, name/type/comment with length-prefixed strings). |
| Device notifications as Streams (Add/Delete 0x0006/0x0007 + demux 0x0008) | The reason this project exists (HMI needs live values) | HIGH | Register with `AdsNotificationAttrib`; server pushes 0x0008 frames; demux by notificationHandle → per-subscription `Stream`; `onCancel` sends DeleteDeviceNotification. Depends on framing + lifecycle. |
| Typed value conversion (PLC types ↔ Dart) | Raw `Uint8List` is unusable for an HMI; BOOL/INT/DINT/REAL/LREAL/STRING expected | MEDIUM | Little-endian codecs: BOOL(1), BYTE/USINT(1), WORD/UINT(2), INT(2), DWORD/UDINT(4), DINT(4), REAL(4 f32), LREAL(8 f64), STRING (fixed, null-terminated Latin-1), WSTRING (UTF-16), TIME/DT (durations/FILETIME). Client must still expose **raw bytes** as an escape hatch. |
| Configurable transport: direct vs local TwinCAT router | Explicit project requirement; deployments differ | HIGH | Direct: embed a minimal AmsRouter, assign our own source AmsNetId+port, connect to peer `:48898`. Local: connect to TwinCAT router on `127.0.0.1:48898`, obtain a dynamic port. Both share the same framing/command layer. |
| Route management (add/list routes) | Direct connections require a route entry on the PLC or it silently drops replies | HIGH | Local-route table (AmsNetId→IP) for our router. Remote AddRoute is a **separate UDP protocol on port 48899** (broadcast add-route packet with credentials) — matches AdsLib `bhf::ads::AddRoute` / adstool `addroute`. |

### Differentiators (Competitive Advantage over a bare port)

Where a pure-Dart, idiomatic library beats an FFI wrapper or a literal C++ transliteration.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Idiomatic async API (Futures + Streams, no callbacks/handles leaking to caller) | Dart-native ergonomics; notifications as first-class `Stream<T>` with backpressure/cancel | MEDIUM | The whole reason to reimplement vs FFI. Hide invoke-IDs, notification handles, symbol handles behind managed objects. |
| Sum (batched) commands with per-item error surfacing | 100 reads in 1 round-trip; huge latency win for HMI polling | HIGH | SUMUP_READ `0xF080`: ReadWrite with N×12-byte sub-headers (iGroup,iOffs,len) in write-buf; response = N×u32 error codes **then** concatenated data. SUMUP_WRITE `0xF081`: N headers+data in, N error codes out. SUMUP_READWRITE `0xF082`: N×16-byte headers (iGroup,iOffs,readLen,writeLen)+data in, per-item (err u32,len u32)+data out. **Partial failure is normal** — one item's error must not fail the batch; return `List<Result<T>>`. Depends on ReadWrite. |
| Type-system upload (SYM_DT_UPLOAD 0xF00E) → structured decoding | Decode STRUCTs/ARRAYs/enums by name, not just scalars | HIGH | Parse `AdsDatatypeEntry` (sub-items = struct members, array dims, base type). Enables reading a whole FB instance into a Dart map/typed object. Depends on browse. |
| Typed symbol wrapper (`AdsSymbol<double>` with `.read()/.write()/.stream()`) | One object binds name→handle→type→conversion→notification | MEDIUM | Builds on symbol-by-name + type info + notifications. Signature convenience feature for the HMI consumer. |
| Automatic handle + subscription lifecycle mgmt | No leaked PLC handles even on error/reconnect | MEDIUM | RAII-equivalent via Dart `finalizer`/explicit `dispose()`; re-register notifications on reconnect. Mirrors AdsLib's `AdsHandle` unique_ptr semantics. |
| RPC / method-call invocation (TC3 methods) | Call PLC methods with in/out params — powers CLI `action` beyond state changes | HIGH | Get handle of `Inst.Method#input` via SYM_HNDBYNAME, ReadWrite on SYM_VALBYHND with serialized inputs → outputs. Needs type info for param marshalling. MEDIUM-confidence on exact framing; verify against a TC3 target. |
| Reconnect with notification re-subscription | HMIs run for weeks; PLCs reboot | MEDIUM | Backoff reconnect; replay AddDeviceNotification for live streams; emit connection-state events. |
| Structured logging / wire-trace hook | Debugging protocol issues without Wireshark | LOW | Optional hex-dump of frames; invaluable during byte-for-byte validation against the C++ mock. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| Web/browser (`dart:html`) support | "Run the HMI in a browser" | ADS is raw TCP; browsers have no socket API. Already Out of Scope in PROJECT.md. | Native VM + Flutter desktop/mobile only; a separate server-side bridge if web is ever needed. |
| FFI to TcAdsDll / native AdsLib | "Reuse the proven C impl" | Defeats the entire purpose (portability, no native toolchain); platform-specific binaries. | Pure-Dart reimplementation validated against the C++ mock. |
| ADS **server**/device role (answer ADS requests) | "Make my Dart app an ADS device" | Different problem domain (implement full server semantics, notification generation, symbol tables); large scope. | Client only. The CMake mock server (C++) fills the test-double role. |
| Reimplement/replace TwinCAT router or runtime | "No dependency on TwinCAT at all" | The local-router mode still interoperates with real TwinCAT; a full router replacement is a product on its own. | Minimal embedded router for direct mode; use the real TwinCAT router when present. |
| Auto-discovery / broadcast scan of all PLCs on the network | "Find every device automatically" | UDP `48899` broadcast scanning is a whole sub-protocol, fragile across VLANs, security-sensitive; scope creep. | Explicit target AmsNetId+IP config; `netid` lookup of a known host as a stretch goal. |
| GUI / dashboard bundled in the package | "Ship a monitoring UI" | Couples a protocol lib to a UI framework; bloats the package; the first consumer already *is* the HMI. | CLI for operators; library stays UI-agnostic so the consumer builds its own UI. |
| Persisting/caching symbol tables across runs to disk | "Speed up startup" | Symbol tables change on PLC redownload (SYM_VERSION); stale cache = silent wrong reads. | Optional in-session cache keyed on SYM_VERSION `0xF008`; re-upload on version change. |
| Rich expression/scripting language in the CLI | "Compute derived values" | Turns an operator tool into a DSL; unbounded scope. | Emit JSON; let users pipe to `jq`/scripts. |

---

## CLI Command Definitions

The reference `adstool` (from Beckhoff/ADS) provides the closest prior art: `addroute`, `netid`, `state`, `raw`, `plc` (read-symbol/write-symbol/show-symbols), `var`, `file`. Mapping the project's verbs concretely:

| CLI verb | Concrete behavior | Underlying ADS ops | adstool analog |
|----------|-------------------|--------------------|----------------|
| `browse` | List/filter PLC symbols (name, type, size, iGroup/iOffs, comment); `--json` for machine output; optional glob filter (`MAIN.*`) | SYM_UPLOADINFO(2) `0xF00C`/`0xF00F` + SYM_UPLOAD `0xF00B`; optionally SYM_DT_UPLOAD `0xF00E` for type expansion | `plc show-symbols` |
| `read` | Read one variable by name **or** by `--group/--offset[--len]`; typed output by default, `--raw` for hex | SYM_HNDBYNAME+VALBYHND, or direct Read `0x0002` | `var` (read) / `raw` |
| `write` | Write one variable by name or group/offset; value parsed to the symbol's PLC type; `--raw` accepts hex | SYM_HNDBYNAME+VALBYHND Write, or Write `0x0003` | `var` (write) / `raw` |
| `subscribe` | Stream live notifications for one or more symbols; print timestamped samples until Ctrl-C; `--on-change`/`--cycle=<ms>`/`--max-delay` flags | AddDeviceNotification `0x0006`, demux `0x0008`, DeleteDeviceNotification `0x0007` on exit | (none — differentiator) |
| `pull` | **Dump** symbols and/or current values to a file (JSON/CSV). "Snapshot the PLC." Two modes: symbol table only, or table + read all values (uses sum-read for speed) | browse + SUMUP_READ `0xF080` | `plc show-symbols` + batched reads |
| `push` | **Apply** values from a file back to the PLC (the inverse of `pull`'s value dump). Batched, with per-item pass/fail report; `--dry-run` | SUMUP_WRITE `0xF081` (or per-symbol handle writes) | `var` write, batched |
| `action` | Issue a control action: (a) state change `--state=RUN\|CONFIG\|STOP` via WriteControl; (b) invoke a PLC RPC method `Inst.Method` with args | WriteControl `0x0005`; or SYM_HNDBYNAME + ReadWrite on SYM_VALBYHND for RPC | `state` (for the state case) |

**Operator UX expectations:** stable exit codes (0 ok / non-zero on ADS error), `--json` on read-oriented commands for piping, human-readable ADS error names (not bare hex), `--target <AmsNetId>`/`--host <ip>`/`--port` connection flags consistent across all subcommands, and `--timeout`. `pull`/`push` should round-trip losslessly (a `pull` then `push` of the same file is a no-op).

---

## Feature Dependencies

```
AMS/TCP + AMS header framing
    └──requires──> dart:io Socket + length-prefixed reassembly
    │
    ├──enables──> invoke-id correlation
    │                 └──enables──> Read / Write / ReadWrite / ReadState / WriteControl / ReadDeviceInfo
    │                                   │
    │                                   ReadWrite ──enables──> Symbol handle-by-name
    │                                   ReadWrite ──enables──> Sum commands (0xF080–0xF086)
    │                                   Read      ──enables──> Symbol browse (UPLOADINFO/UPLOAD)
    │
    └──enables──> notification demux (cmd 0x0008, bypasses invoke-id map)
                      └──requires──> AddDeviceNotification/DeleteDeviceNotification
                      └──enables──> notifications-as-Streams

Connection lifecycle (open/close/reconnect) ──underpins──> everything stateful
                      └──enables──> reconnect + notification re-subscription

Local AmsRouter (source NetId/port assignment + local-route table)
    └──requires──> route management
    └──enables──> direct-connection transport
Remote AddRoute (UDP :48899) ──enables──> PLC accepts our direct connection

Symbol browse ──enables──> Type-system upload (SYM_DT_UPLOAD)
    Symbol-by-name + type info + notifications ──compose──> Typed AdsSymbol<T> wrapper
    Type info ──enables──> RPC method-call marshalling (CLI `action`)

CLI browse   ─uses─> Symbol browse
CLI read/write ─uses─> Symbol-by-name (+ typed conversion) or raw Read/Write
CLI subscribe ─uses─> notifications-as-Streams
CLI pull/push ─uses─> browse + Sum commands
CLI action   ─uses─> WriteControl and/or RPC method call
```

### Dependency Notes

- **Symbol-by-name requires ReadWrite:** handle resolution is a single ReadWrite to `0xF003` (write name, read handle). No ReadWrite, no named access.
- **Sum commands require ReadWrite:** every sum variant is one ReadWrite to `0xF08x`; the batch payload is hand-packed into the write/read buffers. Partial-error handling is intrinsic — the response interleaves per-item u32 error codes, so a `List<Result<T>>` return shape is mandatory, not optional.
- **Notifications bypass invoke-id correlation:** cmd `0x0008` is an unsolicited server push with no matching request; the receive loop must route by `notificationHandle`, not invoke-id. This is the one place the request/response abstraction leaks and must be designed for up front.
- **Direct transport requires the local router AND a remote route:** our embedded router provides a source AmsNetId+port; the *target's* TwinCAT router must also have a route back to us (added via UDP `:48899`) or it drops responses. Local-router mode avoids this by delegating to the installed TwinCAT router.
- **Typed conversion depends on type info for anything beyond scalars:** scalars can be converted from the symbol entry's `dataType`+`size`; STRUCT/ARRAY decoding needs SYM_DT_UPLOAD.
- **Handle + subscription lifecycle spans reconnect:** re-subscription on reconnect depends on retaining the original `AdsNotificationAttrib` per stream.

---

## MVP Definition

### Launch With (v1 — full-parity target per PROJECT.md)

- [ ] AMS/TCP + AMS header framing with invoke-id correlation — nothing works without it
- [ ] Read / Write / ReadWrite / ReadState / WriteControl / ReadDeviceInfo — core command set
- [ ] ADS error-code → typed-exception mapping — usable failures
- [ ] Connection lifecycle (connect/close/timeout) — reliability floor
- [ ] Symbol handle-by-name (resolve/read/write/release) — named access
- [ ] Symbol browse (UPLOADINFO + UPLOAD, scalar entries) — discoverability
- [ ] Device notifications as Streams (Add/Delete + 0x0008 demux) — the core value
- [ ] Typed scalar conversion (BOOL/INT/DINT/REAL/LREAL/STRING) + raw-bytes escape hatch — usable values
- [ ] Sum commands (READ/WRITE/READWRITE) with per-item results — HMI-grade batching
- [ ] Configurable direct + local-router transport with local-route table — deployment requirement
- [ ] CLI: browse, read, write, subscribe, pull, push, action
- [ ] Byte-for-byte validation against the C++ CMake mock server

### Add After Validation (v1.x)

- [ ] Type-system upload (SYM_DT_UPLOAD) → STRUCT/ARRAY decoding — trigger: consumer needs composite reads
- [ ] Typed `AdsSymbol<T>` convenience wrapper — trigger: repetitive bind-read-convert patterns in the HMI
- [ ] Reconnect + notification re-subscription — trigger: long-running deployment stability
- [ ] SUMUP_ADDDEVNOTE/DELDEVNOTE batched subscription — trigger: many simultaneous notifications
- [ ] RPC method-call invocation (CLI `action` RPC mode) — trigger: PLC exposes callable methods
- [ ] Remote AddRoute (UDP :48899) helper / CLI `addroute` — trigger: field deployment onto fresh PLCs

### Future Consideration (v2+)

- [ ] Symbol-table caching keyed on SYM_VERSION — defer: correctness risk; only worth it if startup latency proven painful
- [ ] `netid` discovery lookup — defer: nice-to-have operator convenience
- [ ] File access on target (adstool `file`) — defer: outside core PLC-variable use case
- [ ] License / rtime / ecat diagnostics (adstool parity) — defer: niche, not part of HMI value

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| Framing + invoke-id correlation | HIGH | MEDIUM | P1 |
| Read/Write/ReadWrite/ReadState/WriteControl/DeviceInfo | HIGH | LOW | P1 |
| Error-code mapping | HIGH | LOW | P1 |
| Connection lifecycle | HIGH | MEDIUM | P1 |
| Symbol handle-by-name | HIGH | MEDIUM | P1 |
| Symbol browse (scalar) | HIGH | HIGH | P1 |
| Notifications as Streams | HIGH | HIGH | P1 |
| Typed scalar conversion + raw escape | HIGH | MEDIUM | P1 |
| Sum commands (read/write/readwrite) | HIGH | HIGH | P1 |
| Direct + local-router transport | HIGH | HIGH | P1 |
| CLI browse/read/write/subscribe | HIGH | MEDIUM | P1 |
| CLI pull/push | MEDIUM | MEDIUM | P1 |
| CLI action (state) | MEDIUM | LOW | P1 |
| Type-system upload (STRUCT/ARRAY) | MEDIUM | HIGH | P2 |
| Typed AdsSymbol<T> wrapper | MEDIUM | MEDIUM | P2 |
| Reconnect + re-subscribe | MEDIUM | MEDIUM | P2 |
| RPC method call (action RPC) | MEDIUM | HIGH | P2 |
| Remote AddRoute (UDP :48899) | MEDIUM | MEDIUM | P2 |
| Wire-trace/logging hook | MEDIUM | LOW | P2 |
| Symbol-table cache | LOW | MEDIUM | P3 |
| netid discovery / file / diagnostics | LOW | MEDIUM | P3 |

**Priority key:** P1 must-have for launch · P2 add when possible · P3 future.

---

## Competitor Feature Analysis

| Feature | Beckhoff C++ AdsLib (reference) | pyads (Python, wraps TcAdsDll on Win / has native router on Linux) | node-ads / ads-client (JS, native) | Our Approach (pure Dart) |
|---------|-------------------------------|-------------------------------------------------------------------|------------------------------------|--------------------------|
| Transport | Own AmsRouter (standalone) or TwinCAT router | TcAdsDll (Win) / bundled AdsLib router (Linux) | Pure JS TCP + own routing | Pure Dart `dart:io`, embedded router + local-router mode |
| API style | C++ RAII (`AdsDevice`, `AdsHandle` unique_ptr) | Sync functions + callbacks | Callbacks / async | Idiomatic Futures + Streams |
| Symbol by name | GetHandle(name) | `read_by_name` | by-name | managed handle, auto-release |
| Browse | SYM_UPLOAD parsing | `get_all_symbols` | symbol upload | browse (+ optional type upload) |
| Notifications | callback + hUser | `add_device_notification` callback | event emitter | first-class `Stream<T>` |
| Sum commands | ReadWrite `0xF08x` helpers | `SumRead/SumWrite` | limited | full sum read/write/readwrite with per-item results |
| CLI | `adstool` | none (library only) | none | full operator CLI (browse/read/write/subscribe/pull/push/action) |
| RPC methods | via ReadWrite | manual | manual | first-class `action` (v1.x) |

Our distinct position: **the only pure-Dart client**, Stream-native notifications, and a first-class operator CLI with pull/push snapshot-and-apply that no reference tool offers as a single verb.

## Sources

- Beckhoff/ADS `master` — `AdsLib/AmsHeader.h` (AoE command IDs, AMS header/state-flags, AMS/TCP header) — HIGH
- Beckhoff/ADS `master` — `AdsLib/standalone/AdsDef.h` (ADSIGRP_*, ADSSTATE_*, ADSTRANS_*, AdsNotificationAttrib/Header, AmsAddr, AdsVersion structs) — HIGH
- Beckhoff/ADS `master` — `AdsLib/AdsDevice.h` (high-level API: GetHandle, ReadReqEx2, WriteReqEx, ReadWriteReqEx2, GetState/SetState, GetDeviceInfo, RAII handles) — HIGH
- Beckhoff/ADS `master` — `AdsTool/main.cpp` (reference CLI subcommands: addroute, netid, state, raw, plc, var, file) — HIGH
- Beckhoff InfoSys ADS specification (transmission-mode semantics, sum-command layout, symbol upload record format) — MEDIUM (training + doc structure; exact struct byte layouts to be confirmed against the C++ mock during implementation)
- pyads / node-ads / ads-client ecosystem (competitor feature comparison) — MEDIUM (training data)

---
*Feature research for: Beckhoff ADS pure-Dart client library + operator CLI*
*Researched: 2026-07-03*
