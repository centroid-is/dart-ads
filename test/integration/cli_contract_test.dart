@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

/// The `ads` CLI exit-code contract (CLI-08), proven end-to-end by driving the
/// entrypoint as a SUBPROCESS — the only way to observe the real process exit
/// code the shell sees.
///
/// This suite is tagged `integration` because each case pays the `dart run`
/// startup + compile cost. It covers exactly the two contract points this plan
/// (08-01) owns:
///   * a usage error (unknown flag) exits `2`;
///   * an unreachable/refused endpoint exits `3` (the transport family), NOT
///     `1` (which would mean the SocketException leaked into the ADS-error
///     bucket).
/// The exit-code `1` case (an unknown-symbol ADS error) lands with the `read`
/// verb's real body in 08-03; it needs a live command, not a stub.
void main() {
  /// Runs the CLI as a subprocess from the package root and returns its result
  /// (exit code + captured stdout/stderr).
  Future<ProcessResult> runCli(List<String> args) =>
      Process.run('dart', <String>['run', 'bin/ads.dart', ...args]);

  test('usage error: an unknown flag on a verb exits 2', () async {
    final result = await runCli(<String>['read', '--nope']);

    expect(result.exitCode, 2);
    expect(result.stderr as String, isNotEmpty,
        reason: 'a usage error must explain itself on stderr');
  });

  test('transport error: a refused endpoint exits 3, not 1', () async {
    // 127.0.0.1:1 is a loopback port nothing listens on, so the dial is
    // refused IMMEDIATELY (ECONNREFUSED -> SocketException) rather than
    // filtered-and-timed-out — a timeout would enrich into an AdsRouting
    // exception (exit 1), so a fast refusal is what proves the transport(3)
    // path. Direct mode with a dotted-IPv4 host derives the source NetId, so
    // no --source is needed. --group/--offset/--len take the raw path (no
    // symbol lookup), but the dial fails long before any read is attempted.
    final result = await runCli(<String>[
      'read',
      '--host',
      '127.0.0.1',
      '--port',
      '1',
      '--target',
      '127.0.0.1.1.1',
      '--mode',
      'direct',
      '--group',
      '0x4020',
      '--offset',
      '0',
      '--len',
      '2',
    ]);

    expect(result.exitCode, 3,
        reason: 'refused dial must map to transport(3), not ADS-error(1); '
            'stderr was: ${result.stderr}');
  });
}
