import 'package:clash_pseudo/src/model/core_snapshot.dart';

import '../../platform/app_bridge.dart';
import '../../l10n/messages.dart';

class ConnectionActions {
  ConnectionActions(this.platform);
  final AppBridge platform;

  Future<Map<String, Object?>> execute(Map<String, dynamic> command) async {
    final core = CoreSnapshot(
      generation: command['generation'] as int,
      phase: 'READY',
      purpose: 'VPN',
      configId: command['configId'] as String,
      revision: command['revision'] as int,
    );
    final id = command['connectionId'] as String;
    try {
      final state = await platform.snapshot().timeout(
        const Duration(seconds: 5),
      );
      if (!state.running ||
          !state.core.ready ||
          state.core.purpose != 'VPN' ||
          state.core.generation != core.generation ||
          state.core.configId != core.configId ||
          state.core.revision != core.revision) {
        return {
          'success': false,
          'connectionStatus': 'unconfirmed',
          'message': messages.sessionChangedNoDisconnect,
        };
      }
      final status = await platform
          .closeConnection(core, id)
          .timeout(const Duration(seconds: 5));
      if (status != 'closed' && status != 'absent' && status != 'failed') {
        throw const FormatException('Invalid close result');
      }
      return {
        'success': status != 'failed',
        'connectionStatus': status,
        'message': switch (status) {
          'closed' => messages.connectionClosed,
          'absent' => messages.connectionInactive,
          _ => messages.disconnectFailedShort,
        },
      };
    } catch (_) {
      return {
        'success': false,
        'connectionStatus': 'unconfirmed',
        'message': messages.disconnectUnconfirmedShort,
      };
    }
  }
}
