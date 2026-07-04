---
phase: 08-dart-cli
reviewed: 2026-07-04T00:00:00Z
depth: standard
files_reviewed: 6
files_reviewed_list:
  - lib/src/cli/connection.dart
  - lib/src/cli/base_command.dart
  - lib/src/cli/value_parsing.dart
  - lib/src/cli/commands/subscribe_command.dart
  - lib/src/cli/commands/pull_command.dart
  - lib/src/cli/commands/push_command.dart
findings:
  critical: 1
  warning: 7
  info: 5
  total: 13
status: clean
---

# Phase 8: Code Review Report

**Reviewed:** 2026-07-04
**Depth:** standard
**Files Reviewed:** 6 (plus context reads: bin/ads.dart, runner.dart, exit_codes.dart, browse/read/write/action commands, ads_client.dart subscribe/onCancel, sum_commands.dart, ams_router.dart close)
**Status:** issues_found

## Summary

The CLI backbone is well-structured: exit-code mapping is centralized in `guarded()`, session teardown runs in `finally` on every verb path, subscribe's teardown is idempotent with signals installed only after the subscription exists, and push validates the untrusted snapshot before dialing. Library seams checked: `sub.cancel()` is throw-safe (`_deleteQuietly` swallows), zero-size symbols round-trip losslessly (`checkUint` allows 0; `formatHex`→`"0x"`→`parseHex`→empty), and WSTRING is byte-lossless via hex.

However, the primary untrusted-input seam has a real hole: `parseHex` accepts signed byte tokens and silently writes wrong bytes to the PLC — a direct violation of the T-8-01 contract. Additional gaps: `unawaited(teardown())` can escape the exit-code contract entirely, a declared-but-never-read `--on-change` flag, file-I/O errors misrouted to exit 1, and the `_maxItems` cap bounding count but not bytes.

## Critical Issues

### CR-01: `parseHex` accepts signed byte tokens and silently writes wrong bytes to the PLC

**File:** `lib/src/cli/value_parsing.dart:44-48`
**Issue:** `int.tryParse(byteStr, radix: 16)` accepts a leading sign, so a 2-char token like `"-1"` or `"+f"` parses successfully (`-1`, `15`). The subsequent `out[i] = value` assignment to a `Uint8List` truncates mod 256, so `parseHex('-1-1')` yields `[0xff, 0xff]` with no error. This is reachable from `write --raw`, and — worse — from `push` snapshot `value` fields, which the module doc explicitly designates as hostile input (T-8-01/T-8-02). Malformed input that the contract says must raise `FormatException` (exit 2) instead silently produces different bytes and writes them into a PLC buffer.
**Fix:**
```dart
final value = int.tryParse(byteStr, radix: 16);
if (value == null || value < 0 || value > 0xff ||
    byteStr.codeUnits.any((u) =>
        !((u >= 0x30 && u <= 0x39) ||
          (u >= 0x41 && u <= 0x46) ||
          (u >= 0x61 && u <= 0x66)))) {
  throw FormatException('Invalid hex byte "$byteStr"', input, i * 2);
}
```
(Or simpler: validate the whole compact string against `RegExp(r'^[0-9a-fA-F]*$')` before the loop.)

## Warnings

### WR-01: `unawaited(teardown())` has no error handler — a teardown throw bypasses the exit-code contract

**File:** `lib/src/cli/commands/subscribe_command.dart:206-218`
**Issue:** `teardown()` is invoked via `unawaited(...)` from `onError`, `onDone`, and both signal handlers. `sub.cancel()` is proven throw-safe, but `session.close()` → `AmsRouter.close()` uses `Future.wait(owned.map((c) => c.close()))`, which propagates any error from a connection's `close()` (e.g., closing over an already-dead socket after the very connection drop that triggered `onError`). An exception inside an unawaited teardown is an unhandled asynchronous error: the isolate prints a stack trace and exits 255, defeating the 0/1/2/3 contract — precisely the "exception family that escapes to a stack trace" failure mode. Additionally, when teardown is triggered from a handler, the `finally`'s `await teardown()` returns immediately (`tornDown` is already true) without awaiting the in-flight teardown, so `guarded()` cannot catch a late throw either.
**Fix:** Make `teardown` swallow (or route to `done`) its own failures:
```dart
Future<void> teardown() async {
  if (tornDown) return;
  tornDown = true;
  try {
    for (final s in signals) { await s.cancel(); }
    await sub?.cancel();
    await session.close();
    ...
  } catch (_) {
    // Teardown must never surface an unhandled async error (exit contract).
  }
  if (!done.isCompleted) done.complete(exitOk);
}
```

