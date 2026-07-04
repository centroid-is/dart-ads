# Phase 5: Device Notifications as Streams - Research

**Researched:** 2026-07-04
**Domain:** ADS device-notification protocol (AddDeviceNotification / DeleteDeviceNotification codecs, nested stamp/sample 0x08 stream parsing, FILETIME→DateTime conversion, handle→Stream demux lifecycle, mock emission)
**Confidence:** HIGH — every wire layout is transcribed byte-for-byte from the vendored Beckhoff C++ at `third_party/ADS`; the subtle areas (handle lifecycle, hostile-frame containment, first-listen race) are reasoned from the existing Dart architecture and flagged where design (not fact) is involved.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Subscribe API**
- `AdsClient.subscribe(indexGroup:, indexOffset:, length:, mode:, cycleTime:, maxDelay:)` returns `Stream<AdsNotification>` — single-subscription stream.
- AddDeviceNotification (0x0006) is sent on FIRST LISTEN (not at `subscribe()` call); DeleteDeviceNotification (0x0007) fires unconditionally in `onCancel`.
- `AdsNotification` value type: `handle` (int), `timestamp` (DateTime, converted from FILETIME 100ns-since-1601), `data` (Uint8List).
- `AdsTransmissionMode` enum from ADSTRANS_* constants (noTrans 0, clientCycle 1, clientOnChange 2, serverCycle 3, serverOnChange 4, ...); default serverOnChange; cycleTime/maxDelay in Duration, converted to 100ns units on the wire.

**Handle Lifecycle (research-flagged correctness area)**
- `onCancel` → DeleteDeviceNotification always attempted; failures (connection dead) swallowed after handle invalidation — never throw from cancel.
- On disconnect: all notification StreamControllers error-close (existing Phase 2 fan-out), all handles invalidated locally, NEVER deleted against a new session (stale-handle rule).
- No auto-resubscribe (v2 RECON-01); a dead stream stays dead — consumer re-subscribes explicitly.
- Handle registry lives in AmsConnection's demux map (handle → StreamController), populated by the subscribe flow after AddDeviceNotification returns the handle.

**Wire Parsing (NOTIF-03)**
- Nested layout: length u32, stamps u32, then per stamp { timestamp u64 FILETIME, sampleCount u32, then per sample { handle u32, size u32, data[size] } } — full nested loop, never assume 1 stamp × 1 sample.
- FILETIME → DateTime: 100ns ticks since 1601-01-01 UTC; conversion helper in `protocol/` (pure) with round-trip test.
- Parser lives in `protocol/` (pure, golden-testable); dispatch lives in connection layer.
- Malformed notification frames: throw MalformedFrameException at parse, but the connection must NOT die — log/count and drop the frame; add `droppedNotifications` counter.

**Mock Support**
- Mock implements ADD_DEVICE_NOTIFICATION (allocates incrementing handle, records attribs), DEL_DEVICE_NOTIFICATION (frees), and emits notification frames: serverCycle → emits every cycleTime; serverOnChange → emits when a Write changes the watched region.
- Deterministic emission: a `--notify-burst N` style option or write-triggered emission; multi-stamp/multi-sample frames exercised (at least one test frame with 2 stamps × 2 samples).
- Golden frames for AddDeviceNotification req/res and a notification stream frame added via `dump_golden`.

**C++ Test Parity (TEST-05 slice)**
- testAdsNotification ported 1:1 (register, receive ≥1 notification, delete, verify no more delivery).
- testManyNotifications ported (many concurrent subscriptions e.g. 64+, all receive, all clean up, no handle leak — assert mock-side handle count returns to 0).
- testEndurance ported but tagged `slow` (excluded by default, runnable manually).

### Claude's Discretion
- File layout (`lib/src/protocol/notifications.dart`, client subscription manager placement).
- Exact mock emission mechanics (timer in the C++ loop vs write-triggered) as long as deterministic for tests.
- Backpressure: document that controllers buffer unboundedly in v1 (HMI consumers listen immediately); a bounded-buffer policy is v2 if needed.

### Deferred Ideas (OUT OF SCOPE)
- Auto-resubscribe on reconnect + connection-state stream → v2 (RECON-01).
- SUMUP_ADDDEVNOTE / SUMUP_DELDEVNOTE batched subscription → v2 (NOTIF-05).
- Bounded notification buffering / backpressure policy → v2 if HMI usage shows need.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| NOTIF-01 | Subscribe to a symbol's device notifications as a Dart Stream (AddDeviceNotification on first listen) | AddDeviceNotification request codec (§Wire Layouts 1); `subscribe()` API + `StreamController.onListen` flow (§Pattern: Subscription Plumbing); synchronous handle registration to close the first-listen race |
| NOTIF-02 | Cancelling sends DeleteDeviceNotification (onCancel); all handles cleaned up on disconnect | DeleteDeviceNotification codec (§Wire Layouts 3); `onCancel` swallow-on-dead rule; existing Phase-2 fan-out already error-closes demux controllers (§Handle Lifecycle) |
| NOTIF-03 | Parse nested notification frames (stamps × samples), convert FILETIME → DateTime | Byte-precise 0x08 parser transcribed from `NotificationDispatcher::Run` (§Wire Layouts 4); FILETIME math (§FILETIME Conversion) |
| NOTIF-04 | On-change or cyclic transmission with max-delay / cycle-time attributes | `AdsTransmissionMode` enum from `ADSTRANSMODE`; attrib fields in the Add request (§Wire Layouts 1); Duration→100ns conversion |
| TEST-05 (slice) | testAdsNotification + testManyNotifications ported; testEndurance tagged `slow` | Exact C++ behaviours extracted (§C++ Test Parity); mock active-handle-count magic group for leak proof; multi-stamp/multi-sample golden |
</phase_requirements>

## Summary

Everything the planner needs is byte-exact in the vendored C++. The AddDeviceNotification request is a **40-byte** fixed struct (`AdsAddDeviceNotificationRequest`, `AmsHeader.h:92`); its response is **result u32 + handle u32** (8 bytes). DeleteDeviceNotification is **handle u32** (4 bytes) → **result u32** (4 bytes). The unsolicited 0x08 stream is a doubly-nested structure — `length u32, stamps u32, [ timestamp u64, sampleCount u32, [ handle u32, size u32, data[size] ] ]` — transcribed directly from `NotificationDispatcher::Run` (`NotificationDispatcher.cpp:56`). The parser MUST loop both levels: a flat "1 stamp × 1 sample" parser passes naive tests and silently drops batched samples.

