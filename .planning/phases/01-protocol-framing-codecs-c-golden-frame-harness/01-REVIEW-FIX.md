---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
fixed_at: 2026-07-03T20:45:00Z
review_path: .planning/phases/01-protocol-framing-codecs-c-golden-frame-harness/01-REVIEW.md
iteration: 1
findings_in_scope: 9
fixed: 9
skipped: 0
status: all_fixed
---

# Phase 1: Code Review Fix Report

**Fixed at:** 2026-07-03T20:45:00Z
**Source review:** .planning/phases/01-protocol-framing-codecs-c-golden-frame-harness/01-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 9 (1 Critical + 8 Warning; Info findings IN-01..IN-07 excluded by fix scope)
- Fixed: 9
- Skipped: 0

## Fixed Issues

### CR-01: mock_server dies from SIGPIPE when a client disconnects mid-response

**Files modified:** `test_harness/mock_server.cpp`
**Commit:** 7bc63a0
**Applied fix:** `signal(SIGPIPE, SIG_IGN)` in `main()` (portable across Linux
and macOS, which lacks `MSG_NOSIGNAL`) so `send()` to a closed peer fails with
EPIPE instead of terminating the process; `sendAll()` now retries on
`-1`/`EINTR` and treats EPIPE as a per-connection failure. Empirically
verified live: 10 abortive RST closes during `--fragment 1` byte-by-byte
sends — server survives and remains byte-exact for subsequent clients.

### WR-01: FrameAssembler discards already-completed frames when the max-frame guard throws

**Files modified:** `lib/src/protocol/frame_assembler.dart`, `test/unit/frame_assembler_test.dart`
**Commit:** 8a5ae89
**Applied fix:** The guard now commits consumed state before failing. Frames
completed earlier in the same `add()` call are returned normally; the typed
exception is deferred to the next `add()` call, thrown deterministically at
buffer offset 0 with the poisoned remainder dropped — so repeated feeding of a
poisoned assembler can no longer grow the buffer without bound, and no valid
frame is ever silently lost. Semantics documented in the class and method
docs. Regression test covers the `[full frame][poison wrapper]` coalesced
chunk, the deferred throw, and post-throw buffer state.

### WR-02: FrameAssembler emits structurally impossible frames (length < 32)

**Files modified:** `lib/src/protocol/frame_assembler.dart`, `test/unit/frame_assembler_test.dart`
**Commit:** 4dec428
**Applied fix:** Guard extended to
`length < AmsHeader.byteLength || length > maxFrameBytes`, throwing
`MalformedFrameException` for both bounds (same poison-commit semantics as
WR-01). Regression test covers declared lengths 0, 10, and 31 plus the
32-byte boundary (a header-only frame still parses).

### WR-03: AmsHeader.decode escapes the bounds of the ByteData view it is given

**Files modified:** `lib/src/protocol/ams_header.dart`, `test/unit/ams_header_test.dart`
**Commit:** eecf2c3
**Applied fix:** `decode` now throws a typed `MalformedFrameException` when
fewer than 32 bytes are available from `offset` in the view, and the NetId
reads go through `Uint8List.sublistView` (range-checked against the view)
instead of `bd.buffer.asUint8List` (which resolves against the backing buffer
and can silently read adjacent bytes). Regression test uses a 16-byte clamped
view over a 64-byte backing buffer plus a non-zero-offset underrun.

### WR-04: Encoders silently truncate out-of-range field values onto the wire

**Files modified:** `lib/src/protocol/range_check.dart` (new, internal — not exported by the barrel), `lib/src/protocol/ams_net_id.dart`, `lib/src/protocol/ams_header.dart`, `lib/src/protocol/ams_tcp_header.dart`, `lib/src/protocol/commands.dart`, `test/unit/ams_header_test.dart`, `test/unit/golden_parity_test.dart`
**Commit:** dcf6655
**Applied fix:** Shared `checkUint(value, bits, name)` helper throwing
`ArgumentError`; applied in `AmsAddr` (port — its constructor is no longer
`const`, no call sites used const construction), all seven integer fields of
`AmsHeader.encode`, `AmsTcpHeader.encode` (length), and every integer
parameter of the six command encoders (indexGroup/indexOffset/length/
readLength/adsState/deviceState plus declared data lengths). Regression tests
assert port 70000, negative values, 33-bit invokeId wrap, and 17-bit adsState
all throw instead of truncating.

