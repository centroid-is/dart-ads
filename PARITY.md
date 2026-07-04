# C++ AdsLib Test Parity (TEST-05)

The final audit for TEST-05: every scenario in the reference Beckhoff C++ test
suites — `third_party/ADS/AdsLibTest/main.cpp` and
`third_party/ADS/AdsLibOOITest/main.cpp` — maps to a named Dart test (its
`group(...)` is named EXACTLY after the C++ `void test...` function so this audit
is mechanical), or carries an explicit N/A / covered-by-equivalent rationale.

No unexplained gaps.

## AdsLibTest/main.cpp

| C++ scenario | Dart counterpart | Notes |
|--------------|------------------|-------|
| `testAmsAddrCompare` | `test/unit/protocol/ams_net_id_compare_test.dart` → group `testAmsAddrCompare` | AmsAddr ordering (NetId bytes then port); same-named group. |
| `testAmsRouterAddRoute` | `test/unit/router/ams_router_test.dart` → group `testAmsRouterAddRoute` | add / different-host / re-add / used-host / idempotent. |
| `testAmsRouterDelRoute` | `test/unit/router/ams_router_test.dart` → group `testAmsRouterDelRoute` | remove leaves others intact; closes the live dialed connection. |
| `testAmsRouterSetLocalAddress` | `test/unit/router/ams_router_test.dart` → group `testAmsRouterSetLocalAddress` | default empty; set overwrites; get reflects. |
| `testConcurrentRoutes` | **N/A** | Commented out / disabled upstream (not compiled into the C++ suite); no behaviour to port. |
| `testComparsion` | **Covered-by-equivalent** — `test/unit/protocol/ams_net_id_compare_test.dart` (groups `testAmsAddrCompare` + `AmsNetId.fromIpv4`) | C++ `IpV4` is an internal helper class; the equivalent Dart behaviour is `AmsNetId` `compareTo` ordering + big-endian IPv4 derivation. |
| `testBytesFree` | **Covered-by-equivalent** — `test/unit/frame_assembler_test.dart` → group `FrameAssembler adversarial reassembly` | C++ `RingBuffer.BytesFree()` is an internal buffer primitive; the Dart port uses a streaming `FrameAssembler` whose capacity/coalescing behaviour is exercised by the adversarial-reassembly tests. |
| `testWriteChunk` | **Covered-by-equivalent** — `test/unit/frame_assembler_test.dart` → group `FrameAssembler adversarial reassembly` | Same internal `RingBuffer` primitive; chunked-write/coalesce behaviour is the `FrameAssembler`'s 1-byte-chunk and split-frame tests. |
| `testAdsPortOpenEx` | `test/unit/router/ams_router_test.dart` → group `testAdsPortOpenEx` | opens 128 ports in `[30000, 30128)`, exhausts to 0, closes, double-close/out-of-range → `0x0748`. |
| `testAdsReadReqEx2` | `test/integration/ads_parity_test.dart` → group `testAdsReadReqEx2` | write-then-read loop + invalid-group `SRVNOTSUPP`. |
| `testAdsReadReqEx2LargeBuffer` | `test/integration/ads_parity_test.dart` → group `testAdsReadReqEx2LargeBuffer` | 8192-byte round-trip. |
| `testAdsReadDeviceInfoReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsReadDeviceInfoReqEx` | identity triple over a loop. |
| `testAdsReadStateReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsReadStateReqEx` | run state, device state 0. |
| `testAdsReadWriteReqEx2` | `test/integration/ads_parity_test.dart` → group `testAdsReadWriteReqEx2` | combined write+read loop with a flipping value. |
| `testAdsWriteReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsWriteReqEx` | write then read-back loop with a flipping value. |
| `testAdsWriteControlReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsWriteControlReqEx` | STOP/RUN control observed via ReadState. |
| `testAdsNotification` | `test/integration/ads_notification_test.dart` → group `testAdsNotification` | subscribe → receive → cancel(Delete) → no further delivery. |
| `testAdsTimeout` | `test/integration/ads_parity_test.dart` → group `testAdsTimeout` | unanswered request times out as `AdsTimeoutException` (C++ get/set-timeout config adapted to a real per-request timeout). |
| `testLargeFrames` | `test/integration/ads_parity_test.dart` → group `testLargeFrames` | 64 KiB payload round-trips with integrity. |
| `testManyNotifications` | `test/integration/notification_parity_test.dart` → group `testManyNotifications` | 64+ concurrent subscriptions all receive; handle count returns to 0. |
| `testParallelReadAndWrite` | `test/integration/ads_parity_test.dart` → group `testParallelReadAndWrite` | many concurrent operations each resolve correctly. |
| `testEndurance` | `test/integration/notification_parity_test.dart` → group `testEndurance` | Ported, tagged `slow` (skipped by default; run with `--run-skipped -t slow`). |

