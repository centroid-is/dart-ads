/// The `pull` verb (stub): snapshot symbols (and optionally values) to JSON.
///
/// Shape only in 08-01; the real snapshot body (sumRead batching, lossless for
/// `push`) lands in a later Phase 8 plan that replaces ONLY this `run()`.
library;

import '../base_command.dart';
import '../connection.dart';

/// `ads pull` — snapshot symbols/values to a JSON file (stub).
class PullCommand extends BaseAdsCommand {
  /// Declares the pull-specific flags.
  PullCommand() {
    argParser
      ..addFlag(
        'values',
        help: 'Include current values (batched via sumRead), not just symbols.',
        negatable: false,
      )
      ..addOption(
        'out',
        help: 'Write the JSON snapshot to this file (default: stdout).',
        valueHelp: 'file',
      );
  }

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Snapshot PLC symbols (and optionally values) to JSON.';

  @override
  Future<int> run() => guarded(() async {
        final session = await connectFromGlobals(globalResults!);
        try {
          throw UnimplementedError('pull lands in a later Phase 8 plan');
        } finally {
          await session.close();
        }
      });
}
