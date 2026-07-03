# Pitfalls Research

**Domain:** Pure-Dart Beckhoff ADS/AMS client library (protocol reimplementation + async networking)
**Researched:** 2026-07-03
**Confidence:** HIGH (wire-format facts verified against Beckhoff/ADS source, Beckhoff InfoSys, and jisotalo TS implementations; Dart socket semantics from dart:io behavior)

> Scope note: This document is deliberately domain-specific. Generic advice ("write tests", "handle errors") is omitted in favor of the exact ways an ADS-over-Dart port goes wrong. Phase names below are topic labels the roadmap can map onto; suggested ordering is: **Framing/Codecs → TCP Transport → Async Correlation → Core Commands → Routing/AmsRouter → Notifications → Symbols/Handles → Sum Commands → Mock Server/Integration Tests → CLI → Publishing.**

---

## Critical Pitfalls

### Pitfall 1: Confusing the AMS/TCP header with the AMS header (two headers, not one)

**What goes wrong:**
Every ADS frame on the wire is `[AMS/TCP header: 6 bytes][AMS header: 32 bytes][ADS payload]`. Newcomers treat it as a single 38-byte header, or skip the 6-byte AMS/TCP header entirely, and every field lands at the wrong offset. The two headers have different purposes: the 6-byte AMS/TCP header is a transport framing wrapper (`2 bytes reserved (0x0000)` + `uint32 length` = length of everything after it), while the 32-byte AMS header carries the actual addressing/command semantics.

**Why it happens:**
Beckhoff docs present them on separate pages ("AMS/TCP Header" vs "AMS Header"), and the C++ AdsLib splits them across different code paths, so someone reading only one page or one struct misses the wrapper. The 2 reserved bytes look like padding and get dropped.

**How to avoid:**
Model them as two distinct types. The AMS header (32 bytes) is exactly: `targetNetId[6] + targetPort[2] + sourceNetId[6] + sourcePort[2] + commandId[2] + stateFlags[2] + dataLength[4] + errorCode[4] + invokeId[4]` = 32. The AMS/TCP `length` field = `32 + dataLength` (AMS header + ADS payload), NOT including the 6-byte wrapper itself. Write a byte-for-byte round-trip unit test against a captured real frame on day one.

**Warning signs:**
Server silently drops your connection after the first frame; target reports garbage ports; `length` field off by exactly 6 or 32; response `dataLength` doesn't match remaining bytes.

**Phase to address:** Framing/Codecs (Phase 1) — this is the foundation; get it wrong and nothing downstream works.

---

### Pitfall 2: Wrong endianness / struct packing when porting C++ structs to Dart

**What goes wrong:**
ADS is **little-endian** on the wire. Dart's `ByteData` defaults to **big-endian** unless you pass `Endian.little` on every `getUint32`/`setUint32`/etc. call. A single forgotten `Endian.little` corrupts one field (index group, offset, length, invokeId) while leaving others correct — producing intermittent, field-specific bugs that look like protocol confusion rather than an endianness slip.

**Why it happens:**
The C++ AdsLib relies on x86 memory layout (`reinterpret_cast` over packed structs) and never spells out endianness, because the host is already little-endian. Porting that mental model to Dart, where the default is big-endian, is a silent trap. Also, C++ `#pragma pack(1)` matters: AMS structs are byte-packed with no alignment padding, so you cannot assume natural alignment.

**How to avoid:**
Centralize all reads/writes through a small helper that hard-codes `Endian.little`; never call `ByteData.getUint32` without an explicit endian argument (consider a lint/grep gate in CI). Treat every struct as `pack(1)` — compute offsets by hand, never trust "natural" field alignment. AmsNetId (6 bytes) and the port are adjacent with no padding.

**Warning signs:**
Values that are byte-swapped (e.g., you read `0x08000000` where you expected `8`); index group `0xF003` arrives as `0x03F0`; works for zero/small symmetric values but breaks for large ones.

**Phase to address:** Framing/Codecs (Phase 1).

---

### Pitfall 3: TCP stream reassembly — assuming one `socket.listen` event == one ADS frame

