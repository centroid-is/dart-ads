# Phase 5: Device Notifications as Streams - Context

**Gathered:** 2026-07-04
**Status:** Ready for planning
**Mode:** Autonomous (grey-area recommendations auto-accepted per standing user directive)

<domain>
## Phase Boundary

Users subscribe to PLC device notifications as Dart Streams, with correct nested frame parsing and disciplined handle lifecycle so PLC-side notification handles never leak. Delivers AddDeviceNotification/DeleteDeviceNotification codecs, the nested stamp/sample parser with FILETIME conversion, the handle → Stream demux plumbing on AmsConnection's existing 0x08 path, the AdsClient subscribe API, mock-server notification support, and the notification C++ parity ports. No auto-resubscribe on reconnect (v2 RECON-01). No sum/symbols (Phases 6-7).

Requirements: NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04 (+ TEST-05 slice: testAdsNotification, testManyNotifications; testEndurance tagged `slow`).

</domain>

<decisions>
## Implementation Decisions

### Subscribe API
- `AdsClient.subscribe(indexGroup:, indexOffset:, length:, mode:, cycleTime:, maxDelay:)` returns `Stream<AdsNotification>` — single-subscription stream
- AddDeviceNotification (0x0006) is sent on FIRST LISTEN (not at subscribe() call); DeleteDeviceNotification (0x0007) fires unconditionally in onCancel
- `AdsNotification` value type: `handle` (int), `timestamp` (DateTime, converted from FILETIME 100ns-since-1601), `data` (Uint8List)
- `AdsTransmissionMode` enum from ADSTRANS_* constants (noTrans 0, clientCycle 1, clientOnChange 2, serverCycle 3, serverOnChange 4, ...); default serverOnChange; cycleTime/maxDelay in Duration, converted to 100ns units on the wire

### Handle Lifecycle (the research-flagged correctness area)
- onCancel → DeleteDeviceNotification always attempted; failures (connection dead) swallowed after handle invalidation — never throw from cancel
- On disconnect: all notification StreamControllers error-close (existing Phase 2 fan-out), all handles invalidated locally, NEVER deleted against a new session (stale-handle rule from research PITFALLS)
- No auto-resubscribe (v2 RECON-01); a dead stream stays dead — consumer re-subscribes explicitly
- Handle registry lives in AmsConnection's demux map (handle → StreamController), populated by the subscribe flow after AddDeviceNotification returns the handle

### Wire Parsing (NOTIF-03)
- Nested AdsNotificationStream layout: length u32, stamps u32, then per stamp { timestamp u64 FILETIME, sampleCount u32, then per sample { handle u32, size u32, data[size] } } — full nested loop, never assume 1 stamp × 1 sample
- FILETIME → DateTime: 100ns ticks since 1601-01-01 UTC; conversion helper in protocol/ (pure) with round-trip test
- Parser lives in protocol/ (pure, golden-testable); dispatch lives in connection layer
- Malformed notification frames: throw MalformedFrameException at parse, but the connection must NOT die — log/count and drop the frame (a hostile notification must not kill all subscriptions); add droppedNotifications counter

### Mock Support
- Mock implements ADD_DEVICE_NOTIFICATION (allocates incrementing handle, records attribs), DEL_DEVICE_NOTIFICATION (frees), and emits notification frames: serverCycle mode → emits every cycleTime; serverOnChange → emits when a Write changes the watched (indexGroup, indexOffset) region
- Deterministic emission: a `--notify-burst N` style option or write-triggered emission for tests; multi-stamp/multi-sample frames exercised (at least one test frame with 2 stamps × 2 samples to prove the nested parser)
- Golden frames for AddDeviceNotification req/res and a notification stream frame added via dump_golden

### C++ Test Parity (TEST-05 slice)
- testAdsNotification ported 1:1 (register, receive ≥1 notification, delete, verify no more delivery)
- testManyNotifications ported (many concurrent subscriptions, e.g. 64+, all receive, all clean up, no handle leak — assert mock-side handle count returns to 0 via a mock stats query or delete-count assertion)
- testEndurance ported but tagged `slow` (excluded by default, runnable manually)

### Claude's Discretion
- File layout (lib/src/protocol/notifications.dart, client subscription manager placement)
- Exact mock emission mechanics (timer in the C++ loop vs write-triggered) as long as deterministic for tests
- Backpressure: document that controllers buffer unboundedly in v1 (HMI consumers listen immediately); a bounded-buffer policy is v2 if needed

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- AmsConnection: 0x08 frames already route to a demux path (Phase 2, PROTO-04) — Phase 5 fills in the handle → StreamController dispatch
- Phase 2 fan-out already error-closes notification controllers on disconnect
- commands.dart payload-builder pattern (Phase 3 WR-03 refactor) — Add/DelDeviceNotification codecs follow it
- Mock: full command set, stateful store, magic error groups; dump_golden for new goldens
- AdsClient + router (Phases 3-4): subscribe goes through the same client/connection

### Established Patterns
- protocol/ purity; typed exceptions; -n regex (not -N) for test name filters; verify ordering; --fatal-infos; atomic commits
- Parity test naming 1:1 with C++ scenario + header adaptation comment

### Integration Points
- Phase 8 CLI `subscribe` verb consumes this Stream API
- v2 RECON-01 will build resubscribe on the attribs retained per subscription

</code_context>

<specifics>
## Specific Ideas

- The nested parser MUST be proven against a multi-stamp multi-sample frame (research pitfall: flat parsers pass 1×1 tests and fail on batching)
- Handle-leak proof: after N subscribe/cancel cycles, mock-side active handle count is 0 (deterministic assertion, not "probably fine")
- A hostile/malformed 0x08 frame must not kill the connection or other subscriptions

</specifics>

<deferred>
## Deferred Ideas

- Auto-resubscribe on reconnect + connection-state stream → v2 (RECON-01)
- SUMUP_ADDDEVNOTE/DELDEVNOTE batched subscription → v2 (NOTIF-05)
- Bounded notification buffering/backpressure policy → v2 if HMI usage shows need

</deferred>
