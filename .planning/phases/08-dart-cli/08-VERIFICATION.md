---
phase: 08-dart-cli
verified: 2026-07-04T00:00:00Z
status: human_needed
score: 4/4 must-haves verified
overrides_applied: 0
human_verification:
  - test: "Push to GitHub and confirm CI jobs pass (analyze/format/unit + integration on Linux)"
    expected: "All GitHub Actions jobs green; dart analyze --fatal-infos, dart format, dart test -x slow, dart test -t integration all pass in CI"
    why_human: "Requires a live GitHub remote; cannot observe CI from the local filesystem"
  - test: "Connect the CLI to a real Beckhoff/TwinCAT PLC (if available) and exercise all 7 verbs"
    expected: "browse returns the actual symbol table; read/write round-trip succeeds; subscribe receives live notifications; pull/push losslessly round-trips; action changes device state"
    why_human: "No PLC available in this environment; CLI is mock-verified. Real-PLC behavior depends on network routing and PLC configuration"
---

# Phase 8: dart-cli Verification Report

**Phase Goal:** An operator can drive a PLC entirely from the terminal through all seven CLI verbs, exercising the full library end-to-end.
**Verified:** 2026-07-04
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | All 7 verbs (browse/read/write/subscribe/pull/push/action) work against the mock from the terminal | VERIFIED | All 7 command files fully implemented; 6 integration test suites pass 372/372 (-x slow); `dart run bin/ads.dart --help` lists all 7 verbs |
| 2 | Shared --target/--host/--port/--timeout flags; --json on read-oriented verbs; --raw where applicable; stable exit codes; human-readable ADS error names | VERIFIED | runner.dart declares all global flags; browse+read have --json; read+write have --raw; exit codes 0/1/2/3 in exit_codes.dart; adsErrorName() called in base_command.dart |
| 3 | subscribe streams timestamped notifications until interrupted, clean handle teardown on SIGINT; action changes state via --state | VERIFIED | subscribe_command.dart: ISO8601+hex streaming, single-flight idempotent teardown (CR-01/WR-01 fixes applied), teardown marker on stderr; action_command.dart: readState/writeControl/readState proven in cli_action_test.dart |
| 4 | pull snapshots to JSON via sum-read; push applies via sum-write with --dry-run and per-item pass/fail | VERIFIED | pull_command.dart calls session.client.sumRead(); push_command.dart calls session.client.sumWrite() with --dry-run no-op and per-item OK/FAIL report; lossless round-trip proven in cli_pull_push_test.dart |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `bin/ads.dart` | Thin entrypoint delegating to AdsCliRunner | VERIFIED | Delegates to AdsCliRunner().run(args), maps result to exitCode, catches UsageException → exit 2 |
| `lib/src/cli/runner.dart` | class AdsCliRunner with global flags + 7 commands | VERIFIED | class AdsCliRunner extends CommandRunner<int>; 7 global flags; 7 commands registered |
| `lib/src/cli/connection.dart` | connectFromGlobals + AdsSession | VERIFIED | connectFromGlobals() bootstraps AmsRouter, source NetId policy, dial, idempotent close() |
| `lib/src/cli/base_command.dart` | class BaseAdsCommand with guarded() exit-code mapping | VERIFIED | Maps transport→3, AdsException→1 (adsErrorName), Usage/Format/Argument→2, RangeError→1 (WR-07 fix), FileSystemException→2 (WR-03 fix) |
| `lib/src/cli/exit_codes.dart` | exitOk/exitAdsError/exitUsage/exitTransport constants | VERIFIED | 4 constants: exitOk=0, exitAdsError=1, exitUsage=2, exitTransport=3 |
| `lib/src/cli/value_parsing.dart` | parseHex, formatHex, encodeTypedValue, decodeTypedValue | VERIFIED | parseHex uses strict `^[0-9a-fA-F]+$` regex (CR-01 fix); 44 unit tests in value_parsing_test.dart |
| `lib/src/cli/commands/browse_command.dart` | browse verb over browseSymbols | VERIFIED | Aligned table + --filter glob + --json; calls browseSymbols() |
| `lib/src/cli/commands/read_command.dart` | read verb: by-name typed or group/offset raw | VERIFIED | class ReadCommand; by-name typed (decodeTypedValue), group/offset (formatHex), --raw, --json |
| `lib/src/cli/commands/write_command.dart` | write verb: by-name typed or group/offset raw | VERIFIED | By-name (encodeTypedValue), group/offset (parseHex); confirmation line; exit 2 on bad input |
| `lib/src/cli/commands/subscribe_command.dart` | subscribe verb with SIGINT teardown | VERIFIED | ProcessSignal.sigint; single-flight teardown (WR-01 fix); --on-change/--cycle/--max-delay |
| `lib/src/cli/commands/pull_command.dart` | pull verb: browse + sumRead → JSON snapshot | VERIFIED | sumRead() one-shot batch; dart-ads/pull/1 schema; --values, --out, --filter |
| `lib/src/cli/commands/push_command.dart` | push verb: JSON → sumWrite with --dry-run + per-item | VERIFIED | sumWrite() batch; _maxItems cap; _maxTotalBytes cap (WR-04 fix); data.length==size guard (WR-05 fix) |
| `lib/src/cli/commands/action_command.dart` | action verb over readState + writeControl | VERIFIED | writeControl via --state; case-insensitive AdsState match; readState before+after |
| `test/integration/cli_contract_test.dart` | Exit-code contract: usage→2, unreachable→3 | VERIFIED | 2 cases pass: unknown flag→2, refused port→3 |
| `test/integration/cli_browse_read_test.dart` | browse+read subprocess proof | VERIFIED | 5 cases: browse --json (4 symbols), --filter, read typed, read group/offset, unknown symbol→1 |
| `test/integration/cli_write_test.dart` | write subprocess proof | VERIFIED | 6 cases: typed write, untyped write, raw write, bad value→2, bad hex→2, no payload→2 |
| `test/integration/cli_subscribe_test.dart` | subscribe: stream, SIGINT, teardown marker | VERIFIED | Receives timestamped line; SIGINT → exit 0 + "notification handle released" marker |
| `test/integration/cli_pull_push_test.dart` | pull→push lossless round-trip + --dry-run + bad file | VERIFIED | 5 cases: snapshot shape, --dry-run no-op, lossless round-trip (all-pass), bad JSON→2, non-hex value→2 |
| `test/integration/cli_action_test.dart` | action: state-change proof | VERIFIED | 3 cases: --state CONFIG (run→config), --state RUN (→run), --state BOGUS→2 |
| `test/cli/value_parsing_test.dart` | Unit coverage incl. hostile-input cases | VERIFIED | 44 tests; all hostile cases assert FormatException |
| `test/cli/base_command_exit_codes_test.dart` | RangeError→1, ArgumentError→2, FileSystemException→2 | VERIFIED | 3 regression tests for WR-07 and WR-03 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `bin/ads.dart` | `lib/src/cli/runner.dart` | AdsCliRunner().run(args) | WIRED | bin/ads.dart line 21 |
| `lib/src/cli/base_command.dart` | `lib/src/cli/connection.dart` | connectFromGlobals(globalResults!) | WIRED | All 7 commands call connectFromGlobals; guarded() in base_command |
| `lib/src/cli/commands/read_command.dart` | `lib/src/cli/value_parsing.dart` | decodeTypedValue / formatHex | WIRED | read_command.dart imports value_parsing.dart; calls decodeTypedValue (line 173) and formatHex (line 134) |
| `lib/src/cli/commands/write_command.dart` | `lib/src/cli/value_parsing.dart` | encodeTypedValue / parseHex | WIRED | write_command.dart imports value_parsing.dart; encodeTypedValue (line 181), parseHex (lines 120, 142) |
| `lib/src/cli/commands/pull_command.dart` | `AdsClient.sumRead` | session.client.sumRead(items) | WIRED | pull_command.dart line 115 |
| `lib/src/cli/commands/push_command.dart` | `AdsClient.sumWrite` | session.client.sumWrite(requests) | WIRED | push_command.dart line 124 |
| `lib/src/cli/commands/subscribe_command.dart` | `ProcessSignal.sigint` | ProcessSignal.sigint.watch().listen() | WIRED | subscribe_command.dart line 245 |
| `lib/src/cli/commands/subscribe_command.dart` | `AdsClient.subscribe` | session.client.subscribe(...) | WIRED | subscribe_command.dart line 213 |
| `lib/src/cli/commands/action_command.dart` | `AdsClient.writeControl` | client.writeControl(adsState: target) | WIRED | action_command.dart line 67 |
| `lib/src/cli/commands/action_command.dart` | `AdsClient.readState` | client.readState() | WIRED | action_command.dart lines 66, 68 |
| `lib/src/cli/value_parsing.dart` | `lib/src/protocol/value_codec.dart` | encode/decode per type name | WIRED | value_parsing.dart imports value_codec.dart as codec; delegates all scalar conversion |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `browse_command.dart` | symbols (List<AdsSymbolInfo>) | AdsClient.browseSymbols() → live AMS request | Yes — browseSymbols issues real SYM_UPLOAD request; 4 symbols from mock table | FLOWING |
| `read_command.dart` | bytes (Uint8List) | AdsClient.readByName() / read() → live ADS Read request | Yes — issues ADS Read; guarded by decodeTypedValue length check | FLOWING |
| `write_command.dart` | data (Uint8List) | encodeTypedValue / parseHex from --value/--raw | Yes — encoded bytes from operator input, passed to writeByName/write | FLOWING |
| `subscribe_command.dart` | AdsNotification stream | AdsClient.subscribe() → AddDeviceNotification + 0x0008 frames | Yes — real notification frames from mock --notify-burst; formatHex(n.data) printed | FLOWING |
| `pull_command.dart` | read (List<SumResult<Uint8List>>) | AdsClient.sumRead(items) → live SUMUP_READ batch | Yes — one sumRead batch per symbol; each value formatHex'd into snapshot | FLOWING |
| `push_command.dart` | items (_PushItem list) | _parseSnapshot(File(inPath).readAsStringSync()) → parseHex per item | Yes — reads untrusted file, parseHex validated, passed to sumWrite | FLOWING |
| `action_command.dart` | before/after (AdsStateInfo) | AdsClient.readState() → live ADS ReadState request | Yes — readState before and after writeControl; prints before.adsState.name → after.adsState.name | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `--help` lists all 7 verbs and exits 0 | `dart run bin/ads.dart --help` | Lists 7 verbs: action, browse, pull, push, read, subscribe, write; exits 0 | PASS |
| Unknown flag exits 2 | `dart run bin/ads.dart read --nope` | "Could not find an option named '--nope'"; exit 2 | PASS |
| Refused connection exits 3 | `dart run bin/ads.dart action --state RUN --host 127.0.0.1 --target 127.0.0.1.1.1 --timeout 500 --port 1` | "transport error: Connection refused"; exit 3 | PASS |
| Invalid allowed-option exits 2 | `dart run bin/ads.dart --mode bogus` | '"bogus" is not an allowed value for option "--mode"'; exit 2 | PASS |
| dart analyze --fatal-infos clean | `dart analyze --fatal-infos` | "No issues found!" | PASS |
| dart format clean | `dart format --output=none --set-exit-if-changed lib/src/cli bin/ads.dart` | "0 changed" | PASS |
| Full suite 372/372 | `dart test -x slow` | All tests passed! (372) | PASS |
| Unit suite 304/304 | `dart test -x slow -x integration` | All tests passed! (304) | PASS |

