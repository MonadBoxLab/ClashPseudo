import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_actions.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/logic/configs/strategy_actions.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:clash_pseudo/src/platform/core/core_input.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/config_action_fakes.dart';
import '../../support/strategy_fakes.dart';

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
    'composition': bridge.state.core.composition,
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
    actions = StrategyActions(
      store,
      bridge,
      runInput: File('${directory.path}/owned.input'),
    );
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
      expect(await actions.execute(command()), isNull);
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
            (e) => e.message.id,
            'message id',
            messages.strategySelectionUnconfirmed.id,
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
            (e) => e.message.id,
            'message id',
            messages.strategySelectionUnconfirmed.id,
          ),
        ),
      );
      expect(bridge.events, ['strategy:出口:B', 'strategy:出口:B']);
    },
  );

  test(
    'strategy confirmation retains the real Future after the UI deadline',
    () async {
      final confirmation = Completer<StrategySnapshot>();
      final applied = Completer<void>();
      bridge.beforeApply = () async {
        bridge.pendingRead = confirmation;
        applied.complete();
      };
      var settled = false;
      Object? failure;
      final result = actions
          .execute(command())
          .then<void>(
            (_) => settled = true,
            onError: (Object error) {
              failure = error;
              settled = true;
            },
          );
      await applied.future;
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(settled, isFalse);
      expect((await store.read()).selected!.choices['出口']!.member, 'B');
      confirmation.complete(bridge.data);
      await result;
      expect(failure, isNull);
      expect(settled, isTrue);
      expect(bridge.events, ['strategy:出口:B']);
    },
  );

  test(
    'strategy apply retains the original platform detail after saving intent',
    () async {
      const detail = 'native cause 原文\nSuppressed: cleanup 原文';
      bridge.beforeApply = () async => throw PlatformException(
        code: 'actual-fixture',
        message: 'native apply 原文',
        details: detail,
      );
      await expectLater(
        actions.execute(command()),
        throwsA(
          isA<ConfigFailure>()
              .having(
                (error) => error.message.id,
                'id',
                messages.strategySelectionUnconfirmed.id,
              )
              .having(
                (error) => error.message.detail,
                'detail',
                allOf(contains('native apply 原文'), contains(detail)),
              ),
        ),
      );
      expect((await store.read()).selected!.choices['出口']!.member, 'B');
      expect(bridge.data.find('出口')!.now, 'A');
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

  test(
    'explicit composition is mandatory and stale compositions cannot save',
    () async {
      for (final request in [
        command()..remove('composition'),
        {...command(), 'composition': 'stale'},
      ]) {
        await expectLater(
          actions.execute(request),
          throwsA(isA<ConfigFailure>()),
        );
      }
      expect((await store.read()).selected!.choices, isEmpty);
      expect(bridge.events, isEmpty);
    },
  );

  test(
    'running actual groups remain authoritative over pending main definitions',
    () async {
      bridge.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
        mode: TunnelMode.rule,
        core: vpnCore,
      );
      bridge.data = strategyData(core: vpnCore);
      final pending = strategyEntry.withContent(
        'proxy-groups: [{name: 出口, type: load-balance, proxies: [Other]}]',
      );
      await store.save(ConfigCollection(entries: [pending], selectedId: 'one'));
      await actions.execute(command());
      final saved = (await store.read()).selected!;
      expect(saved.revision, pending.revision);
      expect(saved.body, pending.body);
      expect(saved.choices['出口']!.member, 'B');
      expect(bridge.events, ['strategy:出口:B']);
      await expectLater(
        actions.execute(command(member: 'Other')),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await store.read()).selected!.choices['出口']!.member, 'B');
    },
  );

  test(
    'preview pending revision and deleted running targets remain rejected',
    () async {
      await store.save(
        ConfigCollection(
          entries: [strategyEntry.withContent('pending')],
          selectedId: 'one',
        ),
      );
      await expectLater(
        actions.execute(command()),
        throwsA(isA<ConfigFailure>()),
      );
      bridge.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
        mode: TunnelMode.rule,
        core: vpnCore,
      );
      bridge.data = strategyData(core: vpnCore);
      await store.save(ConfigCollection(entries: [], selectedId: null));
      await expectLater(
        actions.execute(command()),
        throwsA(isA<ConfigFailure>()),
      );
      expect(bridge.events, isEmpty);
    },
  );

  test(
    'reconnect setting does not turn preview selection into a VPN start',
    () async {
      await PreferencesStore(directory)
          .save(const AppPreferences(reconnectOnRoutingChange: true));
      await actions.execute(command());
      expect(bridge.events, ['strategy:出口:B']);
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

  test('strategy snapshot actual mode is optional and never inferred from saved fallback', () {
    for (final value in <Object?>[
      'rule',
      'global',
      'direct',
      null,
      'invalid',
      3,
    ]) {
      final snapshot = StrategySnapshot.fromMap({
        'generation': previewCore.generation,
        'configId': previewCore.configId,
        'revision': previewCore.revision,
        'purpose': previewCore.purpose,
        'composition': previewCore.composition,
        'mode': value,
        'globalReferenced': false,
        'groups': [],
        'unrestored': [],
      });
      expect(snapshot.matches(previewCore), isTrue);
      expect(
        snapshot.mode,
        value is String && value != 'invalid'
            ? TunnelMode.parse(value)
            : isNull,
      );
    }
    final missing = StrategySnapshot.fromMap({
      'generation': previewCore.generation,
      'configId': previewCore.configId,
      'revision': previewCore.revision,
      'purpose': previewCore.purpose,
      'composition': previewCore.composition,
      'globalReferenced': false,
      'groups': [],
      'unrestored': [],
    });
    expect(missing.mode, isNull);
  });

  test('changed saved fallback refreshes an existing preview without forcing its actual YAML mode', () async {
    final entry = strategyEntry.withContent(
      'mode: direct\nrules: [MATCH,DIRECT]\n',
    );
    await store.save(ConfigCollection(entries: [entry], selectedId: entry.id));
    final file = File('${directory.path}/mode-preview.input');
    bridge.input = file;
    bridge.previewMode = TunnelMode.direct;
    final configs = ConfigActions(store, DownloadFake(), bridge, file);
    await configs.execute({
      'action': 'prepareStrategies',
      'id': entry.id,
      'revision': entry.revision,
    });
    final previous = bridge.state.core;
    bridge.events.clear();
    final message = await configs.execute({
      'action': 'setMode',
      'mode': 'global',
    });
    expect(message, messages.modeSavedNextStart);
    expect((await store.read()).mode, TunnelMode.global);
    expect(bridge.events, ['prepare:one:2']);
    expect(bridge.loaded['mode'], 'global');
    expect(bridge.loaded['routingOverride'], isNull);
    expect(bridge.loaded['body'], entry.body);
    expect(bridge.data.mode, TunnelMode.direct);
    expect(bridge.state.core.generation, greaterThan(previous.generation));
    expect(bridge.state.core.composition, previous.composition);
    expect(await file.exists(), isFalse);
    bridge.events.clear();
    await configs.execute({'action': 'setMode', 'mode': 'global'});
    expect(bridge.events, isEmpty);
  });

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
    'failed current update preserves actual preview input and saved choice',
    () async {
      final entry = strategyEntry.withChoice(
        '出口',
        const StrategyChoice(type: StrategyType.select, member: 'B'),
      );
      await store.save(ConfigCollection(entries: [entry], selectedId: 'one'));
      final file = File('${directory.path}/input.json');
      bridge.input = file;
      final download = DownloadFake()..fail = true;
      final configs = ConfigActions(store, download, bridge, file);
      await configs.execute({
        'action': 'prepareStrategies',
        'id': entry.id,
        'revision': entry.revision,
      });
      final prepared = jsonDecode(jsonEncode(bridge.loaded));
      final identity = bridge.state.core;
      expect(bridge.loaded['composition'], '["one",1]');
      expect(bridge.loaded['body'], entry.body);
      expect(bridge.loaded['mode'], isNull);
      bridge.events.clear();
      await expectLater(
        configs.execute({
          'action': 'import',
          'source': entry.source,
          'replace': true,
        }),
        throwsA(isA<ConfigFailure>()),
      );
      final saved = (await store.read()).selected!;
      expect(saved.toJson(), entry.toJson());
      expect(saved.choices['出口']!.member, 'B');
      expect(bridge.loaded, prepared);
      expect(bridge.state.core.matchesIdentity(identity), isTrue);
      expect(bridge.events, isEmpty);
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'only successfully changed preview content releases the actual lease',
    () async {
      final entry = strategyEntry.withChoice(
        '出口',
        const StrategyChoice(type: StrategyType.select, member: 'B'),
      );
      await store.save(
        ConfigCollection(entries: [entry], selectedId: entry.id),
      );
      final file = File('${directory.path}/preview.input');
      bridge.input = file;
      final download = DownloadFake()..body = entry.body;
      final configs = ConfigActions(store, download, bridge, file);
      await configs.execute({
        'action': 'prepareStrategies',
        'id': entry.id,
        'revision': entry.revision,
      });
      final identity = bridge.state.core;
      bridge.events.clear();
      await configs.execute({'action': 'updateConfig', 'id': entry.id});
      expect(bridge.events, isEmpty);
      expect(bridge.state.core.matchesIdentity(identity), isTrue);
      download.body = 'mode: global\nrules: [MATCH,DIRECT]\n';
      await configs.execute({'action': 'updateConfig', 'id': entry.id});
      expect(bridge.events, ['release-preview']);
      expect(bridge.state.core.purpose, isNull);
      expect(bridge.loaded, isEmpty);
      final saved = (await store.read()).selected!;
      expect(saved.body, download.body);
      expect(saved.revision, 2);
      expect(saved.choices['出口']!.member, 'B');
      expect(await file.exists(), isFalse);
    },
  );
}
