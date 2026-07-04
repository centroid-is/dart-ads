@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/mock_server.dart';

/// End-to-end proof of the `action` verb (CLI-07) driven as a SUBPROCESS against
/// the C++ mock — the only way to observe the real process exit code the shell
/// sees.
///
/// STATE-CHANGE NOTE: the mock's `curAdsState` is CONNECTION-scoped and seeded to
/// RUN. Each `dart run bin/ads.dart action` is one process / one connection, and
/// the verb itself reads the OLD state, issues WriteControl, then reads the NEW
/// state — so the old → new transition is fully observable within that single
/// invocation. A fresh connection always starts from the seeded RUN, so
/// `--state CONFIG` reliably prints `run -> config`.
///
/// A single mock is shared across the group (subprocess cost); each case is an
/// independent invocation on its own connection, so no per-test isolation is
/// needed.
void main() {
  late MockServer server;

  setUpAll(() async {
    server = await startMockServer();
  });
  tearDownAll(() async {
    await server.stop();
  });

  /// Runs the CLI as a subprocess with the shared global connection flags for
  /// the mock: direct mode to loopback (the dotted-IPv4 host derives the source
  /// NetId), targeting the mock's AMS NetId.
  Future<ProcessResult> runCli(List<String> verbArgs) => Process.run(
        'dart',
        <String>[
          'run',
          'bin/ads.dart',
          '--host',
          '127.0.0.1',
          '--port',
          '${server.port}',
          '--target',
          '192.168.0.1.1.1',
          '--mode',
          'direct',
          ...verbArgs,
        ],
      );

  test('action --state CONFIG exits 0 and prints run -> config', () async {
    final result = await runCli(<String>['action', '--state', 'CONFIG']);

    expect(result.exitCode, 0,
        reason: 'a state change must succeed; stderr: ${result.stderr}');
    // The connection starts at the seeded RUN, then transitions to CONFIG.
    expect(result.stdout as String, contains('run -> config'));
  });

  test('action --state RUN exits 0 and prints -> run', () async {
    final result = await runCli(<String>['action', '--state', 'RUN']);

    expect(result.exitCode, 0,
        reason: 'a state change must succeed; stderr: ${result.stderr}');
    // Seeded RUN -> RUN; the new state is what matters for this case.
    expect(result.stdout as String, contains('-> run'));
  });

  test('action --state BOGUS exits 2', () async {
    final result = await runCli(<String>['action', '--state', 'BOGUS']);

    expect(result.exitCode, 2,
        reason: 'an unknown state name is a usage error (exit 2), never a '
            'crash or a silent no-op; stderr: ${result.stderr}');
    expect(result.stderr as String, isNotEmpty,
        reason: 'a rejected state must explain itself on stderr');
  });
}