**What goes wrong:**
`Socket` (and `RawSocket`) deliver a **byte stream**, not messages. A single `onData` event may contain a partial frame, exactly one frame, multiple coalesced frames, or a frame split across several events (Nagle, MTU, TCP segmentation all cause this). Code that parses each `Uint8List` chunk as a complete frame works on localhost with small payloads and shatters against a real PLC pushing large symbol uploads or bursts of notifications.

**Why it happens:**
Localhost/loopback and the CMake mock server tend to deliver small responses in single chunks, so the naive parser passes every early test. The bug only surfaces with real network segmentation or high-rate notifications — often in production, not in CI.

**How to avoid:**
Implement a length-prefixed reassembly buffer: accumulate incoming bytes into a growable buffer, then loop — read the 6-byte AMS/TCP header, extract `length`, and only emit a frame once `buffer.length >= 6 + length`; retain the remainder for the next iteration. Never assume a chunk boundary aligns with a frame boundary. This buffering layer sits between the raw socket and the codec.

**Warning signs:**
Occasional `RangeError`/`FormatException` under load; parser works in unit tests but fails against real PLC; failures correlate with payload size or notification rate; two responses "merge" into one garbled decode.

**Phase to address:** TCP Transport (Phase 2). Make the mock server (Phase: Mock/Integration) deliberately split and coalesce frames to force this early.

---

### Pitfall 4: invokeId correlation — leaking Completers and mismatching responses

**What goes wrong:**
ADS is request/response multiplexed over one socket, correlated by the 4-byte `invokeId`. The idiomatic Dart approach is a `Map<int, Completer>` keyed by invokeId. Three failure modes: (1) a request times out or the socket errors and the Completer is never completed nor removed → the awaiting Future hangs forever and the map leaks; (2) a duplicate/late response arrives after timeout and you call `completer.complete()` on an already-completed Completer → `StateError`; (3) invokeId counter collisions (reuse before response) route a response to the wrong caller.

**Why it happens:**
Happy-path code completes on response and forgets the timeout/error/disconnect branches. Completers are invisible when leaked (no crash, just a hung Future). invokeId is often naively started at 0 and can collide across reconnects.

**How to avoid:**
Wrap every request Future with a timeout that (a) completes the Completer with an error and (b) removes it from the map atomically. Guard every completion with `if (!completer.isCompleted)`. Use a monotonically increasing invokeId (wrapping uint32) and, on disconnect, flush the entire pending map by erroring every outstanding Completer before clearing it. Notifications (command 8) are **unsolicited** — they carry invokeId 0 and must be routed by the notification dispatcher, not matched against the request map.

**Warning signs:**
Futures that never resolve; growing memory over long sessions; intermittent "wrong data for this read" where a response belongs to a different request; `Bad state: Future already completed` after timeouts.

**Phase to address:** Async Correlation (Phase 3) — build the request/response manager before layering commands on top.

---

### Pitfall 5: Notification handle leaks — every AddDeviceNotification needs a matching Delete

**What goes wrong:**
`AddDeviceNotification` returns a server-side handle. The PLC/router keeps allocated resources per handle; TwinCAT has a **finite pool of notification handles** per ADS device. If you don't call `DeleteDeviceNotification` when a Dart `Stream` subscription is cancelled — or on disconnect, or when the consumer stops listening — you leak handles on the PLC. Eventually `AddDeviceNotification` starts failing (device out of resources), affecting not just your app but everything talking to that PLC until it's power-cycled.

**Why it happens:**
Dart's `Stream` cancellation is easy to ignore — if you build the Stream without an `onCancel` that fires the Delete, subscribers silently leak. Reconnect logic that re-subscribes without deleting the old handles compounds it. The leak lives on the PLC, invisible from the Dart side.

**How to avoid:**
Tie the notification lifecycle to the Stream lifecycle: use a `StreamController` with `onListen`/`onCancel`, issuing `AddDeviceNotification` on first listen and `DeleteDeviceNotification` on cancel. Maintain a registry of active handles per connection and delete all of them on `close()`/disconnect. On reconnect, treat all prior handles as invalid (they died with the socket) — do not attempt to delete stale handles against the new session, just re-add. Provide (and test) an explicit `dispose()` path.

**Warning signs:**
`AddDeviceNotification` returns error after the app has run for a while or after many reconnects; PLC-side notification count climbs monotonically; other clients start failing to subscribe; only a PLC restart clears it.

**Phase to address:** Notifications (Phase 6), with cleanup wired into Connection lifecycle (Phase 2).

