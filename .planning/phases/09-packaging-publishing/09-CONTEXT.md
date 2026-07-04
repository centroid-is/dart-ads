# Phase 9: Packaging & Publishing - Context

**Gathered:** 2026-07-04
**Status:** Ready for planning
**Mode:** Autonomous (auto-accepted per standing user directive)

<domain>
## Phase Boundary

dart-ads becomes a clean, publishable pure-Dart package with an installable CLI and no C++ harness leaking into the published artifact. Delivers: pubspec platform declarations + metadata polish, .pubignore, example/, dartdoc pass on the public surface, `dart pub publish --dry-run` clean, CLI installable via `dart pub global activate`, README completion, and the TEST-05 final parity audit (every applicable C++ AdsLibTest scenario has a named Dart counterpart; N/A items documented).

Requirements: PKG-01, PKG-02, TEST-05 (final audit).

</domain>

<decisions>
## Implementation Decisions

- pubspec: description, version 0.1.0, repository/homepage placeholders (no remote yet — use TODO-marked URLs or omit; prefer omit to keep dry-run clean), `platforms:` linux/macos/windows/android/ios (NO web), `executables: {ads: ads}` (exists), `topics:` (ads, beckhoff, twincat, plc, industrial)
- .pubignore: exclude test_harness/, third_party/, test/golden/? (goldens are test-only → excluded via test/ exclusion rules? pub includes test/ by default in uploads unless .pubignore — exclude test/, test_harness/, third_party/, .planning/, CLAUDE.md)
- example/example.dart: minimal read/subscribe snippet (pub.dev scoring)
- Dartdoc: public_member_api_docs NOT enforced as lint (too heavy now); ensure barrel-exported symbols have doc comments (most already do)
- README: quickstart (install, connect, read/write/subscribe, CLI usage), limitations section (LocalRouterTarget mock-only, reverse-route requirement), v2 roadmap note
- TEST-05 audit: a PARITY.md (or section in README/test doc) mapping every C++ AdsLibTest/AdsLibOOITest scenario → Dart test (or N/A rationale: RingBuffer/IpV4 internals covered-by-equivalent; adstool different surface; endurance tagged slow); REQUIREMENTS.md TEST-05 checked off after audit passes
- dry-run gate: `dart pub publish --dry-run` must pass with zero errors (warnings documented if unavoidable)
- Do NOT actually publish (no pub.dev credentials/remote in this environment) — publish itself is a human item

</decisions>

<code_context>
Reusable: everything (library complete, 372 tests). CI workflow exists. AdsLibTest scenario list in STATE directive + phase test headers.
Patterns: --fatal-infos, format gate, atomic commits.
</code_context>

<specifics>
- PKG-01 success = dry-run passes + platforms declared + no C++ in package
- PKG-02 success = `dart pub global activate --source path . && ads --help` works
- TEST-05 success = audit doc complete, no unexplained gaps
</specifics>

<deferred>
- Actual pub.dev publish + OIDC workflow → human item (needs GitHub remote)
- v2 items per REQUIREMENTS (DTYPE, RECON, RPC, ROUTE-04, TRACE)
</deferred>