Three correctness areas dominate this phase and are pure design (not lookups), so they are called out explicitly below: (1) **hostile-frame containment** — the current `AmsConnection.connect` listener treats *any* `MalformedFrameException` as connection-poisoning and calls `_failClose`; the notification parse/dispatch MUST catch its own errors locally (increment `droppedNotifications`, drop the frame) so one malformed 0x08 frame cannot kill every subscription; (2) **the first-listen race** — because the handle is only known after the async Add-response, the demux map must be populated **synchronously in the frame-correlation path**, not in an awaited client continuation, or the first notification(s) arriving in the same TCP chunk as the Add-response get dropped; (3) **stale-handle discipline** — on disconnect, handles are invalidated locally and NEVER Deleted against a reconnected session.

**Primary recommendation:** Add `addNotification` / `deleteNotification` methods to `AmsConnection` that own the demux-map lifecycle synchronously (mirroring C++ `CreateNotifyMapping`), put the pure nested parser + FILETIME helper in `lib/src/protocol/notifications.dart`, put the `subscribe()` Stream orchestration (onListen→Add, onCancel→Delete, cancel-during-pending-add state machine) in the client layer, and extend the mock with handle allocation + write-triggered/burst emission + a magic "active-handle-count" read group for the deterministic leak proof.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Add/Del request payload build | `protocol/` (pure) | — | Wire layout single-source-of-truth, golden-testable; follows `commands.dart` builder pattern |
| Nested 0x08 stream parse + FILETIME | `protocol/` (pure) | — | No I/O; golden-testable against a multi-stamp/multi-sample fixture (CONTEXT locked) |
| handle → StreamController demux map | `connection/` (AmsConnection) | — | The 0x08 frame arrives on the connection with no invoke-id; demux is a connection concern (CONTEXT locked: registry lives in AmsConnection) |
| Add/Del round-trip + synchronous map registration | `connection/` (AmsConnection) | — | Must register the controller synchronously with response correlation to beat the first-listen race |
| `subscribe()` Stream + lifecycle state machine (onListen/onCancel, pending-add cancel) | `client/` (AdsClient) | connection | Async orchestration belongs above the pure protocol; mirrors existing `AdsClient` command methods |
| Mock handle allocation + emission + leak-count | test harness (mock_server.cpp) | — | Server-role behaviour; single-threaded request-driven emission |
| Disconnect fan-out (error-close all controllers) | `connection/` (AmsConnection) | — | Already implemented in Phase 2 `_failClose`; Phase 5 only populates the map it drains |

## Standard Stack

This phase adds **zero external packages**. It is pure-Dart protocol code built on the existing stack (`dart:typed_data`, `dart:async`) and the Phase 1–4 in-repo infrastructure.

### Core (in-repo, already present)
| Component | Location | Purpose | Why Standard |
|-----------|----------|---------|--------------|
| `commands.dart` builder pattern | `lib/src/protocol/commands.dart` | Model for `buildAddNotificationPayload` / `buildDeleteNotificationPayload` | Single-source-of-truth wire layouts consumed by both encoders and client; golden-pinned |
| `AmsConnection` demux hook | `lib/src/connection/ams_connection.dart:258` | 0x08 branch + `_demuxControllers` map already stubbed | CONTEXT: "Phase 5 fills in the handle → StreamController dispatch" |
| `_failClose` fan-out | `ams_connection.dart:303` | Already error-closes every `_demuxControllers` entry on disconnect | NOTIF-02 disconnect cleanup is already built |
| `MalformedFrameException` | `lib/src/protocol/exceptions.dart` | Thrown by the parser on inconsistent frames | Existing typed-exception family (matches `commands.dart` decoders) |
| `checkUint` | `lib/src/protocol/range_check.dart` | Range-checks u32 fields in payload builders | Used by every existing builder |
| Mock server | `test_harness/mock_server.cpp` | Add/Del handling + 0x08 emission | Faithful server role; `wrapResponse` helper reusable for 0x08 framing |
| `dump_golden` | `test_harness/dump_golden.cpp` | Emit Add req/res + notification-stream goldens | Existing golden-reproducibility gate |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `subscribe()` orchestration in client layer | Put it all in AmsConnection | Keeps async out of the pure protocol, but AmsConnection is already the demux owner; splitting Stream orchestration (client) from map ownership (connection) matches the existing client/connection seam. RECOMMENDED: connection owns map + Add/Del round-trip; client owns the Stream/lifecycle. |
| Single-subscription `StreamController` | Broadcast controller | CONTEXT locks single-subscription (first-listen semantics + clean onCancel). Broadcast has no `onCancel`-when-last-listener-leaves guarantee and would break the "Add on first listen" contract. |

**Installation:** none — no `pubspec.yaml` change. (No `## Package Legitimacy Audit` section: this phase installs no external packages.)

## Wire Layouts (byte-precise, little-endian)

All offsets are within the **ADS payload** — the bytes AFTER the 6-byte AMS/TCP wrapper and 32-byte AMS header (the same "payload" the existing `build*Payload` functions produce and `AmsConnection.request` returns). All multi-byte fields little-endian. `[VERIFIED: third_party/ADS/AdsLib/AmsHeader.h, AdsDef.h, standalone/NotificationDispatcher.cpp, standalone/AdsLib.cpp]`

### 1. AddDeviceNotification (0x0006) REQUEST — 40 bytes

Source: `struct AdsAddDeviceNotificationRequest` (`AmsHeader.h:92`), populated in `AdsSyncAddDeviceNotificationReqEx` (`AdsLib.cpp:255`): field order is `indexGroup, indexOffset, cbLength, nTransMode, nMaxDelay, nCycleTime`.

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | u32 | indexGroup | the watched variable's index group |
| 4 | u32 | indexOffset | the watched variable's index offset |
| 8 | u32 | cbLength | number of bytes to watch / transfer (the `length:` arg) |
| 12 | u32 | nTransMode | `ADSTRANSMODE` value (see enum below) |
| 16 | u32 | nMaxDelay | 100ns units — callback fires at latest after this time |
| 20 | u32 | nCycleTime | 100ns units — sampling interval (union with `dwChangeFilter`) |
| 24 | 16 bytes | reserved | all zero (`std::array<uint8_t,16> reserved()`) |

**Total: 40 bytes.** Do NOT omit the 16 reserved bytes — a 24-byte payload is the classic off-by-16 bug (a real PLC and this mock both size-check).

`ADSTRANSMODE` (`AdsDef.h:322`): `NOTRANS=0, CLIENTCYCLE=1, CLIENTONCHA=2, SERVERCYCLE=3, SERVERONCHA=4, SERVERCYCLE2=5, SERVERONCHA2=6, CLIENT1REQ=10, MAXMODES=11`. CONTEXT default is `serverOnChange` (4).

