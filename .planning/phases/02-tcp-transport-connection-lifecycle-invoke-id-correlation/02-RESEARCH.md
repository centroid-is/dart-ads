# Phase 2: TCP Transport, Connection Lifecycle & Invoke-ID Correlation - Research

**Researched:** 2026-07-03
**Domain:** dart:io Socket transport + dart:async request/response correlation over one multiplexed TCP connection (Beckhoff AMS/TCP)
**Confidence:** HIGH (protocol + Phase-1 assets verified in-repo; dart:io Socket lifecycle verified against official API docs; correlation pattern verified against project ARCHITECTURE/PITFALLS research)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Transport & Correlation API**
- Transport abstraction: abstract `AdsTransport` (connect / add(bytes) / inbound byte Stream / close) with a `dart:io` Socket implementation and an in-memory `FakeTransport` for unit tests (TRANS-04)
- Invoke-ID scheme: monotonic u32 starting at 1, wrapping back to 1 at 0xFFFFFFFF; 0 is reserved (notification frames carry invokeId 0 and bypass the correlation map)
- Timeout model: connection-level default (5 s) plus a per-request override parameter
- NO auto-reconnect in this phase — disconnect detection + failure fan-out only; reconnect with re-subscription is v2 (RECON-01)

**Error & Lifecycle Semantics**
- Distinct `AdsTimeoutException` (transport error family), separate from `MalformedFrameException` and from future ADS protocol-error exceptions — callers can catch/retry timeouts specifically
- Disconnect fan-out: every pending Completer errors with `AdsConnectionException(cause)`; all notification StreamControllers are closed WITH error so consumers see why the stream died
- Connection-state exposure kept minimal: `bool get isConnected` + `Future<void> get done` (completes on close or error); a state-change Stream waits for v2 reconnect work
- Late/unknown invoke-ID responses are ignored and counted via a `droppedResponses` diagnostic counter — never thrown (a response may legitimately arrive after its timeout fired)

**Integration Tests Against the Live Mock**
- Shared launch helper `test/support/mock_server.dart`: builds the CMake harness if stale, `Process.start`s the mock with an ephemeral port, parses the `LISTENING <port>` readiness line, tears down in `tearDownAll`; designed for reuse by all later phases (TEST-03)
- Extend the C++ mock with a `--delay-ms N` (or per-request jitter) mode so concurrent in-flight requests receive out-of-order responses — proving invoke-ID correlation under reordering
- Add a deterministic disconnect mode to the mock (e.g. `--close-after N` frames) to exercise failure fan-out reproducibly
- CI: extend the existing Linux `integration` job to run `dart test -t integration` — no new workflow file

### Claude's Discretion
- Internal naming/structure of the connection layer files (suggested: lib/src/transport/, lib/src/connection/)
- Exact FakeTransport ergonomics and test file organization
- How the harness-staleness check works in the launch helper

### Deferred Ideas (OUT OF SCOPE)
- Auto-reconnect + connection-state Stream → v2 (RECON-01)
- Wire-trace/hex-dump hook (TRACE-01, v2) — worth remembering when designing the transport interface, but not built now
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TRANS-01 | User can open and close a TCP connection to an ADS peer on port 48898 | `SocketTransport.connect(host, port)` over `Socket.connect`; `close()` = `flush` → `destroy`; port is a caller parameter (48898 default at a higher layer). See Pattern 1 + Socket lifecycle table. |
| TRANS-02 | Library enforces a configurable per-request timeout and fails the pending operation on expiry | Per-request `Timer` (5 s default + override) that removes-and-errors the pending entry with `AdsTimeoutException`. See Pattern 2. |
| TRANS-03 | On disconnect, library errors all pending requests and closes all notification streams (failure fan-out) | Single-shot fan-out driven by inbound-stream `onDone`/`onError`; snapshot-clear-then-error ordering. See Pattern 3. |
| TRANS-04 | Library exposes a fakeable transport interface so codec and connection logic are unit-testable without a live socket | `abstract interface class AdsTransport` + `FakeTransport` (feed/written/simulateDisconnect). See Pattern 1. |
| PROTO-03 | Correlate each response to its request by invoke-ID (monotonic counter → Completer) with a per-request timeout | `Map<int,_Pending>`, monotonic u32 from 1 wrapping to 1 (0 reserved). See Pattern 2 + invoke-ID allocation note. |
| PROTO-04 | Route unsolicited notification frames (cmd 0x0008, no invoke-ID) to the notification demux instead of the request/response map | Branch on `header.commandId == 0x08` BEFORE the invoke-ID lookup in `_onFrame`. See Pattern 4. |
| TEST-03 | Integration tests launch the mock via `Process.start` with ephemeral port + stdout readiness handshake and tear it down cleanly | `test/support/mock_server.dart` launch helper: staleness rebuild, `LISTENING <port>` parse with timeout, `tearDownAll` kill. See Pattern 6 + Validation Architecture. |
</phase_requirements>

## Summary

Phase 2 is the first layer in this codebase that legitimately touches `dart:io` and `dart:async` — Phase 1 kept `lib/src/protocol/` pure (import-purity gate enforced in CI). Three subsystems land: a thin ADS-agnostic **transport** (`AdsTransport` interface + `SocketTransport` over a `dart:io` Socket + an in-memory `FakeTransport`), the **`AmsConnection`** that owns the invoke-ID→Completer correlation map, the notification demux branch, per-request timeouts, and disconnect fan-out, and the **integration-test harness** (`test/support/mock_server.dart` launcher plus two new C++ mock modes `--delay-ms` and `--close-after`).

The correctness core is small but subtle. The single hard invariant that makes correlation race-free is: **removal from the pending map is the only way to claim a request.** Because Dart runs on one event loop, `Map.remove(id)` is atomic — whichever of the three actors (response arrival, timeout Timer, disconnect fan-out) removes an entry first "owns" completing that Completer; the others get `null` and no-op. This eliminates the classic `Bad state: Future already completed` crash (PITFALLS Pitfall 4) without any locking. A single-shot `_closed` guard ensures fan-out runs exactly once even though `dart:io` may deliver both an `onError` and an `onDone` for the same broken connection.

