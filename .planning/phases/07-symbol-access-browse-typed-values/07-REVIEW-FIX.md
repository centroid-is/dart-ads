---
phase: 07-symbol-access-browse-typed-values
fixed_at: 2026-07-04T18:30:00Z
review_path: .planning/phases/07-symbol-access-browse-typed-values/07-REVIEW.md
iteration: 1
findings_in_scope: 4
fixed: 4
skipped: 0
status: all_fixed
---

# Phase 7: Code Review Fix Report

**Fixed at:** 2026-07-04T18:30:00Z
**Source review:** 07-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 4 (CR-01, WR-01, WR-02, WR-03 — Info findings excluded per fix scope)
- Fixed: 4
- Skipped: 0

## Fixed Issues

### CR-01: Typed reads decode device-controlled buffers without length validation

**Files modified:** `lib/src/client/ads_client.dart`, `test/unit/client/symbols_client_test.dart`
**Commit:** a8de742
**Applied fix:** Added a private `_readFixedByName(name, size, timeout)` helper
to `AdsClient` that validates the device-controlled reply length before any
fixed-size codec decode, throwing `MalformedFrameException` naming expected vs
actual bytes (mirrors the existing `getHandleByName` guard at the client
boundary — the variant that preserves the exception-family contract for wire
input). All nine typed reads (`readBoolByName`, `readByteByName`,
`readSintByName`, `readWordByName`, `readIntByName`, `readDwordByName`,
`readDintByName`, `readRealByName`, `readLrealByName`) now route through it.
STRING/WSTRING reads are unchanged — their decoders have no fixed width and
are short-buffer tolerant by construction. Regression tests (FakeTransport):
short 4-byte (DINT), short 8-byte (LREAL), and empty BOOL replies surface
`MalformedFrameException` (not `RangeError`) with the handle still released;
a short STRING reply decodes tolerantly.

### WR-01: `AdsHandle.close()` marks itself closed before the release succeeds

**Files modified:** `lib/src/client/ads_handle.dart`, `test/unit/client/symbols_client_test.dart`
**Commit:** c045a7a
**Applied fix:** `close()` now latches `_closed` only on a SUCCESSFUL release,
or on `0x710`/`0x711` staleness where the device handle is already gone and a
wire release is meaningless (close completes quietly and marks the handle
invalid). Any other release failure (timeout, connection loss, device error)
rethrows and leaves the handle closable, so a retry `close()` re-attempts the
release instead of silently leaking (T-7-01). A `_closing` guard keeps
concurrent `close()` calls single-flight. The already-invalidated path
(`!_valid` → mark closed, no wire release) is preserved. Regression tests:
failed release → rethrow → retry releases and latches; `0x710` during close →
quiet completion, retry writes nothing.

### WR-02: `releaseHandle` silently truncates the handle to u32

**Files modified:** `lib/src/client/ads_client.dart`, `test/unit/client/symbols_client_test.dart`
**Commit:** ebcd49c
**Applied fix:** Applied as suggested — the handle passes through
`checkUint(handle, 32, 'handle')` (from `protocol/range_check.dart`) before the
`setUint32` encode, making the three lifecycle methods consistent:
out-of-range handles now throw `ArgumentError` before any wire traffic instead
of releasing a different, possibly-live handle. Regression test asserts
`releaseHandle(0x1_0000_0001)` and `releaseHandle(-1)` throw with zero frames
written.

### WR-03: 0x4025 relocation incomplete at the fixture/tooling layer

**Files modified:** `test_harness/dump_golden.cpp`, `test_harness/mock_server.cpp`, `test/golden/read_req.hex`, `test/golden/write_req.hex`, `test/unit/golden_parity_test.dart`
**Commit:** 6e30da2
**Applied fix:** Relocated `dump_golden.cpp`'s scratch group constants from
`0xF005` to `0x4025` (Read req and Write req emitters plus their comments/
descriptions), rebuilt the harness, and regenerated the goldens: exactly
`read_req.hex` and `write_req.hex` changed, and only in the group field
(`05f00000` → `25400000` LE). Regeneration verified byte-stable (second run
produced no further diff). `golden_parity_test.dart` updated to `0x4025` in
the Read/Write parity tests and the WR-04 range-validation case. The mock's
stale seed comment now states the `{0x4025, 0x123}` key explicitly and
documents the relocation off 0xF005 (now SYM_VALBYHND). `sym_*` goldens were
deliberately left untouched — their 0xF003/0xF005 usage is correct symbol
semantics. `read_res`/`write_res`/`read_write_*`/`sum_*` goldens do not encode
the scratch group and were unaffected. `mock_server --selftest` → OK
(selftest uses ReadDeviceInfo, unaffected).

## Verification

- `dart analyze --fatal-infos` — No issues found.
- `dart format --set-exit-if-changed` on all touched Dart files — clean.
  (Nine files NOT touched by these fixes are format-dirty under the current
  SDK's formatter — pre-existing on the base commit, left alone to keep fix
  commits scoped.)
- `dart test -x slow` — 302/302 passed (unit + integration, including the new
  regression tests; up from 295 with the 7 added tests).
- CMake harness rebuild + `dump_golden` regeneration byte-stable
  (`git diff` after second run: no additional changes) + `mock_server
  --selftest` OK.
- protocol/ purity intact: no protocol/ source was modified (the CR-01 guard
  lives at the client boundary per the review's preferred variant); locked
  Phase-7 decisions untouched.

## Skipped Issues

None — all in-scope findings were fixed. Info findings IN-01..IN-06 were out
of scope (`fix_scope: critical_warning`) and remain open in 07-REVIEW.md.

---

_Fixed: 2026-07-04T18:30:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