### Probe Execution

No probe-*.sh scripts found or declared for this phase. Step 7c: SKIPPED (no probes).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CLI-01 | 08-03 | `browse` — list/filter PLC symbols with optional glob filter and `--json` | SATISFIED | browse_command.dart: browseSymbols() + glob filter + --json; cli_browse_read_test.dart passes |
| CLI-02 | 08-03 | `read` — read a variable by name or by `--group/--offset[/--len]`, typed by default or `--raw` | SATISFIED | read_command.dart: by-name typed, group/offset raw, --raw, --json; cli_browse_read_test.dart passes |
| CLI-03 | 08-04 | `write` — write a variable by name or group/offset, typed or `--raw` hex | SATISFIED | write_command.dart: by-name typed, group/offset raw, --raw; cli_write_test.dart passes |
| CLI-04 | 08-05 | `subscribe` — stream timestamped live notifications until interrupted | SATISFIED | subscribe_command.dart: ISO8601+hex streaming, SIGINT teardown, --on-change/--cycle/--max-delay; cli_subscribe_test.dart passes |
| CLI-05 | 08-06 | `pull` — snapshot symbols and/or current values to a file (JSON) using sum-read | SATISFIED | pull_command.dart: sumRead() batch, dart-ads/pull/1 schema, --values/--out/--filter; cli_pull_push_test.dart passes |
| CLI-06 | 08-06 | `push` — apply values from a file back to the PLC using sum-write, with `--dry-run` and per-item pass/fail | SATISFIED | push_command.dart: sumWrite() batch, --dry-run no-op, per-item OK/FAIL, exit 1 on any failure; cli_pull_push_test.dart passes |
| CLI-07 | 08-07 | `action` — issue a state change `--state=RUN|CONFIG|STOP` via WriteControl | SATISFIED | action_command.dart: writeControl + readState before/after; cli_action_test.dart passes |
| CLI-08 | 08-01 | All commands share consistent connection flags, stable exit codes, and human-readable ADS error names | SATISFIED | runner.dart global flags; exit_codes.dart; base_command.dart guarded() with adsErrorName(); cli_contract_test.dart proves exit 2 and exit 3 |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | — | No TBD/FIXME/XXX markers; no stubs; no placeholder returns | — | — |

