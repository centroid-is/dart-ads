@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/mock_server.dart';

/// End-to-end proof of the `browse` and `read` verbs (CLI-01/CLI-02) driven as
/// SUBPROCESSES against the C++ mock — the only way to observe the real process
/// exit code the shell sees. This completes the exit-code contract with the
/// unknown-symbol → exit 1 case that needs a live command (deferred from 08-01).
///
/// The mock serves a fixed 4-symbol table (MAIN.counter DINT, MAIN.flag BOOL,
/// MAIN.text STRING(80), MAIN.temp LREAL), all at index group 0x4020. A single
/// mock is shared across the group (subprocess cost) — every case is read-only
/// against that table, so no per-test isolation is needed.
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

  test('browse --json returns the 4-symbol array incl. MAIN.counter', () async {
    final result = await runCli(<String>['browse', '--json']);

    expect(result.exitCode, 0,
        reason: 'browse must succeed; stderr: ${result.stderr}');
    final parsed = jsonDecode(result.stdout as String) as List<Object?>;
    expect(parsed, hasLength(4), reason: 'the mock serves four symbols');
    final names =
        parsed.map((e) => (e! as Map<String, Object?>)['name']).toList();
    expect(names, contains('MAIN.counter'));
  });

  test('browse --filter MAIN.t* lists only MAIN.text and MAIN.temp', () async {
    final result = await runCli(<String>['browse', '--filter', 'MAIN.t*']);

    expect(result.exitCode, 0,
        reason: 'filtered browse must succeed; stderr: ${result.stderr}');
    final out = result.stdout as String;
    expect(out, contains('MAIN.text'));
    expect(out, contains('MAIN.temp'));
    expect(out, isNot(contains('MAIN.counter')));
    expect(out, isNot(contains('MAIN.flag')));
  });

  test('read --name MAIN.counter --type dint prints a number (exit 0)',
      () async {
    final result = await runCli(
        <String>['read', '--name', 'MAIN.counter', '--type', 'dint']);

    expect(result.exitCode, 0,
        reason: 'typed by-name read must succeed; stderr: ${result.stderr}');
    // The decoded DINT is a plain integer on stdout (sign optional).
    expect((result.stdout as String).trim(), matches(RegExp(r'^-?\d+$')));
  });

  test('read --group 0x4020 --offset 0 --len 4 exits 0 with hex', () async {
    final result = await runCli(<String>[
      'read',
      '--group',
      '0x4020',
      '--offset',
      '0',
      '--len',
      '4',
    ]);

    expect(result.exitCode, 0,
        reason: 'raw group/offset read must succeed; stderr: ${result.stderr}');
    expect((result.stdout as String).trim(), matches(RegExp(r'^0x[0-9a-f]+$')));
  });

  test('read --name DOES.NOT.EXIST exits 1 with a human-readable ADS error',
      () async {
    final result =
        await runCli(<String>['read', '--name', 'DOES.NOT.EXIST']);

    expect(result.exitCode, 1,
        reason: 'an unknown symbol is an ADS device error (exit 1); '
            'stderr: ${result.stderr}');
    final err = (result.stderr as String).trim();
    expect(err, isNotEmpty);
    // The contract renders the human-readable ADS error name, not bare hex.
    expect(err, matches(RegExp('[A-Z_]{3,}')),
        reason: 'stderr must name the ADS error, not just a hex code');
  });
}
