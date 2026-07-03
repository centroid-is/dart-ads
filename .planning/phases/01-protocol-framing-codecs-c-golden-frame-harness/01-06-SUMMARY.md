---
phase: 01-protocol-framing-codecs-c-golden-frame-harness
plan: 06
subsystem: protocol
tags: [framing, reassembly, security, tdd, dart]
requirements_completed: [PROTO-02, TEST-04]
dependency_graph:
  requires:
    - "01-01: test/support/hex.dart (readGolden)"
    - "01-02: test/golden/*.hex golden frames"
    - "01-04: AmsTcpHeader + MalformedFrameException"
  provides:
    - "FrameAssembler: pure synchronous stateful AMS/TCP frame reassembler with 4 MiB max-frame guard"
  affects:
    - "Phase 2 socket transport (feeds byte chunks into FrameAssembler.add)"
tech_stack:
  added: []
  patterns:
    - "Incremental length-prefixed framing with a pre-allocation DoS guard (RESEARCH Pattern 3 / Pitfalls 3-4)"
    - "Pure synchronous protocol core: zero dart:async / dart:io imports for socket-free unit testing"
key_files:
  created:
    - "lib/src/protocol/frame_assembler.dart"
    - "test/unit/frame_assembler_test.dart"
  modified: []
decisions:
  - "Emit frames as independent copies (sublist) so callers own them and they never alias future buffer state."
  - "Read the AMS/TCP length u32 directly from the buffer via ByteData and throw before slicing, guaranteeing the DoS guard runs before any frame-sized allocation."
metrics:
  duration: 6min
  completed: 2026-07-03
  tasks: 2
  files: 2
---

# Phase 01 Plan 06: FrameAssembler Reassembly Summary

Pure synchronous `FrameAssembler` that reassembles fragmented and coalesced AMS/TCP byte streams into complete frames and rejects frames over a configurable 4 MiB guard with a typed `MalformedFrameException` — proven against real golden bytes with no sockets.

## What Was Built

- **`FrameAssembler`** (`lib/src/protocol/frame_assembler.dart`): a stateful push API. `add(Uint8List chunk)` appends to an internal buffer, then loops emitting every complete frame (`6 + AMS/TCP length` bytes) now available, in wire order, retaining any trailing partial frame across calls. Reads the length u32 at offset 2 (little-endian) directly from the buffer; if `length > maxFrameBytes` (default `4 * 1024 * 1024`, configurable) it throws `MalformedFrameException` **before** allocating the frame buffer. Never indexes past buffered bytes, so truncated frames simply wait. Depends only on `dart:typed_data`, `AmsTcpHeader`, and `MalformedFrameException` — no async/socket libraries. Exposes `hasBufferedBytes` / `bufferedLength` for observability and testing.
- **`frame_assembler_test.dart`** (`test/unit/frame_assembler_test.dart`, tagged `unit`): 5 adversarial cases against real goldens (`read_device_info_req.hex` 38 B, `read_res.hex` 50 B):
  1. Fragmentation — golden fed 1 byte at a time; nothing emits until the last byte, then exactly one byte-equal frame.
  2. Coalescing — two goldens in one chunk emit two ordered complete frames.
  3. Mixed — `[full A][partial B]` emits A on call 1, completes B on call 2.
  4. Max-frame guard — a 6-byte wrapper with length `0x00500000` (5 MiB) throws `MalformedFrameException` (asserts the offending `length`) with no payload supplied, proving the guard fires on the length field alone.
  5. Truncated — a frame missing its last byte emits nothing and throws no `RangeError`, then recovers when the final byte arrives.

## Verification

- `dart test test/unit/frame_assembler_test.dart -x integration` → 5/5 pass.
- Full unit suite `dart test -x integration` → 38/38 pass (no regressions).
- `dart analyze --fatal-infos` on both files → no issues.
- Import-purity gate: zero `dart:async` / `dart:io` **import** statements in `lib/src/protocol/`.

## Threat Model Coverage

| Threat ID | Category | Mitigation | Test |
|-----------|----------|------------|------|
| T-1-01 | Denial of Service | Reject `length > 4 MiB` before allocation, throw `MalformedFrameException` | Max-frame guard test |
| T-1-02 | Tampering | Buffer to exact `6 + length`, emit each frame once | Fragmentation / coalesce / mixed tests |
| T-1-03 | Info Disclosure / DoS | Never index past buffered bytes; wait for full frame | Truncated test (no RangeError, no partial emit) |

## Deviations from Plan

### Verification-command imperfection (documented, not a code change)

The plan's literal purity gate `grep -REl 'dart:async|dart:io' lib/src/protocol/` returns files because it matches doc-comment **prose** (mentions of the words) in the pre-existing 01-04 files `ams_tcp_header.dart` and `exceptions.dart`, not actual imports. The real invariant — must_have truth "The protocol/ subtree imports zero dart:async and zero dart:io" — was verified with an import-scoped grep (`^\s*import ['\"]dart:(async|io)`), which returns nothing. Those two 01-04 files are out of scope for this plan and were left untouched. My new `frame_assembler.dart` was worded to avoid the literal tokens so it contributes no false positive. No functional code change resulted.

Otherwise: plan executed as written.

## Known Stubs

None.

## Self-Check: PASSED

- FOUND: lib/src/protocol/frame_assembler.dart
- FOUND: test/unit/frame_assembler_test.dart
- FOUND commit: 74997a5 (feat: FrameAssembler)
- FOUND commit: 0e677fb (test: adversarial reassembly)
