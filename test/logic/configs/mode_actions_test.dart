import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_actions.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/config_action_fakes.dart';

class _ModeReceiptPlatform extends PlatformFake {
  CoreSnapshot? modeTarget;
  void Function()? afterMode;

  void loadActual(ConfigEntry entry, {required bool vpn}) {
    load(
      entry,
      mode: TunnelMode.rule,
      parts: [
        if (!vpn)
          const OverrideEntry(
            id: 'lan',
            name: 'LAN',
            kind: ConfigKind.local,
            role: OverrideRole.lanProxy,
            revision: 1,
            body: 'listeners: []',
            enabled: true,
          ),
      ],
    );
    loaded.addAll({
      'inputId': 'initial-input',
      'vpnIntent': vpn,
      'lanIntent': !vpn,
    });
    _project();
  }

  void _project() {
    state = AppSnapshot(
      phase: loaded['vpnIntent'] == true ? 'RUNNING' : 'STOPPED',
      vpnIntent: loaded['vpnIntent'] == true,
      lanIntent: loaded['lanIntent'] == true,
      lanRunning: loaded['lanIntent'] == true,
      generation: state.generation,
      configId: state.core.configId,
      revision: state.core.revision,
      storageEpoch: 23,
      mode: state.mode,
      core: CoreSnapshot(
        processId: 'process-${state.core.generation}',
        inputId: loaded['inputId'] as String,
        generation: state.core.generation,
        phase: 'READY',
        purpose: 'RUNNING',
        configId: state.core.configId,
        revision: state.core.revision,
        composition: state.core.composition,
      ),
    );
  }

  @override
  Future<StrategySnapshot> strategies(CoreSnapshot coreIdentity) async =>
      StrategySnapshot(
        processId: coreIdentity.processId,
        inputId: coreIdentity.inputId,
        generation: coreIdentity.generation,
        configId: coreIdentity.configId!,
        revision: coreIdentity.revision!,
        composition: coreIdentity.composition!,
        purpose: coreIdentity.purpose!,
        globalReferenced: false,
        unrestored: const {},
        groups: const [],
      );

