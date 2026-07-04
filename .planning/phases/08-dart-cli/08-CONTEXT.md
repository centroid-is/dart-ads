# Phase 8: Dart CLI - Context

**Gathered:** 2026-07-04
**Status:** Ready for planning
**Mode:** Autonomous (grey-area recommendations auto-accepted per standing user directive)

<domain>
## Phase Boundary

An operator drives a PLC entirely from the terminal through all seven CLI verbs (browse, read, write, subscribe, pull, push, action), exercising the full library end-to-end. Delivers `bin/ads.dart` with args CommandRunner, consistent connection flags, stable exit codes, human-readable errors, JSON output modes, and integration tests driving the CLI as a subprocess against the mock. Research skipped: args/CommandRunner is the Dart-team standard (project research), and every verb's semantics were pinned in project FEATURES research; the library surface it wraps is complete and tested.

Requirements: CLI-01..CLI-08.

</domain>

<decisions>
## Implementation Decisions

### Structure
- `bin/ads.dart` thin entry → `lib/src/cli/` command classes (args ^2.x CommandRunner) — cli/ may import dart:io freely
- pubspec: add `args` dependency + `executables: { ads: ads }` (PKG-02 lands in Phase 9 but the executable entry is created here)
- Global flags on the runner: `--host` (required for connection verbs), `--port` (default 48898), `--target` (target AmsNetId, default derived/required), `--ams-port` (default 851), `--source` (source AmsNetId, optional), `--timeout` (ms, default 5000), `--mode` (direct|router, default direct)
- Connection bootstrap shared: AmsRouter + addRoute(target→host) + connect per the Phase 4 API; clean teardown on exit/SIGINT

### Verbs (per project FEATURES research)
- `browse` — browseSymbols; table output (name, type, size, group:offset); `--filter <glob>`; `--json`
- `read` — by `--name` (typed via symbol's type when resolvable: browse lookup; fall back raw hex) or `--group/--offset/--len` (raw hex); `--raw` forces hex; `--type <bool|int16|dint|real|lreal|string|...>` forces typed decode; `--json`
- `write` — by `--name` or group/offset; value parsed per `--type` (or symbol type by name); `--raw <hex>` accepts hex bytes
- `subscribe` — streams timestamped lines (ISO8601 + hex/typed value) until SIGINT; `--on-change` (default) / `--cycle <ms>` / `--max-delay <ms>`; clean DeleteDeviceNotification on SIGINT
- `pull` — snapshot symbols (+ values with `--values`, via sumRead batching) to JSON file (`--out <file>`, default stdout); lossless for push
- `push` — apply values from a pull JSON file (`--in <file>`), sumWrite batching; `--dry-run` lists intended writes; per-item pass/fail report; exit non-zero if any item failed
- `action` — `--state <RUN|STOP|CONFIG|...>` via WriteControl (state names from AdsState enum, case-insensitive); prints old → new state

### UX Contract (CLI-08)
- Exit codes: 0 success; 1 ADS/protocol error; 2 usage error (bad flags); 3 connection/transport error
- Errors print human-readable ADS names (AdsException name+code) to stderr, never bare hex only
- `--json` on read-oriented verbs (browse, read, pull) for piping; no scripting DSL (out of scope)

### Tests
- Integration: run the CLI as a subprocess (`dart run bin/ads.dart ...`) against startMockServer — one test per verb (success) + exit-code contract tests (unknown symbol → 1, bad flags → 2, unreachable host → 3); pull→push round-trip losslessness test
- subscribe test: start, receive ≥1 line, SIGTERM, assert clean handle release (mock handle count)
- No C++ parity claim (adstool exists but is a different surface — note for Phase 9 audit)

### Claude's Discretion
- Exact output formatting, table alignment, JSON schema (document it in the pull file header)
- How --type maps to value_codec calls; subscribe line format details

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- Full library: AmsRouter/TransportTarget (Phase 4), AdsClient commands (3), notifications (5), sum (6), symbols+codec (7); startMockServer helper; AdsState enum; AdsException names

### Established Patterns
- --fatal-infos; -n regex; verify ordering; snapshot-before-await; atomic commits; integration tag
- Exit-code discipline mirrors typed exception families (AdsException→1, ArgumentError/usage→2, transport→3)

### Integration Points
- Phase 9 packaging: executables entry + .pubignore; pub.dev score wants an example — CLI serves as living example
</code_context>

<specifics>
## Specific Ideas

- pull→push round-trip must be lossless (FEATURES research contract)
- subscribe must never orphan notification handles on SIGINT (leak-count assertion via 0xE7700005)
- The CLI is the end-to-end proof of the whole stack — its integration tests are the de-facto system test

</specifics>

<deferred>
## Deferred Ideas

- `action` RPC method-call mode → v2 (RPC-01)
- `addroute` verb → v2 (ROUTE-04)
- CSV pull format → v2 if needed (JSON only in v1)

</deferred>