### WR-02: `--on-change` flag is declared but never read; `--no-on-change` is silently ignored

**File:** `lib/src/cli/commands/subscribe_command.dart:55-58, 110-117`
**Issue:** `addFlag('on-change', defaultsTo: true)` is negatable by default, so the parser accepts `--no-on-change` — but `r['on-change']` is never consumed; mode selection depends solely on `--cycle`. An operator passing `--no-on-change` (expecting cyclic) or `--cycle 100 --on-change` (a contradiction) gets no error and silently different behavior. This is a dead option that misleads at exactly the flag-contract layer the phase claims to nail down.
**Fix:** Either read the flag and reject contradictory combinations (`--cycle` + explicit `--on-change`), or drop the flag and document on-change as the `--cycle`-absent default in the `--cycle` help text. At minimum add `negatable: false`.

### WR-03: File-I/O failures map to exit 1 (generic fault) instead of the usage family

**File:** `lib/src/cli/commands/push_command.dart:86`, `lib/src/cli/commands/pull_command.dart:135`, `lib/src/cli/base_command.dart:66-70`
**Issue:** `File(inPath).readAsStringSync()` on a missing/unreadable `--in` throws `PathNotFoundException`/`FileSystemException`, and `File(outPath).writeAsStringSync` on an unwritable `--out` likewise. Neither is caught by any specific `guarded()` clause, so both fall into the generic catch → exit 1 (`exitAdsError`) with a raw `error: FileSystemException: ...` dump. A bad file path is a bad flag value — the documented exit-2 family — and scripts branching on exit codes will misdiagnose it as a PLC/protocol error.
**Fix:** Add `on FileSystemException catch (e)` to `guarded()` mapping to `exitUsage` (or wrap the file read/write at the call sites and rethrow as `FormatException` with an operator-facing message).

### WR-04: `_maxItems` caps item count, not payload bytes — oversized single sumWrite still possible

**File:** `lib/src/cli/commands/push_command.dart:39, 168-171, 192-196`
**Issue:** The T-8-09 comment claims the cap prevents "an oversized single sumWrite round-trip", but only `rawSymbols.length` is bounded. Each item's `value` is bounded only by the declared `size` (`_requireInt` allows up to `0xFFFFFFFF` = 4 GiB) and by the file's own length. A hostile snapshot with one item declaring `size: 4294967295` and a multi-hundred-MB hex value passes validation and produces one enormous sumWrite frame (best case an opaque downstream `ArgumentError`; worst case a huge allocation + wire frame). Note also the cap runs *after* `jsonDecode` of the whole file, so it never bounds parse-time allocation as the doc implies.
**Fix:** Track a running total of decoded data bytes and reject the snapshot when it exceeds a sane ceiling (e.g., a few MB), and/or cap per-item `size` at a realistic symbol bound (e.g., 16 MiB).

### WR-05: push silently accepts an undersized `value` (partial write of a variable)

**File:** `lib/src/cli/commands/push_command.dart:193-196`
**Issue:** Only `data.length > size` is rejected. `pull` always emits exactly `size` bytes for a successful item, so `data.length < size` can only come from a hand-edited (untrusted) file — and it results in silently writing *fewer* bytes than the variable's width (e.g., 1 byte into a DINT mutates only the low byte). That is a silent partial write into a PLC buffer, the class of outcome the module doc says must never happen without an error.
**Fix:** Require `data.length == size` (round-trip losslessness makes this the natural invariant), or at minimum print a per-item warning naming the mismatch.

### WR-06: `_resolveOrRaise` exact-case matching vs case-insensitive TwinCAT names — misleading error and a leaked handle until session close

**File:** `lib/src/cli/commands/subscribe_command.dart:234-243` (mirrored in `read_command.dart:243-252`, `write_command.dart:194-203`)
**Issue:** TwinCAT symbol names are case-insensitive, but the table lookup is `s.name == name` (exact case). For `--name main.counter` against table entry `MAIN.counter`, the table match fails, then `getHandleByName(name)` *succeeds* on the device — hitting the "surprise success" line: the CLI reports `symbol "main.counter" not found` (exit 2) for a symbol the device just resolved, and the acquired handle is never released (only reclaimed when the connection closes). The guard comment assumes success is impossible; case-insensitivity makes it a routine path.
**Fix:** Compare case-insensitively (`s.name.toLowerCase() == name.toLowerCase()`), and on the surprise-success path release the handle before throwing.

