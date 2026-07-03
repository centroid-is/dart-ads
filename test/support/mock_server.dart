/// Test-support helper that launches the C++ mock ADS server and hands back a
/// live [MockServer] handle bound to an ephemeral port.
///
/// This lives under `test/` (not `lib/`), so importing `dart:io` here is
/// intentional and allowed — it is test-only support code, never shipped with
/// the package (`test/` is excluded from published archives).
///
/// Designed for reuse by every integration test in this and later phases
/// (TEST-03): it builds the CMake harness if stale, `Process.start`s the mock
/// on an ephemeral (`:0`) port, parses the `LISTENING <port>` readiness line
/// with a bounded timeout (never a `sleep`, never an unbounded hang), and
/// documents a clean teardown contract.
///
/// Typical use from an integration test:
///
/// ```dart
/// late MockServer server;
/// setUpAll(() async {
///   server = await startMockServer(args: ['--delay-ms', '80']);
/// });
/// tearDownAll(() async {
///   await server.stop();
/// });
/// // ... connect to 127.0.0.1:server.port ...
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A running mock-server child process together with the ephemeral TCP port it
/// bound. Obtain one via [startMockServer]; release it via [stop] (or the
/// documented `tearDownAll` teardown) so no orphan process survives the test.
class MockServer {
  /// The launched mock-server child process.
  final Process proc;

  /// The ephemeral loopback port the mock parsed from its `LISTENING` line.
  final int port;

  /// Wraps a launched [proc] bound to [port]. Constructed by [startMockServer].
  MockServer(this.proc, this.port);

  /// Terminates the mock and awaits its exit, guarding against orphan
  /// processes on test teardown. Safe to await in `tearDownAll`.
  Future<void> stop() async {
    proc.kill(ProcessSignal.sigterm);
    await proc.exitCode;
  }
}

/// Path to the built mock-server binary produced by the CMake harness.
const _mockBinary = 'test_harness/build/mock_server';

/// Source inputs whose modification should force a rebuild of [_mockBinary].
const _mockSources = <String>[
  'test_harness/mock_server.cpp',
  'test_harness/CMakeLists.txt',
];

/// Launches the mock ADS server on an ephemeral port and returns a handle once
/// it has announced readiness.
///
/// [args] are passed through verbatim to the mock (e.g. `['--delay-ms', '80']`
/// or `['--close-after', '2']`); `--port` is intentionally omitted so the mock
/// binds `:0` and reports the chosen port on stdout, avoiding parallel-run
/// port collisions.
///
/// Builds the harness first if the binary is missing or stale (see
/// [_ensureBuilt]). Throws a [StateError] if the C++ toolchain is unavailable
/// or the build fails, and again (after killing the child) if the mock never
/// prints its `LISTENING <port>` line within 10 seconds — integration tests
/// then fail loudly rather than hang.
Future<MockServer> startMockServer({List<String> args = const []}) async {
  final bin = await _ensureBuilt();
  final proc = await Process.start(bin, args); // no --port => ephemeral :0

  // Capture stderr so a failure to bind can surface the server's own logs.
  final stderrBuffer = StringBuffer();
  proc.stderr.transform(utf8.decoder).listen(stderrBuffer.write);

  final port = await proc.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((line) => line.startsWith('LISTENING '))
      .then((line) => int.parse(line.trim().split(' ').last))
      .timeout(
    const Duration(seconds: 10),
    onTimeout: () {
      proc.kill();
      throw StateError('mock never printed LISTENING\n$stderrBuffer');
    },
  );

  return MockServer(proc, port);
}

/// Returns the path to a fresh mock-server binary, rebuilding via CMake when
/// the binary is missing or older than any of [_mockSources].
///
/// On CI the integration job builds the mock in an explicit step, so this is a
/// no-op there; it exists for local-dev ergonomics. Throws a [StateError]
/// naming the missing toolchain (or surfacing the build output) if `cmake` is
/// absent or the build fails, so integration tests fail fast instead of
/// launching a stale or non-existent binary.
Future<String> _ensureBuilt() async {
  final binary = File(_mockBinary);

  var stale = !binary.existsSync();
  if (!stale) {
    final builtAt = binary.lastModifiedSync();
    for (final source in _mockSources) {
      final src = File(source);
      if (src.existsSync() && src.lastModifiedSync().isAfter(builtAt)) {
        stale = true;
        break;
      }
    }
  }

  if (!stale) {
    return _mockBinary;
  }

  // Configure then build. `Process.run` surfaces a ProcessException if `cmake`
  // is not on PATH, which we translate into a clear StateError.
  Future<void> run(List<String> cmakeArgs) async {
    final ProcessResult result;
    try {
      result = await Process.run('cmake', cmakeArgs);
    } on ProcessException catch (e) {
      throw StateError(
        'cannot build mock server: cmake not found on PATH '
        '(needed to compile $_mockBinary). Underlying error: ${e.message}',
      );
    }
    if (result.exitCode != 0) {
      throw StateError(
        'cmake ${cmakeArgs.join(' ')} failed (exit ${result.exitCode}):\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
  }

  await run(['-S', 'test_harness', '-B', 'test_harness/build']);
  await run(['--build', 'test_harness/build']);

  if (!binary.existsSync()) {
    throw StateError(
      'mock server build reported success but $_mockBinary is missing',
    );
  }
  return _mockBinary;
}
