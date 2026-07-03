---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
reviewed: 2026-07-03T18:24:16Z
rereviewed: 2026-07-03T18:51:00Z
rereview_iteration: 2
depth: standard
files_reviewed: 18
files_reviewed_list:
  - .github/workflows/ci.yml
  - lib/dart_ads.dart
  - lib/src/protocol/ams_header.dart
  - lib/src/protocol/ams_net_id.dart
  - lib/src/protocol/ams_tcp_header.dart
  - lib/src/protocol/commands.dart
  - lib/src/protocol/constants.dart
  - lib/src/protocol/exceptions.dart
  - lib/src/protocol/frame_assembler.dart
  - lib/src/protocol/range_check.dart
  - test/support/hex.dart
  - test/unit/ams_header_test.dart
  - test/unit/frame_assembler_test.dart
  - test/unit/golden_parity_test.dart
  - test/unit/hex_support_test.dart
  - test/unit/public_api_test.dart
  - test_harness/CMakeLists.txt
  - test_harness/dump_golden.cpp
  - test_harness/mock_server.cpp
findings:
  critical: 1
  warning: 9
  info: 7
  total: 17
resolved:
  critical: 1
  warning: 9
  info: 0
  total: 10
fixed_at: 2026-07-03T20:30:00Z
fix_scope: critical_warning
status: clean
---

# Phase 1: Code Review Report

**Reviewed:** 2026-07-03T18:24:16Z (initial) / 2026-07-03T18:51:00Z (re-review, iteration 2)
**Depth:** standard
**Files Reviewed:** 18
**Status:** clean — all 9 original Critical + Warning findings verified fixed;
the 1 NEW Warning (WR-09) found in iteration 2 was fixed in iteration 3
(`1dd6f09`). The 7 Info findings remain open (accepted out of fix scope).

## Re-Review (iteration 2) — Fix Verification

Every fix from commits `7bc63a0..be76246` was verified against the current
source, not just for presence:

- **CR-01 — VERIFIED.** `signal(SIGPIPE, SIG_IGN)` present in `main()`
  (`mock_server.cpp:411`) before `runServer()`; `sendAll()` retries `EINTR`
  and treats `n <= 0` as a per-connection failure (`mock_server.cpp:228-242`);
  `<csignal>`/`<cerrno>` included. Verified live: a client that `destroy()`s
  its socket immediately after sending a request does not kill the server —
  a subsequent fresh connection is answered with the full 62-byte response.
- **WR-01 — VERIFIED.** Guard trip with frames already parsed returns those
  frames and retains the poison at buffer offset 0 (`frame_assembler.dart:
  119-122`); the deferred throw on the next `add()` clears the buffer first
  (`:123`) so repeated `add()` on a poisoned assembler cannot grow the buffer;
  exception `offset` is now a meaningful 0. Regression test covers the full
  sequence including post-throw recovery (`frame_assembler_test.dart:160-192`).
  Deferred-throw semantics traced for edge cases (poison-only chunk throws
  immediately; `add(Uint8List(0))` on a poisoned buffer throws; bytes after
  the poison are dropped by design and documented) — no new defect found.
- **WR-02 — VERIFIED.** Guard is now `length < AmsHeader.byteLength || length
  > maxFrameBytes` (`frame_assembler.dart:112`). Tests cover 0/10/31 rejection
  and the length==32 boundary acceptance (`frame_assembler_test.dart:130-158`).
- **WR-03 — VERIFIED.** `AmsHeader.decode` checks `offset < 0 || available <
  byteLength` and throws the typed exception (`ams_header.dart:101-109`);
  NetId reads go through `Uint8List.sublistView(view, ...)`, which is
  range-checked against the view (`:112-118`); the remaining scalar reads
  cannot overrun once the 32-byte precondition holds. Regression test with a
  clamped 16-byte view over a 64-byte buffer passes.
