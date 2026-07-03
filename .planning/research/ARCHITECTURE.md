# Architecture Research

**Domain:** Pure-Dart network protocol client library (Beckhoff ADS / AMS-over-TCP) + CLI + C++ CMake test harness
**Researched:** 2026-07-03
**Confidence:** HIGH (AdsLib component structure verified against github.com/Beckhoff/ADS source; ADS wire protocol is stable and well-documented; Dart concurrency mapping is standard idiom)

## Standard Architecture

### How the reference AdsLib is structured

The Beckhoff C++ AdsLib (`github.com/Beckhoff/ADS`, `AdsLib/` directory) is a layered client with these real components:

| AdsLib component | Role | Notes verified from source |
|------------------|------|----------------------------|
| `Sockets` / `TcpSocket` | Raw socket abstraction (connect, send, recv, deadline reads) | Platform-wrapped (`wrap_socket.h`) |
| `Frame` | Byte buffer for building/parsing AMS frames | `Frame.h/.cpp` |
| `AmsHeader` | Binary layout of AMS/TCP header (6 bytes) + AMS header (32 bytes) | `AmsTcpHeader`, `AoEHeader` structs, all fields little-endian |
| `AmsConnection` | One TCP connection to one target; owns a **dedicated receiver thread**; correlates responses by `invokeId`; routes notifications | `std::thread receiver`, `std::atomic<uint32_t> invokeId`, `std::array<AmsResponse, NUM_PORTS_MAX> queue` |
| `AmsPort` | A logical local endpoint (AMS port number + timeout + its notification registrations) | `dispatcherList` keyed by (AmsAddr, handle) |
| `AmsRouter` | Owns all connections; maps `AmsNetId → AmsConnection`; allocates ports; manages routes | `mapping` (NetId→conn), `connections` set, `ports[]` array, `AddRoute/DelRoute/GetConnection` |
| `NotificationDispatcher` | Own thread + semaphore; parses notification stream, maps `hNotify → Notification` callback | `std::map<uint32_t, shared_ptr<Notification>>`, `Run()`, `Notify()` |
| `AdsDevice` / `AdsVariable` / `SymbolAccess` | High-level typed API: symbol-by-name, typed read/write, RAII notifications | OOI (object-oriented interface) layer |
| `AdsLib.h` / `AdsDef.h` | Public C API + protocol constants (command IDs, index groups, error codes) | Stable public surface |
| `AdsTool/main.cpp` | Reference CLI (`netid`, `addroute`, `raw`, `state`, `var`, `plc read-symbol/write-symbol/show-symbols`, `file`, `rtime`, …) | Maps almost 1:1 to our CLI verbs |

**Key architectural insight:** In C++ the concurrency is achieved with **threads** — one receiver thread per connection blocking on `recv()`, plus a separate dispatcher thread so notification callbacks never block the receive loop. **This entire thread structure collapses into Dart's single event loop.** A `Socket` stream listener replaces the receiver thread; `Completer` replaces the response condition-variable; a `StreamController` per notification handle replaces the dispatcher thread. The *component boundaries* transfer directly; the *threading* does not.

### System Overview (proposed Dart layering — mirrors AdsLib boundaries)