---

### Pitfall 6: Parsing the nested notification sample buffer incorrectly

**What goes wrong:**
The `Notification` command (ID 8) payload is a **nested, variable-length** structure, not a flat sample. Layout: `AdsNotificationStream { uint32 length; uint32 stamps; }` followed by `stamps` × `AdsStampHeader { uint64 timeStamp (FILETIME); uint32 samples; }`, each followed by `samples` × `AdsNotificationSample { uint32 notificationHandle; uint32 sampleSize; byte[sampleSize] data; }`. Naive parsers assume one sample per notification, or a fixed offset to the data, and misread everything once cyclic notifications batch multiple samples/stamps into one frame.

**Why it happens:**
On-change notifications for a single variable often arrive as exactly one stamp with one sample, so a flat parser passes early tests. Batching (multiple variables, or cyclic delivery, or the server coalescing) only appears later. The `timeStamp` is a Windows **FILETIME** (100 ns ticks since 1601-01-01 UTC), not a Unix epoch — treating it as epoch milliseconds yields dates in the year ~1601 or wildly wrong.

**How to avoid:**
Parse the full nested loop: outer count of stamps, inner count of samples per stamp, and advance the cursor by `sampleSize` for each sample's data. Convert FILETIME to `DateTime` explicitly (subtract the 1601→1970 epoch offset, divide 100 ns ticks). Route each sample to its subscriber by `notificationHandle`. Test with a frame containing multiple stamps AND multiple samples per stamp.

**Warning signs:**
Only the first variable in a batched notification updates; timestamps in 1601 or absurd values; `RangeError` when a second sample is present; data offset drifts after the first sample.

**Phase to address:** Notifications (Phase 6).

---

### Pitfall 7: Symbol handle lifecycle — stale handles after PLC program reload

**What goes wrong:**
Symbol-by-name access is a two-step dance: `ReadWrite` with index group `ADSIGRP_SYM_HNDBYNAME (0xF003)` to get a handle, then `Read`/`Write` on index group `ADSIGRP_SYM_VALBYHND (0xF005)` with the handle as the offset, and finally `Write` to `ADSIGRP_SYM_RELEASEHND (0xF006)` to release. Two failures: (1) never releasing handles → same resource leak as notifications; (2) **caching handles across a PLC program download/activate** — after a TwinCAT reload, all handles are invalidated and previously-valid handles now point at garbage or return errors, so a cached handle silently reads the wrong memory or fails.

**Why it happens:**
Resolving a handle per read is "slow", so developers cache them. That's correct within a session but catastrophic across a PLC reconfiguration, which happens routinely during commissioning. There's no push notification that handles were invalidated — the PLC just changes underneath you.

**How to avoid:**
Treat handles as session-scoped and cheap to re-resolve. Release handles you own (on cancel/close). Detect PLC state changes: a `ReadState` returning `Reset`/`Config`/`Stop→Run` transition, or an ADS error like symbol-not-found (0x710 / 1808) / invalid-handle on a previously-valid handle, should invalidate the whole handle cache and force re-resolution. Never persist handles across reconnects.

**Warning signs:**
Reads return stale/constant values after a PLC download; errors 1808 (symbol not found) or 1809 (invalid index group) appear after re-activation; values correct at startup then wrong after commissioning changes.

**Phase to address:** Symbols/Handles (Phase 7).

---

### Pitfall 8: Missing ADS route on the target — the "works then times out" trap (error 1861 / 0x745)

**What goes wrong:**
A direct AMS/TCP connection is not enough. TwinCAT targets reject/ignore AMS packets from a source AmsNetId they don't have a **route** for. Symptom is ADS error **1861 (0x745)** "timeout elapsed" — the TCP connect succeeds, but ADS requests time out because the target won't route replies back to an unknown AmsNetId. This is the single most common real-world ADS connectivity failure, and it looks like a bug in your library when it's actually target configuration.

**Why it happens:**
The library authors test against a mock server (which happily replies to anyone) or a PLC where a route was already configured manually, so the missing-route case never surfaces in dev. Also, the **source AmsNetId** must match what the route on the target expects; a mismatched or auto-generated source NetId is treated as unrouted. Firewalls blocking 48898/UDP route-registration add another layer.