- **WR-04 — VERIFIED (with one new finding, WR-09 below).** `checkUint` is
  applied at every integer encode site: all 7 `AmsHeader.encode` fields, the
  AMS/TCP `length`, `AmsAddr.port`, and all 12 integer fields across the six
  command encoders (grep-confirmed, no site missed). `AmsAddr` is no longer
  `const`; no `const AmsAddr` call sites remain. Range-validation tests pass
  on the VM. However, the helper's `(1 << bits) - 1` is broken under dart2js —
  see WR-09.
- **WR-05 — VERIFIED.** `kMaxFrameBytes` = 4 MiB (`mock_server.cpp:83`);
  violation sets `dropConnection`, exits both loops, and closes only that
  connection (`:353-357, 385-387`); `frameLen` uses an explicit
  `static_cast<size_t>` and the cap removes the 32-bit wrap path. Verified
  live: a 6-byte wrapper declaring 5 MiB gets the connection closed by the
  server, which keeps accepting.
- **WR-06 — VERIFIED.** Accept loop swaps addressing (`mock_server.cpp:
  371-373`: response target = request source, source = request target);
  `--selftest` builds with `(kSource, kSourcePort, kTarget, kTargetPort)`
  (`:197-198`); `dump_golden.cpp` `wrap()` swaps for `isResponse` (`:76-80`).
  The committed `read_device_info_res.hex` bytes were verified by hand:
  target `c0a800640101`/port `0x9c41` (client), source `c0a800010101`/port
  `0x0353` (PLC), stateFlags `0x0005`; request goldens retain original
  addressing. `golden_parity_test.dart:50-55` asserts the inversion for all
  six response goldens. Verified live: the mock's on-socket response is
  byte-identical to the regenerated golden. `--selftest` prints OK;
  `dump_golden && git diff --exit-code test/golden` is clean (goldens
  reproducible from current source).
- **WR-07 — VERIFIED.** `writeHex` checks the stream after `flush()` and
  returns false with a stderr report (`dump_golden.cpp:126-130`; an
  open-failure also lands in the same failbit check); `main` accumulates
  `ok &=` across all 12 fixtures and returns `ok ? 0 : 1` (`:276`). Verified
  empirically: unwritable output dir produces 12 stderr lines and exit 1.
- **WR-08 — VERIFIED.** `readGolden` throws `FormatException` on an odd
  nibble count (`test/support/hex.dart:35-38`), matching the C++ twin.
  Regression test present in `hex_support_test.dart`.

Full unit suite: 50/50 passing. `dart analyze lib test`: no issues.

One new Warning was introduced by the WR-04 fix (below). No other new
Critical/Warning issues were found in the fix-touched code.

## Critical Issues

### CR-01: mock_server dies from SIGPIPE when a client disconnects mid-response

**Resolution:** fixed: `7bc63a0` — `signal(SIGPIPE, SIG_IGN)` in `main()` (portable Linux + macOS) and EINTR retry loop in `sendAll()`. **Re-verified 2026-07-03 (iteration 2), including a live abrupt-disconnect smoke test.**

**File:** `test_harness/mock_server.cpp:216-223` (also 271, 311)
**Issue:** The delivered accept loop's send path has an unhandled fatal error
path. `sendAll()` calls `send(fd, ..., 0)` with no `MSG_NOSIGNAL`, and the
process never sets `SIG_IGN` for `SIGPIPE`. On both Linux and macOS, writing
to a socket whose peer has closed raises `SIGPIPE`, whose default disposition
terminates the process — `sendAll`'s `n <= 0` error check never executes. Any
client that closes early (test teardown, a crashed Dart test, a timeout kill)
takes down the whole mock server, including its listening socket, so every
subsequent test against that server hangs or fails with connection-refused.
`--fragment 1` mode widens the window to one `send()` per byte. The header
comment defers "hostile-input hardening" to Phase 2, but this is not hostile
input — it is the normal disconnect path of the loop delivered in this phase.
Secondary defect in the same function: `send()` interrupted by a signal
returns `-1`/`EINTR`, which `sendAll` treats as a fatal error instead of
retrying.
**Fix:**
```cpp
// In main(), before runServer():
#include <csignal>
signal(SIGPIPE, SIG_IGN);   // portable across Linux + macOS

// And in sendAll(), retry EINTR:
static bool sendAll(int fd, const uint8_t* data, size_t size)
{
    size_t sent = 0;
    while (sent < size) {
        const ssize_t n = send(fd, data + sent, size - sent, 0);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            return false;   // now actually reachable on EPIPE
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}
```
(On Linux alone, `send(..., MSG_NOSIGNAL)` would suffice, but the harness
explicitly targets macOS too, which lacks `MSG_NOSIGNAL` — use
`signal(SIGPIPE, SIG_IGN)`.)