```
┌──────────────────────────────────────────────────────────────────┐
│  L7  CLI  (bin/ads.dart)                                           │
│      browse · read · write · subscribe · pull · push · action     │
├──────────────────────────────────────────────────────────────────┤
│  L6  High-level typed client   (AdsDevice / AdsClient)            │
│      read<T>() write<T>() readState() writeControl()              │
│      symbolByName() browseSymbols() subscribe()→Stream sum()      │
├──────────────────────────────────────────────────────────────────┤
│  L5  Router / connection manager   (AmsRouter)                   │
│      NetId→AmsConnection map · port allocation · route table      │
│      transport target resolution (direct vs local-router)         │
├──────────────────────────────────────────────────────────────────┤
│  L4  Connection   (AmsConnection)                                 │
│   ┌───────────────────────┐   ┌──────────────────────────────┐   │
│   │ invokeId → Completer   │   │ notifyHandle → StreamCtrl    │   │
│   │ (request correlation)  │   │ (notification demux)         │   │
│   └───────────┬───────────┘   └──────────────┬───────────────┘   │
├───────────────┴──────────────────────────────┴───────────────────┤
│  L3  Codec   (AMS/TCP + AMS header + per-command payload)         │
│      encode requests · decode responses · frame assembler         │
├──────────────────────────────────────────────────────────────────┤
│  L2  Transport   (SocketTransport over dart:io Socket)           │
│      connect · add(bytes) · Stream<Uint8List> in · close          │
├──────────────────────────────────────────────────────────────────┤
│  L1  Wire  (dart:io Socket → TCP :48898)                          │
└──────────────────────────────────────────────────────────────────┘
       ▲ symmetric to →  C++ mock ADS server (CMake, vendored AdsLib framing)
```

### Component Responsibilities

| Component | Responsibility | Dart implementation |
|-----------|----------------|---------------------|
| `SocketTransport` (L2) | Own the `Socket`; expose `Future connect()`, `void add(List<int>)`, `Stream<Uint8List> inbound`, `close()`. Nothing about ADS. | Wrap `Socket.connect`; forward `socket` as broadcast/single stream; abstract so a fake transport can back unit tests |
| `FrameCodec` + `FrameAssembler` (L3) | Encode a request into bytes; decode a fully-received AMS frame into a typed message. `FrameAssembler` reassembles TCP chunks into whole frames (read 6-byte header → `length` → buffer until complete). | Pure functions + `ByteData`/`Uint8List`; stateful accumulator for reassembly |
| `AmsConnection` (L4) | One TCP conn to one peer. Assign `invokeId`; hold `Map<int, _Pending>` (Completer + Timer); on inbound frame: if cmd==Notification route to demux, else complete matching pending. | Listens to `assembler` stream; owns correlation + demux maps |
| Notification demux (L4) | Map `hNotify → StreamController`; parse notification stream (stamps→samples) and `add()` decoded samples to the right controller. | `Map<int, StreamController<AdsNotification>>` |
| `AmsRouter` (L5) | Map `AmsNetId → AmsConnection` (create/reuse); allocate local AMS ports; hold route table; **resolve transport target** (direct IP vs `127.0.0.1:48898`) and stamp the correct source NetId. | `Map<AmsNetId, AmsConnection>`; port counter starting ~0x8000 |
| `AdsClient` / `AdsDevice` (L6) | Typed ergonomic API. Compose raw commands: symbol-handle-by-name (ReadWrite `0xF003`), value-by-handle (`0xF005`), browse (`0xF00B/0xF00F`), sum commands (`0xF080+`). Return `Future`/`Stream`. | Thin orchestration over router+connection |
| `AdsCli` (L7) | Parse args; map verbs to client calls; format output; manage lifetime (connect/subscribe/teardown). | `args` package; `bin/` entrypoint |

## Recommended Project Structure