**How to avoid:**
Document clearly that direct connections require a static route on the target (or programmatic route registration). Implement the AMS route-registration handshake (the UDP/port-0xBF discovery + AddRoute with credentials) if router-less operation is a goal, and surface a specific, actionable error for 1861 ("no ADS route on target for source AmsNetId X — add a route or check firewall") rather than a bare timeout. Make the source AmsNetId explicitly configurable, not derived silently from the local IP.

**Warning signs:**
TCP connects fine but every ADS command times out with 1861/0x745; works on one machine (route exists) but not a fresh one; works to the mock server but not a real PLC; adding a manual route in TwinCAT "fixes" it.

**Phase to address:** Routing/AmsRouter (Phase 5); error mapping in Async Correlation/Core Commands.

---

### Pitfall 9: Sum-command partial failure — one bad sub-request, aggregate "success"

**What goes wrong:**
Sum (ADS-Sum) commands batch N reads/writes into one `ReadWrite` on index group `ADSIGRP_SUMUP_READ (0xF080)` / `SUMUP_WRITE (0xF081)` / `SUMUP_READWRITE (0xF082)`. The **outer** ADS command can return error 0 (success) while **individual** sub-commands failed. The response layout is: an array of per-sub-command uint32 error codes first, then the concatenated data. Naive code checks only the outer error, returns "success", and hands back garbage data for the sub-requests that actually failed.

**Why it happens:**
The outer/inner error distinction is non-obvious and under-documented; the happy path (all succeed) makes the per-item error array look like it can be skipped. Variable-length sub-results also make it tempting to assume fixed slicing.

**How to avoid:**
Always parse the per-sub-command error array first, then map each sub-result's data using its declared length, associating each with its original request and its individual error code. Surface partial failures per-item (e.g., a result list where each entry has its own success/error), never collapse to a single boolean. Test a sum command where item 2 of 3 deliberately fails (bad handle/index).

**Warning signs:**
Batched reads occasionally return one bad value amid good ones with no error raised; data misalignment after the first failed item; results "shift" when one symbol is invalid.

**Phase to address:** Sum Commands (Phase 8), building on Symbols/Handles (Phase 7).

---

### Pitfall 10: Half-open connections and reconnect state not being reset

**What goes wrong:**
TCP connections to PLCs go half-open silently (cable pull, PLC reboot, switch failure): `Socket` gives no immediate error, writes appear to succeed, but no response ever arrives. Without application-level liveness detection, the library hangs indefinitely. On reconnect, developers forget to reset per-connection state — pending Completers, notification handles, symbol handles, invokeId counter, reassembly buffer — leading to responses correlated against the wrong (dead) requests or replayed stale handles against a fresh session.

**Why it happens:**
`dart:io` `Socket.done`/`onError` only fire on clean FIN/RST, not on a dead peer that never responds. TCP keepalive defaults are minutes-to-hours. State cleanup is easy to overlook because the happy path never reconnects.

**How to avoid:**
Implement per-request timeouts (already needed for Pitfall 4) as the primary liveness signal, plus an optional application-level heartbeat (periodic `ReadState`) to detect half-open links proactively. On any disconnect: error all pending Completers, clear the reassembly buffer, invalidate all notification and symbol handles, and only then reconnect. Make reconnect a full state reset, not a socket swap. Consider enabling TCP keepalive via `Socket` options as defense-in-depth.

**Warning signs:**
App hangs after PLC reboot until restarted; first request after reconnect returns data meant for a pre-disconnect request; notification streams go silent but never error; handles from before the reconnect "work" then return garbage.

