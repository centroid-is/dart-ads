@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../support/mock_server.dart';

/// End-to-end proof of the `write` verb (CLI-03) driven as a SUBPROCESS against
/// the C++ mock — the only way to observe the real process exit code the shell
/// sees.
///
/// ROUND-TRIP NOTE: the mock's value store is CONNECTION-scoped, and each `dart
/// run bin/ads.dart` is its own process (its own connection). A write in one
/// subprocess and a read-back in a second subprocess therefore cannot share a
/// value store, so a cross-process write→read round-trip is not a mock
/// guarantee. The write+read-back round-trip IS proven, connection-scoped, at
/// library level by test/integration/symbols_test.dart ("typed round-trips
/// DINT/BOOL/STRING/LREAL"). This subprocess suite asserts the write PATH
/// succeeds (exit 0 + a confirmation line) and that a hostile value maps to the
/// usage exit code (2) without crashing.
///
/// The mock serves a fixed 4-symbol table (MAIN.counter DINT, MAIN.flag BOOL,
/// MAIN.text STRING(80), MAIN.temp LREAL), all at index group 0x4020. A single
/// mock is shared across the group (subprocess cost); each case is an
/// independent write, so no per-test isolation is needed.
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

  test('write --name MAIN.counter --type dint --value 42 exits 0', () async {
    final result = await runCli(<String>[
      'write',
      '--name',
      'MAIN.counter',
      '--type',
      'dint',
      '--value',
      '42',
    ]);

    expect(result.exitCode, 0,
        reason: 'typed by-name write must succeed; stderr: ${result.stderr}');
    // A 4-byte DINT was written; the confirmation names the byte count + target.
    expect(result.stdout as String, contains('wrote 4 bytes to MAIN.counter'));
  });

  test('write --name MAIN.text --value hello (no --type) exits 0', () async {
    // No --type: the verb resolves MAIN.text's declared STRING(80)/size(81) via
    // browseSymbols, so the operator need not restate the type.
    final result = await runCli(<String>[
      'write',
      '--name',
      'MAIN.text',
      '--value',
      'hello',
    ]);

    expect(result.exitCode, 0,
        reason: 'untyped by-name write resolves the symbol type; '
            'stderr: ${result.stderr}');
    expect(result.stdout as String, contains('wrote 81 bytes to MAIN.text'));
  });

  test('write --group 0x4020 --offset 0 --raw 0x2a000000 exits 0', () async {
    final result = await runCli(<String>[
      'write',
      '--group',
      '0x4020',
      '--offset',
      '0',
      '--raw',
      '0x2a000000',
    ]);

    expect(result.exitCode, 0,
        reason:
            'raw group/offset write must succeed; stderr: ${result.stderr}');
    // 0x2a000000 is four bytes (little-endian DINT 42) written verbatim.
    expect(result.stdout as String, contains('wrote 4 bytes to 0x4020:0x0'));
  });

  test('write --name MAIN.counter --type dint --value notanint exits 2',
      () async {
    final result = await runCli(<String>[
      'write',
      '--name',
      'MAIN.counter',
      '--type',
      'dint',
      '--value',
      'notanint',
    ]);

    expect(result.exitCode, 2,
        reason: 'a non-integer DINT value is a usage error (exit 2), '
            'never a crash; stderr: ${result.stderr}');
    expect(result.stderr as String, isNotEmpty,
        reason: 'a rejected value must explain itself on stderr');
  });

  test('write --group 0x4020 --offset 0 --raw 0xZZ exits 2', () async {
    final result = await runCli(<String>[
      'write',
      '--group',
      '0x4020',
      '--offset',
      '0',
      '--raw',
      '0xZZ',
    ]);

    expect(result.exitCode, 2,
        reason: 'garbage hex is a usage error (exit 2), never a crash; '
            'stderr: ${result.stderr}');
    expect(result.stderr as String, isNotEmpty);
  });

  test('write --name MAIN.counter with no --value/--raw exits 2', () async {
    final result = await runCli(<String>['write', '--name', 'MAIN.counter']);

    expect(result.exitCode, 2,
        reason: 'a write with no payload is a usage error (exit 2); '
            'stderr: ${result.stderr}');
    expect(result.stderr as String, isNotEmpty);
  });
}
