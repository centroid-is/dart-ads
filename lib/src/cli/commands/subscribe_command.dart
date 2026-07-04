/// The `subscribe` verb (stub): stream device notifications for a symbol.
///
/// Shape only in 08-01; the real streaming body (with clean
/// DeleteDeviceNotification on SIGINT) lands in a later Phase 8 plan that
/// replaces ONLY this `run()`.
library;

import '../base_command.dart';
import '../connection.dart';

/// `ads subscribe` — stream device notifications (stub).
class SubscribeCommand extends BaseAdsCommand {
  /// Declares the subscribe-specific flags (target + transmission mode).
  SubscribeCommand() {
    argParser
      ..addOption(
        'name',
        help: 'Symbol name to subscribe to.',
        valueHelp: 'symbol',
      )
      ..addOption(
        'group',
        help: 'Index group for a raw subscription (hex or decimal).',
        valueHelp: 'int',
      )
      ..addOption(
        'offset',
        help: 'Index offset for a raw subscription (hex or decimal).',
        valueHelp: 'int',
      )
      ..addFlag(
        'on-change',
        help: 'Notify only when the value changes (default).',
        defaultsTo: true,
      )
      ..addOption(
        'cycle',
        help: 'Server cycle time in milliseconds (cyclic mode).',
        valueHelp: 'ms',
      )
      ..addOption(
        'max-delay',
        help: 'Maximum delay before a notification is delivered (ms).',
        valueHelp: 'ms',
      );
  }

  @override
  String get name => 'subscribe';

  @override
  String get description =>
      'Stream device notifications for a symbol until interrupted.';

  @override
  Future<int> run() => guarded(() async {
        final session = await connectFromGlobals(globalResults!);
        try {
          throw UnimplementedError('subscribe lands in a later Phase 8 plan');
        } finally {
          await session.close();
        }
      });
}