No new pub packages are introduced — everything is SDK (`dart:io`, `dart:async`, `dart:typed_data`). The mock extensions must be **deterministic without threads**: `--delay-ms` should defer the *first* response of a connection and flush it *last*, so two pipelined requests provably invert order (a plain inline sleep before response 1 does NOT reorder because the mock drains and answers frames in-order). `--close-after N` closes the socket upon receiving the Nth complete request frame without answering it, guaranteeing at least one pending request fans out.

**Primary recommendation:** Build `AdsTransport`/`FakeTransport` first (pure dart:async, unit-testable), then `AmsConnection` against `FakeTransport` (scripted reordering, timeout, disconnect — no sockets, no mock), then wire `SocketTransport` + the `mock_server.dart` launcher for end-to-end integration tests. Make map-remove the sole completion claim and guard fan-out with a single-shot flag.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Open/close TCP socket, byte in/out | Transport (L2) | — | `dart:io` Socket is the only ADS-agnostic byte pipe; nothing above L2 knows it is a socket vs a fake |
| TCP-chunk → whole-frame reassembly | Codec (L3, existing `FrameAssembler`) | Transport (feeds it) | Already built in Phase 1; L4 owns the assembler instance and pushes L2's inbound chunks into it |
| Invoke-ID assignment + response correlation | Connection (L4) | — | The connection owns the monotonic counter and the pending map; single-conn, single-peer |
| Per-request timeout | Connection (L4) | — | Timeout is per in-flight request; the `Timer` lives beside the Completer in the pending map |
| Notification demux branch (cmd 0x08) | Connection (L4) | Notifications (L5, Phase 5 attaches real Streams) | The frame-routing split lives here; Phase 5 hangs Stream plumbing off the demux hook |
| Disconnect detection + failure fan-out | Connection (L4) | Transport (surfaces onDone/onError) | Transport reports the break; connection decides the policy (error pendings, close controllers) |
| `isConnected` / `done` exposure | Connection (L4) | — | Minimal lifecycle surface; state-change Stream deferred to v2 |
| Launch/ready/teardown of C++ mock | Test support (`test/support/`) | — | `dart:io` `Process` in test support only, never in `lib/` |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `dart:io` (SDK) | SDK `>=3.5.0` | `Socket` (Stream<Uint8List> + IOSink), `Process` (mock launch), `ProcessSignal`, `InternetAddress` | The only raw-TCP transport for AMS/TCP; already the mandated stack in CLAUDE.md `[CITED: CLAUDE.md Technology Stack]` |
| `dart:async` (SDK) | SDK | `Completer` (response correlation), `Timer` (timeout), `StreamController` (notification demux + fake inbound), `Future` | Canonical Dart request/response + push idioms; project ARCHITECTURE maps the C++ receiver-thread + condition-variable onto exactly these `[CITED: research/ARCHITECTURE.md Concurrency Model]` |
| `dart:typed_data` (SDK) | SDK | `Uint8List`, `ByteData`, `Endian.little` — building/stamping outbound frames, reading `commandId`/`invokeId` off inbound frames | Established Phase-1 pattern; `AmsHeader.decode(ByteData, offset)` already exists `[VERIFIED: lib/src/protocol/ams_header.dart]` |
| `dart:convert` (SDK) | SDK | `utf8.decoder` + `LineSplitter` to parse the mock's `LISTENING <port>` stdout line | Standard stdout line-parsing idiom `[CITED: research/ARCHITECTURE.md Test Harness]` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `package:test` | ^1.31.0 (dev, already present) | Integration + unit tests; `@Tags(['integration'])`, `setUpAll`/`tearDownAll` | All Phase-2 tests `[VERIFIED: pubspec.yaml + dart_test.yaml]` |
| `package:meta` | ^1.16.0 (optional, NOT yet a dep) | `@visibleForTesting` on `droppedResponses`/internal hooks, `@internal` on transport impls | Optional — only add if you want annotations; not required. If added, verify on pub.dev first. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `Socket` (buffered, Stream+IOSink) | `RawSocket` | RawSocket gives explicit read/write-ready events and byte-level backpressure, but adds event-plumbing complexity for no benefit here — request volume is low and `FrameAssembler` already buffers. Stick with `Socket`. `[CITED: CLAUDE.md — "Socket (buffered) vs RawSocket"]` |
| Per-request `Timer` | Single sweep Timer over a deadline heap | A sweep timer is more efficient at thousands of concurrent in-flight requests, but ADS request concurrency is tiny and a sweep timer adds a min-heap + coalescing logic. Per-request `Timer` is simpler and precise — recommended. `[ASSUMED]` (see Assumptions A1) |
| Snapshot-clear-then-error fan-out | Complete-in-place while iterating | Iterating `_pending.values` while `completeError` callbacks may re-enter `request()`/removal risks concurrent-modification. Snapshot to a `List`, `clear()` the map, THEN error each. Recommended. |

**Installation:** None. No new pub dependencies. All imports are SDK libraries already available under the pinned `>=3.5.0 <4.0.0` floor.

## Package Legitimacy Audit

**No external packages are installed in this phase.** Every import is a Dart SDK library (`dart:io`, `dart:async`, `dart:typed_data`, `dart:convert`) or an already-vendored dev dependency (`package:test`, `package:lints`) approved in Phase 1. `slopcheck` / registry verification is therefore not applicable — there is nothing new to install. If the planner later chooses to add `package:meta` for annotations, gate it behind a `checkpoint:human-verify` and run `dart pub add meta` (pub.dev-verified, Dart-team-maintained).

## Architecture Patterns

### System Architecture Diagram