**Phase to address:** TCP Transport / Connection lifecycle (Phase 2), reinforced in Async Correlation (Phase 3).

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Parse each socket chunk as a full frame (skip reassembly buffer) | Fast to write; passes localhost tests | Breaks on any real network segmentation / large payloads; hard-to-repro corruption | **Never** — reassembly is mandatory for a stream socket |
| Resolve symbol handle per read, never cache | Simple; avoids stale-handle bugs | Extra round-trip per read; poor throughput for HMI polling | MVP only; add session-scoped caching with invalidation later |
| Assume one sample per notification | Simple flat parser | Silent data loss once notifications batch; timestamp bugs | Never — batching is normal for cyclic/multi-var |
| Hard-code source AmsNetId from local IP | No config needed | Breaks routing on multi-homed hosts, NAT, and when target route expects a specific NetId | Never for a library; always make it configurable |
| Skip DeleteDeviceNotification on cancel ("PLC will clean up") | Less lifecycle code | Handle-pool exhaustion on PLC affecting all clients; needs power-cycle | Never |
| Check only outer ADS error on sum commands | Less parsing | Silent wrong data on partial failure | Never |
| Complete Completers without `isCompleted` guard | Terser code | `StateError` crashes on late/duplicate responses after timeout | Never |
| Treat FILETIME as Unix epoch | Skip conversion math | Every notification timestamp wrong | Never |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| TwinCAT target (real PLC) | Assuming TCP connect == ready to talk | Requires a static/programmatic ADS route for the source AmsNetId; handle 1861 explicitly |
| AMS ports | Using AmsNetId port interchangeably with TCP port 48898 | TCP port (48898) addresses the router/host; AMS **port** (e.g. 851 for TC3 PLC runtime, 852+, 10000 system service) addresses the device *inside* — both are needed |
| Local TwinCAT router vs direct | Assuming one transport works everywhere | Router mode connects to `127.0.0.1:48898` and lets TwinCAT route; direct mode embeds the AmsRouter and needs target-side routes. Must be runtime-selectable |
| Notification (cmd 8) frames | Matching them against the invokeId request map | They are unsolicited (invokeId 0); dispatch by notificationHandle to Streams |
| String data in symbols | Treating PLC strings as UTF-8 / null-terminated Dart strings | TwinCAT `STRING` is fixed-length, single-byte (Windows-1252/ASCII), null-padded; `WSTRING` is UTF-16LE. Decode by declared byte length, strip at first null, choose codec by type |
| ReadState / WriteControl | Ignoring ADS state vs device state distinction | Response has both `adsState` (Run/Config/Stop/Reset...) and `deviceState`; WriteControl must echo/set the right pair or the PLC ignores/faults |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| High-rate notifications overwhelming a Dart Stream | Rising memory, event-loop lag, GC pauses | Use bounded/backpressure-aware handling; do NOT use an unbounded broadcast buffer; coalesce or sample on the consumer side; consider `StreamController` with explicit pause via subscription | Cyclic notifications at <10 ms cycle time, or many variables |
| No sum commands — one round-trip per variable | HMI feels sluggish; PLC ADS load high | Batch reads/writes via SUMUP_* once >~5 symbols per cycle | Polling dashboards with dozens of tags |
| Re-resolving handles every cycle | Latency dominated by handle round-trips | Cache session-scoped handles with invalidation (Pitfall 7) | >10 symbols polled continuously |
| Reassembly buffer via repeated `List` concatenation | O(n²) copying under load | Use `BytesBuilder` / a ring or offset-tracked buffer, avoid rebuilding the whole buffer per chunk | Large symbol uploads, notification bursts |
| Broadcast StreamController for per-handle notifications with no consumer | Work done for samples nobody reads | Add/Delete notifications lazily on listen/cancel | Idle subscriptions left open |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Logging PLC route credentials (AddRoute username/password) | Credential leak in logs/CI artifacts | Never log route auth; redact; keep out of error messages |
| Assuming ADS is authenticated/encrypted | ADS is plaintext, minimal auth — full read/write control of industrial process | Document that ADS must run on a trusted/isolated network (VLAN/VPN); do not expose 48898 to untrusted networks |
| Blindly trusting frame `length`/`dataLength` fields | Malformed/hostile frame triggers huge allocation or OOB read (DoS) | Bound-check `length` against a sane max before allocating; validate `dataLength` against actual bytes present |
| Exposing WriteControl / write-by-name in the CLI without guardrails | Accidental writes to a live process (safety) | Require explicit confirmation flags for writes/control; dry-run default for `push`/`action` |

## UX Pitfalls (library + CLI ergonomics)

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Surfacing raw ADS error numbers only | User sees "error 1861" with no idea it's a routing issue | Map ADS error codes to messages + remediation (esp. 1861 route, 1808 symbol-not-found, 6 port-not-found, 1793 service-not-supported) |
| Bare timeout with no context on missing route | User blames the library | Timeout error should hint "check ADS route / source AmsNetId / firewall 48898" |
| Notification Stream that never errors on disconnect | Consumer waits forever for updates that stopped | Close/error the Stream on disconnect so consumers can react |
| CLI `read`/`write` requiring index-group/offset only | Operators think in symbol names | Support both symbol-name and IG/offset addressing per PROJECT scope |

