# Phase 3: Core ADS Commands & Error Mapping - Research

**Researched:** 2026-07-04
**Domain:** ADS command veneer (AdsClient), ADS error-code table + typed exceptions, C++ mock data-store
**Confidence:** HIGH (all findings verified against vendored source in this repo)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Client API Shape**
- Entry class `AdsClient(connection, target, source)` — explicit AmsAddr addressing for now; Phase 4's router takes over source stamping without changing command-method code.
- Named parameters on command methods (`read(indexGroup:, indexOffset:, length:)`).
- Typed return values: `AdsStateInfo` (adsState as an `AdsState` enum + deviceState int) and `DeviceInfo` (name + version triple); raw ints remain accessible.
- WriteControl takes an optional named `data` parameter defaulting to empty bytes.

**Error Mapping (ERR-01)**
- Single `AdsException` carrying `code`, `name`, `message` (+ `isDeviceError`/`isClientError` helpers) — no deep subtype tree in v1.
- Full ADS global error table sourced from the vendored `third_party/ADS` `AdsDef.h` (named constants, code → name lookup).
- Errors throw at BOTH levels: non-zero AMS header `errorCode` AND non-zero command `result` field in the payload → `AdsException`.
- Error 1861 maps generically in this phase; the actionable source-NetId message is ERR-02, owned by Phase 4.

**Mock Extensions & Command Tests**
- Mock gains an in-memory data store keyed by (indexGroup, indexOffset): Read/Write/ReadWrite operate on it with write-back persisting within a session; canned ReadState/WriteControl responses.
- Magic index group fixture: requests to a designated indexGroup make the mock return a chosen non-zero ADS error — real error frames exercised end-to-end.
- Coverage bar: integration test per command (success path) + at least one live error-response case + unit tests for the error-table mapping at both levels (AMS errorCode, payload result).

### Claude's Discretion
- File layout for the client + errors (suggested: `lib/src/client/`, `lib/src/protocol/ads_error.dart` or similar — keep `protocol/` pure).
- Exact `AdsState` enum members (from `ADSSTATE_*` constants) and `DeviceInfo` field naming.
- Mock data-store implementation details and the magic indexGroup value.
- Whether ReadWrite gets a convenience that returns the read bytes directly (it should).

### Deferred Ideas (OUT OF SCOPE)
- ERR-02 actionable 1861 message → Phase 4 (router owns source NetId).
- Typed value conversion (BOOL/INT/REAL/STRING) → Phase 7 (SYM-03); this phase stays at `Uint8List` payloads.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CMD-01 | Read bytes at (indexGroup, indexOffset, length) [0x0002] | `encodeReadRequest`/`decodeReadResponse` exist (commands.dart); client wires them + throws on both error levels. Mock data-store Read case (this doc §Mock). |
| CMD-02 | Write bytes at (indexGroup, indexOffset) [0x0003] | `encodeWriteRequest`/`decodeWriteResponse` exist; mock Write case persists write-back for read-after-write tests. |
| CMD-03 | ReadWrite (write-then-read one round-trip) [0x0009] | `encodeReadWriteRequest`/`decodeReadWriteResponse` exist; client convenience returns read bytes directly; mock ReadWrite = write-then-read on same key. |
| CMD-04 | Read device state (adsState + deviceState) [0x0004] | `decodeReadStateResponse` exists; client wraps as `AdsStateInfo` with `AdsState` enum (§AdsState enum). Mock returns connection-scoped current state. |
| CMD-05 | Set device state via WriteControl [0x0005] | `encodeWriteControlRequest` (optional `data`) exists; mock stores state so ReadState reflects it (§Mock ReadState/WriteControl). |
| CMD-06 | Read device info (name + version) [0x0001] | `decodeReadDeviceInfoResponse` exists; client wraps as `DeviceInfo`. Mock already answers this (unchanged — keeps `--selftest` green). |
| ERR-01 | Map ADS error codes to typed exceptions distinct from transport errors | Full error table extracted from `AdsDef.h` (§ADS Error Table). `AdsException` sits alongside `MalformedFrameException`/`AdsTimeoutException`/`AdsConnectionException` — a distinct family. Both-levels throw (§request() seam). |
</phase_requirements>

## Summary

This phase is a thin veneer plus two data assets. The six request encoders and sealed `AdsResponse` decoders already exist and are golden-parity proven (`lib/src/protocol/commands.dart`). `AmsConnection.request()` already handles correlation, timeout, and disconnect fan-out. What remains: (1) an `AdsClient` that calls encoder → `request()` → decoder and throws `AdsException` on either error level; (2) the ADS error-code table transcribed from the vendored `AdsDef.h`; (3) `AdsState` enum + typed `AdsStateInfo`/`DeviceInfo`; (4) C++ mock extensions — a keyed data store, stateful WriteControl/ReadState, and two magic-indexGroup error triggers.

