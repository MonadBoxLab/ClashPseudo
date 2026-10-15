import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/features/configs/config_actions.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/features/strategies/strategy_actions.dart';
import 'package:clash_pseudo/features/strategies/strategy_choice.dart';
import 'package:clash_pseudo/platform/core_input.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configs/action_fakes.dart';
import 'strategy_fakes.dart';

void main() {
  late Directory directory;
  late ConfigStore store;
  late StrategyBridgeFake bridge;
  late StrategyActions actions;
  Map<String, dynamic> command({
    String name = '出口',
    String? member = 'B',
    String type = 'select',
    int generation = 7,
  }) => {
    'id': 'one',
    'revision': 1,
    'generation': generation,
    'name': name,
    'choice': {'type': type, 'member': member},
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-strategies-');
    store = ConfigStore(directory);
    await store.save(
      ConfigCollection(entries: [strategyEntry], selectedId: 'one'),
    );
    bridge = StrategyBridgeFake();
    actions = StrategyActions(store, bridge);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'selection is saved before apply without changing body or revision',
    () async {
      bridge.beforeApply = () async {
        final entry = (await store.read()).selected!;
        expect(entry.choices['出口']!.member, 'B');
        expect(entry.body, strategyEntry.body);
        expect(entry.revision, 1);
      };
      expect(await actions.execute(command()), '');
      expect(bridge.events, ['strategy:出口:B']);
      expect(bridge.data.find('出口')!.now, 'B');
    },
  );

  test('failed save never mutates native selection', () async {
    await Directory('${directory.path}/configurations.json.tmp').create();
    await expectLater(
      actions.execute(command()),
      throwsA(isA<ConfigFailure>()),
    );
    expect(bridge.events, isEmpty);
    expect((await store.read()).selected!.choices, isEmpty);
  });

  test(
    'failed apply and mismatched confirmation retain saved intent',
    () async {
      bridge.failApply = true;
      await expectLater(
        actions.execute(command()),
        throwsA(
          isA<ConfigFailure>().having(
            (e) => e.message,
            'message',
            contains('已保存'),
          ),
        ),
      );
      expect((await store.read()).selected!.choices['出口']!.member, 'B');
      expect(bridge.data.find('出口')!.now, 'A');
      bridge.failApply = false;
      bridge.mismatch = true;
      await expectLater(
        actions.execute(command()),
        throwsA(
          isA<ConfigFailure>().having(
            (e) => e.message,
            'message',
            contains('未确认'),
          ),
        ),
      );
      expect(bridge.events, ['strategy:出口:B', 'strategy:出口:B']);
    },
  );

  test(
    'invalid or expired clicks cannot save a choice into another context',
    () async {
      for (final request in [
        command(generation: 6),
        command(member: 'missing'),
        command(name: '均衡'),
        command(name: '自动'),
        command(name: 'missing'),
      ]) {
        await expectLater(
          actions.execute(request),
          throwsA(isA<ConfigFailure>()),
        );
      }
      expect(bridge.events, isEmpty);
      expect((await store.read()).selected!.choices, isEmpty);
    },
  );

  test('automatic groups retain explicit restore-auto intent', () async {
    await actions.execute(command(name: '自动', type: 'url-test'));
    expect((await store.read()).selected!.choices['自动']!.member, 'B');
    await actions.execute(command(name: '自动', type: 'url-test', member: null));
    final entry = (await store.read()).selected!;
    expect(entry.choices.containsKey('自动'), isTrue);
    expect(entry.choices['自动']!.member, isNull);
    expect(bridge.data.find('自动')!.fixed, '');
  });

  test(
    'run input preserves original text and carries scoped choices',
    () async {
      final file = File('${directory.path}/work/input.json');
      final entry = strategyEntry.withChoice(
        '出口',
        const StrategyChoice(type: StrategyType.select, member: '节点🌐'),
      );
      final input = CoreInput(file);
      await input.write(entry, TunnelMode.global);
      final value = jsonDecode(await file.readAsString()) as Map;
      expect(value['body'], strategyEntry.body);
      expect(value['id'], strategyEntry.id);
      expect(value['revision'], 1);
      expect(value['mode'], 'global');
      expect(value['choices'], {
        '出口': {'type': 'select', 'member': '节点🌐'},
      });
      await input.clear();
      expect(await file.exists(), isFalse);
    },
  );

  test('preview preparation does not authorize or start VPN', () async {
    final input = File('${directory.path}/work/input.json');
    final configs = ConfigActions(store, DownloadFake(), bridge, input);
    await configs.execute({
      'action': 'prepareStrategies',
      'id': 'one',
      'revision': 1,
    });
    expect(bridge.events, ['prepare:one:1']);
    expect(await input.exists(), isFalse);
    await expectLater(
      configs.execute({
        'action': 'prepareStrategies',
        'id': 'old',
        'revision': 1,
      }),
      throwsA(isA<ConfigFailure>()),
    );
    expect(bridge.events, ['prepare:one:1']);
  });

  test(
    'failed current update retires preview while preserving saved choice',
    () async {
      final entry = strategyEntry.withChoice(
        '出口',
        const StrategyChoice(type: StrategyType.select, member: 'B'),
      );
      await store.save(ConfigCollection(entries: [entry], selectedId: 'one'));
      final download = DownloadFake()..fail = true;
      final configs = ConfigActions(
        store,
        download,
        bridge,
        File('${directory.path}/input.json'),
      );
      await expectLater(
        configs.execute({
          'action': 'import',
          'source': entry.source,
          'replace': true,
        }),
        throwsA(isA<ConfigFailure>()),
      );
      final saved = (await store.read()).selected!;
      expect(saved.body, isNull);
      expect(saved.choices['出口']!.member, 'B');
      expect(bridge.events, ['release-preview']);
    },
  );
}
