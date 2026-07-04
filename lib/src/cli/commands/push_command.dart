/// The `push` verb (stub): apply values from a pull JSON file to the PLC.
///
/// Shape only in 08-01; the real apply body (sumWrite batching, per-item
/// pass/fail, non-zero exit on any failure) lands in a later Phase 8 plan that
/// replaces ONLY this `run()`.
library;

import '../base_command.dart';
import '../connection.dart';

/// `ads push` — apply values from a pull JSON file (stub).
class PushCommand extends BaseAdsCommand {
  /// Declares the push-specific flags.
  PushCommand() {
    argParser
      ..addOption(
        'in',
        help: 'Read the values-to-apply from this pull JSON file.',
        valueHelp: 'file',
      )
      ..addFlag(
        'dry-run',
        help: 'List the intended writes without applying them.',
        negatable: false,
      );
  }

  @override
  String get name => 'push';

  @override
  String get description => 'Apply values from a pull JSON file to the PLC.';

  @override
  Future<int> run() => guarded(() async {
        final session = await connectFromGlobals(globalResults!);
        try {
          throw UnimplementedError('push lands in a later Phase 8 plan');
        } finally {
          await session.close();
        }
      });
}