**Duration → 100ns conversion:** `100ns units = duration.inMicroseconds * 10` (1 µs = 10 × 100ns). Range-check the result fits u32 (max ≈ 429.4 s). A `Duration.zero` → 0 (valid: "every cycle / every change").

### 2. AddDeviceNotification (0x0006) RESPONSE — 8 bytes

Source: decoded as `AoEResponseHeader` (result u32) followed by the 4-byte handle buffer (`AmsConnection.cpp:363` dispatches ADD as `ReceiveFrame<AoEResponseHeader>`; `AdsLib.cpp:247` `buffer[sizeof(*pNotification)]` = 4 bytes).

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | u32 | result | ADS status word (0 == success) |
| 4 | u32 | notificationHandle | the PLC-assigned handle used to demux + Delete |

Guard: require ≥ 8 bytes only when `result == 0`; on a non-zero result the payload may be just the 4-byte result (mirror the `commands.dart` "check errorCode/result before reading data" pattern — threat T-3-02).

### 3. DeleteDeviceNotification (0x0007)

Source: `AmsConnection::DeleteNotification` (`AmsConnection.cpp:96`): `request.frame.prepend(htole(hNotify))`, bufferLength 0.

REQUEST — 4 bytes:
| Offset | Size | Field |
|--------|------|-------|
| 0 | u32 | notificationHandle |

RESPONSE — 4 bytes:
| Offset | Size | Field |
|--------|------|-------|
| 0 | u32 | result (0 == success) |

### 4. Device Notification stream (0x0008, unsolicited) — nested

Source: `NotificationDispatcher::Run` (`NotificationDispatcher.cpp:56-101`). NOTE: the C++ reads an extra leading u32 (`fullLength`) that is **not on the wire** — the C++ manually prepends `AoEHeader.length()` into its own ring buffer (`AmsConnection.cpp:304`) before the wire bytes. On the actual wire (= the AMS payload the Dart parser receives), the stream begins with the `length` field:

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0 | u32 | length | bytes following this field = `payload.length - 4` (validate) |
| 4 | u32 | stamps | number of stamp headers |
| — | — | **per stamp (× stamps):** | |
| +0 | u64 | timestamp | FILETIME: 100ns ticks since 1601-01-01 UTC |
| +8 | u32 | sampleCount | number of samples in THIS stamp |
| — | — | **per sample (× sampleCount):** | |
| +0 | u32 | handle | `hNotification` — demux key |
| +4 | u32 | size | `cbSampleSize` — data byte count |
| +8 | size | data | the sample bytes |

The C++ callback flattens each **sample** into one `AdsNotificationHeader { nTimeStamp = stamp.timestamp, hNotification = sample.handle, cbSampleSize = sample.size }` (`AdsNotification.h:31`). So **one wire sample → one `AdsNotification`**, with `timestamp` taken from the enclosing stamp (shared across all samples in that stamp). There is no separate on-wire "AdsNotificationHeader" — it is a C++ in-memory reconstruction.

