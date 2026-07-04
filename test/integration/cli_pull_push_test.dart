@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../support/mock_server.dart';

/// End-to-end proof of the `pull`/`push` verb pair (CLI-05, CLI-06) driven as
/// SUBPROCESSES against the C++ mock — the headline lossless snapshot contract.
///
/// The mock serves a fixed 4-symbol table (MAIN.counter DINT, MAIN.flag BOOL,
/// MAIN.text STRING(80), MAIN.temp LREAL) at index group 0x4020, and its value
/// store is CONNECTION-scoped: every `dart run bin/ads.dart` is its own process
/// (its own connection), so each pull/push reads the SAME deterministic seed
/// (each symbol seeded to `size` zero bytes). That is exactly what makes the
/// round-trip provable across subprocesses: pull1 and pull3 both read the fresh
/// seed, and push writes those seed bytes back (an all-pass sumWrite), so the
/// two snapshots' value sets are byte-for-byte equal (lossless).
void main() {
  late MockServer server;
  late Directory tmp;

  setUpAll(() async {
    server = await startMockServer();
  });
  tearDownAll(() async {
    await server.stop();
  });
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dart_ads_pullpush_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Runs the CLI as a subprocess with the shared mock connection flags.
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

  /// Parses a written snapshot file into a `name -> hex value` map (only items
  /// that carry a value).
  Map<String, String> valuesOf(String path) {
    final doc = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    final symbols = doc['symbols'] as List;
    return <String, String>{
      for (final s in symbols.cast<Map<String, Object?>>())
        if (s['value'] != null) s['name'] as String: s['value'] as String,
    };
  }

  test('pull --values --out writes a schema-tagged snapshot with 4 hex values',
      () async {
    final snap = '${tmp.path}/snap.json';
    final result = await runCli(<String>['pull', '--values', '--out', snap]);

    expect(result.exitCode, 0, reason: 'pull must succeed; ${result.stderr}');
    final doc =
        jsonDecode(File(snap).readAsStringSync()) as Map<String, Object?>;
    expect(doc['schema'], 'dart-ads/pull/1');
    expect(doc['generatedAt'], isA<String>());
    final symbols = doc['symbols'] as List;
    expect(symbols, hasLength(4));
    for (final s in symbols.cast<Map<String, Object?>>()) {
      expect(s['value'], startsWith('0x'),
          reason: '${s['name']} must carry a lossless hex value');
      expect(s['ok'], isTrue);
    }
  });

  test('push --dry-run lists intended writes and changes nothing', () async {
    final snap = '${tmp.path}/snap.json';
    expect((await runCli(<String>['pull', '--values', '--out', snap])).exitCode,
        0);
    final before = valuesOf(snap);

    final dry = await runCli(<String>['push', '--in', snap, '--dry-run']);
    expect(dry.exitCode, 0, reason: 'dry-run must succeed; ${dry.stderr}');
    expect(dry.stdout as String, contains('intended write'));
    expect(dry.stdout as String, contains('MAIN.counter'));

    // A follow-up pull must show the values UNCHANGED — dry-run wrote nothing.
    final after = '${tmp.path}/after.json';
    expect(
        (await runCli(<String>['pull', '--values', '--out', after])).exitCode,
        0);
    expect(valuesOf(after), equals(before));
  });

  test('pull -> push -> pull round-trips losslessly with an all-pass report',
      () async {
    final first = '${tmp.path}/first.json';
    expect((await runCli(<String>['pull', '--values', '--out', first])).exitCode,
        0);
    final before = valuesOf(first);
    expect(before, hasLength(4));

    final push = await runCli(<String>['push', '--in', first]);
    expect(push.exitCode, 0,
        reason: 'a snapshot pushed back must all-pass; ${push.stderr}');
    expect(push.stdout as String, contains('4/4 applied'));
    expect(push.stdout as String, isNot(contains('FAIL')));

    final second = '${tmp.path}/second.json';
    expect(
        (await runCli(<String>['pull', '--values', '--out', second])).exitCode,
        0);
    expect(valuesOf(second), equals(before),
        reason: 'the value set must survive a pull->push->pull round-trip');
  });

  test('a malformed snapshot file makes push exit 2', () async {
    final bad = '${tmp.path}/bad.json';
    File(bad).writeAsStringSync('{ this is not valid json ]');
    final result = await runCli(<String>['push', '--in', bad]);

    expect(result.exitCode, 2,
        reason: 'a hostile/malformed snapshot must exit 2, never crash; '
            'stderr: ${result.stderr}');
    expect(result.stderr as String, isNotEmpty);
  });

  test('a non-hex value in an otherwise valid snapshot makes push exit 2',
      () async {
    final bad = '${tmp.path}/badvalue.json';
    File(bad).writeAsStringSync(jsonEncode(<String, Object?>{
      'schema': 'dart-ads/pull/1',
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'target': '192.168.0.1.1.1',
      'symbols': <Object?>[
        <String, Object?>{
          'name': 'MAIN.counter',
          'type': 'DINT',
          'size': 4,
          'indexGroup': 0x4020,
          'indexOffset': 0,
          'value': '0xZZ',
        },
      ],
    }));
    final result = await runCli(<String>['push', '--in', bad]);

    expect(result.exitCode, 2,
        reason: 'a non-hex value is a parse failure (exit 2); '
            'stderr: ${result.stderr}');
    expect(result.stderr as String, isNotEmpty);
  });
}