```
dart-ads/
├── lib/
│   ├── ads.dart                     # public library barrel export
│   └── src/
│       ├── protocol/                # L3 constants + codec (no I/O)
│       │   ├── constants.dart       # command IDs, index groups (0xF0xx), ADS error codes, state flags
│       │   ├── ams_net_id.dart      # AmsNetId (6 bytes), AmsAddr (NetId+port)
│       │   ├── ams_header.dart      # AmsTcpHeader (6B) + AmsHeader (32B) encode/decode
│       │   ├── commands.dart        # per-command request/response payload codecs
│       │   ├── notification.dart    # notification stream: stamp/sample parsing
│       │   └── frame_assembler.dart # TCP-chunk → whole-frame reassembly
│       ├── transport/               # L2
│       │   ├── transport.dart       # Transport interface
│       │   └── socket_transport.dart# dart:io Socket implementation
│       ├── connection/              # L4
│       │   ├── ams_connection.dart  # invokeId↔Completer, notify demux
│       │   └── pending_request.dart # Completer + timeout Timer
│       ├── router/                  # L5
│       │   ├── ams_router.dart      # NetId→conn, port alloc, route table
│       │   └── transport_target.dart# direct vs local-router resolution
│       └── client/                  # L6
│           ├── ads_client.dart      # typed API surface
│           ├── symbol.dart          # symbol-by-name / browse
│           └── sum_command.dart     # batched reads/writes
├── bin/
│   └── ads.dart                     # L7 CLI (browse/read/write/subscribe/pull/push/action)
├── test/
│   ├── unit/                        # codec tests against golden frames
│   ├── golden/                      # *.hex frame fixtures produced by C++ dumper
│   └── integration/                 # tests that Process.start the mock server
└── test_harness/                    # C++ CMake mock ADS server
    ├── CMakeLists.txt
    ├── vendor/ADS/                  # vendored Beckhoff/ADS (framing reuse)
    ├── mock_server.cpp              # deterministic ADS device
    └── dump_golden.cpp             # optional: emit golden request/response frames
```

### Structure Rationale

- **`protocol/` has zero I/O dependencies** — it is pure encode/decode. This is the layer most heavily unit-tested against golden frames, and the layer where wire-parity bugs live. Keeping it I/O-free makes it trivially testable and reusable by the golden-frame tooling.
- **`transport/` is an interface + one impl** — a `FakeTransport` lets `AmsConnection` be unit-tested with scripted byte sequences, no sockets.
- **`connection/` vs `router/` split** mirrors AdsLib's `AmsConnection` vs `AmsRouter` boundary: one connection = one peer socket + correlation; the router owns the *set* of connections and the addressing/routing policy. Keeping them separate is what makes direct-vs-router mode a router-only concern.
- **`test_harness/` is a sibling, not under `test/`**, because it is a C++/CMake artifact with its own build lifecycle; `dart test` shells out to its built binary.

## Architectural Patterns

### Pattern 1: invokeId → Completer correlation (request/response)

**What:** Every request gets a unique monotonically increasing `invokeId`. A `Map<int, _Pending>` holds the `Completer` (and a timeout `Timer`) for each in-flight request. The single inbound frame handler looks up the response's `invokeId` and completes it. This replaces the C++ receiver-thread + condition-variable model with one event-loop map.

**When to use:** Any multiplexed request/response protocol over one socket.
**Trade-offs:** Must guard against invokeId reuse/wraparound and orphaned completers on timeout/disconnect (fail all pending on socket error). Zero locking needed — single-threaded event loop guarantees atomic map access.

```dart
class AmsConnection {
  int _nextInvokeId = 1;
  final _pending = <int, _Pending>{};

  Future<AdsResponse> request(AdsRequest req) {
    final id = _nextInvokeId++;                 // no lock: single event loop
    final c = Completer<AdsResponse>();
    final timer = Timer(timeout, () {
      _pending.remove(id)?.completer
          .completeError(AdsTimeoutException(id));
    });
    _pending[id] = _Pending(c, timer);
    _transport.add(_codec.encode(req, invokeId: id));
    return c.future;
  }

  void _onFrame(AmsFrame f) {
    if (f.commandId == Cmd.notification) { _demux(f); return; }
    final p = _pending.remove(f.invokeId);
    p?..timer.cancel()..completer.complete(_codec.decodeResponse(f));
  }
}
```

### Pattern 2: notification handle → Stream demux (server-push fan-out)

**What:** Notification frames (command id `0x0008`) carry `invokeId == 0` and are *not* replies to any request. Their payload is a stream: `length, stampCount, {timestamp, sampleCount, {hNotification, sampleSize, data}...}...`. Each `hNotification` was returned earlier by AddDeviceNotification (`0x0006`). Maintain `Map<int, StreamController>` keyed by handle; parse each sample and `add()` it to the matching controller.