## Warnings

### WR-01: FrameAssembler discards already-completed frames when the max-frame guard throws

**Resolution:** fixed: `8a5ae89` — frames completed before the poison are returned; the guard exception is deferred to the next `add()` (thrown at buffer offset 0) and the poisoned remainder is dropped, so the buffer cannot grow without bound. Regression test added (`frame_assembler_test.dart`). **Re-verified 2026-07-03 (iteration 2); deferred-throw edge cases traced clean.**

**File:** `lib/src/protocol/frame_assembler.dart:71-118`
**Issue:** `add()` collects completed frames into the local `frames` list and
only compacts `_buffer` after the loop. If chunk `[good frame A][poison
wrapper with length > 4 MiB]` arrives in one call — entirely realistic under
TCP coalescing — the guard throws at line 91 *after* frame A was parsed:
frame A is never returned (the local list is lost), and the compaction at
line 113 never runs, so `_buffer` still contains A plus the poison bytes.
Every subsequent `add()` re-scans from offset 0 and re-throws before ever
returning A, so a valid, fully-received frame is silently and permanently
lost. Compounding this, each subsequent `add()` still concatenates the new
chunk into `_buffer` (line 72) before throwing, so a caller that keeps feeding
a poisoned assembler grows the buffer without bound. Finally, the exception's
`offset` field reports an offset into the private internal buffer, which is
meaningless to the caller. None of this is covered by the current tests —
the guard test feeds the poison wrapper as the only content.
**Fix:** Commit consumed state before throwing, so completed frames survive
and the poison is deterministic:
```dart
if (length > maxFrameBytes) {
  // Persist frames consumed so far; drop the poisoned remainder so the
  // assembler does not re-scan (and re-grow) it on every subsequent add.
  _buffer = Uint8List(0);
  throw MalformedFrameException(...);
}
```
…and either return the completed frames via an out-parameter/callback or
document explicitly that a `MalformedFrameException` invalidates the
assembler and any frames buffered before the poison frame. At minimum, stop
appending new chunks to a buffer that can never drain.

### WR-02: FrameAssembler emits structurally impossible frames (length < 32) that crash downstream decoders with RangeError

**Resolution:** fixed: `4dec428` — guard now rejects `length < AmsHeader.byteLength || length > maxFrameBytes` with the typed exception. Regression test covers lengths 0/10/31 and the 32-byte boundary. **Re-verified 2026-07-03 (iteration 2).**

**File:** `lib/src/protocol/frame_assembler.dart:90` (guard), `lib/src/protocol/ams_header.dart:92-106` (downstream victim)
**Issue:** The guard rejects only `length > maxFrameBytes`. A hostile or
corrupt wrapper declaring `length` in `0..31` is accepted and emitted as a
"complete frame" of 6–37 bytes — but every AMS/TCP frame must carry a 32-byte
AMS header, so such a frame is malformed by definition. The Phase-2 consumer
will call `AmsHeader.decode` on it and get an unchecked `RangeError` (or, per
WR-03, silently wrong bytes) instead of the typed `MalformedFrameException`
the exception taxonomy promises for "these bytes are not a valid frame".
Hostile-input handling of the length field is asymmetric: too-big is a typed
error, too-small is a latent crash.
**Fix:** Add a minimum bound next to the existing guard:
```dart
if (length < AmsHeader.byteLength || length > maxFrameBytes) {
  throw MalformedFrameException(
    'AMS/TCP frame length $length outside valid range '
    '[${AmsHeader.byteLength}, $maxFrameBytes]',
    length: length, offset: offset,
  );
}
```
(Requires importing `ams_header.dart`, or a local `const _minFrameLength = 32`.)

