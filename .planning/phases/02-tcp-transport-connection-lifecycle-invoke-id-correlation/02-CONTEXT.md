# Phase 2: TCP Transport, Connection Lifecycle & Invoke-ID Correlation - Context

**Gathered:** 2026-07-03
**Status:** Ready for planning

<domain>
## Phase Boundary

A live TCP connection to an ADS peer round-trips real frames through the FrameAssembler, correlates responses to requests by invoke-ID, enforces timeouts, and fails safely on disconnect. Delivers the transport layer (`AdsTransport` interface + dart:io impl + FakeTransport), the `AmsConnection` (invoke-ID → Completer map, notification demux path, failure fan-out), and the live integration-test harness (Process.start + ephemeral port + stdout readiness). No routing (Phase 4), no command-level API (Phase 3), no auto-reconnect (v2).

Requirements: TRANS-01, TRANS-02, TRANS-03, TRANS-04, PROTO-03, PROTO-04, TEST-03.

</domain>

<decisions>
## Implementation Decisions

### Transport & Correlation API
- Transport abstraction: abstract `AdsTransport` (connect / add(bytes) / inbound byte Stream / close) with a `dart:io` Socket implementation and an in-memory `FakeTransport` for unit tests (TRANS-04)
- Invoke-ID scheme: monotonic u32 starting at 1, wrapping back to 1 at 0xFFFFFFFF; 0 is reserved (notification frames carry invokeId 0 and bypass the correlation map)
- Timeout model: connection-level default (5 s) plus a per-request override parameter
- NO auto-reconnect in this phase — disconnect detection + failure fan-out only; reconnect with re-subscription is v2 (RECON-01)

### Error & Lifecycle Semantics
- Distinct `AdsTimeoutException` (transport error family), separate from `MalformedFrameException` and from future ADS protocol-error exceptions — callers can catch/retry timeouts specifically
- Disconnect fan-out: every pending Completer errors with `AdsConnectionException(cause)`; all notification StreamControllers are closed WITH error so consumers see why the stream died
- Connection-state exposure kept minimal: `bool get isConnected` + `Future<void> get done` (completes on close or error); a state-change Stream waits for v2 reconnect work
- Late/unknown invoke-ID responses are ignored and counted via a `droppedResponses` diagnostic counter — never thrown (a response may legitimately arrive after its timeout fired)

### Integration Tests Against the Live Mock
- Shared launch helper `test/support/mock_server.dart`: builds the CMake harness if stale, `Process.start`s the mock with an ephemeral port, parses the `LISTENING <port>` readiness line, tears down in `tearDownAll`; designed for reuse by all later phases (TEST-03)
- Extend the C++ mock with a `--delay-ms N` (or per-request jitter) mode so concurrent in-flight requests receive out-of-order responses — proving invoke-ID correlation under reordering
- Add a deterministic disconnect mode to the mock (e.g. `--close-after N` frames) to exercise failure fan-out reproducibly
- CI: extend the existing Linux `integration` job to run `dart test -t integration` — no new workflow file

### Claude's Discretion
- Internal naming/structure of the connection layer files (suggested: lib/src/transport/, lib/src/connection/)
- Exact FakeTransport ergonomics and test file organization
- How the harness-staleness check works in the launch helper

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `lib/src/protocol/` (Phase 1): FrameAssembler (pure sync push API, 4 MiB guard), AmsTcpHeader/AmsHeader codecs, six command encoders/decoders (sealed AdsResponse), AmsNetId/AmsAddr, MalformedFrameException, range-checked encoders
- `test_harness/mock_server.cpp`: POSIX accept loop, byte-accurate ReadDeviceInfo response, `LISTENING <port>` readiness line, `--fragment N` / `--coalesce` / `--selftest`, SIGPIPE-safe sendAll, 4 MiB inbound guard, response addressing swap (target = request source)
- `test/support/hex.dart` readGolden; committed goldens in test/golden/
- `.github/workflows/ci.yml`: 2 jobs; integration job already builds the harness on Linux

### Established Patterns
- Purity boundary: `lib/src/protocol/` has zero dart:async/dart:io — the NEW transport/connection layer is where dart:io and dart:async legitimately enter (outside protocol/)
- All errors typed; wire errors = MalformedFrameException, caller bugs = ArgumentError (encode range checks)
- Commit style: type(01-XX): description; atomic per task
- CI endian gate is statement-scoped (handles comments and format-wrapped calls — d99f98b)

### Integration Points
- `AmsConnection` branches on `commandId == 0x08` (DeviceNotification) BEFORE invoke-ID lookup — routes to the demux path (PROTO-04); Phase 5 attaches real Stream plumbing to that demux
- Phase 3 builds AdsClient commands on top of AmsConnection.request()
- Phase 4's AmsRouter will own AmsConnection instances per AmsNetId

</code_context>

<specifics>
## Specific Ideas

- Success criterion 2 must be proven under response REORDERING (mock --delay-ms), not just sequential requests
- No hung Futures ever: every pending request must resolve (response, timeout, or connection-error) — verify with a test that kills the mock mid-request (--close-after)
- The notification demux path must exist and be tested at the frame-routing level in this phase (a 0x0008 frame routes to the demux, not the invoke-ID map) even though the full Stream API is Phase 5

</specifics>

<deferred>
## Deferred Ideas

- Auto-reconnect + connection-state Stream → v2 (RECON-01)
- Wire-trace/hex-dump hook (TRACE-01, v2) — worth remembering when designing the transport interface, but not built now

</deferred>
