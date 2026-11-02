import 'package:clash_pseudo/src/model/core_snapshot.dart';

import '../../model/app_platform.dart';
import '../../model/messages.dart';
import '../../model/platform_failure.dart';

class ConnectionActions {
  ConnectionActions(this.platform);
  final AppPlatform platform;

  Future<Map<String, Object?>> execute(Map<String, dynamic> command) async {
    final core = CoreSnapshot(
      processId: command['processId'] as String?,
      inputId: command['inputId'] as String?,
      networkRevision: command['networkRevision'] as int? ?? 0,
      generation: command['generation'] as int,
      phase: 'READY',
      purpose: command['purpose'] as String?,
      configId: command['configId'] as String,
      revision: command['revision'] as int,
      composition: command['composition'] as String?,
    );
    final id = command['connectionId'] as String;
    try {
      // A UI/operation deadline may revoke new work, not settle a submitted
      // native Future. Keep the runtime writer until the actual reply drains.
      final state = await platform.snapshot();
      if (!state.forwarding ||
          !state.core.ready ||
          core.purpose != 'RUNNING' ||
          core.composition == null ||
          !state.core.matchesIdentity(core) ||
          state.core.networkRevision != core.networkRevision) {
        return {
          'success': false,
          'connectionStatus': 'unconfirmed',
          'message': messages.sessionChangedNoDisconnect,
        };
      }
      final status = await platform.closeConnection(core, id);
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
    } catch (failure, stack) {
      return {
        'failure': failureValue(failure, stack),
        'success': false,
        'connectionStatus': 'unconfirmed',
        'message': messages.disconnectUnconfirmedShort.withDetail(failure),
      };
    }
  }
}
