import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_choice.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_snapshot.dart';

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
  composition: '["one",1]',
);
const vpnCore = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
  composition: '["one",1]',
);

StrategySnapshot strategyData({
  String now = 'A',
  String currentIdentity = '',
  String fixed = '',
  CoreSnapshot core = previewCore,
  bool globalReferenced = false,
  TunnelMode? mode = TunnelMode.rule,
}) => StrategySnapshot(
  generation: core.generation,
  configId: core.configId!,
  revision: core.revision!,
  purpose: core.purpose!,
  composition: core.composition,
  mode: mode,
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
        currentIdentity: currentIdentity,
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
  TunnelMode? previewMode;
  int reads = 0;
  bool failRead = false;
  bool failApply = false;
  bool mismatch = false;
  Completer<StrategySnapshot>? pendingRead;
  Future<void> Function()? beforeApply;

  final delayStarts = <Map<String, Object?>>[];
  final delayCancels = <String>[];
  int delayReads = 0;
  bool failDelayStart = false;
  Map<String, Object?>? delayBatch;

  @override
  Future<Map<String, dynamic>> startDelayTest(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    if (failDelayStart) throw StateError('delay start failed');
    delayStarts.add(Map.of(query));
    final names =
        (query['members'] as List?)?.cast<String>() ??
        (data.groups
            .firstWhere((group) => group.name == query['group'])
            .members
            .map((member) => member.name)
            .toList());
    delayReads = 0;
    delayBatch = {
      'id': 'batch-${delayStarts.length}',
      'group': query['group'],
      'state': 'running',
      'target': 'https://www.gstatic.com/generate_204',
      'members': [
        for (final name in names)
          {'name': name, 'type': 'Socks5', 'status': 'running'},
      ],
    };
    return {
      'start': delayBatch,
      'generation': core.generation,
      'composition': core.composition,
    };
  }

  void finishDelay(Map<String, (String, int?)> results) {
    final batch = delayBatch!;
    batch['state'] = 'done';
    batch['members'] = [
      for (final row in batch['members'] as List)
        {
          'name': (row as Map)['name'],
          'type': row['type'],
          'status': results[row['name']]!.$1,
          if (results[row['name']]!.$2 != null)
            'delay': results[row['name']]!.$2,
        },
    ];
  }

  @override
  Future<Map<String, dynamic>> delayTest(
    CoreSnapshot core,
    String batch,
  ) async {
    delayReads++;
    return {
      'batch': delayBatch,
      'generation': core.generation,
      'composition': core.composition,
    };
  }

  @override
  Future<void> cancelDelayTest(String batch) async => delayCancels.add(batch);

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
        mode: data.mode,
        now: choice.member ?? 'A',
        fixed: choice.type.automatic ? choice.member ?? '' : '',
      );
    }
  }

  @override
  Future<void> prepareStrategies({
    required String id,
    required int revision,
    required TunnelMode? mode,
  }) async {
    events.add('prepare:$id:$revision');
    if (input != null) {
      loaded = jsonDecode(await input!.readAsString()) as Map<String, dynamic>;
      if (loaded['id'] != id ||
          loaded['revision'] != revision ||
          loaded['mode'] != mode?.name) {
        throw StateError('Prepared preview input changed');
      }
      final core = CoreSnapshot(
        generation: state.core.generation + 1,
        phase: 'READY',
        purpose: 'PREVIEW',
        configId: id,
        revision: revision,
        composition: loaded['composition'] as String,
      );
      state = AppSnapshot(phase: 'STOPPED', core: core);
      data = strategyData(
        core: core,
        mode: previewMode ?? mode ?? TunnelMode.rule,
      );
    }
  }

  @override
  Future<void> releasePreview() async {
    events.add('release-preview');
    if (input != null) {
      loaded = {};
      state = const AppSnapshot(phase: 'STOPPED');
    }
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
