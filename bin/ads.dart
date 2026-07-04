/// The `ads` CLI entrypoint: a thin `main` that delegates to [AdsCliRunner] and
/// turns its result into a process exit code (CLI-08).
///
/// All command logic, connection bootstrap, and error→exit-code mapping live in
/// `lib/src/cli/` (importable + testable). This file only:
///   * awaits `AdsCliRunner().run(args)` and uses the returned `int` as the
///     process [exitCode] (each verb's `guarded(...)` produces 0/1/2/3);
///   * translates a thrown [UsageException] — an unknown command/flag/value the
///     parser rejects before any command runs — into exit code `2` with its
///     message on stderr.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_ads/src/cli/exit_codes.dart';
import 'package:dart_ads/src/cli/runner.dart';

Future<void> main(List<String> args) async {
  try {
    final code = await AdsCliRunner().run(args);
    // A null result (e.g. `--help`) is a successful no-op.
    exitCode = code ?? exitOk;
  } on UsageException catch (error) {
    // Parser-level rejection (unknown command/flag/disallowed value) never
    // reaches a command's guarded() — map it to the usage exit code here.
    stderr.writeln(error);
    exitCode = exitUsage;
  }
}