```
                 request(commandId, payload, {timeout})           Phase 3 caller (AdsClient)
                          │  returns Future<response>
                          ▼
        ┌─────────────────────────────────────────────────────────┐
        │  AmsConnection  (L4)                                      │
        │                                                          │
        │  OUTBOUND                        INBOUND                 │
        │  ─ allocate invokeId (u32,       ─ transport.inbound     │
        │    monotonic 1..0xFFFFFFFF→1)      onData ─┐             │
        │  ─ build+stamp AMS frame                    ▼            │
        │  ─ _pending[id] = (Completer,    FrameAssembler.add(chunk)│
        │       Timer, expectedCmdId)        │ (Phase-1, pure)     │
        │  ─ transport.add(bytes) ──┐        ▼ List<Uint8List>     │
        │                           │      for each whole frame:   │
        │                           │        _onFrame(frame)       │
        │                           │          │                   │
        │                           │   decode AmsHeader @off 6    │
        │                           │          │                   │
        │                           │   commandId == 0x08 ?        │
        │                           │      ├─ yes → _demux(frame)  │  (Phase-5 hook)
        │                           │      └─ no  → p = _pending   │
        │                           │             .remove(invokeId)│
        │                           │             p==null → drop++ │
        │                           │             else complete    │
        │  onDone / onError ────────┼──────► _failClose(cause):    │
        │                           │          single-shot guard;  │
        │                           │          error all pending;  │
        │                           │          close notif ctrls   │
        │                           │          with error; done✓   │
        └───────────────────────────┼─────────────────────────────┘
                                    │ add(bytes) / inbound Stream / close
                                    ▼
        ┌─────────────────────────────────────────────────────────┐
        │  AdsTransport (L2)   SocketTransport ── dart:io Socket    │
        │                      FakeTransport   ── StreamController  │
        └─────────────────────────────────────────────────────────┘
                                    │ TCP :ephemeral (tests) / :48898 (real)
                                    ▼
                       C++ mock_server  /  real TwinCAT PLC
```

### Recommended Project Structure
```
lib/src/
├── transport/
│   ├── transport.dart          # abstract interface AdsTransport
│   ├── socket_transport.dart   # dart:io Socket impl
│   └── fake_transport.dart     # in-memory impl for unit tests
└── connection/
    ├── ams_connection.dart     # invokeId↔Completer, demux branch, fan-out
    ├── pending_request.dart    # _Pending: Completer + Timer + expectedCmdId (private)
    └── exceptions.dart         # AdsTimeoutException, AdsConnectionException
test/
├── unit/
│   ├── fake_transport_test.dart
│   └── ams_connection_test.dart      # correlation/timeout/disconnect via FakeTransport (no socket)
├── integration/
│   ├── socket_transport_test.dart    # @Tags(['integration'])
│   └── ams_connection_live_test.dart # reorder + mid-request disconnect vs mock
└── support/
    └── mock_server.dart              # launch helper (Process.start + LISTENING parse)
```

### Pattern 1: AdsTransport interface + FakeTransport (TRANS-01, TRANS-04)

**What:** A minimal ADS-agnostic byte pipe. Keep it to exactly the four CONTEXT-locked members so `SocketTransport` and `FakeTransport` are trivially symmetric. Lifecycle exposure (`isConnected`/`done`) lives on `AmsConnection`, NOT on the transport.

**When to use:** Every `AmsConnection` is constructed with an `AdsTransport`; production wires `SocketTransport`, unit tests wire `FakeTransport`.

```dart
// Source: derived from research/ARCHITECTURE.md Component Responsibilities (L2)
abstract interface class AdsTransport {
  Future<void> connect(String host, int port);
  void add(List<int> bytes);          // outbound; non-blocking, buffered
  Stream<Uint8List> get inbound;      // inbound byte chunks (single-subscription)
  Future<void> close();
}

class SocketTransport implements AdsTransport {
  Socket? _socket;
  @override
  Future<void> connect(String host, int port) async {
    _socket = await Socket.connect(host, port);        // throws SocketException on refuse
    _socket!.setOption(SocketOption.tcpNoDelay, true);  // low-latency small frames
  }
  @override
  Stream<Uint8List> get inbound => _socket!;            // Socket IS a Stream<Uint8List>
  @override
  void add(List<int> bytes) => _socket!.add(bytes);
  @override
  Future<void> close() async {
    final s = _socket;
    if (s == null) return;
    try { await s.flush(); } catch (_) {/* peer gone */}
    s.destroy();                                        // both directions, immediate
  }
}
```