All review findings (CR-01, WR-01 through WR-07) were resolved in the "fix(08): CLI review fixes" commit and confirmed in the current codebase:
- CR-01: parseHex strict `^[0-9a-fA-F]+$` guard present in value_parsing.dart line 40
- WR-01: single-flight `teardownFuture ??= doTeardown()` with per-step try/catch in subscribe_command.dart lines 152-182
- WR-02: --on-change/--no-on-change read and contradictions throw UsageException in subscribe_command.dart lines 114-127
- WR-03: FileSystemException → exit 2 in base_command.dart lines 73-79
- WR-04: `_maxTotalBytes = 4 * 1024 * 1024` total-bytes cap in push_command.dart
- WR-05: `data.length != size` rejected in push_command.dart line 199
- WR-06: case-insensitive `s.name.toLowerCase() == name.toLowerCase()` in subscribe_command.dart line 265; handle released on surprise-success path
- WR-07: `on RangeError` caught before `on ArgumentError` in base_command.dart lines 63-69; regression tested in base_command_exit_codes_test.dart

Info findings (IN-01 through IN-05) remain open by scope as documented in 08-REVIEW.md.

### Human Verification Required

#### 1. GitHub CI

**Test:** Push the phase-8 commits to the GitHub remote and confirm all CI jobs pass
**Expected:** dart analyze --fatal-infos clean, dart format no changes, dart test -x slow all pass (unit + integration on Linux with CMake-built mock server); publish dry-run clean
**Why human:** Requires a live GitHub remote and a runner with CMake/g++; cannot observe CI job status from the local filesystem

