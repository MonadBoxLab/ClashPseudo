import 'dart:async';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/features/strategies/strategy_choice.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';

import '../configs/action_fakes.dart';

const strategyEntry = ConfigEntry(
  id: 'one',
  name: '策略配置',
  source: 'https://example.test/one',
  revision: 1,
  body: 'rules:\n  - MATCH,DIRECT\n',
);
const previewCore = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'PREVIEW',
  configId: 'one',
  revision: 1,
);
const vpnCore = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
);

StrategySnapshot strategyData({
  String now = 'A',
  String fixed = '',
  CoreSnapshot core = previewCore,
  bool globalReferenced = false,
}) => StrategySnapshot(
  generation: core.generation,
  configId: core.configId!,
  revision: core.revision!,
  purpose: core.purpose!,
  globalReferenced: globalReferenced,
  unrestored: {},
  groups: [
    for (final (name, type, hidden) in [
      ('出口', 'select', false),
      ('自动', 'url-test', false),
      ('故障转移', 'fallback', false),
      ('均衡', 'load-balance', false),
      ('隐藏', 'select', true),
      ('GLOBAL', 'select', false),
    ])
      StrategyGroup(
        name: name,
        rawType: type,
        hidden: hidden,
        now: type == 'load-balance' ? '' : now,
        fixed: const ['url-test', 'fallback'].contains(type) ? fixed : '',
        members: const [
          StrategyMember(name: 'A', type: 'Socks5'),
          StrategyMember(name: 'B', type: 'Direct'),
        ],
      ),
  ],
);

class StrategyBridgeFake extends PlatformFake {
  StrategyBridgeFake() {
    state = const AppSnapshot(phase: 'STOPPED', core: previewCore);
  }
  StrategySnapshot data = strategyData();
  int reads = 0;
  bool failRead = false;
  bool failApply = false;
  bool mismatch = false;
  Completer<StrategySnapshot>? pendingRead;
  Future<void> Function()? beforeApply;

  @override
  Future<StrategySnapshot> strategies(int generation) async {
    reads++;
    if (failRead || generation != data.generation) {
      throw StateError('read failed');
    }
    return pendingRead == null ? data : pendingRead!.future;
  }

  @override
  Future<void> setStrategy(
    int generation,
    String name,
    StrategyChoice choice,
  ) async {
    await beforeApply?.call();
    events.add('strategy:$name:${choice.member}');
    if (failApply) throw StateError('apply failed');
    if (!mismatch) {
      data = strategyData(
        core: state.core,
        now: choice.member ?? 'A',
        fixed: choice.type.automatic ? choice.member ?? '' : '',
      );
    }
  }

  @override
  Future<void> prepareStrategies({
    required String id,
    required int revision,
    required TunnelMode mode,
  }) async {
    events.add('prepare:$id:$revision');
  }

  @override
  Future<void> releasePreview() async {
    events.add('release-preview');
  }
}

class StrategyAppFake extends AppController {
  StrategyAppFake(StrategyBridgeFake bridge) : super(bridge) {
    loading = false;
    configsLoaded = true;
    state = bridge.state;
    collection = ConfigCollection(entries: [strategyEntry], selectedId: 'one');
  }
  final commands = <Map<String, Object?>>[];
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    lastCommandAutomatic = automatic;
    commands.add(command);
    lastCommand = command;
    return 'operation-${commands.length}';
  }

  @override
  Future<void> refresh() async {
    notifyListeners();
  }

  void changed() => notifyListeners();
}