Two genuinely open technical questions were resolved by reading source:

1. **The error table is fully enumerated below**, transcribed verbatim from `third_party/ADS/AdsLib/standalone/AdsDef.h` (the locked source of truth). It is ready to paste into a Dart constants file. `1861 == 0x745 == ADSERR_CLIENT_SYNCTIMEOUT`.
2. **`AmsConnection.request()` currently drops the AMS header `errorCode`.** `_onFrame` decodes the full 32-byte AMS header (which *contains* `errorCode`) but completes the request Future with only the payload slice. To satisfy the "throw at BOTH levels" decision, the connection must surface `errorCode` to the client. Recommendation below: return it alongside the payload and let the client map both — keeps `AmsConnection` transport-pure.

**Primary recommendation:** Add `AdsClient` (async, outside `protocol/`) that composes existing encoders/decoders; put the pure error table + `AdsException` in `protocol/ads_error.dart`; change `request()` to surface the AMS `errorCode` (record or tiny value type); extend the mock's `switch (aoe.cmdId())` with a connection-scoped `std::map<std::pair<u32,u32>, vector<u8>>` store, stateful ADS-state fields, and two magic index-groups (one for payload-`result` errors, one for AMS-`errorCode` errors). Leave `buildReadDeviceInfoRes` and `--selftest` untouched.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Command encode/decode | `protocol/commands.dart` (pure) | — | Already shipped Phase 1; client only calls it. |
| Error table + `AdsException` | `protocol/ads_error.dart` (pure) | — | Pure lookup data + a value type; no async → stays in `protocol/`. |
| Compose encode→request→decode | `client/ads_client.dart` (async) | connection | Async orchestration belongs outside `protocol/`. |
| Both-levels error check/throw | `client/ads_client.dart` | connection surfaces the raw AMS errorCode | Mapping needs the table (client's concern); connection stays transport-generic. |
| AMS errorCode surfacing | `connection/ams_connection.dart` | — | The field is decoded here; only the plumbing (not the mapping) belongs here. |
| Mock command semantics + error fixtures | `test_harness/mock_server.cpp` (C++) | — | Test double; source of truth for integration behavior. |

## ADS Error Table (ERR-01) — ready to transcribe

> **Source (VERIFIED, this repo):** `third_party/ADS/AdsLib/standalone/AdsDef.h` lines 131–280. This is the locked source of truth per CONTEXT. All codes are the full u32 AMS/ADS error value (base range + offset), shown in hex. `0x0000` (`ADSERR_NOERR`) is success and never throws.

**Range map (for `isDeviceError`/`isClientError` helpers and message grouping):**

| Range base | Class | Notes |
|------------|-------|-------|
| `0x0000` | Global (`ERR_GLOBAL`) | Router/transport-level; typically arrives in the **AMS header errorCode**, not the ADS payload result. `0x06`/`0x07` are the "port not found"/"missing route" pair. |
| `0x0500` | Router (`ERR_ROUTER`) | Local AMS router errors. |
| `0x0700` | ADS **device** error (`ERR_ADSERRS`, `0x00–0x3F`) | `isDeviceError` → code in `[0x0700, 0x073F]`. |
| `0x0740` | ADS **client** error (`0x40–0x55`) | `isClientError` → code in `[0x0740, 0x07FF]`. `0x745` (1861) is the sync-timeout / missing-route symptom. |

### Global return codes (base `0x0000`)
| Code | Constant | Canonical text |
|------|----------|----------------|
| `0x0006` | GLOBALERR_TARGET_PORT | target port not found, possibly the ADS Server is not started |
| `0x0007` | GLOBALERR_MISSING_ROUTE | target machine not found, possibly missing ADS routes |
| `0x0019` | GLOBALERR_NO_MEMORY | no memory |
| `0x001A` | GLOBALERR_TCP_SEND | TCP send error |

### Router return codes (base `0x0500`)
| Code | Constant | Canonical text |
|------|----------|----------------|
| `0x0506` | ROUTERERR_PORTALREADYINUSE | the desired port number is already assigned |
| `0x0507` | ROUTERERR_NOTREGISTERED | port not registered |
| `0x0508` | ROUTERERR_NOMOREQUEUES | the maximum number of ports reached |

### ADS device errors (base `0x0700`)
| Code | Constant | Canonical text |
|------|----------|----------------|
| `0x0700` | ADSERR_DEVICE_ERROR | error class < device error > |
| `0x0701` | ADSERR_DEVICE_SRVNOTSUPP | service is not supported by server |
| `0x0702` | ADSERR_DEVICE_INVALIDGRP | invalid indexGroup |
| `0x0703` | ADSERR_DEVICE_INVALIDOFFSET | invalid indexOffset |
| `0x0704` | ADSERR_DEVICE_INVALIDACCESS | reading/writing not permitted |
| `0x0705` | ADSERR_DEVICE_INVALIDSIZE | parameter size not correct |
| `0x0706` | ADSERR_DEVICE_INVALIDDATA | invalid parameter value(s) |
| `0x0707` | ADSERR_DEVICE_NOTREADY | device is not in a ready state |
| `0x0708` | ADSERR_DEVICE_BUSY | device is busy |
| `0x0709` | ADSERR_DEVICE_INVALIDCONTEXT | invalid context (must be in Windows) |
| `0x070A` | ADSERR_DEVICE_NOMEMORY | out of memory |
| `0x070B` | ADSERR_DEVICE_INVALIDPARM | invalid parameter value(s) |
| `0x070C` | ADSERR_DEVICE_NOTFOUND | not found (files, ...) |
| `0x070D` | ADSERR_DEVICE_SYNTAX | syntax error in command or file |
| `0x070E` | ADSERR_DEVICE_INCOMPATIBLE | objects do not match |
| `0x070F` | ADSERR_DEVICE_EXISTS | object already exists |
| `0x0710` | ADSERR_DEVICE_SYMBOLNOTFOUND | symbol not found |
| `0x0711` | ADSERR_DEVICE_SYMBOLVERSIONINVALID | symbol version invalid (online change) → release handle and get a new one |
| `0x0712` | ADSERR_DEVICE_INVALIDSTATE | server is in invalid state |
| `0x0713` | ADSERR_DEVICE_TRANSMODENOTSUPP | AdsTransMode not supported |
| `0x0714` | ADSERR_DEVICE_NOTIFYHNDINVALID | notification handle is invalid (online change) → release handle and get a new one |
| `0x0715` | ADSERR_DEVICE_CLIENTUNKNOWN | notification client not registered |
| `0x0716` | ADSERR_DEVICE_NOMOREHDLS | no more notification handles |
| `0x0717` | ADSERR_DEVICE_INVALIDWATCHSIZE | size for watch too big |
| `0x0718` | ADSERR_DEVICE_NOTINIT | device not initialized |
| `0x0719` | ADSERR_DEVICE_TIMEOUT | device has a timeout |
| `0x071A` | ADSERR_DEVICE_NOINTERFACE | query interface failed |
| `0x071B` | ADSERR_DEVICE_INVALIDINTERFACE | wrong interface required |
| `0x071C` | ADSERR_DEVICE_INVALIDCLSID | class ID is invalid |
| `0x071D` | ADSERR_DEVICE_INVALIDOBJID | object ID is invalid |
| `0x071E` | ADSERR_DEVICE_PENDING | request is pending |
| `0x071F` | ADSERR_DEVICE_ABORTED | request is aborted |
| `0x0720` | ADSERR_DEVICE_WARNING | signal warning |
| `0x0721` | ADSERR_DEVICE_INVALIDARRAYIDX | invalid array index |
| `0x0722` | ADSERR_DEVICE_SYMBOLNOTACTIVE | symbol not active (online change) → release handle and get a new one |
| `0x0723` | ADSERR_DEVICE_ACCESSDENIED | access denied |
| `0x0724` | ADSERR_DEVICE_LICENSENOTFOUND | no license found → activate license for TwinCAT 3 function |
| `0x0725` | ADSERR_DEVICE_LICENSEEXPIRED | license expired |
| `0x0726` | ADSERR_DEVICE_LICENSEEXCEEDED | license exceeded |
| `0x0727` | ADSERR_DEVICE_LICENSEINVALID | license invalid |
| `0x0728` | ADSERR_DEVICE_LICENSESYSTEMID | license invalid system id |
| `0x0729` | ADSERR_DEVICE_LICENSENOTIMELIMIT | license not time limited |
| `0x072A` | ADSERR_DEVICE_LICENSEFUTUREISSUE | license issue time in the future |
| `0x072B` | ADSERR_DEVICE_LICENSETIMETOLONG | license time period too long |
| `0x072C` | ADSERR_DEVICE_EXCEPTION | exception in device specific code → check each device transition |
| `0x072D` | ADSERR_DEVICE_LICENSEDUPLICATED | license file read twice |
| `0x072E` | ADSERR_DEVICE_SIGNATUREINVALID | invalid signature |
| `0x072F` | ADSERR_DEVICE_CERTIFICATEINVALID | public key certificate |

### ADS client errors (base `0x0740`)
| Code | Constant | Canonical text |
|------|----------|----------------|
| `0x0740` | ADSERR_CLIENT_ERROR | error class < client error > |
| `0x0741` | ADSERR_CLIENT_INVALIDPARM | invalid parameter at service call |
| `0x0742` | ADSERR_CLIENT_LISTEMPTY | polling list is empty |
| `0x0743` | ADSERR_CLIENT_VARUSED | var connection already in use |
| `0x0744` | ADSERR_CLIENT_DUPLINVOKEID | invoke id in use |
| `0x0745` | ADSERR_CLIENT_SYNCTIMEOUT | timeout elapsed → check ADS routes of sender and receiver and your firewall setting **(this is decimal 1861; ERR-02's actionable NetId message is Phase 4)** |
| `0x0746` | ADSERR_CLIENT_W32ERROR | error in win32 subsystem |
| `0x0747` | ADSERR_CLIENT_TIMEOUTINVALID | invalid client timeout value |
| `0x0748` | ADSERR_CLIENT_PORTNOTOPEN | ads port not opened |
| `0x0749` | ADSERR_CLIENT_NOAMSADDR | no ams address |
| `0x0750` | ADSERR_CLIENT_SYNCINTERNAL | internal error in ads sync |
| `0x0751` | ADSERR_CLIENT_ADDHASH | hash table overflow |
| `0x0752` | ADSERR_CLIENT_REMOVEHASH | key not found in hash table |
| `0x0753` | ADSERR_CLIENT_NOMORESYM | no more symbols in cache |
| `0x0754` | ADSERR_CLIENT_SYNCRESINVALID | invalid response received |
| `0x0755` | ADSERR_CLIENT_SYNCPORTLOCKED | sync port is locked |

> **Transcription note (VERIFIED):** the client range has intentional gaps — the header jumps `0x0749 → 0x0750` (no `0x074A–0x074F`). Do **not** invent filler entries. Model the table as an explicit code→(name,text) map; a lookup miss returns a synthetic name like `ADS error 0x{code}` so unknown codes from a real PLC still surface a usable message. Recommend `isDeviceError => code >= 0x0700 && code < 0x0740` and `isClientError => code >= 0x0740 && code <= 0x07FF`.

## AdsState enum (CMD-04) — ready to transcribe

> **Source (VERIFIED, this repo):** `AdsDef.h` lines 334–356, `enum ADSSTATE : uint16_t`.

| Value | Constant | Suggested Dart member |
|-------|----------|-----------------------|
| 0 | ADSSTATE_INVALID | `invalid` |
| 1 | ADSSTATE_IDLE | `idle` |
| 2 | ADSSTATE_RESET | `reset` |
| 3 | ADSSTATE_INIT | `init` |
| 4 | ADSSTATE_START | `start` |
| 5 | ADSSTATE_RUN | `run` |
| 6 | ADSSTATE_STOP | `stop` |
| 7 | ADSSTATE_SAVECFG | `saveConfig` |
| 8 | ADSSTATE_LOADCFG | `loadConfig` |
| 9 | ADSSTATE_POWERFAILURE | `powerFailure` |
| 10 | ADSSTATE_POWERGOOD | `powerGood` |
| 11 | ADSSTATE_ERROR | `error` |
| 12 | ADSSTATE_SHUTDOWN | `shutdown` |
| 13 | ADSSTATE_SUSPEND | `suspend` |
| 14 | ADSSTATE_RESUME | `resume` |
| 15 | ADSSTATE_CONFIG | `config` |
| 16 | ADSSTATE_RECONFIG | `reconfig` |
| 17 | ADSSTATE_STOPPING | `stopping` |
| 18 | ADSSTATE_INCOMPATIBLE | `incompatible` |
| 19 | ADSSTATE_EXCEPTION | `exception` |

`ADSSTATE_MAXSTATES` (20) is a sentinel, not a real state — omit it. **Provide a tolerant `AdsState.fromCode(int)`** that maps unknown u16 values (a real PLC can return values outside this list) to a fallback rather than throwing — e.g. an `unknown` member or a nullable return, since `ReadStateResponse.adsState` is a raw int and `AdsStateInfo` must not throw on decode. `deviceState` stays a raw int (device-specific, no enum). [ASSUMED] the `unknown`-fallback naming — confirm during planning; the enum values themselves are VERIFIED.

## The `request()` errorCode seam (ERR-01, both levels)

**Finding (VERIFIED, `lib/src/connection/ams_connection.dart`):**
- `request()` returns `Future<Uint8List>` — **payload bytes only** (line 138, 272–277).
- `_onFrame` decodes the *full* 32-byte AMS header via `AmsHeader.decode(...)` (line 247–248). That header object **has** an `errorCode` field (`ams_header.dart` line 55, wire offset 24). But `_onFrame` uses only `commandId` and `invokeId`; it completes the Completer with `Uint8List.sublistView(frame, headerEnd)` and **discards `errorCode`**.
- **Therefore the AMS header errorCode is NOT surfaced or checked today.** `request()` does not throw on a non-zero AMS errorCode. The client cannot currently see it.

**Exception family (VERIFIED, `connection/exceptions.dart`):** transport errors are `AdsTimeoutException` and `AdsConnectionException`; wire errors are `MalformedFrameException`. `AdsException` (ERR-01) must be a *distinct* new type so callers can `catch` device errors separately (this is exactly the separation the codebase already documents).

**Recommendation — surface the errorCode, map in the client (do NOT map in the connection):**

Change `request()` to resolve to both the AMS `errorCode` and the payload, e.g. a Dart record `Future<({int amsErrorCode, Uint8List payload})>` (records are already the house style per STACK.md), or a tiny value type `AmsResponse(errorCode, payload)` if a named public type reads better. In `_onFrame`, pass `header.errorCode` into the completed value. The `AdsClient` then, for every command:

1. If `amsErrorCode != 0` → `throw AdsException.fromCode(amsErrorCode)`.
2. Decode the payload with the existing decoder.
3. If the decoded `response.result != 0` → `throw AdsException.fromCode(response.result)`.
4. Otherwise map to the typed return (`DeviceInfo`, `AdsStateInfo`, bytes, …).

**Why this seam and not "check inside `AmsConnection`":** `AmsConnection` is deliberately scoped to framing + correlation + timeout + disconnect fan-out (see its library doc). The error *table* lives in `protocol/` and is an ADS-semantics concern. Making the connection throw `AdsException` would pull ADS-error mapping into the transport core and force it to import the table — muddying L4. Surfacing the raw code keeps one mapping site (the client) that handles both levels uniformly. Cost: a one-line update to the single existing caller in `test/integration/ams_connection_live_test.dart` (which today reads the payload directly) — trivial, same phase.

> Alternative considered: keep `request()` returning `Uint8List` and add a parallel `requestFull()`. Rejected — two code paths for one concern, and every command needs the errorCode, so the split adds no value.

**Verify-ordering note (from CONTEXT):** the `request()` signature change and its caller update must land in the same task, since tasks may only reference files/APIs that exist at their completion.

## Mock data-store design (C++) — Read/Write/ReadWrite + error fixtures

**Where:** extend the `switch (aoe.cmdId())` inside `runServer`'s frame-drain loop (`test_harness/mock_server.cpp` lines 404–426). Today only `AoEHeader::READ_DEVICE_INFO` has a case; add `READ` (0x02), `WRITE` (0x03), `READ_STATE` (0x04), `WRITE_CTRL` (0x05), `READ_WRITE` (0x09). **Do not touch `buildReadDeviceInfoRes`, `runSelftest`, or the golden path — `--selftest` must stay byte-identical.**

**Store (connection-scoped for deterministic per-test isolation):** declare alongside `inbuf` inside the per-connection block (near line 355), so each accepted connection — i.e. each `startMockServer()` in each integration test — begins clean and write-back persists only "within a session":

```cpp
std::map<std::pair<uint32_t,uint32_t>, std::vector<uint8_t>> store;
uint16_t curAdsState = ADSSTATE_RUN;   // 5 — seed to RUN
uint16_t curDeviceState = 0;
// optional: seed a fixture so a pure Read (no prior Write) is meaningful
store[{0xF005u, 0x123u}] = {0x2A,0x00,0x00,0x00};  // matches read_req golden key
```

**Reading the request ADS payload:** the ADS body starts at `inbuf.data() + sizeof(AmsTcpHeader) + sizeof(AoEHeader)`, length `tcp.length() - sizeof(AoEHeader)`. Parse the fixed little-endian header fields (group u32, offset u32, length u32, …) with the same `putU16/putU32` mirror-helpers already in the file (add matching `getU32` readers, or `memcpy` since the mock is little-endian on both dev platforms).

**Per-command semantics (deterministic):**

| Command | Behavior |
|---------|----------|
| Read (0x02) | key = (group, offset). `data` = first `length` bytes of `store[key]`, zero-padded if shorter/absent. Response payload: `result u32=0, readLength u32=length, data`. |
| Write (0x03) | `store[{group,offset}] = writeData` (the incoming bytes). Response: `result u32=0`. Enables read-after-write assertions. |
| ReadWrite (0x09) | Write-then-read the **same** key: `store[key] = writeData; return first readLength bytes of store[key]`. Response: `result u32=0, readLength u32, data`. Round-trips satisfyingly (write "MAIN.foo", read it back). |
| ReadState (0x04) | Response: `result u32=0, adsState u16=curAdsState, deviceState u16=curDeviceState`. |
| WriteControl (0x05) | **Stateful:** `curAdsState = req.adsState; curDeviceState = req.deviceState;` Response: `result u32=0`. So a WriteControl(STOP) → ReadState round-trip observably returns STOP — the state analogue of write-back. |

**Magic index-group error fixtures (both levels — CONTEXT requires each):**

Pick two reserved, obviously-synthetic index groups (u32). Recommended:

- `kErrResultGroup = 0xE770'0000` → **payload-`result` error path.** Any command targeting this group returns a response whose ADS `result` field = the request's `indexOffset`. The Dart test requests `(group: 0xE7700000, offset: 0x703)` and asserts `AdsException(code: 0x703, name: 'ADSERR_DEVICE_INVALIDOFFSET')`. One fixture covers *any* code.
- `kErrAmsGroup = 0xE770'0001` → **AMS-header-`errorCode` path.** Same trick, but the mock sets the **AMS header errorCode** (not the payload result) to the request offset. This requires a small extension to `wrapResponse`: add an optional `uint32_t amsError = 0` and, after layering, patch the 4 bytes at `sizeof(AmsTcpHeader) + 24` (AMS header errorCode wire offset — VERIFIED against `ams_header.dart` line 88) in little-endian, exactly as the existing code already patches the `stateFlags` bytes at offset 18. Test requests `(group: 0xE7700001, offset: 0x007)` and asserts `AdsException(code: 0x0007 / GLOBALERR_MISSING_ROUTE)` surfaced from the AMS header.

Encode `result` in a response with the standard `putU32(p, result)` at payload offset 0 (all decoders read `result` at offset 0). For Read/ReadWrite error responses, `readLength=0` + empty data is the natural shape.

**`--selftest` intact:** all new logic is additive inside `runServer`; `runSelftest` still calls only the unchanged `buildReadDeviceInfoRes`. The one shared function touched is `wrapResponse` (adding a defaulted `amsError=0` param) — its behavior for the existing ReadDeviceInfo call is unchanged, so the golden and selftest stay byte-identical. Add a build gate: keep running `mock_server --selftest` in CI as today.

> **Golden vs. live distinction (note for planner):** the committed `*_res.hex` goldens drive *codec* unit tests (`golden_parity_test.dart`) via `dump_golden.cpp` — they do **not** need to match the mock's dynamic data-store responses. The mock only needs byte-accuracy for ReadDeviceInfo (selftest) and *structural* correctness for the rest (the Dart decoders validate structure). So the store's seeded values need not equal the goldens.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Command framing | New encoders | `commands.dart` `encode*Request` | Golden-parity proven Phase 1. |
| Response parsing + overrun guard | Manual byte slicing | `commands.dart` `decode*Response` | Already validates `readLength` (T-1-03). |
| Correlation / timeout / fan-out | Any retry/matching logic | `AmsConnection.request()` | Map-remove-wins invariant already correct. |
| C++ response byte-layout | Hand-packed buffers | `wrapResponse` + `AoEHeader`/`AmsTcpHeader` prepend | Byte-accurate by construction from the vendored framing structs. |
| Error message text | Invented strings | The canonical text column above (from `AdsDef.h` comments) | Matches Beckhoff/AdsLib operator expectations. |

**Key insight:** this phase adds ~0 new algorithms. The only new *logic* is a code→exception lookup and a two-level throw; everything else is wiring and data transcription.

## Common Pitfalls

### Pitfall 1: Checking only the payload `result`, missing the AMS errorCode
**What goes wrong:** router-level failures (missing route `0x07`, port not found `0x06`, timeout `0x745`) come back in the **AMS header errorCode**, often with an empty/short ADS payload — so a client that only reads `response.result` sees `0` (or a decode failure) and reports success/garbage.
**How to avoid:** check `amsErrorCode` **first**, before decoding, and throw. The mock's `kErrAmsGroup` fixture makes this a live test, not just a unit assumption.
**Warning sign:** an error-injection test that only passes via the payload path.

### Pitfall 2: Breaking `--selftest` / goldens while extending the mock
**What goes wrong:** refactoring `wrapResponse` or `buildReadDeviceInfoRes` shifts a byte and the selftest gate fails, or worse passes by coincidence.
**How to avoid:** make the `wrapResponse` change purely additive (defaulted param); never edit the ReadDeviceInfo builder; run `mock_server --selftest` locally before commit.

### Pitfall 3: Process-global mock store leaking state across tests
**What goes wrong:** a `static`/global store makes test N see writes from test N-1 → flaky, order-dependent assertions.
**How to avoid:** declare the store connection-scoped (inside the accept-loop body). Each `startMockServer()` gets a fresh connection and fresh store.

### Pitfall 4: `AdsState.fromCode` throwing on an unknown value
**What goes wrong:** a real PLC returns a state outside 0–19 and `ReadState` blows up instead of surfacing the raw number.
**How to avoid:** tolerant `fromCode` with a fallback; keep the raw `adsState` int on `AdsStateInfo`.

### Pitfall 5: Endian slips in the new mock readers
**What goes wrong:** `memcpy`-ing multi-byte request fields on a big-endian assumption, or reusing host-order.
**How to avoid:** both CI (Linux) and dev (macOS) are little-endian and match the wire, but write explicit little-endian readers mirroring `putU32` so the code is correct-by-inspection (CLAUDE.md endian rule).

## Runtime State Inventory

Not applicable — this is a greenfield feature phase (new client class, new error table, additive mock cases). No rename/refactor/migration. No stored data, live-service config, OS registrations, secrets, or build artifacts carry a renamed identifier. **None — verified: the phase only adds new files plus additive C++ cases.**

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Dart SDK | client + unit/integration tests | ✓ (Phase 1/2 established) | `^3.5` floor, 3.12.x dev | — |
| CMake + C++ toolchain | mock_server rebuild | ✓ (Phase 1 harness) | as pinned | — |
| Vendored Beckhoff/ADS | AdsDef.h + framing structs | ✓ | commit 57d63747 | — |

No new external dependencies. No missing blockers.

## Package Legitimacy Audit

**No new packages installed in this phase.** The client and mock use only SDK libraries (`dart:typed_data`, `dart:async`) already in use, plus `meta` (already a dependency). slopcheck not applicable — nothing to install. Disposition: N/A.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `test` ^1.31.0 (Dart) |
| Config file | `dart_test.yaml` (`@Tags(['integration'])` splits fast codec/unit tests from mock-spawning tests) |
| Quick run command | `dart test test/unit` (pure-Dart, no mock, sub-second) |
| Full suite command | `dart test` (unit + integration; integration spawns the C++ mock via `test/support/mock_server.dart`) |

### Phase Requirements → Test Map
| Req | Behavior | Test Type | Automated Command | File Exists? |
|-----|----------|-----------|-------------------|-------------|
| CMD-01 | Read returns bytes; read-after-write matches | integration | `dart test test/integration/ads_client_test.dart -N read` | ❌ Wave 0 |
| CMD-02 | Write persists (read-back) | integration | `dart test test/integration/ads_client_test.dart -N write` | ❌ Wave 0 |
| CMD-03 | ReadWrite write-then-read round-trip | integration | `dart test test/integration/ads_client_test.dart -N read_write` | ❌ Wave 0 |
| CMD-04 | ReadState → `AdsStateInfo(run,…)` | integration | `dart test test/integration/ads_client_test.dart -N read_state` | ❌ Wave 0 |
| CMD-05 | WriteControl(STOP) then ReadState==STOP | integration | `dart test test/integration/ads_client_test.dart -N write_control` | ❌ Wave 0 |
| CMD-06 | ReadDeviceInfo → `DeviceInfo("Dart ADS Mock", v3.1.4024)` | integration | `dart test test/integration/ads_client_test.dart -N device_info` | ❌ Wave 0 |
| ERR-01 | code→(name,text) lookup incl. `0x745==1861`, range helpers, unknown-code fallback | unit | `dart test test/unit/ads_error_test.dart` | ❌ Wave 0 |
| ERR-01 | payload-`result` error → `AdsException` (client, via FakeTransport) | unit | `dart test test/unit/ads_client_test.dart -N result_error` | ❌ Wave 0 |
| ERR-01 | AMS-`errorCode` error → `AdsException` (client, via FakeTransport) | unit | `dart test test/unit/ads_client_test.dart -N ams_error` | ❌ Wave 0 |
| ERR-01 | live payload-result error via `kErrResultGroup` | integration | `dart test test/integration/ads_client_test.dart -N result_error` | ❌ Wave 0 |
| ERR-01 | live AMS-errorCode error via `kErrAmsGroup` | integration | `dart test test/integration/ads_client_test.dart -N ams_error` | ❌ Wave 0 |

> The existing `FakeTransport` (TRANS-04) lets the client's encode→decode→map path and **both** error levels be unit-tested with canned frames — no mock needed. The mock's magic-group fixtures give the same coverage end-to-end over a real socket.

### Sampling Rate
- **Per task commit:** `dart test test/unit` (+ `mock_server --selftest` when the C++ changed).
- **Per wave merge:** `dart test` (full, incl. integration).
- **Phase gate:** full suite green before `/gsd:verify-work`.

### Wave 0 Gaps
- [ ] `test/integration/ads_client_test.dart` — per-command success + live error cases (CMD-01..06, ERR-01)
- [ ] `test/unit/ads_error_test.dart` — error-table lookup + range helpers + `0x745`/unknown-code (ERR-01)
- [ ] `test/unit/ads_client_test.dart` — client both-levels throw via `FakeTransport` (ERR-01)
- [ ] C++: extend `mock_server.cpp` switch + `wrapResponse` amsError param; rebuild via existing CMake gate
- [ ] Update existing `test/integration/ams_connection_live_test.dart` for the `request()` return-shape change

## Security Domain

Low surface for this phase (no auth, no crypto, no untrusted-network parsing beyond the already-hardened frame assembler).

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | Decoders already validate `readLength` before slicing (T-1-03, `commands.dart`); the client must not re-slice unchecked. New C++ mock readers must bounds-check the ADS payload length before reading group/offset/length (a short/hostile frame must not overread `inbuf`). |
| V6 Cryptography | no | ADS has no transport crypto in scope. |
| V2/V3/V4 | no | No auth/session/access-control in this phase. |

| Pattern | STRIDE | Mitigation |
|---------|--------|-----------|
| Malformed/short response payload | Tampering / DoS | Decoders throw `MalformedFrameException`; client surfaces it distinctly from `AdsException`. |
| Hostile inbound frame length (mock side) | DoS | Existing `kMaxFrameBytes` 4 MiB guard already in the accept loop; new payload readers must respect `tcp.length()`. |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `AdsState.fromCode` uses an `unknown` fallback member/name for out-of-range values | AdsState enum | Low — naming only; enum values are VERIFIED. Confirm during planning. |
| A2 | Magic index-group constants `0xE7700000`/`0xE7700001` are free of collision with real ADS groups | Mock design | Low — chosen in an unused high range; planner may pick different sentinels (discretion). |
| A3 | Connection-scoped (not process-global) mock store is the intended "within a session" scope | Mock design | Low — matches how tests spawn one mock per test; confirm if any test reuses a connection across writes. |
| A4 | Changing `request()`'s return type (vs. adding a parallel method) is acceptable pre-1.0 API churn | request() seam | Low — single internal caller; CONTEXT anticipates the client composing on `request()`. |

## Sources

### Primary (HIGH confidence — verified in-repo this session)
- `third_party/ADS/AdsLib/standalone/AdsDef.h` — error codes (131–280), `ADSSTATE` enum (334–356), command IDs (34–43). Full error table + state enum transcribed verbatim.
- `lib/src/connection/ams_connection.dart` — `request()` returns payload only; `_onFrame` decodes header but discards `errorCode` (the seam).
- `lib/src/protocol/commands.dart` — six encoders + sealed `AdsResponse` decoders already exist; `result` at payload offset 0.
- `lib/src/protocol/ams_header.dart` — `errorCode` field, wire offset 24 (line 88).
- `lib/src/connection/exceptions.dart` / `lib/src/protocol/exceptions.dart` — existing exception family (`AdsTimeout`/`AdsConnection`/`MalformedFrame`).
- `test_harness/mock_server.cpp` — switch location (404–426), `wrapResponse` stateFlags-patch pattern (115–130), connection-scoped state (355), selftest isolation (202–227).
- `test/golden/*.hex`, `test/support/mock_server.dart`, `dart_test.yaml` layout — test infra + golden key values (Read/Write group `0xF005` offset `0x123`; ReadWrite group `0xF003`).
- `CLAUDE.md`, `.planning/config.json` — endian rule, `test`/`args`/`meta` stack, `nyquist_validation: true`.

## Metadata

**Confidence breakdown:**
- Error table: HIGH — transcribed verbatim from the vendored source of truth.
- AdsState enum: HIGH — verbatim from `AdsDef.h`.
- request() seam: HIGH — read the exact code path; `errorCode` is provably dropped.
- Mock design: HIGH (mechanics verified against existing mock structure); MEDIUM on the two discretionary constants (sentinel groups).

**Research date:** 2026-07-04
**Valid until:** stable — anchored to vendored source pinned at commit 57d63747; no external drift.