### WR-05: mock_server has no inbound max-frame guard (and a 32-bit size_t overread)

**Files modified:** `test_harness/mock_server.cpp`
**Commit:** d1e4cf6
**Applied fix:** `kMaxFrameBytes = 4 MiB` inbound cap mirroring the Dart
FrameAssembler guard; a violating length field drops the connection instead of
buffering. `frameLen` now uses explicit `static_cast<size_t>(tcp.length())`;
the cap also eliminates the 32-bit `6 + 0xFFFFFFFF` wrap/overread path.
Empirically verified live: a 0xFFFFFFFF wrapper is dropped and the server
keeps serving.

### WR-06: mock_server responses echo request addressing instead of swapping target/source

**Files modified:** `test_harness/mock_server.cpp`, `test_harness/dump_golden.cpp`, `test/golden/read_device_info_res.hex`, `test/golden/read_res.hex`, `test/golden/read_state_res.hex`, `test/golden/read_write_res.hex`, `test/golden/write_control_res.hex`, `test/golden/write_res.hex`, `test/unit/golden_parity_test.dart`
**Commit:** 12483bf
**Applied fix:** Response addressing now inverts the request's (target =
request source / client, source = request target / PLC) in the mock's accept
loop, in `--selftest`, and in `dump_golden`'s `wrap()` for response frames.
All six `*_res.hex` goldens regenerated — the diff is exactly the swapped
8-byte NetId+port pairs; request goldens byte-identical (verified via
`git diff --name-only`). `golden_parity_test.dart` now asserts the response
header's target/source addressing on every decoded golden response, and
`mock_server --selftest` passes against the regenerated golden. Live
round-trip against the running mock matches the regenerated golden
byte-for-byte.

### WR-07: dump_golden ignores all I/O errors and always exits 0

**Files modified:** `test_harness/dump_golden.cpp`
**Commit:** f5384d7
**Applied fix:** `writeHex` returns `bool`, checks the stream after flushing,
and reports each failed path on stderr; `main` accumulates results
(`ok &= writeHex(...)` at all 12 call sites — `&=` so a later success cannot
mask an earlier failure) and exits 1 on any failure. Empirically verified:
unwritable output dir produces 12 stderr diagnostics and exit code 1; the
normal path still exits 0 with byte-stable goldens.

### WR-08: Dart hex fixture reader silently truncates odd-length input

**Files modified:** `test/support/hex.dart`, `test/unit/hex_support_test.dart`
**Commit:** be76246
**Applied fix:** `readGolden` throws `FormatException('odd number of hex
nibbles (...) in <path>')` when the cleaned content has an odd nibble count,
matching the C++ `readGoldenHex` twin's rejection of corrupt fixtures.
Regression test added.

## Skipped Issues

None.

## Additional artifact commit

- 83e3cb3 `docs(01): mark CR-01 and WR-01..WR-08 resolved in review report` —
  01-REVIEW.md frontmatter updated (`resolved` counts,
  `status: critical_warning_resolved`) and a `**Resolution:** fixed: <commit>`
  note added under each of the nine findings.

## Verification (all green, run after the final fix)

- `dart analyze --fatal-infos` — no issues
- `dart format --output=none --set-exit-if-changed .` — 0 changed
- `dart test -x integration` — 50 tests passed (42 pre-existing + 8 new regression tests)
- Fresh `cmake -S test_harness -B test_harness/build && cmake --build` — clean
- `dump_golden test/golden/ && git diff --exit-code test/golden` — goldens reproduce byte-identically
- `mock_server --selftest` — OK against the regenerated golden
- Live smoke: response == golden over a socket; server survives abrupt/RST
  disconnects (incl. `--fragment 1`) and hostile 4 GiB length fields

---

_Fixed: 2026-07-03T20:45:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