### WR-07: `RangeError` is caught by the `ArgumentError` clause — protocol faults misreported as usage errors

**File:** `lib/src/cli/base_command.dart:63-65`; consumers at `lib/src/cli/commands/pull_command.dart:116-123`, `lib/src/cli/commands/push_command.dart:122-131`
**Issue:** In Dart, `RangeError extends ArgumentError`, so `guarded()`'s `on ArgumentError` clause maps every `RangeError` to exit 2 ("bad flags/values"). pull indexes `read[i]` and push indexes `report[i]` on the assumption the device returned exactly one result per request; a short/malformed sum response raises `RangeError` → the operator sees a usage-error exit for what is a device/protocol fault (should be exit 1). The doc for the usage family ("bad flags / bad values") does not cover indexing errors.
**Fix:** Either add explicit length checks in pull/push (`if (read.length != symbols.length) throw AdsProtocolException(...)`) or catch `on RangeError` before `on ArgumentError` in `guarded()` and map it to `exitAdsError`.

## Info

### IN-01: Router construction precedes the source-NetId guard block, contradicting the no-leak docstring

**File:** `lib/src/cli/connection.dart:83-99`
**Issue:** The docstring promises "On any failure between building the router and a successful connect, the router is closed before rethrowing", but the `AmsNetId.parse(sourceStr)` `FormatException` and the direct-mode `UsageException` (lines 87-99) throw after `AmsRouter(...)` is built and before the `try` that closes it. A pre-connect router holds no OS resources today, so impact is nil — but the stated invariant is not honored.
**Fix:** Move the router construction below the source-policy block, or widen the `try` to cover lines 87-99.

### IN-02: No range validation on `--port` / `--ams-port` / `--timeout`

**File:** `lib/src/cli/connection.dart:63-65, 130-137`
**Issue:** `_parseInt` accepts negatives and oversized values: `--timeout -5000` yields a negative `Duration` (timers clamp to zero → instant timeouts, confusing exit 3), `--port 70000` fails only downstream. Fix: bounds-check (`port`/`ams-port` in 1..65535, `timeout` > 0) in `_parseInt` callers.

### IN-03: Helper quadruplication across command files

**File:** `lib/src/cli/commands/subscribe_command.dart:234-260` (and read/write/browse/pull)
**Issue:** `_resolveOrRaise` (x3), `_parseAnyInt` (x3), `_normalizeType` (x2), `_globToRegExp` (x2) are copy-pasted. Any fix (e.g., WR-06) must now be applied in multiple places. Fix: hoist into a shared `lib/src/cli/helpers.dart`.

### IN-04: Untrusted strings printed to the terminal unsanitized

**File:** `lib/src/cli/commands/push_command.dart:95, 125-130` (also browse/pull symbol names and comments)
**Issue:** Snapshot `name` fields (hostile file) and PLC-supplied names/comments are printed verbatim; embedded control characters / ANSI escapes reach the operator's terminal. Fix: strip C0 control characters (except `\t`) before printing untrusted strings.

### IN-05: read's typed-decode fallback masks short reads

**File:** `lib/src/cli/commands/read_command.dart:181-187`
**Issue:** The `on FormatException` fallback is documented as "declared type is not codec-known", but `decodeTypedValue` also throws `FormatException` for a too-short buffer of a *known* type — that case silently degrades to hex output instead of reporting the short read. Fix: distinguish unknown-type (check `_fixedSizes`/type name before decoding) from short-buffer, and only fall back on the former.

---

_Reviewed: 2026-07-04_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_


## Resolutions (orchestrator-applied, iteration 2)

All 8 findings fixed in one commit (see `fix(08): CLI review fixes`):
- CR-01: parseHex strict `^[0-9a-fA-F]+$` guard + 3 regression tests
- WR-01: single-flight `teardownFuture ??= doTeardown()`; teardown never throws (per-step try/catch); finally awaits the in-flight future
- WR-02: --on-change/--no-on-change honored; contradictions and --no-on-change-without---cycle are UsageException
- WR-03: FileSystemException → exit 2 (usage family) in guarded()
- WR-04: `_maxTotalBytes` 4 MiB total-bytes cap in push snapshot validation
- WR-05: `data.length != size` rejected (no silent partial writes)
- WR-06: case-insensitive symbol resolve in all 3 copies; surprise-success handle released before throwing
- WR-07: RangeError caught before ArgumentError → exit 1; regression tests in test/cli/base_command_exit_codes_test.dart
- Verification: analyze --fatal-infos clean, format clean, full suite 372/372 green
- Info findings remain open by scope.