### WR-03: AmsHeader.decode escapes the bounds of the ByteData view it is given

**Resolution:** fixed: `eecf2c3` — typed `MalformedFrameException` precondition on available view bytes; NetId reads now go through `Uint8List.sublistView` (range-checked against the view, not the backing buffer). Regression test uses a 16-byte clamped view over a 64-byte buffer. **Re-verified 2026-07-03 (iteration 2), including the negative-offset path.**

**File:** `lib/src/protocol/ams_header.dart:93-98`
**Issue:** `decode` reads the two NetIds via
`bd.buffer.asUint8List(bd.offsetInBytes + offset, 6)` — that is, it goes
around the `ByteData` view and reads from the *underlying buffer*. If a
caller passes a view that is shorter than `offset + 32` but whose backing
buffer has more bytes after it (e.g. a clamped view over a larger receive
buffer), the NetId reads silently return bytes *outside the view* — adjacent,
unrelated buffer contents — with no exception. Verified empirically: a 4-byte
`ByteData.sublistView` happily yields 6 bytes via this pattern. So violating
the documented "caller must guarantee 32 bytes" precondition produces either
an untyped `RangeError` (from the scalar `getUint16`/`getUint32` calls) or,
worse, a structurally valid header populated with garbage — the failure mode
depends on which field overruns first. For a decoder that will sit on the
untrusted-wire path in Phase 2, the precondition should be checked, and the
reads should stay inside the view.
**Fix:** Validate once, and slice through the view rather than the buffer:
```dart
factory AmsHeader.decode(ByteData bd, [int offset = 0]) {
  if (bd.lengthInBytes - offset < byteLength) {
    throw MalformedFrameException(
      'AmsHeader requires $byteLength bytes, '
      'got ${bd.lengthInBytes - offset}',
      length: bd.lengthInBytes - offset, offset: offset);
  }
  final view = Uint8List.sublistView(bd, offset, offset + byteLength);
  return AmsHeader(
    targetNetId: AmsNetId(Uint8List.sublistView(view, 0, 6)),
    ...
```
(`Uint8List.sublistView(bd, ...)` is range-checked against the view, unlike
`bd.buffer.asUint8List`.)

### WR-04: Encoders silently truncate out-of-range field values onto the wire

**Resolution:** fixed: `dcf6655` — shared internal `checkUint` helper (`lib/src/protocol/range_check.dart`, not exported); applied in `AmsAddr` (port, constructor is no longer `const`), `AmsHeader.encode` (all seven integer fields), `AmsTcpHeader.encode` (length), and all integer parameters of the six command encoders. Throws `ArgumentError`. Regression tests in `ams_header_test.dart` + `golden_parity_test.dart`. **Re-verified 2026-07-03 (iteration 2): all encode sites covered, VM behavior correct — but the helper itself has a dart2js-only defect, see WR-09.**

**File:** `lib/src/protocol/ams_header.dart:76-83`; `lib/src/protocol/ams_tcp_header.dart:36`; `lib/src/protocol/ams_net_id.dart:95-101`; `lib/src/protocol/commands.dart:165-276`
**Issue:** Dart's `ByteData.setUint16`/`setUint32` do not range-check — they
store the low bits. Verified empirically: `setUint16(0, 70000)` writes
`0x1170` (port 4464), `setUint16(0, -1)` writes `0xFFFF`, and
`setUint32(0, 0x1FFFFFFFF)` writes `0xFFFFFFFF`. Nothing in the encode path
validates: `AmsAddr` documents "port (0..65535)" but its `const` constructor
accepts anything; `AmsHeader.encode` truncates ports, commandId, stateFlags,
dataLength, invokeId; `encodeReadRequest(length: ...)`,
`encodeReadWriteRequest(readLength: ...)`, and the AMS/TCP `length` field are
likewise truncated. A caller bug (negative port, 33-bit invokeId counter
wrap, oversized read length) therefore produces a *well-formed but wrong*
frame that a PLC will act on, instead of an immediate error at the API
boundary. For a codec whose whole contract is byte-exactness, silent
corruption is the worst failure mode.
**Fix:** Add a shared range check used by the value types and encoders, e.g.:
```dart
int _checkUint(int value, int bits, String field) {
  if (value < 0 || value > (1 << bits) - 1) {
    throw ArgumentError.value(value, field, 'must fit in u$bits');
  }
  return value;
}
```
Apply in `AmsAddr` (port), `AmsHeader.encode` (or its constructor), 
`AmsTcpHeader` (length), and the six encoders (invokeId, length/readLength).

