/// Regression for WR-07/WR-03: RangeError (a device-side short-response
/// symptom) maps to exit 1 (protocol), NOT the usage family that its
/// ArgumentError supertype belongs to; FileSystemException maps to exit 2.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_ads/src/cli/base_command.dart';
import 'package:dart_ads/src/cli/exit_codes.dart';
import 'package:test/test.dart';

final class _ProbeCommand extends BaseAdsCommand {
  _ProbeCommand(this.body);
  final Future<int> Function() body;
  @override
  String get name => 'probe';
  @override
  String get description => 'test probe';
  @override
  Future<int> run() => guarded(body);
}

Future<int> _run(Future<int> Function() body) async {
  final runner = CommandRunner<int>('t', 't')..addCommand(_ProbeCommand(body));
  return (await runner.run(['probe']))!;
}

void main() {
  test('RangeError maps to exit 1 (protocol), not usage (WR-07)', () async {
    expect(await _run(() => throw RangeError('short response')), exitAdsError);
  });
  test('ArgumentError still maps to exit 2 (usage)', () async {
    expect(await _run(() => throw ArgumentError('bad value')), exitUsage);
  });
  test('FileSystemException maps to exit 2 (usage family, WR-03)', () async {
    expect(
      await _run(
          () => throw const FileSystemException('open failed', '/nope.json')),
      exitUsage,
    );
  });
}