  @override
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode? mode,
    bool explicitStart = true,
    String? path,
  }) async {
    await super.start(
      id: id,
      revision: revision,
      mode: mode,
      explicitStart: explicitStart,
      path: path,
    );
    _project();
  }

  @override
  Future<TunnelMode> setMode(TunnelMode mode, CoreSnapshot coreIdentity) async {
    modeTarget = coreIdentity;
    events.add('mode:${mode.name}');
    if (failMode) throw PlatformFailure(code: 'mode');
    afterMode?.call();
    return mode;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ConfigStore store;
  late PlatformFake platform;
  late ConfigActions actions;
  const entry = ConfigEntry(
    id: 'one',
    name: 'one',
    source: 'https://example.test/one',
    revision: 1,
    body: 'mode: direct\nrules:\n  - MATCH,DIRECT\n',
  );
  const other = ConfigEntry(
    id: 'two',
    name: 'two',
    source: 'https://example.test/two',
    revision: 1,
    body: 'mode: direct\nrules:\n  - MATCH,DIRECT\n',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-mode-');
    store = ConfigStore(directory);
    platform = PlatformFake()..input = File('${directory.path}/run.yaml');
    actions = ConfigActions(
      store,
      DownloadFake(),
      platform,
      File('${directory.path}/run.yaml'),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'saved mode receipt identifies storage without inventing a runtime target',
    () async {
      platform.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 23);
      await actions.execute({'action': 'setMode', 'mode': 'global'});
      expect((await store.read()).mode, TunnelMode.global);
      expect(actions.result['modeResult'], {
        'status': 'saved',
        'mode': 'global',
        'storageEpoch': 23,
      });
      expect(platform.events, isEmpty);
    },
  );

  for (final vpn in [false, true]) {
    test(
      'hot mode receipt retains its native target across a later core replacement vpn=$vpn',
      () async {
        final bridge = _ModeReceiptPlatform()
          ..input = File('${directory.path}/receipt.input');
        bridge.loadActual(entry, vpn: vpn);
        final target = bridge.state.core;
        bridge.afterMode = () => bridge.loadActual(other, vpn: vpn);
        final action = ConfigActions(
          store,
          DownloadFake(),
          bridge,
          bridge.input!,
        );
        await action.execute({'action': 'setMode', 'mode': 'global'});
        expect(bridge.modeTarget!.identity, target.identity);
        expect(bridge.state.core.identity, isNot(target.identity));
        expect(action.result['modeResult'], {
          'status': 'applied',
          'mode': 'global',
          'storageEpoch': 23,
          ...target.wireIdentity,
        });
        expect((await store.read()).mode, TunnelMode.global);
        expect(bridge.events, ['mode:global']);
      },
    );

    test(
      'mode reconnect receipt names its newly prepared input vpn=$vpn',
      () async {
        await store.save(
          ConfigCollection(entries: [entry], selectedId: entry.id),
        );
        await PreferencesStore(directory)
            .save(const AppPreferences(reconnectOnRoutingChange: true));
        final bridge = _ModeReceiptPlatform()
          ..input = File('${directory.path}/receipt.input');
        bridge.loadActual(entry, vpn: vpn);
        final previous = bridge.state.core;
        final action = ConfigActions(
          store,
          DownloadFake(),
          bridge,
          bridge.input!,
        );
        await action.execute({'action': 'setMode', 'mode': 'global'});
        final target = bridge.state.core;
        expect(target.processId, isNot(previous.processId));
        expect(target.inputId, isNot(previous.inputId));
        expect(target.inputId, bridge.loaded['inputId']);
        expect(bridge.state.running, vpn);
        expect(bridge.state.lanRunning, !vpn);
        expect(bridge.loaded['body'], entry.body);
        expect(bridge.loaded['routingOverride'], 'global');
        expect(bridge.events, ['stop', 'start:one']);
        expect(action.result['modeResult'], {
          'status': 'applied',
          'mode': 'global',
          'storageEpoch': 23,
          ...target.wireIdentity,
        });
        final receipt = action.result['modeResult'];
        bridge.loadActual(other, vpn: vpn);
        expect(action.result['modeResult'], receipt);
        expect((action.result['modeResult'] as Map)['inputId'], target.inputId);
        expect(await bridge.input!.exists(), isFalse);
      },
    );
  }

  test(
    'failed mode publication cannot retain an earlier applied receipt',
    () async {
      final bridge = _ModeReceiptPlatform()
        ..input = File('${directory.path}/receipt.input');
      bridge.loadActual(entry, vpn: true);
      final action = ConfigActions(
        store,
        DownloadFake(),
        bridge,
        bridge.input!,
      );
      await action.execute({'action': 'setMode', 'mode': 'global'});
      expect(action.result['modeResult'], isNotNull);
      bridge.failMode = true;
      await expectLater(
        action.execute({'action': 'setMode', 'mode': 'direct'}),
        throwsA(isA<ConfigFailure>()),
      );
      expect(action.result['modeResult'], isNull);
      expect(action.result['configStatus'], 'applyFailed');
      expect((await store.read()).mode, TunnelMode.direct);
    },
  );

  test('stage failure after save reports partial completion without changing native', () async {
    platform.load(entry, mode: TunnelMode.rule);
    platform.failModeStage = true;
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'direct'}),
      throwsA(
        isA<ConfigFailure>()
            .having(
              (failure) => failure.message.id,
              'message',
              'modeNotConfirmed',
            )
            .having(
              (failure) => failure.message.detail,
              'original error',
              contains('stage'),
            ),
      ),
    );
    expect(actions.result['configStatus'], 'applyFailed');
    expect(actions.result['success'], isFalse);
    expect((await store.read()).mode, TunnelMode.direct);
    expect(platform.events, isEmpty);
    expect(platform.state.mode, TunnelMode.rule);
  });

  test(
    'missing and invalid saved mode fallback are rejected without rewriting',
    () async {
      final file = File('${directory.path}/configurations.json');
      final data = {'version': 2, 'entries': <Object>[], 'selectedId': null};
      await file.writeAsString(jsonEncode(data));
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
      expect(await file.readAsString(), jsonEncode(data));
      for (final invalid in ['follow', 0, true]) {
        final body = jsonEncode({...data, 'mode': invalid});
        await file.writeAsString(body);
        await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
        expect(await file.readAsString(), body);
      }
    },
  );

  test('stopped selection without configs persists all three modes without starting', () async {
    for (final mode in TunnelMode.values) {
      await actions.execute({'action': 'setMode', 'mode': mode.name});
      expect((await ConfigStore(directory).read()).mode, mode);
    }
    expect(platform.events, isEmpty);
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'follow'}),
      throwsFormatException,
    );
    expect((await store.read()).mode, TunnelMode.direct);
  });

  test(
    'running save precedes apply; failed apply retains preference not actual',
    () async {
      platform.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 7,
        mode: TunnelMode.rule,
        core: CoreSnapshot(
          generation: 7,
          phase: 'READY',
          purpose: 'RUNNING',
          configId: 'one',
          revision: 1,
          composition: '["one",1]',
        ),
      );
      platform.failMode = true;
      await expectLater(
        actions.execute({'action': 'setMode', 'mode': 'global'}),
        throwsA(
          isA<ConfigFailure>()
              .having(
                (failure) => failure.message.id,
                'message',
                'modeNotConfirmed',
              )
              .having(
                (failure) => failure.message.detail,
                'original error',
                contains('mode'),
              ),
        ),
      );
      expect(actions.result['configStatus'], 'applyFailed');
      expect(actions.result['success'], isFalse);
      expect((await store.read()).mode, TunnelMode.global);
      expect(platform.state.mode, TunnelMode.rule);
      expect(platform.events, ['mode:global:7']);
      platform.failMode = false;
      await actions.execute({'action': 'setMode', 'mode': 'global'});
      expect(platform.state.mode, TunnelMode.global);
      final count = platform.events.length;
      await actions.execute({'action': 'setMode', 'mode': 'global'});
      expect(platform.events.length, count);
    },
  );

  test('failed save and unknown phase never change native mode', () async {
    await store.save(ConfigCollection(entries: []));
    await Directory('${directory.path}/configurations.json.tmp').create();
    platform.state = const AppSnapshot(phase: 'RUNNING', mode: TunnelMode.rule);
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'global'}),
      throwsA(isA<ConfigFailure>()),
    );
    expect((await store.read()).mode, isNull);
    platform.state = const AppSnapshot();
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'global'}),
      throwsA(isA<ConfigFailure>()),
    );
    expect(platform.events, isEmpty);
  });

  for (final throwsSnapshot in [false, true]) {
    test(
      'saved fallback survives unconfirmed native status throw=$throwsSnapshot',
      () async {
        const raw = 'https://user:password@fixture.test?token=原文🙂';
        platform.state = const AppSnapshot(
          error: AppMessage('operationFailed', detail: raw),
        );
        if (throwsSnapshot) platform.snapshotError = raw;
        await expectLater(
          actions.execute({'action': 'setMode', 'mode': 'global'}),
          throwsA(
            isA<ConfigFailure>()
                .having(
                  (failure) => failure.message.id,
                  'saved result',
                  'modeNotConfirmed',
                )
                .having(
                  (failure) => failure.message.detail,
                  'original error',
                  contains(raw),
                ),
          ),
        );
        expect((await store.read()).mode, TunnelMode.global);
        expect(actions.result['configStatus'], 'applyFailed');
        expect(actions.result['success'], isFalse);
        expect(platform.events, isEmpty);
        platform.snapshotError = null;
        platform.state = const AppSnapshot(phase: 'STOPPED');
        await actions.execute({'action': 'setMode', 'mode': 'global'});
        expect((await store.read()).mode, TunnelMode.global);
        expect(actions.result['configStatus'], 'saved');
        expect(platform.events, isEmpty);
      },
    );
  }

  test('ordinary start and selection transmit saved fallback without overriding source YAML', () async {
    await store.save(
      ConfigCollection(
        entries: [entry, other],
        selectedId: entry.id,
        mode: TunnelMode.global,
      ),
    );
    await actions.execute({'action': 'start'});
    expect(platform.loaded['mode'], 'global');
    expect(platform.loaded['routingOverride'], isNull);
    expect((await store.read()).selected!.body, entry.body);
    expect(platform.loaded['body'], entry.body);
    await actions.execute({'action': 'select', 'id': other.id});
    expect(platform.loaded['body'], other.body);
    expect(platform.loaded['mode'], 'global');
    expect(platform.loaded['routingOverride'], isNull);
    await actions.execute({
      'action': 'import',
      'id': other.id,
      'source': other.source,
      'replace': true,
    });
    expect(platform.loaded['mode'], 'global');
    expect(platform.loaded['routingOverride'], isNull);
    await actions.execute({
      'action': 'import',
      'source': 'https://example.test/new',
    });
    expect((await store.read()).mode, TunnelMode.global);
    await actions.execute({'action': 'delete', 'id': entry.id});
    expect((await store.read()).mode, TunnelMode.global);
    await actions.execute({'action': 'stop'});
    await actions.execute({'action': 'start'});
    expect(platform.loaded['mode'], 'global');
    expect(platform.loaded['routingOverride'], isNull);
  });

  test('mode bridge preserves explicit null fallback across both start entry points', () async {
    final calls = <(String, Map)>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      calls.add((call.method, call.arguments as Map));
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(AppBridge.channel, null),
    );
    final bridge = AppBridge(operationId: 'nullable-mode');
    await bridge.start(id: entry.id, revision: entry.revision, mode: null);
    await bridge.prepareStrategies(
      id: entry.id,
      revision: entry.revision,
      mode: null,
    );
    expect(calls.map((call) => call.$1), ['start', 'prepareStrategies']);
    for (final (_, arguments) in calls) {
      expect(arguments.containsKey('mode'), isTrue);
      expect(arguments['mode'], isNull);
      expect(arguments['owner'], 'nullable-mode');
      expect(arguments['id'], entry.id);
      expect(arguments['revision'], entry.revision);
    }
  });

  test('unselected mode is persisted as explicit null, not an implicit rule choice', () async {
    expect((await store.read()).mode, isNull);
    await store.save(ConfigCollection(entries: [entry], selectedId: entry.id));
    final data = jsonDecode(
      await File('${directory.path}/configurations.json').readAsString(),
    ) as Map;
    expect(data.containsKey('mode'), isTrue);
    expect(data['mode'], isNull);
    expect((await ConfigStore(directory).read()).mode, isNull);
    await actions.execute({'action': 'start'});
    expect(platform.loaded.containsKey('mode'), isTrue);
    expect(platform.loaded['mode'], isNull);
    expect(platform.loaded['routingOverride'], isNull);
    expect(platform.loaded['body'], entry.body);
  });

  test('Always-on input carries nullable saved fallback, never an implicit routing override', () async {
    final file = File('${directory.path}/system.input');
    final system = ConfigActions(
      store,
      DownloadFake(),
      platform,
      File('${directory.path}/run.input'),
      systemInput: file,
    );
    for (final fallback in <TunnelMode?>[null, TunnelMode.global]) {
      await store.save(
        ConfigCollection(
          entries: [entry],
          selectedId: entry.id,
          mode: fallback,
        ),
      );
      platform.state = const AppSnapshot(phase: 'STOPPED');
      await system.execute({'action': 'systemStart'});
      final input = jsonDecode(await file.readAsString()) as Map;
      expect(input['mode'], fallback?.name);
      expect(input['routingOverride'], isNull);
      expect(input['body'], entry.body);
      expect(platform.loaded['mode'], fallback?.name);
      expect(platform.loaded['routingOverride'], isNull);
      expect(platform.loaded['body'], entry.body);
      expect(system.result['configStatus'], 'applied');
      expect(platform.events.last, 'start:one');
    }
  });

  test('explicit reconnect mode action sends current routing override with saved fallback', () async {
    await store.save(ConfigCollection(entries: [entry], selectedId: entry.id));
    platform.load(entry, mode: TunnelMode.global);
    await PreferencesStore(directory)
        .save(const AppPreferences(reconnectOnRoutingChange: true));
    await actions.execute({'action': 'setMode', 'mode': 'rule'});
    expect((await store.read()).mode, TunnelMode.rule);
    expect(platform.loaded['mode'], 'rule');
    expect(platform.loaded['routingOverride'], 'rule');
    expect(platform.loaded['body'], entry.body);
    expect(platform.state.mode, TunnelMode.rule);
    expect(platform.events, ['stop', 'start:one']);
  });

  test('native invalid or missing mode preserves running phase and permits independent recovery', () {
    for (final value in [null, 'unknown', 3]) {
      final state = AppSnapshot.fromMap({'phase': 'RUNNING', 'mode': value});
      expect(state.running, isTrue);
      expect(state.mode, isNull);
      expect(state.modeError, isNotNull);
    }
    final stopped = AppSnapshot.fromMap({'phase': 'STOPPED', 'mode': 'global'});
    expect(stopped.mode, isNull);
    expect(stopped.modeError, isNull);
    expect(
      AppSnapshot.fromMap({'phase': 'RUNNING', 'mode': 'direct'}).mode,
      TunnelMode.direct,
    );
  });
}