### WR-05: mock_server has no inbound max-frame guard — unbounded buffering from a single hostile length field (and a 32-bit size_t overread)

**Resolution:** fixed: `d1e4cf6` — `kMaxFrameBytes = 4 MiB` inbound cap mirroring the Dart guard; violation drops the connection; `frameLen` computed with explicit `static_cast<size_t>` (cap also removes the 32-bit wrap path). **Re-verified 2026-07-03 (iteration 2), including a live hostile-length smoke test.**

**File:** `test_harness/mock_server.cpp:332-335`
**Issue:** The server-side reassembly trusts the wire length completely:
`frameLen = sizeof(AmsTcpHeader) + tcp.length()` with `tcp.length()` up to
`0xFFFFFFFF`, and the loop keeps `inbuf.insert(...)`-ing until `inbuf.size()
>= frameLen`. One 6-byte wrapper declaring a 4 GiB frame makes the process
buffer everything the peer sends, indefinitely — precisely the DoS pattern
the Dart FrameAssembler's 4 MiB guard exists to prevent (the mock enforces
nothing). Additionally, on a 32-bit `size_t` build, `6 + 0xFFFFFFFF` wraps to
`5`, so `inbuf.size() < frameLen` passes with only 6 buffered bytes, and
`tcp.length() >= sizeof(AoEHeader)` (true: `0xFFFFFFFF >= 32`) then lets
`AoEHeader aoe(inbuf.data() + 6)` `memcpy` 32 bytes from a 6-byte buffer — a
heap overread. CI runners are 64-bit so the overread is latent, but the
unbounded buffering is live on every platform. A test-infra process on
loopback is a soft target, but the Dart integration client connecting to it
in Phase 2 shares the machine with it in CI.
**Fix:** Mirror the Dart guard and drop the connection on violation:
```cpp
static const uint32_t kMaxFrameBytes = 4 * 1024 * 1024;
const AmsTcpHeader tcp(inbuf.data());
if (tcp.length() > kMaxFrameBytes) {
    goto drop_connection; // or: break out of both loops and close(fd)
}
const size_t frameLen = sizeof(AmsTcpHeader) + static_cast<size_t>(tcp.length());
```
The cap also eliminates the 32-bit overflow path.

### WR-06: mock_server responses echo request addressing instead of swapping target/source

**Resolution:** fixed: `12483bf` — addressing swapped in the mock's accept loop, in `--selftest`, and in `dump_golden`'s `wrap()` for response frames; all six `*_res.hex` goldens regenerated (request goldens byte-identical); `golden_parity_test.dart` now asserts response target == request source and response source == request target. **Re-verified 2026-07-03 (iteration 2): golden bytes checked by hand, selftest OK, goldens reproducible, live socket response byte-identical to golden.**