## "Looks Done But Isn't" Checklist

- [ ] **Framing:** Byte-for-byte round-trip verified against a *real captured* frame (or C++ mock output), not just self-consistency — verify AMS/TCP length excludes the 6-byte wrapper.
- [ ] **TCP reassembly:** Tested with deliberately split AND coalesced frames — verify against a mock that fragments payloads.
- [ ] **Notifications:** Tested with multiple stamps and multiple samples per stamp in one frame — verify all samples dispatched, FILETIME converted correctly.
- [ ] **Notification cleanup:** DeleteDeviceNotification verified to fire on Stream cancel AND on disconnect — verify PLC-side handle count returns to baseline.
- [ ] **Handles:** Symbol handle invalidation after PLC reload tested — verify re-resolution, not stale reads.
- [ ] **Sum commands:** Partial-failure case tested (item N fails) — verify per-item error surfaced and data alignment correct.
- [ ] **Timeouts:** Pending Completers verified to error-and-remove on timeout AND on disconnect — verify no hung Futures, no map leak.
- [ ] **Reconnect:** Full state reset verified — verify no cross-session response correlation, no stale handles.
- [ ] **Routing:** Behavior against a real PLC *without* a pre-existing route tested — verify 1861 surfaced with actionable message.
- [ ] **Strings:** STRING (single-byte, null-padded) vs WSTRING (UTF-16LE) both decoded by declared length.
- [ ] **pub.dev:** `platforms:` declared (no web) so consumers aren't surprised at resolve time.

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Endianness/offset bug in codec | LOW | Add golden byte-vector tests; fix centralized read/write helper; re-run round-trip suite |
| No reassembly buffer (chunk == frame) | MEDIUM | Insert buffering layer between socket and codec; add fragmenting mock tests |
| Notification handle leak in production | MEDIUM (needs PLC restart to clear now) | Add onCancel/disconnect deletes; power-cycle PLC to reclaim leaked handles; audit all Add/Delete pairs |
| Flat notification parser | MEDIUM | Rewrite as nested stamp/sample loop; add multi-sample fixture |
| Leaked Completers / hung Futures | LOW–MEDIUM | Add timeout wrapper + isCompleted guards + disconnect flush |
| Cached stale handles across PLC reload | LOW | Add state-change/error-driven cache invalidation; make handles session-scoped |
| Missing-route (1861) discovered late | LOW (config) / MEDIUM (if route-registration must be implemented) | Document route requirement; add error mapping; optionally implement AddRoute handshake |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Two-header confusion (AMS/TCP vs AMS) | Framing/Codecs (P1) | Round-trip test vs captured/mock frame |
| Endianness / packing | Framing/Codecs (P1) | Golden byte-vector tests, CI grep for endian-less ByteData calls |
| TCP stream reassembly | TCP Transport (P2) | Fragmenting + coalescing mock server tests |
| invokeId correlation / Completer leaks | Async Correlation (P3) | Timeout + duplicate-response + disconnect tests; leak assertion on map size |
| Half-open / reconnect state reset | TCP Transport (P2) + Async (P3) | Simulated PLC reboot; assert full state reset |
| Notification handle leaks | Notifications (P6) + Connection lifecycle (P2) | Assert PLC handle count returns to baseline after cancel/close |
| Nested notification buffer parsing | Notifications (P6) | Multi-stamp/multi-sample fixture; FILETIME conversion test |
| Symbol handle staleness | Symbols/Handles (P7) | Simulated PLC reload → cache invalidation test |
| Missing route / error 1861 | Routing/AmsRouter (P5) | Test against PLC without route; assert actionable error |
| Sum-command partial failure | Sum Commands (P8) | Deliberate mid-batch failure fixture |
| Mock server determinism / port races | Mock/Integration (P9) | Ephemeral ports, readiness handshake, no fixed-port assumptions |
| pub.dev platform declaration | Publishing (P11) | `dart pub publish --dry-run`; verify `platforms:` excludes web |

## Additional phase-specific warnings