**Parser validation rules (transcribe, do not improvise):**
- `length + 4 == payload.length` (the `length` field is self-describing; a mismatch is malformed).
- Every field read is bounds-checked before dereference (mirror the mock's `getU32(body,bodyLen,off,...)` discipline and `commands.dart` `_require`).
- Per-sample: `size` must not exceed remaining bytes → else `MalformedFrameException`.
- C++ behaviour on a sample-size mismatch vs. the registered notification size: it `LOG_WARN`s and `goto cleanup` (abandons the rest of the frame). For Dart, an unknown handle → skip that sample's `data` (C++ `ring.Read(size)`), a size-inconsistent or truncated frame → `MalformedFrameException` caught at the dispatch boundary (see Pitfall 1).

## FILETIME → DateTime Conversion

**Epoch offset (VERIFIED by computation):** the number of 100-nanosecond ticks between 1601-01-01 00:00:00 UTC and 1970-01-01 00:00:00 UTC is exactly **116444736000000000**. `[VERIFIED: python datetime delta = 11644473600 s × 10⁷]`

```dart
/// FILETIME (100ns ticks since 1601-01-01 UTC) → DateTime (UTC).
const int _filetimeEpochOffset = 116444736000000000; // 100ns ticks 1601→1970
DateTime filetimeToDateTime(int filetime) {
  final micros = (filetime - _filetimeEpochOffset) ~/ 10; // 100ns → µs (truncates)
  return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
}

int dateTimeToFiletime(DateTime dt) =>
    dt.toUtc().microsecondsSinceEpoch * 10 + _filetimeEpochOffset;
```

**Precision:** FILETIME resolution is 100ns (0.1 µs); Dart `DateTime` on the native VM is **microsecond** precision. Converting FILETIME→DateTime **truncates the sub-microsecond 100ns digit** (`~/ 10`). Round-trip (`filetime → DateTime → filetime`) is lossless ONLY when the original FILETIME is a whole number of microseconds (a multiple of 10). **Round-trip test strategy:** pick a FILETIME that is a multiple of 10 (e.g. build one via `dateTimeToFiletime(knownUtcInstant)`) and assert exact equality; separately assert that a FILETIME with a non-zero 100ns digit truncates predictably. `[VERIFIED: DateTime is µs-precision on dart:io VM; this package is native-only per PKG-01, so the web ms-precision caveat does not apply]`

**64-bit safety:** modern FILETIMEs (~1.3×10¹⁷ for 2020s dates) sit far below `2^63`, so Dart's signed 64-bit `int` and `ByteData.getUint64(..., Endian.little)` handle them without overflow. `getUint64` is available on the native VM. `[VERIFIED: native int is 64-bit; current filetimes ≪ 2^63]`

## Architecture Patterns

### System Architecture Diagram

```
 subscribe(group,offset,len,mode,cycle,maxDelay)  [AdsClient]
        │  creates single-subscription StreamController (NOT yet subscribed on PLC)
        ▼
   returns Stream<AdsNotification>  ──────────────► consumer
        │
   consumer.listen()  ── onListen ──►  buildAddNotificationPayload (protocol, 40B)
        │                                     │
        │                              AmsConnection.addNotification(payload, controller)
        │                                     │  request(0x06) ──► [mock/PLC]
        │                                     ▼
        │                              Add-response {result, handle}
        │                                     │  (SYNCHRONOUS in frame-correlation path)
        │                              _demuxControllers[handle] = controller   ◄── beats first-listen race
        │
   ═══ inbound TCP ═══► FrameAssembler ═══► _onFrame(frame)
                                               │
                          commandId == 0x08 ?  ├── YES ──► try { parseNotificationStream(payload) }  [protocol, pure]
                                               │            for each sample:
                                               │              _demuxControllers[handle]?.add(AdsNotification)
                                               │            catch (_) { droppedNotifications++; return }  ◄── containment
                                               │
                                               └── NO ───► invoke-id correlation (existing)

   consumer.cancel()  ── onCancel ──► buildDeleteNotificationPayload(handle) (protocol, 4B)
                                          AmsConnection.deleteNotification(handle)  request(0x07)
                                          _demuxControllers.remove(handle) ; controller.close()
                                          (swallow errors if connection dead — never throw from cancel)

   disconnect ──► _failClose (EXISTING Phase-2): error+close every _demuxControllers entry,
                  clear the map; handles invalidated locally, NEVER Deleted on a new session.
```

### Recommended Project Structure
```
lib/src/
├── protocol/
│   └── notifications.dart     # NEW: pure. AdsTransmissionMode enum,
│                              #   buildAddNotificationPayload / buildDeleteNotificationPayload,
│                              #   AddNotificationResponse/DeleteNotificationResponse decoders,
│                              #   parseNotificationStream() → List<AdsNotification>,
│                              #   filetimeToDateTime()/dateTimeToFiletime()
├── client/
│   ├── ads_notification.dart  # NEW (or fold into ads_types.dart): AdsNotification value type
│   └── ads_client.dart        # EDIT: add subscribe(...) → Stream<AdsNotification>
├── connection/
│   └── ams_connection.dart    # EDIT: addNotification()/deleteNotification(),
│                              #   fill 0x08 branch, add droppedNotifications counter
```

### Pattern 1: Payload builders mirror `commands.dart`
```dart
// Source: lib/src/protocol/commands.dart:157 (buildReadPayload pattern)
Uint8List buildAddNotificationPayload({
  required int indexGroup,
  required int indexOffset,
  required int length,
  required int transMode,        // AdsTransmissionMode.code
  required int maxDelay100ns,    // Duration.inMicroseconds * 10
  required int cycleTime100ns,
}) {
  final payload = Uint8List(40);            // 24 fields + 16 reserved
  final bd = ByteData.sublistView(payload);
  bd.setUint32(0,  checkUint(indexGroup, 32, 'indexGroup'),  Endian.little);
  bd.setUint32(4,  checkUint(indexOffset, 32, 'indexOffset'), Endian.little);
  bd.setUint32(8,  checkUint(length, 32, 'length'),          Endian.little);
  bd.setUint32(12, checkUint(transMode, 32, 'transMode'),    Endian.little);
  bd.setUint32(16, checkUint(maxDelay100ns, 32, 'maxDelay'), Endian.little);
  bd.setUint32(20, checkUint(cycleTime100ns, 32, 'cycleTime'),Endian.little);
  // bytes 24..39 remain zero (reserved)
  return payload;
}
```

### Pattern 2: Synchronous demux registration (beats the first-listen race)
**What:** The handle is only known after the async Add-response. If the client populates `_demuxControllers` in an `await` continuation, a notification frame arriving in the SAME TCP chunk as the Add-response is processed (synchronously, in `_onFrame`) BEFORE the microtask that registers the controller → the first notification is dropped.

**When to use:** always, for correctness on a real PLC (the mock can be made to avoid the race, but the library must not depend on that).

**How:** give `AmsConnection` an `addNotification` method that registers the controller synchronously at the moment the Add-response is correlated — before the returned Future completes — mirroring C++ `CreateNotifyMapping` (`AmsConnection.cpp:86`), which registers the mapping synchronously with the handle. Concretely: the pending-request entry for an Add carries the target `StreamController`; when `_onFrame` correlates it, decode the handle and do `_demuxControllers[handle] = controller` in the same synchronous turn, then complete the Future with the handle.

```dart
// AmsConnection — sketch
Future<int> addNotification(Uint8List payload, StreamController<AdsNotification> ctrl,
    {Duration? timeout}) async {
  final resp = await request(AdsCommandId.addDeviceNotification, payload, timeout: timeout);
  if (resp.errorCode != 0) throw AdsException.fromCode(resp.errorCode);
  final decoded = decodeAddNotificationResponse(resp.payload); // result + handle
  if (decoded.result != 0) throw AdsException.fromCode(decoded.result);
  _demuxControllers[decoded.handle] = ctrl;   // registered before any 0x08 for this handle can be *dispatched*
  return decoded.handle;
}
```
> NOTE (design, not fact): because a notification for handle H cannot be *sent* by the peer until it has processed the Add and sent its response (both travel in-order on the one TCP connection), H's demux entry is guaranteed present by the time H's first 0x08 frame is *parsed* — PROVIDED registration is synchronous with response correlation. The registration above runs one microtask after the response frame is processed; if the Add-response and the first notification are in the same chunk, the notification's `_onFrame` runs first. **Two robust options for the planner to choose between (flag for discuss if unsure):**
> - **(A)** Register the controller inside `_onFrame`'s Add-correlation branch (fully synchronous — strongest). Requires the pending entry to hold the controller and `_onFrame` to know "this is an Add, extract handle, register, then complete."
> - **(B)** Keep the `await`-based registration above AND make the 0x08 dispatch tolerant of a not-yet-registered handle by buffering unmatched samples in a tiny short-lived holding map keyed by handle, flushed when the handle registers. More moving parts.
>
> **Recommendation: (A)** — it is the direct analogue of the C++ synchronous `CreateNotifyMapping` and adds no buffering state. `[ASSUMED — design choice; validate against the chosen AmsConnection internals]`

### Pattern 3: `subscribe()` lifecycle state machine (client)
```dart
// AdsClient.subscribe — sketch
Stream<AdsNotification> subscribe({
  required int indexGroup, required int indexOffset, required int length,
  AdsTransmissionMode mode = AdsTransmissionMode.serverOnChange,
  Duration cycleTime = Duration.zero, Duration maxDelay = Duration.zero,
}) {
  int? handle;              // null until Add returns
  var cancelled = false;    // set if onCancel fires while Add still pending
  late final StreamController<AdsNotification> ctrl;
  ctrl = StreamController<AdsNotification>(
    onListen: () async {
      try {
        final h = await connection.addNotification(
          buildAddNotificationPayload(/* ...mode.code, us*10... */), ctrl);
        if (cancelled) {                 // cancelled during pending Add
          await _deleteQuietly(h);       // immediately release the just-created handle
          return;
        }
        handle = h;
      } catch (e, st) {
        if (!ctrl.isClosed) ctrl.addError(e, st);  // surface Add failure to the listener
      }
    },
    onCancel: () async {
      cancelled = true;
      final h = handle;
      if (h != null) await _deleteQuietly(h);      // Delete always attempted (NOTIF-02)
      // if h == null the onListen path handles the pending-cancel Delete
    },
  );
  return ctrl.stream;
}

Future<void> _deleteQuietly(int handle) async {
  try {
    await connection.deleteNotification(
      buildDeleteNotificationPayload(handle: handle));
  } catch (_) { /* connection dead: handle already invalidated — never throw from cancel */ }
}
```

### Anti-Patterns to Avoid
- **Flat "1 stamp × 1 sample" parser:** passes a single-sample fixture, silently drops batched samples. CONTEXT mandates a 2×2 golden to prove the nested loop.
- **Letting a notification parse error reach the connect() listener:** it calls `_failClose` → kills every subscription. Catch at the 0x08 dispatch boundary.
- **Deleting handles on a reconnected session:** a stale handle number may now belong to a different subscription on the new session. Invalidate locally only.
- **Building the Add request as 24 bytes:** omit the 16 reserved bytes and the PLC/mock rejects it (`ADSERR_DEVICE_INVALIDSIZE`).
- **Throwing from `onCancel`:** Stream cancel must never throw; swallow after handle invalidation.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| First-listen / on-cancel subscription lifecycle | A custom listener-count tracker | `StreamController(onListen:, onCancel:)` (single-subscription) | Dart's single-subscription controller gives exactly-once onListen/onCancel; matches CONTEXT's "Add on first listen, Delete in onCancel" verbatim |
| Disconnect cleanup of controllers | New teardown code | Existing `_failClose` fan-out (`ams_connection.dart:317`) | Already error-closes + clears `_demuxControllers`; Phase 5 only populates the map |
| FILETIME epoch math | Ad-hoc date arithmetic | The single `116444736000000000` constant + `~/10` | One verified constant; anything else drifts by leap-second / offset mistakes |
| u32/u64 LE field access | Manual byte shifts | `ByteData.setUint32/getUint32/getUint64(..., Endian.little)` | Matches every existing codec; CLAUDE-rule "explicit little-endian" satisfied by the Endian arg |
| Frame reassembly for 0x08 | Anything | Existing `FrameAssembler` — 0x08 frames arrive as complete frames already | The demux operates on whole frames from `_onFrame`; no new reassembly |

**Key insight:** this phase is 90% transcription + wiring into slots that already exist. The genuinely new logic is the nested parser, the FILETIME helper, and the lifecycle state machine — everything else plugs into Phase 1–4 seams.

## Common Pitfalls

### Pitfall 1: A malformed 0x08 frame kills the whole connection
**What goes wrong:** the parser throws `MalformedFrameException`; it propagates to the `connect()` inbound listener, whose `on MalformedFrameException catch (e) => _failClose(e)` (`ams_connection.dart:121`) tears the connection down — every subscription dies from one bad frame.
**Why it happens:** the current listener cannot distinguish an assembler-level poison (truly corrupt stream, should die) from a notification-payload parse error (should be contained). The 0x08 branch at `_onFrame:258` currently just counts and returns — the parse doesn't exist yet, so no one has closed this gap.
**How to avoid:** wrap the notification parse + per-sample dispatch in its own `try/catch` INSIDE the 0x08 branch of `_onFrame`. On any error: `droppedNotifications++`, optionally log, and `return`. Never rethrow. Add a `droppedNotifications` counter alongside the existing `notificationFrames` / `droppedResponses` counters.
**Warning signs:** an integration test that sends one crafted bad 0x08 frame and then a good one — the good one must still be delivered and the connection must still be `isConnected`.

### Pitfall 2: First notification dropped (the race)
**What goes wrong:** notifications that arrive in the same TCP segment as the Add-response are dropped because the demux map isn't populated yet.
**Why it happens:** async handle registration runs a microtask after the synchronous `_onFrame` drain. See Pattern 2.
**How to avoid:** synchronous registration in the frame-correlation path (Pattern 2, option A).
**Warning signs:** flaky "expected ≥1 notification, got 0" on the first sample when emission is immediate; robust only when emission is write-triggered after a round-trip. Test with immediate burst emission to expose it.

### Pitfall 3: Stale handle deleted on a new session
**What goes wrong:** after reconnect, cancelling an old subscription sends `DeleteDeviceNotification(oldHandle)` to the new session, freeing an unrelated subscription's handle.
**Why it happens:** handle numbers are per-session; the PLC reuses low integers.
**How to avoid:** on disconnect, `_failClose` invalidates (clears) all handles locally; `onCancel` after disconnect finds no live handle and no live connection → swallows. Never Delete across sessions. `ADSERR_DEVICE_NOTIFYHNDINVALID` (0x714) is the PLC's symptom of this class of bug.
**Warning signs:** deletes succeeding against a freshly reconnected mock that never received the corresponding Add.

### Pitfall 4: Reserved-bytes / mode-order transposition in the Add request
**What goes wrong:** swapping `nMaxDelay` and `nCycleTime`, or omitting the 16 reserved bytes → `ADSERR_DEVICE_INVALIDSIZE` / wrong cyclic timing.
**Why it happens:** the struct order (`mode, maxDelay, cycleTime`) is not alphabetical and the API arg order in some SDKs differs.
**How to avoid:** transcribe field order from `AdsAddDeviceNotificationRequest` (`AmsHeader.h:92`) exactly; pin with a golden.
**Warning signs:** golden-diff mismatch at bytes 12–23; mock size-check rejection.

### Pitfall 5: FILETIME sign / precision surprises
**What goes wrong:** using `getInt64`, or expecting nanosecond round-trip fidelity.
**Why it happens:** FILETIME is unsigned; DateTime is µs-precision.
**How to avoid:** `getUint64`; document the 100ns→µs truncation; round-trip test only with multiple-of-10 FILETIMEs.
**Warning signs:** off-by-a-few-ticks round-trip failures.

## Code Examples

### Reading the nested stream (pure parser)
```dart
// Source: transcribed from third_party/ADS/AdsLib/standalone/NotificationDispatcher.cpp:56
List<AdsNotification> parseNotificationStream(Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  if (payload.length < 8) {
    throw MalformedFrameException('notification stream < 8 bytes', length: payload.length);
  }
  final length = bd.getUint32(0, Endian.little);
  if (length + 4 != payload.length) {
    throw MalformedFrameException(
      'notification length $length + 4 != payload ${payload.length}', length: length);
  }
  final stamps = bd.getUint32(4, Endian.little);
  final out = <AdsNotification>[];
  var off = 8;
  for (var s = 0; s < stamps; s++) {
    if (off + 12 > payload.length) throw MalformedFrameException('stamp header overrun', offset: off);
    final ticks = bd.getUint64(off, Endian.little);
    final ts = filetimeToDateTime(ticks);
    final samples = bd.getUint32(off + 8, Endian.little);
    off += 12;
    for (var i = 0; i < samples; i++) {
      if (off + 8 > payload.length) throw MalformedFrameException('sample header overrun', offset: off);
      final handle = bd.getUint32(off, Endian.little);
      final size = bd.getUint32(off + 4, Endian.little);
      off += 8;
      if (off + size > payload.length) throw MalformedFrameException('sample data overrun', offset: off);
      final data = Uint8List.fromList(payload.sublist(off, off + size)); // defensive copy
      off += size;
      out.add(AdsNotification(handle: handle, timestamp: ts, data: data));
    }
  }
  return out;
}
```

### 0x08 dispatch in `_onFrame` (containment + demux)
```dart
// EDIT of ams_connection.dart:258 branch
if (header.commandId == AdsCommandId.deviceNotification) {
  notificationFrames++;
  try {
    final payload = Uint8List.sublistView(
      frame, AmsTcpHeader.byteLength + AmsHeader.byteLength);
    for (final n in parseNotificationStream(payload)) {
      _demuxControllers[n.handle]?.add(n);  // unknown handle → silently ignored (C++ parity)
    }
  } catch (_) {
    droppedNotifications++;                 // one bad frame must not kill the connection
  }
  return;
}
```

## State of the Art

| Old Approach | Current Approach | When | Impact |
|--------------|------------------|------|--------|
| Callback (`PAdsNotificationFuncEx`) + polling FIFO (C++ AdsLib) | Dart `Stream<AdsNotification>` with lazy Add-on-first-listen | This port | Idiomatic Dart; backpressure deferred to v2 (unbounded buffer, HMI listens immediately) |
| C++ dispatch on a background `std::thread` per virtual connection | Single event-loop dispatch in `_onFrame` | This port | No threads/locks; the "map-remove-wins" single-loop invariant extends to demux |

**Deprecated/outdated:** none relevant. The `BHF_ADS_USE_TWINCAT_ORDER` `#ifdef` (`AdsDef.h:415`) swaps the in-memory `AdsNotificationHeader` field order for shared-library ABI compatibility — it does NOT affect the wire format (which is stamp-nested, not header-prefixed). Ignore it for the wire parser.

## Runtime State Inventory

Not a rename/refactor/migration phase — greenfield feature addition. Section omitted per the template's "omit for greenfield" rule.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Dart SDK (native VM) | all Dart code, `getUint64`, µs `DateTime` | ✓ (Phases 1–4 built on it) | project-pinned | — |
| CMake + C++ toolchain | mock_server / dump_golden rebuild for new goldens + emission | ✓ (harness already built in Phase 1) | project-pinned | — |

No new external dependencies. `dart:async` `StreamController`, `dart:typed_data` `ByteData` are core-library.

## Validation Architecture

*(nyquist_validation is `true` in `.planning/config.json`.)*

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `package:test` (Dart) + C++ mock via `Process.start` (existing `test/support/mock_server.dart`) |
| Config file | `dart_test.yaml` (tags: `integration`, `slow`); no new config needed |
| Quick run command | `dart test test/unit/protocol/notifications_test.dart -x` (golden + parser, no socket) |
| Full suite command | `dart test` (unit) + `dart test -t integration` (mock-backed) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| NOTIF-03 | Nested 2-stamp × 2-sample parse | unit (golden) | `dart test test/unit/golden_parity_test.dart -n notification` | ❌ Wave 0 |
| NOTIF-03 | FILETIME round-trip (µs-exact) + truncation | unit | `dart test test/unit/protocol/notifications_test.dart -n filetime` | ❌ Wave 0 |
| NOTIF-01 | Add req = 40 bytes, field order, golden | unit (golden) | `dart test test/unit/golden_parity_test.dart -n add_notification` | ❌ Wave 0 |
| NOTIF-01 | subscribe→onListen sends Add; first sample delivered (race) | integration | `dart test -t integration test/integration/ads_notification_test.dart -n testAdsNotification` | ❌ Wave 0 |
| NOTIF-02 | onCancel sends Delete; disconnect error-closes all streams | integration | `dart test -t integration -n "cancel\|disconnect"` | ❌ Wave 0 |
| NOTIF-02 | Handle-leak proof: after N sub/cancel cycles mock active-handle count == 0 | integration | `dart test -t integration -n testManyNotifications` | ❌ Wave 0 |
| NOTIF-04 | serverCycle vs serverOnChange; cycle/maxDelay 100ns encoding | unit + integration | `dart test -n "transmission mode"` | ❌ Wave 0 |
| NOTIF-03 | Hostile 0x08 frame dropped, connection survives | integration | `dart test -t integration -n "hostile notification"` | ❌ Wave 0 |
| TEST-05 | testEndurance (long-running) tagged `slow`, excluded by default | integration (slow) | `dart test -t slow -n testEndurance` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `dart test test/unit/protocol/notifications_test.dart -x` (pure parser + FILETIME, sub-second).
- **Per wave merge:** `dart test` + `dart test -t integration` (excludes `slow`).
- **Phase gate:** full suite green (excluding `slow`) before `/gsd:verify-work`; `slow` endurance runnable manually.

### Wave 0 Gaps
- [ ] `test/unit/protocol/notifications_test.dart` — parser (incl. 2×2 nesting, overruns), FILETIME round-trip/truncation, payload builders.
- [ ] `test/integration/ads_notification_test.dart` — C++-named groups `testAdsNotification`, `testManyNotifications`, `testEndurance` (slow), plus hostile-frame + race groups.
- [ ] New goldens via `dump_golden`: `add_notification_req.hex`, `add_notification_res.hex`, `del_notification_req.hex`, `del_notification_res.hex`, `notification_stream.hex` (2 stamps × 2 samples).
- [ ] Mock extension: ADD/DEL handling, active-handle-count magic read group, emission mechanism (write-triggered + burst).
- [ ] `dart_test.yaml`: confirm `slow` tag registered (or add) so endurance is excluded by default.

## C++ Test Parity (exact behaviours extracted)

Source: `third_party/ADS/AdsLibTest/main.cpp`.

**Attribs used by EVERY notification test** (`main.cpp:861,1046,1097`):
```cpp
AdsNotificationAttrib attrib = { 1, ADSTRANS_SERVERCYCLE, 0, { 1000000 } };
//  cbLength=1, nTransMode=3 (SERVERCYCLE), nMaxDelay=0, nCycleTime=1000000 (100ns) = 100 ms
```
The "normal test" registration loop calls `AddDeviceNotificationReqEx(port, &server, 0x4020, 4, &attrib, ...)` — **0x4020 is indexGroup, 4 is indexOffset** (a TwinCAT memory/flags area), cbLength stays 1 from the attrib.

**testAdsNotification** (`main.cpp:851`): a **lifecycle + error-code** test — it does NOT assert a received-notification count (`g_NumNotifications` is not checked here). Sequence:
1. Error cases (adapt to Dart / mock magic groups; several are Phase-2/4 covered-by-equivalent):
   - out-of-range port → `ADSERR_CLIENT_PORTNOTOPEN` (0x748) — Dart: covered-by-equivalent (no port handle).
   - nullptr AmsAddr → `ADSERR_CLIENT_NOAMSADDR` (0x749) — covered-by-equivalent.
   - unknown AmsAddr → `GLOBALERR_MISSING_ROUTE` (0x7) — Phase-4 router concern / mock magic AMS group `kErrAmsGroup`.
   - invalid indexGroup (`0`) → `ADSERR_DEVICE_SRVNOTSUPP` (0x701) — mock magic result group `kErrResultGroup` offset 0x701.
   - invalid indexOffset (`0x4025, 0x10000`) → `ADSERR_DEVICE_SRVNOTSUPP` (0x701).
   - nullptr attrib/callback/handle → `ADSERR_CLIENT_INVALIDPARM` (0x706) — Dart API makes these non-nullable (compile-time); document as covered-by-type.
   - **delete nonexistent handle (0xDEADBEEF) → `ADSERR_CLIENT_REMOVEHASH` (0x752)** — mock must return this for an unknown Delete handle.
2. Normal: register **1024** notifications (`MAX_NOTIFICATIONS_PER_PORT`), `sleep 100ms`, delete the first **512** (`MAX - LEAKED`, `LEAKED = 512`) — the remaining 512 are **intentionally leaked** to prove **port-close cleans them up** (`AdsPortCloseEx`). Dart adaptation: register N, cancel some, and assert the connection-close / disconnect fan-out cleans up the rest (the mock active-handle count returns to 0 after close). CONTEXT relaxes 1024→"64+".

**Dart port of testAdsNotification** (CONTEXT 1:1 intent): register a subscription against a mock-known (group,offset), **receive ≥1 notification** (mock emits via write-trigger or burst), cancel → Delete sent, **verify no further delivery** after cancel.

**testManyNotifications** (`main.cpp:998`): spawns **8 threads**, each running `Notifications(1024)` = register 1024, `sleep 5s`, delete 1024 (`main.cpp:1090`). It is a **throughput** harness (prints `notifications/ms`) with `fructose_assert_eq(0, Add...)`/`Delete...` on every call — the correctness content is "all 8192 Add and all 8192 Delete return 0." Dart adaptation (CONTEXT): **many concurrent subscriptions (64+), all receive, all clean up, assert mock active-handle count returns to 0** — a deterministic leak proof, not a throughput number.

**testEndurance** (`main.cpp:1038`): register 1024, run a concurrent reader thread, **block on `std::cin` until ENTER**, then delete 1024. Interactive/manual by construction. Dart adaptation: a long-running loop tagged **`slow`** (excluded by default, runnable manually) — CONTEXT locked.

**Mock active-handle-count exposure (RECOMMENDED, in-band):** reserve a magic read index group (e.g. `0xE7700002`) — a `Read` to it returns the current count of active notification handles as a u32. Clean, deterministic, no side channel, matches the existing magic-group idiom (`kErrResultGroup`/`kErrAmsGroup` at `mock_server.cpp:108`). The leak-proof test reads it before subscribing (expect 0), after N subscribes (expect N), and after cancel/disconnect (expect 0). `[ASSUMED — new mock convention; pick a group number that cannot collide with real ADS groups]`

## Mock Emission Design (recommended)

The mock is single-threaded, request-driven, one connection per accept, no timers/threads (`mock_server.cpp:444`). Recommended additions (all deterministic):

1. **Per-connection notification table:** `std::map<uint32_t handle, {group, offset, cbLength, transMode}>` + an incrementing `nextHandle` starting at 1 (declared in the per-connection block like `store`, so each test starts clean — `mock_server.cpp:427`).
2. **ADD_DEVICE_NOTIFICATION (0x06):** parse the 40-byte request (bounds-checked `getU32`), allocate a handle, record attribs, respond `result u32=0 + handle u32` via `wrapResponse(f, ADD_DEVICE_NOTIFICATION, ...)`.
3. **DEL_DEVICE_NOTIFICATION (0x07):** parse handle u32; if present → erase, respond `result=0`; if absent → respond `result = ADSERR_CLIENT_REMOVEHASH (0x752)` (matches testAdsNotification's delete-nonexistent assertion).
4. **Emission — write-triggered (serverOnChange faithful):** on a `WRITE` to `(group, offset)`, after storing, emit a 0x08 frame to every handle watching that exact `(group, offset)`, carrying the written bytes (truncated/padded to `cbLength`). Deterministic: a test writes, then expects exactly one notification. This proves onChange semantics AND exercises the demux.
5. **Emission — burst (immediate, race-exposing):** a `--notify-burst N` CLI flag → on each ADD, immediately emit N single-sample frames for that handle. Use this to deliberately expose the first-listen race (Pitfall 2).
6. **Multi-stamp/multi-sample proof:** a dedicated magic write group (e.g. `0xE7700003`) that, when written, emits ONE crafted frame with **2 stamps × 2 samples** (distinct timestamps, distinct handles/data) — the fixture that proves the nested parser. Also emit this exact frame from `dump_golden` as `notification_stream.hex`.
7. **Framing a 0x08 frame:** build the nested payload with `putU32`/`putU64` (add a `putU64` helper mirroring `putU32`), wrap with `AoEHeader(cmdId = DEVICE_NOTIFICATION 0x08, invokeId = 0)` addressed TO the client (target = request source), via the existing `wrapResponse` (the stateFlags patch is harmless — Dart's `_onFrame` branches on `commandId == 0x08` before any invoke-id/stateFlags check, `ams_connection.dart:258`). `[VERIFIED: Dart demux ignores invokeId/stateFlags for 0x08]`

> Emission mechanics (write-triggered vs. burst vs. cyclic timer) are explicitly **Claude's discretion** per CONTEXT. Write-triggered + burst + the 2×2 magic group cover every locked requirement deterministically without a timer in the select loop.

## Security Domain

*(security_enforcement key absent from config → treat as enabled. This phase parses untrusted inbound bytes, so V5 Input Validation is the dominant concern.)*

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | **yes** | Bounds-check every field of the 0x08 stream before dereference (`length+4==payload.length`, per-sample `size` within remaining bytes); `MalformedFrameException` on any overrun; the existing mock/codec `getU32(body,bodyLen,off)` and `_require` discipline is the model |
| V6 Cryptography | no | ADS has no transport crypto in scope |
| V2/V3/V4 Auth/Session/Access | no | Client library; addressing/routing handled in Phase 4 |

### Known Threat Patterns for the 0x08 parser
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Oversized `size`/`sampleCount`/`stamps` → heap overread or huge alloc | Denial of Service / Tampering | Bounds-check each field against remaining `payload.length` before read; never trust `length`/`size`; the parser reads only within `payload` |
| Malformed frame throws → connection death (all subscriptions die) | Denial of Service | Catch at the 0x08 dispatch boundary, `droppedNotifications++`, drop frame (Pitfall 1) — one hostile frame cannot take down other subscriptions |
| Unknown/forged handle in a sample | Spoofing | Unknown handle → silently ignored (C++ parity: `ring.Read(size)` skips it); no dispatch to an unrelated stream |
| Integer overflow in `off + size` on accumulation | Tampering | Dart `int` is 64-bit; offsets stay well below `2^53`; still compare in subtraction-safe form where a u32 could be near `2^32` |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Synchronous demux registration (Pattern 2 option A) is the chosen race fix | Architecture Patterns | If the planner picks option B (holding-buffer) instead, the AmsConnection API differs; both are correct — this is a design pick, not a fact |
| A2 | Mock active-handle count exposed via a magic read group `0xE7700002` | C++ Test Parity / Mock | Group number is a new convention; must not collide with a real ADS group the mock also serves — pick a clearly-synthetic value like the existing `0xE7700000/1` |
| A3 | Multi-stamp/multi-sample proof via magic write group `0xE7700003` | Mock Emission | Convention choice; any deterministic trigger works |
| A4 | `notificationHandle` is the SECOND u32 of the Add response (after `result`) | Wire Layouts 2 | Verified from C++ (`buffer[sizeof(handle)]` read after `AoEResponseHeader`); low risk |
| A5 | Real PLCs send notifications only AFTER the Add-response on the same ordered TCP stream (the basis for "registration beats first frame") | Pattern 2 | If a PLC could interleave, option A still holds (registration is synchronous with correlation); risk is only to the reasoning, not the fix |

## Open Questions

1. **Where does the `AdsNotification` value type live — `client/` or `protocol/`?**
   - What we know: the pure parser (in `protocol/`) must construct it, so it can't depend on `client/`.
   - What's unclear: whether to co-locate it with the parser (`protocol/notifications.dart`) or in `client/` (like `ads_types.dart`).
   - Recommendation: put it in `protocol/notifications.dart` (the parser needs it and `protocol/` stays pure); re-export from the barrel. `[CLAUDE'S DISCRETION per CONTEXT — file layout]`

2. **Does `dart_test.yaml` already register the `slow` tag?**
   - What we know: `integration` tag is used (`@Tags(['integration'])` in existing tests).
   - What's unclear: whether `slow` is pre-declared (undeclared tags warn).
   - Recommendation: verify during planning; add `slow: {skip: ...}`-style registration if missing so endurance is excluded by default.

3. **Should `subscribe()` validate `mode` vs. `cycleTime`/`maxDelay` combinations** (e.g. reject a non-zero cycleTime with `noTrans`)?
   - Recommendation: pass values through as given (mirror C++, which does no such validation); the PLC/mock returns `ADSERR_DEVICE_TRANSMODENOTSUPP` (0x713) for an unsupported mode. Surface that error to the listener via `ctrl.addError`.

## Sources

### Primary (HIGH confidence)
- `third_party/ADS/AdsLib/AmsHeader.h` — `AdsAddDeviceNotificationRequest` (40-byte layout, field order), `AoEHeader` cmd IDs 0x06/0x07/0x08, `AoEResponseHeader`.
- `third_party/ADS/AdsLib/standalone/AdsDef.h` — `ADSTRANSMODE` enum, `AdsNotificationAttrib`, `AdsNotificationHeader` (FILETIME semantics), `ADSERR_*` codes.
- `third_party/ADS/AdsLib/standalone/NotificationDispatcher.cpp:56` — the authoritative nested-stream parse loop.
- `third_party/ADS/AdsLib/AdsNotification.h` — per-sample header reconstruction (timestamp/handle/size flattening).
- `third_party/ADS/AdsLib/standalone/AmsConnection.cpp` — `ReceiveNotification` (0x08 routing), `CreateNotifyMapping` (synchronous handle registration), `DeleteNotification` request build, ADD/DEL response dispatch (`:363`).
- `third_party/ADS/AdsLib/standalone/AdsLib.cpp:234` — Add request assembly (field order proof).
- `third_party/ADS/AdsLibTest/main.cpp` — `testAdsNotification` (:851), `testManyNotifications` (:998), `testEndurance` (:1038), `Notifications` (:1090); exact attrib values, counts, assertions.
- Existing Dart: `lib/src/connection/ams_connection.dart` (demux hook, `_failClose`, listener catch), `lib/src/protocol/commands.dart` (builder/decoder pattern), `lib/src/client/ads_client.dart` (command-method pattern), `lib/src/protocol/constants.dart` (cmd IDs already present), `lib/src/router/ams_router.dart` (client construction), `test_harness/mock_server.cpp` + `dump_golden.cpp` (server/golden idioms), `test/support/mock_server.dart` + `test/integration/ads_parity_test.dart` (parity harness).

### Secondary (MEDIUM confidence)
- FILETIME epoch offset `116444736000000000` — cross-checked by direct computation (Python `datetime` delta × 10⁷) AND matches the `AdsNotificationHeader` doc comment "100-nanosecond intervals since January 1, 1601 (UTC)" (`AdsDef.h:419`).

### Tertiary (LOW confidence)
- None — every load-bearing claim traces to vendored source or in-repo code.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — zero external packages; all slots exist in Phases 1–4.
- Wire layouts: HIGH — transcribed byte-for-byte from vendored C++ structs and the parse loop.
- FILETIME: HIGH — constant verified by computation and doc comment; precision behaviour verified against Dart `DateTime` semantics.
- C++ test behaviours: HIGH — exact attrib values / counts / assertions read from `main.cpp`.
- Handle-lifecycle / race / containment design: MEDIUM — these are design recommendations (flagged A1/A5) reasoned from the existing architecture, not lookups; both offered options are correct.
- Mock emission + leak-count conventions: MEDIUM — new conventions (A2/A3), CONTEXT grants discretion.

**Research date:** 2026-07-04
**Valid until:** 2026-08-04 (stable — vendored C++ pinned at submodule commit 57d63747; in-repo APIs change only with this project).