**File:** `test_harness/mock_server.cpp:341-345` (and the same convention in `test_harness/dump_golden.cpp:69-74`)
**Issue:** For `READ_DEVICE_INFO` the server responds with
`buildReadDeviceInfoRes(aoe.targetAddr(), aoe.targetPort(), aoe.sourceAddr(),
aoe.sourcePort(), aoe.invokeId())` — i.e. the response's AMS `target` is the
*server's own* address and its `source` is the *client*. A real ADS response
inverts the request's addressing: target = original source (the client),
source = original target (the PLC). As emitted, the response frame claims to
be addressed *to the PLC, from the client* — backwards. Nothing in Phase 1
notices because the golden-parity tests only decode response *payloads* and
the goldens were generated with the same unswapped convention (goldens are
committed data, out of this review's scope, but they encode the same
mistake). The moment the Phase-2 client validates that an inbound response's
`targetNetId`/`targetPort` match its own source address — which upstream
`AmsConnection` does when dispatching by port — every mock response will be
rejected, and the failure will look like a client bug.
**Fix:**
```cpp
// Response: swap request addressing (to: requester, from: us).
const std::vector<uint8_t> res = buildReadDeviceInfoRes(
    aoe.sourceAddr(), aoe.sourcePort(),   // response target = request source
    aoe.targetAddr(), aoe.targetPort(),   // response source = request target
    aoe.invokeId());
```
Regenerate the goldens with the same swap in `dump_golden.cpp`'s `wrap()`
call sites (response frames only) so `--selftest` stays consistent, and adjust
the two frame-length-only assertions if needed (lengths are unchanged).

### WR-07: dump_golden ignores all I/O errors and always exits 0 — the CI "goldens are reproducible" gate can false-pass