## AdsLibOOITest/main.cpp

The OOI suite re-runs the same scenarios through the object-oriented
`AdsDevice`/`AdsVariable` facade rather than the free-function API. Wire behaviour
is identical, so each maps to the **same** Dart test as its `AdsLibTest`
namesake — the Dart client is a single idiomatic API, so there is no separate
"OOI" surface to test twice.

| C++ scenario (OOI) | Dart counterpart | Notes |
|--------------------|------------------|-------|
| `testAdsPortOpenEx` | `test/unit/router/ams_router_test.dart` → group `testAdsPortOpenEx` | Same port-allocator behaviour; OOI is just a facade. |
| `testAdsReadReqEx2` | `test/integration/ads_parity_test.dart` → group `testAdsReadReqEx2` | Same Read scenario, OOI-style. |
| `testAdsReadReqEx2LargeBuffer` | `test/integration/ads_parity_test.dart` → group `testAdsReadReqEx2LargeBuffer` | Same large-buffer Read. |
| `testAdsReadDeviceInfoReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsReadDeviceInfoReqEx` | Same ReadDeviceInfo. |
| `testAdsReadStateReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsReadStateReqEx` | Same ReadState. |
| `testAdsReadWriteReqEx2` | `test/integration/ads_parity_test.dart` → group `testAdsReadWriteReqEx2` | Same ReadWrite. |
| `testAdsWriteReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsWriteReqEx` | Same Write. |
| `testAdsWriteControlReqEx` | `test/integration/ads_parity_test.dart` → group `testAdsWriteControlReqEx` | Same WriteControl. |
| `testAdsNotification` | `test/integration/ads_notification_test.dart` → group `testAdsNotification` | Same Notification. |
| `testAdsTimeout` | `test/integration/ads_parity_test.dart` → group `testAdsTimeout` | Same Timeout. |
| `testLargeFrames` | `test/integration/ads_parity_test.dart` → group `testLargeFrames` | Same Large frames. |
| `testManyNotifications` | `test/integration/notification_parity_test.dart` → group `testManyNotifications` | Same many-notifications stress. |
| `testParallelReadAndWrite` | `test/integration/ads_parity_test.dart` → group `testParallelReadAndWrite` | Same parallel read/write. |
| `testEndurance` | `test/integration/notification_parity_test.dart` → group `testEndurance` | Same endurance soak, tagged `slow`. |

## Summary

- **Ported 1:1** (same-named Dart group): 17 scenarios (AmsAddr compare; router
  add/del route + set local address; port open/close; Read + large buffer;
  ReadDeviceInfo; ReadState; ReadWrite; Write; WriteControl; Notification;
  Timeout; Large frames; many-notifications; parallel read/write; endurance).
- **Covered-by-equivalent** (C++ internal primitives, no public analogue):
  `testComparsion` (IpV4 helper → `AmsNetId` ordering/derivation),
  `testBytesFree` + `testWriteChunk` (RingBuffer → `FrameAssembler`
  adversarial-reassembly tests).
- **N/A**: `testConcurrentRoutes` — disabled upstream, nothing to port.
- **OOI suite**: every scenario is the free-function scenario re-run through the
  C++ OO facade; the single idiomatic Dart API covers both with the same tests.

No unexplained gaps remain — TEST-05 is satisfied.