**Mock server / integration testing (Phase 9):**
- **Port races in CI:** Binding a hard-coded port causes flaky "address in use" failures when tests run in parallel or a prior run lingers. Use an OS-assigned ephemeral port (bind :0) and pass the actual port to the Dart client; add a readiness handshake (wait until the server accepts) rather than a fixed `sleep`.
- **Cross-platform CMake build:** The C++ AdsLib + mock must build on Linux CI, macOS (dev), and possibly Windows. Beckhoff/ADS uses POSIX vs WinSock differences; pin a known-good commit of the vendored AdsLib, and gate integration tests behind a "C++ toolchain available" check so `dart test` still runs unit tests where CMake isn't present.
- **Mock faithfulness drift:** A hand-rolled mock that's *too* lenient (replies to any NetId, never fragments, always succeeds) hides Pitfalls 3, 8, 9. Deliberately make the mock exercise fragmentation, missing-route rejection, batched notifications, and sum partial-failure — otherwise integration tests give false confidence. Reusing AdsLib's own framing code for the mock (per PROJECT decision) maximizes faithfulness; keep the reused portion as large as possible.
- **CI without a real PLC:** No TwinCAT in CI means real-PLC-only behaviors (route auth, actual timing, real symbol tables) are untested. Keep a manual/optional test suite tagged for local runs against real hardware; don't let the mock lull you into assuming real-PLC parity.

**pub.dev publishing (Phase 11):**
- Declare supported platforms explicitly in `pubspec.yaml` (`platforms:` with linux/macos/windows/android/ios, **omitting web**). Without this, pub.dev may infer web support and Flutter web users get a broken package at runtime (`dart:io` unavailable) instead of a resolve-time signal. A `dart:io` import already excludes web, but be explicit so the pub.dev scorecard and the platform badges are correct.
- Ship the library and CLI such that the C++/CMake test harness is NOT a consumer dependency — keep it in `test/` or a separate dir excluded from the published package, or the analyzer/scoring penalizes the package and consumers pull unnecessary files.
- Run `dart pub publish --dry-run` early to catch missing `platforms:`, oversized package (don't ship vendored AdsLib source in the published tarball via a `.pubignore`), and example/doc gaps that hurt the pub.dev score.

## Sources

- Beckhoff/ADS C++ reference implementation (constants verified: `AMS_TCP_HEADER_LENGTH=6`, `AMS_HEADER_LENGTH=32`, `AmsNetId=6`, command IDs 0–9): https://github.com/Beckhoff/ADS
- Beckhoff/ADS AdsNotification.h (AdsNotificationHeader hNotification/cbSampleSize/nTimeStamp fields): https://github.com/Beckhoff/ADS/blob/master/AdsLib/AdsNotification.h
- Beckhoff InfoSys — AMS/TCP Header & AMS Header specification: https://infosys.beckhoff.com/content/1033/tcadscommon/12440282379.html
- Beckhoff InfoSys — ADS Device Notification (nested stream layout, AdsStampHeader/AdsNotificationSample): https://infosys.beckhoff.com/content/1033/tcadscommon/12440299147.html
- Beckhoff/ADS Issue #68 "Create handle failed with 0x745 (1861)" and Issue #14 — route/timeout semantics: https://github.com/Beckhoff/ADS/issues/68
- Beckhoff InfoSys — Create/delete ADS routes; route = AmsNetId↔IP mapping: https://infosys.beckhoff.com/content/1033/twincat_bsd/12459254539.html
- jisotalo/ads-server & ads-client (independent TS implementations confirming header offsets, state flags, command IDs, error codes): https://github.com/jisotalo/ads-server / https://github.com/jisotalo/ads-client
- FlowFuse — "How to Connect to Beckhoff TwinCAT PLC Using ADS" (routing layer is the usual failure): https://flowfuse.com/blog/2026/03/how-to-connect-to-twincat-using-ads/
- soup01.com — ADS Error 1861 (0x745) causes/solutions: http://soup01.com/en/2021/12/14/beckhoffads-error-18610x745-solution/
- Dart `dart:io` Socket/RawSocket stream semantics (byte-stream, not message-framed) — dart.dev API docs and known behavior (HIGH confidence from ecosystem experience)

---
*Pitfalls research for: pure-Dart Beckhoff ADS/AMS client library*
*Researched: 2026-07-03*