**When to use:** Subscription/push semantics on a multiplexed connection.
**Trade-offs:** Handle lifecycle must be managed — creating a subscription is a round-trip (AddDeviceNotification returns the handle), and canceling the `StreamSubscription` must trigger DeleteDeviceNotification (`0x0007`). Use per-handle single-subscription controllers with `onCancel` cleanup.

```dart
Stream<AdsNotification> subscribe(AdsAddr addr, NotifyAttrib a) async* {
  final handle = await _addDeviceNotification(addr, a);   // round-trip
  final ctrl = StreamController<AdsNotification>(
    onCancel: () => _deleteDeviceNotification(addr, handle),
  );
  _demuxControllers[handle] = ctrl;
  yield* ctrl.stream;
}
```

### Pattern 3: Pluggable transport target (direct vs local-router)

**What:** The AMS *framing is identical* in both modes; only two things change — the TCP endpoint the socket opens, and the source NetId stamped into outgoing frames. Encapsulate that decision in the router so nothing below L5 knows which mode is active.

- **Direct mode:** our library *is* the router (exactly what AdsLib's own AmsRouter does). Open TCP to `remoteIp:48898`. Source NetId = a configured/synthetic local NetId; target NetId = the remote device's NetId. No TwinCAT install required.
- **Local-router mode:** open TCP to `127.0.0.1:48898` (the installed TwinCAT router). Source NetId = the local machine's real NetId (which the router recognizes); target NetId = the final device. The router forwards. Requires pre-configured routes in TwinCAT.

**When to use:** Any time one protocol supports both peer-to-peer and broker-mediated topologies.
**Trade-offs:** Direct mode needs us to manage per-target connections and NetId assignment ourselves; router mode delegates that but adds an external dependency and route-provisioning. Making it a runtime strategy (per PROJECT.md requirement) keeps both paths on one codebase.

```dart
abstract class TransportTarget {
  ({String host, int port}) endpoint(AmsNetId targetDevice);
  AmsNetId sourceNetId;
}
class DirectTarget    implements TransportTarget { /* host = device IP */ }
class LocalRouterTarget implements TransportTarget { /* host = 127.0.0.1 */ }
```

## Data Flow

### Request flow (e.g. `read` a variable by index-group/offset)

```
CLI `ads read 0x4020 0 --len 4`
   ↓
AdsClient.read(group, offset, len)
   ↓  build AdsReadRequest{indexGroup, indexOffset, length}
AmsRouter.connectionFor(targetNetId)         → returns/creates AmsConnection
   ↓                                            (endpoint + sourceNetId from TransportTarget)
AmsConnection.request(req)
   ↓  invokeId = N; _pending[N] = Completer+Timer
FrameCodec.encode → [AMS/TCP hdr 6B][AMS hdr 32B][Read payload 12B]
   ↓
SocketTransport.add(bytes)  →  TCP :48898  →  device
                                              device replies
TCP inbound chunks → FrameAssembler (buffer until full frame)
   ↓  whole AmsFrame (invokeId=N, cmd=Read)
AmsConnection._onFrame → _pending.remove(N).complete(AdsReadResponse{result,len,data})
   ↓
AdsClient decodes typed value ← Future resolves
   ↓
CLI prints value
```

### Notification flow (server-initiated push)

```
subscribe() → AddDeviceNotification round-trip → device returns hNotify=H
   register _demuxControllers[H] = StreamController
   ... time passes ...
device emits Device-Notification frame (cmd 0x08, invokeId=0)
   ↓
TCP inbound → FrameAssembler → whole frame
   ↓
AmsConnection._onFrame: cmd==0x08 → _demux(frame)
   ↓  parse stream: for each stamp{timestamp} → for each sample{hNotify, size, data}
_demuxControllers[H].add(AdsNotification{timestamp, data})
   ↓
consumer's Stream<AdsNotification> receives event
   (StreamSubscription.cancel() → DeleteDeviceNotification(H) → controller closed)
```

The two paths **share the same inbound frame handler** and diverge on a single `commandId == 0x08` check — exactly the AdsLib split between the response `queue` and the `NotificationDispatcher`.

## Concurrency Model (Dart)

- **Single event loop, no Isolates.** ADS work is I/O-bound; framing/decoding is a few bytes of `ByteData` reads. There is no CPU-bound stage that would block the loop. An Isolate would only add message-copy overhead across the socket boundary. **Recommendation: do not use Isolates.** (Only revisit if a consumer decodes multi-MB sum-command payloads and profiling shows loop stalls — unlikely in v1.)
- **Correlation without locks.** Because everything runs on one loop, the `invokeId → Completer` map and the notify-demux map need no synchronization — the atomics/mutexes AdsLib requires are unnecessary.
- **Timeouts:** per-request `Timer`; on fire, remove pending and `completeError`. Mirrors AmsPort's `tmms` (default 5000 ms).
- **Backpressure:** inbound — the `FrameAssembler` consumes chunks as they arrive; if a consumer's notification `Stream` is slow, use a bounded/dropping policy or pause the subscription (be careful: pausing the *socket* stalls all multiplexed traffic, so prefer per-handle buffering, not socket pause). Outbound — `Socket.add` buffers; for large writes `await socket.flush()` or watch `done`. In practice request volume is low.
- **Failure fan-out:** on socket error/close, complete-error every pending Completer and close every notification controller so nothing hangs forever.

## AMS Addressing (verified)

- **AmsNetId:** 6 bytes, conventionally `IPv4 + ".1.1"` (e.g. `192.168.1.10.1.1`). Identifies a device on the AMS network.
- **AmsPort:** 16-bit logical endpoint. Well-known: `851` = TC3 PLC runtime (`801` TC2), `10000` = router, `10000+` system services. Our *local* source port is allocated by the router (AdsLib uses an array up to `NUM_PORTS_MAX`, ~`0x8000`+).
- **AmsAddr = (AmsNetId, AmsPort).** Every AMS header carries target AmsAddr + source AmsAddr.
- **Header layout (all little-endian):** `AmsTcpHeader{reserved u16=0, length u32}` (6B) then `AmsHeader{targetNetId[6], targetPort u16, sourceNetId[6], sourcePort u16, commandId u16, stateFlags u16, length u32, errorCode u32, invokeId u32}` (32B). `stateFlags`: `0x0004` request, `0x0005` response.
- **Command IDs:** `0x01` ReadDeviceInfo, `0x02` Read, `0x03` Write, `0x04` ReadState, `0x05` WriteControl, `0x06` AddDeviceNotification, `0x07` DeleteDeviceNotification, `0x08` DeviceNotification, `0x09` ReadWrite.
- **Symbol/browse index groups:** `0xF003` handle-by-name (ReadWrite), `0xF005` value-by-handle, `0xF006` release-handle, `0xF00B` symbol upload, `0xF00F` upload-info; sum commands `0xF080`+ (SumRead/Write/ReadWrite).

## Test Harness Architecture

### C++ mock ADS server (CMake)

**Goal:** a deterministic ADS *device* that speaks byte-identical AMS/TCP framing, so Dart integration tests validate the Dart codec against real C++-produced frames (per PROJECT.md: the mock is the source of truth).

Structure:
1. **Reuse AdsLib framing.** Vendor `Beckhoff/ADS` under `test_harness/vendor/ADS/` and link the mock against its `AmsHeader`/`Frame` structs (or copy those headers). This guarantees the mock's byte layout is the reference layout — the whole point of the exercise.
2. **Minimal accept loop.** Bind a `SOCK_STREAM` listener; per client: read 6-byte AMS/TCP header → read `length` bytes → parse AMS header → `switch(commandId)`:
   - `Read (0x02)` → return canned bytes keyed by `(indexGroup, indexOffset)` from a fixture table.
   - `Write (0x03)` → store value, return `errorCode=0`.
   - `ReadWrite (0x09)` → handle symbol-by-name (`0xF003`) returning a fixed handle; sum commands.
   - `ReadState (0x04)` → fixed adsState/deviceState.
   - `AddDeviceNotification (0x06)` → allocate handle, register a timer that emits `DeviceNotification (0x08)` frames on a schedule (or on a trigger command); return handle.
   - `DeleteDeviceNotification (0x07)` → stop timer, return 0.
   - Echo target/source NetId swapped, `stateFlags=0x0005`, same `invokeId`.
3. **Determinism:** a fixture table (compiled-in or loaded from a JSON/CSV) maps requests → exact responses, so tests assert precise bytes and values. Notification cadence is fixed or command-driven so tests are not timing-flaky.

### How Dart tests drive it

- **Port selection:** mock binds ephemeral port `0`, then prints `LISTENING <port>\n` to stdout. Avoids port-collision flakiness. (Alternative: Dart binds a `ServerSocket` on `0`, records the port, closes it, passes it as `argv` — but ephemeral+stdout handshake is more robust against races.)
- **Launch/ready/teardown:**
  ```dart
  final proc = await Process.start(mockBinary, ['--fixtures', path]);
  final port = await proc.stdout
      .transform(utf8.decoder).transform(const LineSplitter())
      .firstWhere((l) => l.startsWith('LISTENING '))
      .then((l) => int.parse(l.split(' ').last));
  // ... connect Dart client to 127.0.0.1:port, run assertions ...
  proc.kill(ProcessSignal.sigterm);   // tearDown
  await proc.exitCode;
  ```
  Use the readiness *line* as the barrier — never a `sleep`.
- **CI build step:** `cmake -S test_harness -B build && cmake --build build` before `dart test`; skip integration tests (tag them) when the binary is absent so unit tests still run on machines without a C++ toolchain.

### Golden frames (recommended, decouples codec tests from the live server)

Add a tiny `dump_golden.cpp` (also linked against vendored AdsLib) that serializes a fixed catalog of request AND response frames to `test/golden/*.hex`. Dart unit tests then:
- assert `FrameCodec.encode(knownRequest) == goldenRequestBytes` (encode parity), and
- assert `FrameCodec.decode(goldenResponseBytes) == expectedTypedValue` (decode parity).

This gives fast, hermetic, byte-for-byte parity tests with no process launch, while the live mock covers end-to-end behavior (round-trips, notifications, timeouts, reconnect).

## Suggested Build Order / Dependency Graph

```
(1) protocol/constants + ams_net_id      ── no deps (pure data)
        ↓
(2) protocol/ams_header + commands + notification + frame_assembler
        ↓            └── testable NOW with golden frames + C++ dump_golden.cpp
(3) transport/ (interface + socket + fake)   ── depends only on dart:io
        ↓
(4) connection/ams_connection                ── depends on (2)+(3)
        ↓            └── first integration point: test against mock server
(5) router/ams_router + transport_target     ── depends on (4); adds direct/router modes
        ↓
(6) client/ads_client + symbol + sum         ── depends on (5)
        ↓
(7) bin/ads.dart CLI                         ── depends on (6)

Parallel track:
(T) test_harness/ C++ mock + dump_golden     ── built alongside (2); required by (4)+ integration tests
```

**Phasing implications for the roadmap:**
- **Phase A — Protocol core (1–2) + golden-frame harness (T).** Highest-leverage, most parity-critical, fully unit-testable without sockets. The C++ dumper should land here so codec tests are byte-verified from day one.
- **Phase B — Transport + connection (3–4) + live mock server.** First real round-trips; introduces invokeId correlation and notification demux. Needs the runnable mock, so budget C++/CMake + `Process.start` plumbing here.
- **Phase C — Router + addressing (5).** Direct vs local-router modes and route management. Depends on a working connection.
- **Phase D — Typed client + symbols + sum (6).** Symbol-by-name, browse, batched commands — the parity-heavy high-level surface.
- **Phase E — CLI (7).** Thin veneer; validates the whole stack end-to-end (browse/read/write/subscribe/pull/push/action map onto AdsTool's proven verb set).

Notification handling (add/delete + stream demux) spans B (mechanism) and D (typed `Stream` API); flag it for deeper research at the phase that owns the `subscribe` verb because handle lifecycle + `onCancel` cleanup is the subtlest correctness area.

## Anti-Patterns

### Anti-Pattern 1: Porting the C++ thread model into Dart

**What people do:** Spin up Isolates to mimic AdsLib's receiver + dispatcher threads.
**Why it's wrong:** Adds cross-Isolate copy cost and complexity for an I/O-bound workload; correlation maps then need message passing instead of direct access.
**Do this instead:** One event loop, `Completer` for responses, `StreamController` for notifications. The threads were a C++ necessity, not an ADS requirement.

### Anti-Pattern 2: Assuming one TCP read == one AMS frame

**What people do:** Parse each `Uint8List` chunk from `socket.listen` as a complete frame.
**Why it's wrong:** TCP is a byte stream; a chunk may contain a partial frame or several frames. This produces intermittent decode corruption under load.
**Do this instead:** A stateful `FrameAssembler` — read the 6-byte AMS/TCP header, learn `length`, buffer until a whole frame is present, emit it, repeat.

### Anti-Pattern 3: Treating notifications as request replies

**What people do:** Route command-`0x08` frames through the invokeId map.
**Why it's wrong:** Notifications carry `invokeId=0` and are server-initiated; they'll never match a pending request and will be dropped (or crash a lookup).
**Do this instead:** Branch on `commandId == 0x08` before correlation; send those to the handle→Stream demux.

### Anti-Pattern 4: Sleeping to wait for the mock server

**What people do:** `Process.start` then `await Future.delayed(...)` before connecting.
**Why it's wrong:** Flaky under CI load; either too short (connect refused) or wastes time.
**Do this instead:** Have the mock print `LISTENING <port>` and gate on that stdout line.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| TwinCAT PLC / ADS device | Raw TCP `:48898`, AMS/TCP framing | Direct mode: connect to device IP; needs correct target NetId |
| Local TwinCAT router | Raw TCP `127.0.0.1:48898` | Router mode: routes must be pre-provisioned; source NetId must be the local machine's |
| C++ mock server | `Process.start` + stdout readiness handshake | Integration tests only; built via CMake |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| CLI ↔ client (L7↔L6) | Direct Dart calls, Futures/Streams | CLI holds no protocol knowledge |
| client ↔ router (L6↔L5) | `connectionFor(netId)` → `AmsConnection` | Client never opens sockets directly |
| router ↔ connection (L5↔L4) | owns map of connections; injects `TransportTarget` | Direct/router mode lives entirely here |
| connection ↔ codec (L4↔L3) | encode(req)→bytes, decode(frame)→msg | Codec is pure/I/O-free |
| connection ↔ transport (L4↔L2) | `add(bytes)` out, `Stream<Uint8List>` in | Transport is ADS-agnostic; fakeable |

## Sources

- github.com/Beckhoff/ADS — `AdsLib/` source: `AmsRouter.h`, `AmsConnection.h`, `AmsPort.h`, `AmsHeader.h`, `NotificationDispatcher.h`, `AdsNotification.h` (component structure, data members, correlation/dispatch mechanism) — HIGH
- github.com/Beckhoff/ADS — repo tree + `AdsTool/main.cpp` (test/example layout, Meson/CMake build, CLI verb set) — HIGH
- ADS/AMS protocol specification (Beckhoff InfoSys) — header layouts, command IDs, index groups, notification stream format — HIGH (stable, corroborated by source structs)
- Dart `dart:io` / `dart:async` idioms (Socket streams, Completer, StreamController, Timer) — standard practice — HIGH

---
*Architecture research for: pure-Dart ADS/AMS client library + CLI + C++ CMake test harness*
*Researched: 2026-07-03*
