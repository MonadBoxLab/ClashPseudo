import '../../platform/app_bridge.dart';
import '../strategies/strategy_snapshot.dart';

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
          'message': '会话已变化，未执行断开。',
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
          'closed' => '已断开',
          'absent' => '已不活跃',
          _ => '断开失败',
        },
      };
    } catch (_) {
      return {
        'success': false,
        'connectionStatus': 'unconfirmed',
        'message': '断开结果未确认',
      };
    }
  }
}