**FakeTransport ergonomics (Claude's discretion — recommended shape):**
```dart
class FakeTransport implements AdsTransport {
  final _inbound = StreamController<Uint8List>();       // single-subscription
  final List<Uint8List> written = [];                   // assert outbound correlation
  @override Future<void> connect(String host, int port) async {}
  @override void add(List<int> bytes) => written.add(Uint8List.fromList(bytes));
  @override Stream<Uint8List> get inbound => _inbound.stream;
  @override Future<void> close() async => _inbound.close();
  // Test-only drivers:
  void feed(Uint8List serverBytes) => _inbound.add(serverBytes);       // simulate server→client
  void simulateDisconnect([Object? error]) =>
      error == null ? _inbound.close() : _inbound.addError(error);     // trigger fan-out
}
```
This lets `ams_connection_test.dart` script reordered responses (`feed` frame 2 before frame 1), fire timeouts (feed nothing), and simulate mid-request disconnect (`simulateDisconnect`) with zero sockets.

### Pattern 2: invoke-ID → Completer correlation with per-request timeout (PROTO-03, TRANS-02)

**What:** The connection owns a monotonic u32 counter and `Map<int,_Pending>`. Map-remove is the sole completion claim.

```dart
// Source: research/ARCHITECTURE.md Pattern 1, adapted with the map-remove-wins invariant
int _nextInvokeId = 1;                       // 0 reserved for notifications
final _pending = <int, _Pending>{};
int droppedResponses = 0;                    // diagnostic counter (locked decision)

int _allocInvokeId() {
  final id = _nextInvokeId;
  _nextInvokeId = id == 0xFFFFFFFF ? 1 : id + 1;   // wrap to 1, never 0
  return id;                                        // collision guard: see Assumption A2
}

Future<Uint8List> request(int commandId, Uint8List payload, {Duration? timeout}) {
  if (!isConnected) throw AdsConnectionException('not connected');
  final id = _allocInvokeId();
  final c = Completer<Uint8List>();
  final timer = Timer(timeout ?? _defaultTimeout, () {
    final p = _pending.remove(id);           // remove-wins: null if response beat us
    p?.completer.completeError(AdsTimeoutException(id, commandId));
  });
  _pending[id] = _Pending(c, timer, commandId);
  _transport.add(_buildFrame(commandId, id, payload));   // stamps invokeId into AMS header
  return c.future;
}

void _onFrame(Uint8List frame) {
  final header = AmsHeader.decode(ByteData.sublistView(frame), AmsTcpHeader.byteLength);
  if (header.commandId == AdsCommandId.deviceNotification) { _demux(frame, header); return; } // PROTO-04
  final p = _pending.remove(header.invokeId);            // remove-wins
  if (p == null) { droppedResponses++; return; }         // late/unknown → count, never throw
  p.timer.cancel();
  final payload = Uint8List.sublistView(
      frame, AmsTcpHeader.byteLength + AmsHeader.byteLength);   // 38-byte prefix
  p.completer.complete(Uint8List.fromList(payload));
}
```

**Why map-remove-wins is race-free:** Dart is single-threaded; `_pending.remove(id)` is atomic against every other event-loop turn. Exactly one of {response, timeout, fan-out} obtains the non-null `_Pending`. The others get `null` and do nothing → no double-complete, no `StateError`. Keep `_Pending._` construction private and never expose the raw `Completer`. Belt-and-suspenders `if (!c.isCompleted)` is cheap but strictly redundant given this invariant.

**Trade-off / discretion:** `request` returns raw response `Uint8List` (payload after the 38-byte header) rather than a typed `AdsResponse`. Rationale: keeps L4 command-agnostic; Phase 3 owns per-command decoding AND ADS `errorCode`→exception mapping (ERR-01, Phase 3). Recommend the connection also stash `expectedCommandId` in `_Pending` and drop (count) any response whose `commandId` mismatches the pending's — a mismatched command for a valid invokeId is a protocol violation, not a valid completion.

### Pattern 3: Single-shot disconnect fan-out (TRANS-03)

**What:** Inbound-stream `onDone` (clean FIN) and `onError` (RST/reset) both route to one `_failClose(cause)` that runs exactly once.

```dart
// Source: research/PITFALLS.md Pitfall 4 & 10; research/ARCHITECTURE.md "Failure fan-out"
bool _closed = false;
final _doneCompleter = Completer<void>();
Future<void> get done => _doneCompleter.future;
bool get isConnected => !_closed;

void _wireInbound() {
  _assembler = FrameAssembler();
  _transport.inbound.listen(
    (chunk) {
      try {
        for (final frame in _assembler.add(chunk)) { _onFrame(frame); }
      } on MalformedFrameException catch (e) {
        _failClose(e);                       // corrupt stream → tear down (assembler is poisoned)
      }
    },
    onError: (Object e) => _failClose(e),
    onDone: () => _failClose(const AdsConnectionException('peer closed connection')),
    cancelOnError: false,                    // we drive teardown ourselves
  );
}

void _failClose(Object cause) {
  if (_closed) return;                       // single-shot: onError THEN onDone may both fire
  _closed = true;
  // 1) snapshot + clear BEFORE erroring, so re-entrant request()s fail fast and
  //    completeError callbacks can't mutate the map we're draining.
  final pend = List.of(_pending.values);
  _pending.clear();
  for (final p in pend) {
    p.timer.cancel();
    p.completer.completeError(AdsConnectionException(cause));
  }
  // 2) close notification controllers WITH error so consumers learn why (locked decision).
  for (final ctrl in _demuxControllers.values) {
    ctrl.addError(AdsConnectionException(cause));
    ctrl.close();
  }
  _demuxControllers.clear();
  // 3) release the socket and complete done.
  _transport.close();
  if (!_doneCompleter.isCompleted) _doneCompleter.complete();
}
```

**Ordering rationale:** set `_closed=true` first (fail-fast for re-entrancy) → snapshot+clear pending → error pendings → error+close notification controllers → close transport → complete `done`. Cancel each timer during the drain so a stray timeout can't fire mid-fan-out (map-remove-wins already protects against it, but cancelling is tidy).

### Pattern 4: Notification demux branch before correlation (PROTO-04)

**What:** In `_onFrame`, branch on `header.commandId == 0x08` (DeviceNotification) BEFORE the invoke-ID lookup. In Phase 2 the demux path is a routing hook only — the full Stream API is Phase 5. Give it a testable, minimal implementation so PROTO-04 is provable now.

**Phase-2 demux hook (recommended minimal):** keep a `Map<int, StreamController> _demuxControllers` (empty in Phase 2) and a `_notificationFrames` counter (or a `@visibleForTesting` sink). The Phase-2 test asserts that feeding a `commandId==0x08` frame (invokeId 0) does NOT touch `_pending`, does NOT increment `droppedResponses`, and DOES reach the demux branch (counter increments / sink receives). This locks the routing split that Phase 5 hangs real controllers off of.

**Note on state flags:** Do NOT demux on `stateFlags` or on `invokeId==0`. Server-initiated notifications are request-style frames (stateFlags `0x0004`), so the ONLY reliable discriminator is `commandId==0x08`. `[VERIFIED: research/ARCHITECTURE.md Anti-Pattern 3 + lib/src/protocol/constants.dart deviceNotification=0x08]`

### Pattern 5: Building & stamping the outbound AMS frame

**What:** The connection owns the invoke-ID counter, so it must stamp `invokeId` (and source/target addressing) into the AMS header. Phase 1 gives `AmsHeader.encode()` and `AmsTcpHeader`. Phase 2 `AmsConnection` holds the target/source `AmsAddr` (injected at construction; the Phase-4 router will supply these per NetId).

```dart
Uint8List _buildFrame(int commandId, int invokeId, Uint8List payload) {
  final ams = AmsHeader(
    targetNetId: _target.netId, targetPort: _target.port,
    sourceNetId: _source.netId, sourcePort: _source.port,
    commandId: commandId, stateFlags: AmsStateFlags.request,   // 0x0004
    dataLength: payload.length, errorCode: 0, invokeId: invokeId,
  ).encode();                                                   // 32 bytes, LE, range-checked
  final tcp = AmsTcpHeader(AmsHeader.byteLength + payload.length).toBytes(); // 6-byte wrapper
  final out = Uint8List(tcp.length + ams.length + payload.length)
    ..setRange(0, 6, tcp)
    ..setRange(6, 38, ams)
    ..setRange(38, 38 + payload.length, payload);
  return out;
}
```
(Confirm the exact `AmsTcpHeader` construction/`toBytes` name against `lib/src/protocol/ams_tcp_header.dart` during planning — the codec API is Phase-1's; this is illustrative.)

### Pattern 6: Mock launch helper (TEST-03)

```dart
// test/support/mock_server.dart
@Tags(['integration'])          // at top of each integration TEST file, not the helper
Future<MockServer> startMockServer({List<String> args = const []}) async {
  final bin = await _ensureBuilt();               // staleness check → cmake build if needed
  final proc = await Process.start(bin, args);    // no --port → ephemeral :0
  final stderr = StringBuffer();
  proc.stderr.transform(utf8.decoder).listen(stderr.write);
  final port = await proc.stdout
      .transform(utf8.decoder).transform(const LineSplitter())
      .firstWhere((l) => l.startsWith('LISTENING '))
      .then((l) => int.parse(l.trim().split(' ').last))
      .timeout(const Duration(seconds: 10),
        onTimeout: () { proc.kill(); throw StateError('mock never printed LISTENING\n$stderr'); });
  return MockServer(proc, port);
}
// tearDownAll: server.proc.kill(ProcessSignal.sigterm); await server.proc.exitCode;
```

**Staleness check (Claude's discretion — recommended):** build path `test_harness/build/mock_server`. Rebuild when the binary is missing OR older than any of `test_harness/mock_server.cpp`, `test_harness/CMakeLists.txt` (use `File.lastModifiedSync()`); run `cmake -S test_harness -B test_harness/build` then `cmake --build test_harness/build` via `Process.run`, surfacing a clear error if `cmake` is absent. On CI's integration job the binary is already freshly built by an explicit step, so this is a no-op there; it exists for local-dev ergonomics. `[CITED: research/ARCHITECTURE.md Test Harness "Launch/ready/teardown"]`

### Anti-Patterns to Avoid
- **Demuxing on `stateFlags`/`invokeId==0`:** use `commandId==0x08` only. `[CITED: ARCHITECTURE Anti-Pattern 3]`
- **Inline sleep before the first response in `--delay-ms`:** the mock answers frames in-order, so sleeping before response 1 does NOT reorder — it just slows both. Defer response 1 and flush it LAST (see Mock section). `[CITED: focus question 3]`
- **Pausing the socket stream for backpressure:** pausing stalls ALL multiplexed traffic. Phase-2 volume is low; do not pause. Per-handle buffering is a Phase-5 concern. `[CITED: ARCHITECTURE Concurrency Model]`
- **Completing Completers without going through map-remove:** every completion path must first `_pending.remove(id)`; never hold a `Completer` reference that can be completed twice.
- **Two separate fan-outs for onError and onDone:** guard with a single `_closed` bool.
- **`socket.close()` alone on teardown:** `close()` only half-closes the write side (sends FIN); use `flush()` then `destroy()` to release both directions immediately. `[VERIFIED: api.dart.dev Socket — close "Close the consumer", destroy "Destroys the socket in both directions"]`

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| TCP-chunk → whole-frame reassembly | A new byte accumulator | Existing `FrameAssembler` (Phase 1) | Already handles fragmentation, coalescing, 4 MiB guard, poison-length rejection with `MalformedFrameException` — proven with adversarial tests `[VERIFIED: lib/src/protocol/frame_assembler.dart]` |
| Reading commandId/invokeId/dataLength off a frame | Manual offset math | `AmsHeader.decode(ByteData, offset=6)` | Range-checked, view-bounded (T-1-03 safe), LE-correct `[VERIFIED: lib/src/protocol/ams_header.dart]` |
| Building/stamping the AMS + AMS/TCP headers | Hand byte-packing | `AmsHeader.encode()` + `AmsTcpHeader` | Phase-1 encoders are range-checked (throw `ArgumentError` on overflow) not silently truncating `[VERIFIED: ams_header.dart encode()]` |
| Request/response correlation primitive | Custom future registry | `Completer` + `Map<int,_Pending>` | Idiomatic; single-event-loop atomicity removes all locking `[CITED: ARCHITECTURE Concurrency Model]` |
| Per-request timeout | `Future.delayed` races | `Timer` stored beside the Completer, cancelled on completion | `Timer.cancel()` + map-remove is the clean, leak-free pattern `[CITED: ARCHITECTURE Pattern 1]` |
| Mock readiness detection | `Future.delayed` before connect | Parse the `LISTENING <port>` stdout line | Sleep is flaky under CI load; the readiness line is a hard barrier `[CITED: ARCHITECTURE Anti-Pattern 4; already emitted by mock_server.cpp]` |
| Ephemeral port selection | Hard-coded test port | Mock binds `:0`, prints actual port | Avoids parallel-run "address in use" flakiness `[VERIFIED: mock_server.cpp getsockname + LISTENING line]` |

**Key insight:** Phase 1 already delivered every pure-protocol primitive Phase 2 needs. Phase 2 writes *no* new byte-parsing — it only wires existing codecs to `dart:io` and adds the async correlation/lifecycle logic that could not exist while `protocol/` was I/O-free.

## Common Pitfalls

### Pitfall 1: `dart:io` does not report a dead peer that never sends FIN/RST (half-open)
**What goes wrong:** Cable pull / PLC hang leaves the socket "up"; writes appear to succeed; no `onDone`/`onError` ever fires; the request Future hangs forever.
**Why it happens:** `Socket.done`/stream `onError` only fire on clean FIN or RST. TCP keepalive defaults are minutes-to-hours. `[VERIFIED: research/PITFALLS.md Pitfall 10 + api.dart.dev Socket done semantics]`
**How to avoid:** The **per-request timeout is the primary liveness signal** (already a locked decision). On timeout the pending errors with `AdsTimeoutException`; the caller decides whether to `close()`. Do NOT rely on socket events alone. (Optional TCP keepalive via `SocketOption` is defense-in-depth, out of Phase-2 scope.)
**Warning signs:** App hangs after a PLC reboot; a test that kills the mock mid-request never resolves.

### Pitfall 2: `onError` AND `onDone` both fire → double fan-out
**What goes wrong:** A reset connection can deliver an error then a done; without a guard you error the (already cleared) pending map twice or complete `done` twice (`StateError`).
**How to avoid:** Single-shot `_closed` bool at the top of `_failClose`; guard `_doneCompleter.isCompleted`. `[CITED: Pattern 3]`
**Warning signs:** `Bad state: Future already completed` during disconnect tests.

### Pitfall 3: Response arrives after its timeout already fired (late response)
**What goes wrong:** Timeout removed+errored the pending; the real response arrives later; a naive handler looks it up, finds nothing, and throws.
**How to avoid:** `_pending.remove(id)` returning `null` on the inbound path is EXPECTED — increment `droppedResponses` and return. Never throw. `[CITED: locked decision "Late/unknown invoke-ID responses are ignored and counted"]`
**Warning signs:** Intermittent crashes under `--delay-ms` reordering tests where a delayed response lands after a short-timeout request.

### Pitfall 4: `--delay-ms` implemented as an inline pre-send sleep does not reorder
**What goes wrong:** The mock drains and answers frames in receive order; sleeping before response 1 keeps order `1,2` (just slower). The test for reordering passes only by luck or fails.
**How to avoid:** Defer the first response of a connection; send responses 2..N immediately; flush the deferred first response LAST (after `usleep(N*1000)`). This provably inverts order for 2 pipelined requests, deterministically, no threads. `[CITED: focus question 3]`
**Warning signs:** Reorder test is flaky or the mock emits `1,2` under `--delay-ms`.

### Pitfall 5: Client must PIPELINE the two requests for reordering to occur
**What goes wrong:** If the test `await`s request 1 before issuing request 2, only one is ever in flight and there is nothing to reorder.
**How to avoid:** In the reorder test, call `conn.request(...)` twice WITHOUT awaiting between them (capture both Futures), then `await` both. `AmsConnection.request` is fire-and-forget on the write, so two calls pipeline naturally.
**Warning signs:** Reorder test green even when correlation is broken (it never exercised concurrency).

### Pitfall 6: `MalformedFrameException` mid-stream poisons the assembler
**What goes wrong:** After a poison-length frame, `FrameAssembler` drops its buffer and the stream is corrupt by definition; continuing to feed it is meaningless.
**How to avoid:** Catch `MalformedFrameException` in the inbound `listen` handler and route to `_failClose(e)` — tear the connection down (the Phase-1 assembler docs mandate discarding the assembler with its connection). `[VERIFIED: frame_assembler.dart class doc]`

### Pitfall 7: Notification frame routed through the invoke-ID map
**What goes wrong:** A `0x08` frame carries invokeId 0, never matches a pending, silently inflates `droppedResponses` (or crashes a lookup) instead of reaching the demux.
**How to avoid:** Branch on `commandId==0x08` BEFORE the map lookup (Pattern 4). Test asserts a `0x08` frame does not touch `droppedResponses`. `[CITED: ARCHITECTURE Anti-Pattern 3]`

## Code Examples

### Mock `--delay-ms N`: deterministic first-response deferral (C++)
```cpp
// Source: focus question 3 + existing mock_server.cpp runServer() loop structure.
// Connection-scoped state (declared OUTSIDE the recv loop, per accept):
std::vector<uint8_t> deferred;      // holds response #1's bytes
bool haveDeferred = false;
int  respCount = 0;
// ... inside the frame-drain switch, for a matched command:
const std::vector<uint8_t> res = buildReadDeviceInfoRes(/* inverted addressing */);
++respCount;
if (delayMs > 0 && respCount == 1) {
    deferred = res; haveDeferred = true;        // hold response #1
} else {
    sendResponse(fd, res, mode, fragmentN, coalesceBuf);   // #2..N go immediately
}
// ... after the inner drain loop for this recv() batch, once >=1 later response
//     has been sent, flush the deferred one LAST so order inverts:
if (haveDeferred && respCount >= 2) {
    usleep(static_cast<useconds_t>(delayMs) * 1000);
    sendResponse(fd, deferred, mode, fragmentN, coalesceBuf);
    haveDeferred = false;
}
// ... and on connection close, flush any still-deferred single response so it
//     is never lost when only one request ever arrived:
if (haveDeferred) { sendResponse(fd, deferred, mode, fragmentN, coalesceBuf); }
```

### Mock `--close-after N`: deterministic mid-request disconnect (C++)
```cpp
// Count COMPLETE inbound request frames; on the Nth, close without answering it,
// guaranteeing at least one pending request fans out with AdsConnectionException.
int reqCount = 0;   // connection-scoped, outside recv loop
// ... where a complete frame has been parsed from inbuf (before/at the switch):
++reqCount;
if (closeAfter > 0 && reqCount >= closeAfter) {
    close(fd);              // drop the connection now; do NOT send this response
    break;                 // exit drain loop; outer accept loop continues
}
```
`--selftest` stays intact: it returns from `main()` before `runServer`, so neither new flag is parsed in that path. `--delay-ms`/`--close-after` are orthogonal to `--fragment`/`--coalesce` (timing/lifecycle vs segmentation); tests use them independently.

### Reorder correlation test (Dart, integration)
```dart
// Source: derived from locked decision "prove correlation under REORDERING".
test('correlates reordered responses by invoke-ID', () async {
  final server = await startMockServer(args: ['--delay-ms', '80']);
  final conn = AmsConnection(SocketTransport()..connect('127.0.0.1', server.port), /*addr*/);
  final f1 = conn.request(AdsCommandId.readDeviceInfo, Uint8List(0));   // pipelined
  final f2 = conn.request(AdsCommandId.readDeviceInfo, Uint8List(0));   // no await between
  final r1 = await f1;   // response #1 arrives LAST on the wire, but f1 still resolves it
  final r2 = await f2;
  expect(r1, isNotNull); expect(r2, isNotNull);
  expect(conn.droppedResponses, 0);
}, tags: ['integration']);
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| C++ AdsLib: receiver thread + condition variable per connection | Dart: one event loop, `Completer` + `Map`, no locks | N/A (language idiom) | No Isolates; correlation map needs no synchronization `[CITED: ARCHITECTURE]` |
| C++ dispatcher thread for notifications | `StreamController` per handle, single `_onFrame` split on `commandId==0x08` | N/A | Phase-2 lays the routing hook; Phase-5 attaches Streams |

**Deprecated/outdated:** none relevant — `dart:io` `Socket`/`Completer`/`Timer` APIs are stable across the Dart 3.x line.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Per-request `Timer` (not a single sweep timer) is the right timeout strategy for ADS request volumes | Standard Stack / Pattern 2 | Low — if a consumer ever holds thousands of concurrent requests, revisit; ADS workloads are tiny, so risk is negligible |
| A2 | invoke-ID wrap collision is practically impossible, so a forward-skip guard on `_pending.containsKey(id)` is optional | Pattern 2 | Very low — would require 2^32 in-flight requests to collide; a defensive skip loop is cheap if the planner wants belt-and-suspenders |
| A3 | `AmsConnection.request` should return raw response payload `Uint8List`, leaving typed decode + errorCode mapping to Phase 3 | Pattern 2 (discretion) | Low — this is an internal boundary the planner can adjust; either choice keeps the layer split clean. Flag for the planner to confirm with the Phase-3 owner |
| A4 | The connection holds a fixed source/target `AmsAddr` injected at construction (Phase-4 router will supply per-NetId) | Pattern 5 | Low — addressing policy is a Phase-4 concern; Phase 2 only needs *some* valid addressing to round-trip against the mock |
| A5 | `--delay-ms` semantics = defer FIRST response, flush LAST (vs literal per-response jitter) | Mock section | Low — matches focus-question 3 guidance and is strictly more deterministic than jitter; confirm the flag name/semantics with the planner |

## Open Questions

1. **Does `AmsConnection.request` decode to a typed `AdsResponse` or return raw bytes?**
   - What we know: Phase 3 owns per-command decoding + ADS errorCode→exception mapping (ERR-01, Phase 3).
   - What's unclear: whether Phase 2 returns raw `Uint8List` payload or a `(AmsHeader, Uint8List)` record.
   - Recommendation: return raw payload (or a small record) and keep L4 command-agnostic (Assumption A3). Cheap to change later.

2. **Mock addressing for live round-trips.** The Phase-1 mock passes request addressing through un-swapped (matched the golden). For realistic responses the mock should invert addressing (target↔source) as noted in its own comments.
   - Recommendation: have the Phase-2 mock work invert addressing on response (as `AmsConnection._onFrame` doesn't care about addressing for correlation, this is cosmetic for Phase 2 but correct for later phases). Low risk either way since correlation keys on invokeId+commandId.

3. **CI wording.** The integration job currently runs full `dart test` (which already includes integration-tagged tests). The locked decision says "run `dart test -t integration`."
   - Recommendation: either is fine; full `dart test` already covers them. If the planner wants the exact wording, add a `dart test -t integration` step or leave the existing full-suite step. No new workflow file needed.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Dart SDK | Everything | ✓ | 3.11.5 dev (satisfies `>=3.5.0`) `[VERIFIED: 01-01 SUMMARY notes dev Dart 3.11.5]` | — |
| `cmake` + C++14 (g++/clang) | Building the mock for integration tests | ✓ on dev + CI Linux | project floors CMake 3.16, C++14 `[VERIFIED: test_harness/CMakeLists.txt]` | Integration tests are `@Tags(['integration'])`; `dart test -x integration` runs unit tests with no toolchain |
| Beckhoff/ADS submodule | Mock framing | ✓ pinned `57d63747` | — | `git submodule update --init` on fresh clones |
| Built `mock_server` binary | Live round-trip tests | Rebuilt on demand by the launch helper (staleness check) | — | If `cmake` absent locally, integration tests fail with a clear error; unit tests (FakeTransport) still fully cover correlation/timeout/disconnect |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** integration tests degrade to skipped/excluded when no C++ toolchain is present — all Phase-2 *logic* (correlation, timeout, fan-out, demux) is unit-testable via `FakeTransport` with zero external deps.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `package:test` ^1.31.0 (dev dep, present) |
| Config file | `dart_test.yaml` (tags `unit`, `integration` [timeout 30s], `golden`) |
| Quick run command | `dart test -x integration` (pure-Dart, no toolchain — includes all FakeTransport unit tests) |
| Full suite command | `dart test` (unit + integration; requires built mock) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TRANS-04 | FakeTransport records outbound bytes; feeds inbound; simulates disconnect | unit | `dart test test/unit/fake_transport_test.dart -x integration` | ❌ Wave 0 |
| PROTO-03 | invokeId monotonic 1→wrap; response matched to correct Future; two pipelined requests each resolve their own | unit | `dart test test/unit/ams_connection_test.dart -x integration -N correlat` | ❌ Wave 0 |
| PROTO-03 | reordered responses (feed frame#2 before frame#1) each resolve correct Future | unit | `dart test test/unit/ams_connection_test.dart -x integration -N reorder` | ❌ Wave 0 |
| TRANS-02 | request times out → `AdsTimeoutException`; pending removed (no leak); late response counts as dropped | unit | `dart test test/unit/ams_connection_test.dart -x integration -N timeout` | ❌ Wave 0 |
| TRANS-03 | `simulateDisconnect` → all pending error `AdsConnectionException`; notif controllers closed-with-error; `done` completes; single-shot | unit | `dart test test/unit/ams_connection_test.dart -x integration -N disconnect` | ❌ Wave 0 |
| PROTO-04 | `commandId==0x08` frame routes to demux, does NOT touch pending or `droppedResponses` | unit | `dart test test/unit/ams_connection_test.dart -x integration -N notification` | ❌ Wave 0 |
| TRANS-01 | live connect to mock, ReadDeviceInfo round-trip resolves; `close()` completes `done`; `isConnected` transitions | integration | `dart test test/integration/socket_transport_test.dart -t integration` | ❌ Wave 0 |
| PROTO-03 | live reordered responses via `--delay-ms` correlate correctly | integration | `dart test test/integration/ams_connection_live_test.dart -t integration -N reorder` | ❌ Wave 0 |
| TRANS-03 | live mid-request disconnect via `--close-after` fans out (no hung Future) | integration | `dart test test/integration/ams_connection_live_test.dart -t integration -N disconnect` | ❌ Wave 0 |
| TEST-03 | launch helper: ephemeral port parsed from `LISTENING`, clean `tearDownAll` | integration | covered by any integration test using `startMockServer` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `dart test -x integration` (fast; FakeTransport covers all correlation/lifecycle logic) + `dart analyze --fatal-infos` + `dart format --set-exit-if-changed`.
- **Per wave merge:** `dart test` (full, incl. integration against the built mock).
- **Phase gate:** full `dart test` green + both CI jobs green before `/gsd:verify-work`.

### Wave 0 Gaps
- [ ] `test/support/mock_server.dart` — launch helper (blocks all integration tests) — covers TEST-03
- [ ] `test/unit/fake_transport_test.dart` — covers TRANS-04
- [ ] `test/unit/ams_connection_test.dart` — correlation/reorder/timeout/disconnect/notification (FakeTransport) — covers PROTO-03, PROTO-04, TRANS-02, TRANS-03
- [ ] `test/integration/socket_transport_test.dart` — live connect/round-trip/close — covers TRANS-01
- [ ] `test/integration/ams_connection_live_test.dart` — live reorder (`--delay-ms`) + mid-request disconnect (`--close-after`) — covers PROTO-03, TRANS-03
- [ ] C++ mock: `--delay-ms N` (first-response deferral) + `--close-after N` (drop on Nth request) added to `test_harness/mock_server.cpp`
- Framework install: none — `package:test` already present.

## Security Domain

> `security_enforcement` is not set in `.planning/config.json` → treated as enabled. Scope here is narrow: this is a client transport layer, no auth/session/crypto surface (ADS is plaintext by design; trusted-network operation is documented in project PITFALLS).

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | ADS has no transport auth in this phase; route credentials are Phase-4 (ROUTE-04, v2). Documented as trusted-network-only. |
| V3 Session Management | no | No sessions; one TCP connection per peer |
| V4 Access Control | no | Client library; no server role |
| V5 Input Validation | **yes** | Inbound frame length guard + malformed-frame rejection via existing `FrameAssembler` (4 MiB cap, `MalformedFrameException` before allocation); connection tears down on malformed input |
| V6 Cryptography | no | ADS is plaintext; encryption is out of scope (VLAN/VPN responsibility, documented) |

### Known Threat Patterns for dart:io TCP transport
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Hostile inbound length prefix → huge allocation (DoS) | Denial of Service | `FrameAssembler` rejects `length > 4 MiB` before allocating; `_failClose` on `MalformedFrameException` `[VERIFIED: frame_assembler.dart]` |
| Pending-map / Completer leak → unbounded memory + hung Futures | Denial of Service | Per-request timeout removes+errors; disconnect fan-out clears the whole map; `droppedResponses` counter observes anomalies `[CITED: PITFALLS Pitfall 4]` |
| Half-open connection → indefinite hang | Denial of Service | Per-request timeout is the primary liveness signal `[CITED: PITFALLS Pitfall 10]` |
| Mid-send peer close → process-killing SIGPIPE (mock side) | Denial of Service | Mock already `signal(SIGPIPE, SIG_IGN)` + EPIPE handling; new `--close-after` path just `close(fd)` `[VERIFIED: mock_server.cpp main()]` |
| Response injected for an unknown/late invokeId | Spoofing/Tampering | Unmatched responses are counted and dropped, never acted on; commandId-mismatch also dropped (Pattern 2) |

## Sources

### Primary (HIGH confidence)
- In-repo Phase-1 source: `lib/src/protocol/frame_assembler.dart`, `ams_header.dart`, `constants.dart`, `dart_ads.dart`, `exceptions.dart` — codec/API surface Phase 2 wires to (VERIFIED by direct read)
- In-repo `test_harness/mock_server.cpp`, `CMakeLists.txt`, `.github/workflows/ci.yml`, `dart_test.yaml`, `pubspec.yaml` — mock structure, CI jobs, test tags (VERIFIED by direct read)
- `.planning/research/ARCHITECTURE.md` + `PITFALLS.md` — project-level correlation/demux/fan-out patterns and the 10 ADS-porting pitfalls (CITED)
- `.planning/phases/.../02-CONTEXT.md` — locked decisions (CITED verbatim in User Constraints)
- api.dart.dev `Socket` class — `close()` half-closes ("Close the consumer") vs `destroy()` ("Destroys the socket in both directions"), `done`/`flush` semantics (VERIFIED via WebFetch)

### Secondary (MEDIUM confidence)
- Dart SDK issue #55978 (Socket/SecureSocket error-handling nuances) and general dart:io write-after-close behavior — corroborates that write errors surface via `done`/`flush`, not the `add` call (WebSearch, cross-checked with API docs)

### Tertiary (LOW confidence)
- None material; all load-bearing claims verified against in-repo code or official API docs.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all SDK, no new packages; verified against pubspec + CLAUDE.md
- Architecture (correlation/demux/fan-out): HIGH — patterns verified against in-repo codec API + project ARCHITECTURE/PITFALLS
- dart:io Socket lifecycle edge cases: HIGH — verified against official API docs (close vs destroy, done/flush)
- Mock C++ extensions: MEDIUM-HIGH — design is sound and deterministic, but the exact `--delay-ms` ordering must be verified by the reorder integration test (Pitfall 4/5); flagged in Assumptions A5
- Pitfalls: HIGH — sourced from project PITFALLS research + direct code reading

**Research date:** 2026-07-03
**Valid until:** 2026-08-02 (stable domain — dart:io + protocol are stable; 30 days)