**Resolution:** fixed: `f5384d7` — `writeHex` checks the stream after flush and reports failures on stderr; `main` accumulates per-file results (`ok &=`) and exits 1 on any failure. Verified empirically: unwritable dir → 12 stderr lines + exit 1. (IN-04's untracked-file gap remains open.) **Re-verified 2026-07-03 (iteration 2), failure path re-tested empirically.**

**File:** `test_harness/dump_golden.cpp:93-112, 253`; `.github/workflows/ci.yml:101-104`
**Issue:** `writeHex` never checks the `ofstream`: if the output path cannot
be opened (missing directory, permissions, disk full) the write silently does
nothing, and `main` unconditionally `return 0`. The CI step
`./test_harness/build/dump_golden test/golden/ && git diff --exit-code
test/golden` therefore passes when the dumper wrote *nothing at all* — the
committed files are untouched, the diff is clean, and CI certifies "goldens
are reproducible from source" without a single byte having been reproduced.
The one gate this phase exists to establish can be defeated by any silent
write failure.
**Fix:**
```cpp
static bool writeHex(...)
{
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    ...
    out << h << "\n";
    if (!out) {
        fprintf(stderr, "dump_golden: failed to write %s\n", path.c_str());
        return false;
    }
    return true;
}
```
Accumulate failures in `main` and `return` non-zero if any write failed.
(See also IN-04: the `git diff` check additionally misses newly *untracked*
golden files.)

### WR-08: Dart hex fixture reader silently truncates odd-length input, diverging from its C++ twin

**Resolution:** fixed: `be76246` — `readGolden` throws `FormatException` on an odd nibble count, matching `readGoldenHex`. Regression test added (`hex_support_test.dart`). **Re-verified 2026-07-03 (iteration 2).**

**File:** `test/support/hex.dart:29-33`
**Issue:** After stripping comments/whitespace, `Uint8List(cleaned.length ~/
2)` silently drops a trailing odd nibble. The C++ counterpart
(`mock_server.cpp:156-158 readGoldenHex`) explicitly *rejects* odd-length
input as corrupt. This is test-support code, but it directly affects test
reliability: a golden fixture corrupted by a truncated write (see WR-07) or a
bad merge decodes to a shorter-but-plausible byte string, and the resulting
parity failure points at the codec rather than the fixture — or, for a
length-only assertion, may not fail at all. The two parsers of the same
fixture format should agree that malformed input is an error.
**Fix:**
```dart
if (cleaned.length.isOdd) {
  throw FormatException(
      'odd number of hex nibbles (${cleaned.length}) in $path');
}
```

### WR-09: checkUint computes `(1 << 32) - 1 == -1` under dart2js, breaking every u32 encoder field on the web platform (NEW, iteration 2)

**Status:** RESOLVED — introduced by the WR-04 fix (`dcf6655`).
**Resolution:** fixed: `1dd6f09` — mask built from two sub-31-bit shifts (`((1 << (bits - 1)) - 1) * 2 + 1`), verified u16=65535 / u32=4294967295 on VM; 50/50 tests green. (iteration 3)

**File:** `lib/src/protocol/range_check.dart:18`
**Issue:** `final max = (1 << bits) - 1;` relies on 64-bit integer shift
semantics. On the Dart VM (and dart2wasm) `1 << 32` is `4294967296`, so
`max = 0xFFFFFFFF` — correct. Under **dart2js**, integers are JS doubles and
dart2js's `<<` returns `0` for shift counts above 31, so `(1 << 32) - 1`
evaluates to `-1`. Verified empirically: `dart compile js` on a program
printing `(1 << 32) - 1` emits `-1` where the VM prints `4294967295`. With
`max = -1`, the guard `value < 0 || value > max` is true for **every**
non-negative value, so on the web every u32 `checkUint` call site —
`AmsHeader.encode` (dataLength, errorCode, invokeId), `AmsTcpHeader.encode`
(length), and all six command encoders (indexGroup, indexOffset, length,
readLength, data lengths) — throws
`ArgumentError: must fit in u32 (0..-1)` for any input, including 0. All
encoding is therefore completely non-functional when the codec is compiled
with dart2js. The 16-bit path (`1 << 16`) is unaffected.

Severity rationale: the package's transport layer targets `dart:io`, and CI
runs VM-only, so no *current* build reaches this — which is why it is a
Warning rather than a Critical. But the `lib/src/protocol/` subtree is
explicitly documented as pure/platform-independent (every library header
advertises it), dart2js remains an official compile target for that layer
(e.g. decoding recorded frames in a web tool), and the failure is total, so
it must not ship in code whose purity is the advertised contract. The defect
mirrors the exact suggested-fix snippet from the original WR-04 finding, so
the original review shares the blame — but it is a defect nonetheless.
**Fix:** Compute the mask without a 32-position shift, e.g.:
```dart
int checkUint(int value, int bits, String name) {
  // ((1 << (bits - 1)) - 1) * 2 + 1 == 2^bits - 1 without shifting by 32,
  // which dart2js evaluates as 0 (JS shift semantics).
  final max = ((1 << (bits - 1)) - 1) * 2 + 1;
  if (value < 0 || value > max) {
    throw ArgumentError.value(value, name, 'must fit in u$bits (0..$max)');
  }
  return value;
}
```
(or branch on `bits == 32` returning the literal `0xFFFFFFFF`). Add a
regression note/test asserting `checkUint(0xFFFFFFFF, 32, 'x')` passes and
`checkUint(0x100000000, 32, 'x')` throws — both already hold on the VM; the
comment should record the dart2js rationale so the shift is not
"simplified" back.

## Info

### IN-01: AmsNetId.parse accepts non-decimal octet spellings, contradicting its documented contract

**File:** `lib/src/protocol/ams_net_id.dart:58`
**Issue:** The doc says "exactly six dot-separated *decimal* octets", but
`int.tryParse` accepts hex (`'0x10'` → 16), an explicit sign (`'+5'` → 5),
and surrounding whitespace (`' 5 '` → 5) — all verified. So
`AmsNetId.parse('192.168.0.0x64.1.1')` succeeds. `'-0'` also passes the
`>= 0` check.
**Fix:** Parse with `int.tryParse(parts[i], radix: 10)` and reject when
`parts[i] != value.toString()` (or match `RegExp(r'^\d{1,3}$')` first).

### IN-02: Redundant double copy in _decodeResultAndData with a misleading comment

**File:** `lib/src/protocol/commands.dart:400-402`
**Issue:** `Uint8List.fromList(payload.sublist(8, 8 + readLength))` copies
twice: `sublist` already returns a fresh, non-aliasing `Uint8List` (verified —
mutating the sublist does not affect the source). The comment "Defensive copy
so the returned data does not alias the source buffer" implies the outer
`fromList` is doing the de-aliasing; it is doing nothing.
**Fix:** `final data = payload.sublist(8, 8 + readLength);` and keep the
comment on that line.

### IN-03: maxFrameBytes validated only by assert — a no-op in release mode

**File:** `lib/src/protocol/frame_assembler.dart:44-45`
**Issue:** `assert(maxFrameBytes > 0, ...)` vanishes outside debug/checked
mode, so `FrameAssembler(maxFrameBytes: 0)` (or negative) constructs fine in
production and then rejects *every* frame with a confusing guard exception.
**Fix:** Promote to a real check:
`if (maxFrameBytes <= 0) throw ArgumentError.value(maxFrameBytes, 'maxFrameBytes', 'must be positive');`
(constructor body instead of initializer-list assert).

### IN-04: Goldens-reproducible CI step misses newly created untracked files

**File:** `.github/workflows/ci.yml:101-104`
**Issue:** `git diff --exit-code test/golden` only detects changes to
*tracked* files. If `dump_golden` gains a new frame emitter but the new
`.hex` is never committed, the step still passes — the "committed goldens
match the source" invariant is only half-enforced.
**Fix:** Add an untracked-file check:
```yaml
run: |
  ./test_harness/build/dump_golden test/golden/
  git diff --exit-code test/golden
  test -z "$(git status --porcelain test/golden)"
```

### IN-05: mock_server exits 0 on accept() failure and never validates --port / --fragment values

**File:** `test_harness/mock_server.cpp:307-308, 366, 391, 397`
**Issue:** (a) A fatal `accept` error breaks the loop and falls through to
`return 0` — the harness reports success after dying. (b) `--port` uses
`std::atoi` with no range check: `--port 99999` or `--port -5` silently wraps
through `static_cast<uint16_t>`, binding an unexpected port; non-numeric input
becomes 0 (ephemeral) without complaint. Same `atoi` pattern for
`--fragment`.
**Fix:** Track a failure flag (`return everythingOk ? 0 : 1;`) and parse with
`strtol` + explicit `0..65535` validation, rejecting on error.

### IN-06: CMakeLists resolves the vendored tree via CMAKE_SOURCE_DIR, breaking embedding

**File:** `test_harness/CMakeLists.txt:19`
**Issue:** `set(ADS "${CMAKE_SOURCE_DIR}/../third_party/ADS/AdsLib")` is only
correct when `test_harness/` is the top-level source dir (`cmake -S
test_harness`). If this project is ever pulled in via `add_subdirectory` (or
built from a superproject), `CMAKE_SOURCE_DIR` points at the *parent*
project's root and the path silently resolves elsewhere or fails.
**Fix:** Use `${CMAKE_CURRENT_SOURCE_DIR}/../third_party/ADS/AdsLib` (or
`CMAKE_CURRENT_LIST_DIR`).

### IN-07: Coalesce mode withholds a response until a second frame or connection close — strict request/response clients hang

**File:** `test_harness/mock_server.cpp:244-253, 357-361`
**Issue:** In `--coalesce` mode, the first response is buffered and flushed
only when a second response arrives (`>= frame.size() * 2`) or when the peer
closes. ADS is request/response: a client that sends one request and awaits
the reply before sending the next will deadlock against this mode until its
own timeout. The Phase-2 test client must therefore *pipeline* two requests
up front for this mode to function — a hard, currently-undocumented usage
requirement (the in-code comment describes the heuristic, not the pipelining
obligation). The size heuristic also assumes equal-sized frames, which stops
holding as soon as the command table grows.
**Fix:** Document the pipelining requirement where Phase 2 will find it (e.g.
in the mode's `--help`/header comment), and consider flushing on a frame
*count* (`if (++coalesced == 2)`) rather than a size heuristic.

---

_Reviewed: 2026-07-03T18:24:16Z_
_Re-reviewed: 2026-07-03T18:51:00Z (iteration 2)_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