#### 2. Real Beckhoff/TwinCAT PLC (if available)

**Test:** Run all 7 CLI verbs against a real TwinCAT 3 PLC in the field — `ads browse`, `ads read`, `ads write`, `ads subscribe`, `ads pull --values`, `ads push`, `ads action --state`
**Expected:** Same behaviors proven against the C++ mock: browse lists the actual symbol table; read/write round-trips correctly; subscribe receives live change notifications; pull/push round-trips losslessly; action changes the actual PLC run state
**Why human:** No PLC available in this environment. CLI is mock-verified; wire behavior of the underlying library was verified against the reference C++ AdsLib in earlier phases. Real-PLC verification depends on a suitable network path, TwinCAT routing configuration, and hardware availability

### Gaps Summary

No gaps. All ROADMAP success criteria, plan must-haves, and requirement IDs (CLI-01..CLI-08) are VERIFIED in the current codebase. The 372-test suite (excluding tagged-slow tests) is fully green, dart analyze is clean, and dart format makes no changes.

The two human verification items are pre-acknowledged limitations documented in 08-VALIDATION.md: CI-on-GitHub requires a GitHub remote push; real-PLC testing requires PLC hardware. Neither represents an implementation gap in the phase deliverables.

---

_Verified: 2026-07-04_
_Verifier: Claude (gsd-verifier)_
