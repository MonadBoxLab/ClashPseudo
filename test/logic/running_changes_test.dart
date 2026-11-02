import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_actions.dart';
import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/logic/overrides/override_actions.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/logic/running_input.dart';
import 'package:clash_pseudo/src/platform/core/core_input.dart';
import 'package:clash_pseudo/src/logic/configs/strategy_actions.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _Download extends ConfigDownloader {
  bool fail = false;
  String body = 'dns: {enable: true}';
  @override
  Future<String> download(String source) async {
    if (fail) throw const ConfigFailure(AppMessage('downloadFailed'));
    return body;
  }
}

class _Platform extends AppBridge {
  _Platform(this.input);
  final File input;
  final events = <String>[];
  Map<String, dynamic>? started;
  bool failStart = false;
  bool expired = false;
  int _coreGeneration = 8;
  final loaded = <String, dynamic>{
    'vpnIntent': true,
    'lanIntent': false,
    'id': 'one',
    'name': 'Main',
    'revision': 1,
    'source': 'https://fixture.test/main',
    'body': 'rules: [MATCH,DIRECT]',
    'mode': 'rule',
    'overrides': <Map<String, dynamic>>[],
    'composition': '["one",1]',
    'access': 'only',
    'packages': ['fixture.loaded'],
    'choices': <String, dynamic>{
      'Proxy': <String, dynamic>{'type': 'select', 'member': 'A'},
    },
  };
  AppSnapshot state = const AppSnapshot(
    phase: 'RUNNING',
    generation: 4,
    configId: 'one',
    revision: 1,
    mode: TunnelMode.global,
    core: CoreSnapshot(
      generation: 8,
      phase: 'READY',
      purpose: 'RUNNING',
      configId: 'one',
      revision: 1,
      composition: '["one",1]',
    ),
  );
  void loadParts(List<OverrideEntry> parts) {
    loaded['overrides'] = [
      for (final part in parts)
        {
          'id': part.id,
          'name': part.name,
          'role': part.role?.name,
          'revision': part.revision,
          'source': part.source,
          'body': part.body,
          'mode': part.mode.name,
        },
    ];
    loaded['composition'] = jsonEncode([
      'one',
      1,
      for (final part in parts) [part.id, part.revision, part.mode.name],
    ]);
    state = AppSnapshot(
      phase: 'RUNNING',
      generation: 4,
      configId: 'one',
      revision: 1,
      mode: TunnelMode.global,
      core: CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'RUNNING',
        configId: 'one',
        revision: 1,
        composition: loaded['composition'] as String,
      ),
    );
  }

  void Function()? afterStop;
  String strategyRawType = 'select';
  bool mismatchChoice = false;
  bool mismatchAccess = false;
  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<void> stage(AppMessage message) async {}
  @override
  Future<void> checkOperation() async {
    if (expired) throw PlatformFailure(code: 'expired');
  }

  @override
  Future<Map<String, dynamic>?> runningRecord(CoreSnapshot core) async =>
      jsonDecode(jsonEncode(loaded)) as Map<String, dynamic>;
  @override
  Future<StrategySnapshot> strategies(CoreSnapshot coreIdentity) async =>
      StrategySnapshot(
        processId: coreIdentity.processId,
        inputId: coreIdentity.inputId,
        generation: coreIdentity.generation,
        configId: 'one',
        revision: 1,
        purpose: 'RUNNING',
        composition: loaded['composition'] as String,
        globalReferenced: false,
        unrestored: const {},
        groups: [
          StrategyGroup(
            name: 'Proxy',
            rawType: strategyRawType,
            hidden: false,
            now: (loaded['choices'] as Map)['Proxy']['member'] as String,
            fixed: '',
            members: const [
              StrategyMember(name: 'A', type: 'Direct'),
              StrategyMember(name: 'B', type: 'Direct'),
            ],
          ),
        ],
      );
  @override
  Future<bool> authorize() async {
    events.add('authorize');
    return true;
  }

  @override
  Future<void> stop({bool preserveLan = true}) async {
    events.add('stop');
    state = AppSnapshot(phase: 'STOPPED', generation: state.generation);
    afterStop?.call();
  }

  @override
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode? mode,
    bool explicitStart = true,
    String? path,
  }) async {
    events.add('start');
    if (failStart) throw PlatformFailure(code: 'start');
    started = jsonDecode(await input.readAsString()) as Map<String, dynamic>;
    loaded.addAll(started!);
    if (mismatchChoice) {
      loaded['choices'] = <String, dynamic>{
        'Proxy': <String, dynamic>{'type': 'select', 'member': 'A'},
      };
    }
    state = AppSnapshot(
      phase: 'RUNNING',
      generation: state.generation + 1,
      runningApplicationAccess: RunningApplicationAccess(
        generation: state.generation + 1,
        access: mismatchAccess
            ? ApplicationAccess.all
            : ApplicationAccess.values.byName(started!['access'] as String),
        packages: mismatchAccess
            ? []
            : (started!['packages'] as List).cast<String>(),
      ),
      configId: id,
      revision: revision,
      mode: started!['routingOverride'] == null
          ? mode ?? TunnelMode.rule
          : TunnelMode.parse(started!['routingOverride']),
      core: CoreSnapshot(
        inputId: started!['inputId'] as String,
        generation: ++_coreGeneration,
        phase: 'READY',
        purpose: 'RUNNING',
        configId: id,
        revision: revision,
        composition: started!['composition'] as String,
      ),
    );
  }

  @override
  Future<TunnelMode> setMode(TunnelMode mode, CoreSnapshot coreIdentity) async {
    events.add('mode:${mode.name}');
    return mode;
  }

  @override
  Future<void> setStrategy(
    CoreSnapshot coreIdentity,
    String name,
    StrategyChoice choice,
  ) async {
    events.add('strategy:${choice.member}');
    (loaded['choices'] as Map)[name] = choice.toJson();
  }

  @override
  Future<void> releasePreview() async => events.add('release');
  bool failSchedules = false;
  int scheduleCalls = 0;
  @override
  Future<void> syncSchedules(
    List<Map<String, Object?>> targets, {
    required String kind,
  }) async {
    scheduleCalls++;
    if (failSchedules) throw PlatformFailure(code: 'schedule');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File input;
  late ConfigStore configs;
  late OverrideStore overrides;
  late _Platform platform;
  late _Download download;
  late OverrideActions parts;
  const main = ConfigEntry(
    id: 'one',
    name: 'Main',
    source: 'https://fixture.test/main',
    revision: 1,
    body: 'rules: [MATCH,DIRECT]',
  );
  const part = OverrideEntry(
    id: 'part',
    name: 'Part',
    kind: ConfigKind.local,
    revision: 1,
    body: '{}',
    enabled: true,
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('running-changes-');
    input = File('${directory.path}/owned.input');
    configs = ConfigStore(directory);
    overrides = OverrideStore(directory);
    platform = _Platform(input);
    download = _Download();
    parts = OverrideActions(overrides, download, platform, runInput: input);
    await configs.save(ConfigCollection(entries: [main], selectedId: 'one'));
    await overrides.save([part]);
  });
  tearDown(() => directory.delete(recursive: true));

  test('公开 Selector 类型的实际选择在插件更新重连后保留', () async {
    platform.strategyRawType = 'Selector';
    platform.loadParts([part]);
    (platform.loaded['choices'] as Map)['Proxy']['member'] = 'B';
    final running = (await RunningInput.read(platform, platform.state))!;
    expect(running.entry.choices['Proxy']!.toJson(), {
      'type': 'select',
      'member': 'B',
    });
    await parts.execute({
      'action': 'saveOverride',
      'id': part.id,
      'revision': part.revision,
      'body': 'dns: {}',
    });
    expect(parts.result['overrideStatus'], 'applied');
    expect(platform.events, ['stop', 'start']);
    expect(platform.started!['choices'], {
      'Proxy': {'type': 'select', 'member': 'B'},
    });
    expect(await input.exists(), isFalse);
  });

  test('known preparation metadata overflow leaves the actual running lease untouched', () async {
    platform.loadParts([part]);
    final loaded = (await RunningInput.read(platform, platform.state))!;
    final before = platform.state;
    // A control character expands in the identity JSON and again when that
    // complete identity is encoded inside preparation options.
    final oversized = OverrideEntry(
      id: String.fromCharCode(0) * (maxPreparationOptionsBytes ~/ 7 + 1),
      name: 'Controlled metadata',
      kind: ConfigKind.local,
      revision: 1,
      body: '{}',
      enabled: true,
    );
    await expectLater(
      loaded.reconnect(
        platform,
        CoreInput(input),
        fallbackMode: loaded.fallbackMode,
        parts: [oversized],
      ),
      throwsA(
        isA<ConfigFailure>().having(
          (failure) => failure.message.id,
          'message',
          'preparationOptionsTooLarge',
        ),
      ),
    );
    expect(platform.events, isEmpty);
    expect(platform.state, same(before));
    expect(await input.exists(), isFalse);
    expect(await File('${input.path}.tmp').exists(), isFalse);
  });

  test('renames stay saved until actual input changes and a target body edit keeps other loaded names', () async {
    const custom = OverrideEntry(
      id: 'custom',
      name: 'Loaded custom',
      kind: ConfigKind.local,
      revision: 7,
      body: 'dns: {}',
      enabled: true,
      role: OverrideRole.localCustom,
      mode: OverrideMode.replace,
    );
    const other = OverrideEntry(
      id: 'other',
      name: 'Loaded other',
      kind: ConfigKind.local,
      revision: 3,
      body: 'actual-other',
      enabled: true,
    );
    final target = part.changed(name: 'Loaded target');
    platform.loadParts([custom, target, other]);
    platform.loaded['name'] = 'Loaded main';
    await overrides.save([
      custom.changed(name: 'Saved custom'),
      target,
      other.withContent('pending-other'),
    ]);
    final configActions = ConfigActions(configs, download, platform, input);
    await configActions.execute({
      'action': 'renameConfig',
      'id': main.id,
      'name': 'Saved main',
    });
    await parts.execute({
      'action': 'changeOverride',
      'id': target.id,
      'name': 'Saved target',
    });
    await parts.execute({
      'action': 'changeOverride',
      'id': other.id,
      'name': 'Saved other',
    });
    download.body = main.body;
    await configActions.execute({
      'action': 'updateConfig',
      'id': main.id,
      'source': 'http://fixture.test/new-main',
    });
    expect(platform.events, isEmpty);
    expect((await configs.read()).selected!.revision, main.revision);
    expect(platform.loaded['name'], 'Loaded main');
    expect(
      (platform.loaded['overrides'] as List).map((value) => value['name']),
      ['Loaded custom', 'Loaded target', 'Loaded other'],
    );
    await parts.execute({
      'action': 'saveOverride',
      'id': target.id,
      'revision': 1,
      'body': 'new-target',
    });
    expect(parts.result['overrideStatus'], 'applied');
    expect(platform.started!['name'], 'Loaded main');
    expect(platform.started!['source'], main.source);
    final actual = platform.started!['overrides'] as List;
    expect(actual.map((value) => value['name']), [
      'Loaded custom',
      'Saved target',
      'Loaded other',
    ]);
    expect(actual.map((value) => value['role']), ['localCustom', null, null]);
    expect(actual.first['body'], custom.body);
    expect(actual[1]['body'], 'new-target');
    expect(actual[1]['revision'], 2);
    expect(actual.last['body'], other.body);
    final previous = platform.state.core;
    await configActions.execute({'action': 'stop'});
    await configActions.execute({'action': 'start'});
    expect(platform.started!['name'], 'Saved main');
    expect(platform.started!['source'], 'http://fixture.test/new-main');
    expect(
      (platform.started!['overrides'] as List).map((value) => value['name']),
      ['Saved custom', 'Saved target', 'Saved other'],
    );
    expect(
      (platform.started!['overrides'] as List).first['role'],
      'localCustom',
    );
    expect(platform.state.core.generation, greaterThan(previous.generation));
    expect(await input.exists(), isFalse);
  });

  test('main body delta adopts its saved name without importing disk plugin names or roles', () async {
    const custom = OverrideEntry(
      id: 'custom',
      name: 'Loaded custom',
      kind: ConfigKind.local,
      revision: 3,
      body: 'dns: {}',
      enabled: true,
      role: OverrideRole.localCustom,
    );
    platform.loadParts([custom, part.changed(name: 'Loaded plugin')]);
    platform.loaded['name'] = 'Loaded main';
    await configs.save(
      ConfigCollection(
        entries: [main.renamed('Saved main')],
        selectedId: main.id,
      ),
    );
    await overrides.save([
      custom.changed(name: 'Saved custom'),
      part.changed(name: 'Saved plugin').withContent('pending-plugin'),
    ]);
    download.body = 'rules: [MATCH,REJECT]';
    final actions = ConfigActions(configs, download, platform, input);
    await actions.execute({'action': 'updateConfig', 'id': main.id});
    expect(actions.result['configStatus'], 'applied');
    expect(platform.started!['name'], 'Saved main');
    expect(platform.started!['body'], download.body);
    expect(platform.started!['revision'], 2);
    final actual = platform.started!['overrides'] as List;
    expect(actual.map((value) => value['name']), [
      'Loaded custom',
      'Loaded plugin',
    ]);
    expect(actual.first['role'], 'localCustom');
    expect(actual.last['role'], isNull);
    expect(actual.last['body'], part.body);
    expect(await input.exists(), isFalse);
  });

  test('target body delta keeps the loaded LocalCustom role and mode but adopts saved name and revision', () async {
    const actual = OverrideEntry(
      id: 'custom',
      name: 'Loaded custom',
      kind: ConfigKind.local,
      revision: 10,
      body: 'old',
      enabled: true,
      mode: OverrideMode.replace,
      role: OverrideRole.localCustom,
    );
    const saved = OverrideEntry(
      id: 'custom',
      name: 'Saved custom',
      kind: ConfigKind.local,
      revision: 4,
      body: 'new',
      enabled: false,
    );
    platform.loadParts([actual]);
    final loaded = (await RunningInput.read(platform, platform.state))!;
    expect(loaded.entry.name, main.name);
    expect(loaded.parts.single.name, actual.name);
    expect(loaded.parts.single.role, OverrideRole.localCustom);
    final updated = loaded.updatedParts(saved);
    await loaded.reconnect(
      platform,
      CoreInput(input),
      fallbackMode: loaded.fallbackMode,
      parts: updated,
    );
    final value = (platform.started!['overrides'] as List).single as Map;
    expect(value['name'], saved.name);
    expect(value['body'], saved.body);
    expect(value['revision'], saved.revision);
    expect(value['role'], 'localCustom');
    expect(value['mode'], 'replace');
    expect(platform.events, ['stop', 'start']);
  });

  for (final invalid in [
    'main-name-missing',
    'main-name-null',
    'main-name-empty',
    'part-name-missing',
    'part-name-null',
    'part-name-empty',
    'part-role-missing',
    'part-role-unknown',
    'part-role-type',
    'part-role-remote',
  ]) {
    test(
      'missing or invalid loaded metadata rejects application without guessed names: $invalid',
      () async {
        platform.loadParts([part]);
        final fragment = (platform.loaded['overrides'] as List).single as Map;
        switch (invalid) {
          case 'main-name-missing':
            platform.loaded.remove('name');
          case 'main-name-null':
            platform.loaded['name'] = null;
          case 'main-name-empty':
            platform.loaded['name'] = ' ';
          case 'part-name-missing':
            fragment.remove('name');
          case 'part-name-null':
            fragment['name'] = null;
          case 'part-name-empty':
            fragment['name'] = ' ';
          case 'part-role-missing':
            fragment.remove('role');
          case 'part-role-unknown':
            fragment['role'] = 'custom';
          case 'part-role-type':
            fragment['role'] = 1;
          case 'part-role-remote':
            fragment['role'] = 'localCustom';
            fragment['source'] = 'https://fixture.test/remote';
        }
        await parts.execute({
          'action': 'saveOverride',
          'id': part.id,
          'revision': part.revision,
          'body': 'saved-new',
        });
        expect(parts.result['overrideStatus'], 'applyFailed');
        expect((await overrides.read()).single.body, 'saved-new');
        expect(platform.events, isEmpty);
        expect(await input.exists(), isFalse);
      },
    );
  }

  for (final reject in [false, true]) {
    test(
      'application access forwards guarded publication reject=$reject',
      () async {
        const original = AppPreferences(
          access: ApplicationAccess.only,
          packages: ['original.app'],
        );
        await PreferencesStore(directory).save(original);
        var checks = 0;
        final published = <String>[];
        final guarded = ConfigStore(
          directory,
          beforeWrite: () async {
            checks++;
          },
          publish: (file) async {
            published.add(file);
            expect(file, 'preferences.json');
            final staged = File('${directory.path}/$file.tmp');
            expect(await staged.exists(), isTrue);
            expect(
              (await PreferencesStore(directory).read()).toJson(),
              original.toJson(),
            );
            final value = jsonDecode(await staged.readAsString()) as Map;
            expect(value['packages'], ['new.access']);
            if (reject) throw PlatformFailure(code: 'storage');
            await staged.rename('${directory.path}/$file');
          },
        );
        platform.state = const AppSnapshot(phase: 'STOPPED');
        final operation = ConfigActions(guarded, download, platform, input)
            .execute({
              'action': 'setApplicationAccess',
              'access': 'except',
              'packages': ['new.access'],
            });
        if (reject) {
          await expectLater(operation, throwsA(isA<PlatformFailure>()));
        } else {
          expect((await operation)?.id, 'accessSavedNextConnection');
        }
        expect(checks, 2);
        expect(published, ['preferences.json']);
        final saved = await PreferencesStore(directory).read();
        expect(
          saved.access,
          reject ? original.access : ApplicationAccess.except,
        );
        expect(saved.packages, reject ? original.packages : ['new.access']);
        expect(
          await File('${directory.path}/preferences.json.tmp').exists(),
          isFalse,
        );
        expect(platform.events, isEmpty);
      },
    );
  }

  for (final failure in ['staging', 'publication']) {
    test(
      'running application access $failure failure preserves saved bytes and actual lease',
      () async {
        const original = AppPreferences(
          access: ApplicationAccess.only,
          packages: ['original.app'],
        );
        await PreferencesStore(directory).save(original);
        final preferences = File('${directory.path}/preferences.json');
        final originalBytes = await preferences.readAsBytes();
        platform.loadParts([part]);
        final loadedState = platform.state;
        platform.state = AppSnapshot(
          phase: loadedState.phase,
          generation: loadedState.generation,
          configId: loadedState.configId,
          revision: loadedState.revision,
          mode: loadedState.mode,
          core: loadedState.core,
          runningApplicationAccess: RunningApplicationAccess(
            generation: loadedState.generation,
            access: ApplicationAccess.only,
            packages: ['fixture.loaded'],
          ),
        );
        final before = platform.state;
        final beforeInput = await platform.runningRecord(before.core);
        final beforeLoaded = (await RunningInput.read(platform, before))!;
        expect(before.running, isTrue);
        expect(beforeLoaded.preferences.access, ApplicationAccess.only);
        expect(beforeLoaded.preferences.packages, ['fixture.loaded']);
        expect(await input.exists(), isFalse);

        final temporary = File('${preferences.path}.tmp');
        if (failure == 'staging') {
          // Use a directory obstruction to fail actual staging while retaining the old
          // preference file.
          await Directory(temporary.path).create();
        }
        var checks = 0;
        final published = <String>[];
        final guarded = ConfigStore(
          directory,
          beforeWrite: () async {
            checks++;
            await platform.checkOperation();
          },
          publish: (file) async {
            published.add(file);
            expect(file, 'preferences.json');
            expect(await temporary.exists(), isTrue);
            expect(await preferences.readAsBytes(), originalBytes);
            final staged = jsonDecode(await temporary.readAsString()) as Map;
            expect(staged['access'], 'except');
            expect(staged['packages'], ['new.access']);
            throw PlatformFailure(code: 'storage');
          },
        );
        final actions = ConfigActions(guarded, download, platform, input);
        await expectLater(
          actions.execute({
            'action': 'setApplicationAccess',
            'access': 'except',
            'packages': ['new.access'],
          }),
          failure == 'staging'
              ? throwsA(
                  isA<ConfigFailure>().having(
                    (error) => error.message.id,
                    'message',
                    'preferencesSaveFailed',
                  ),
                )
              : throwsA(
                  isA<PlatformFailure>().having(
                    (error) => error.code,
                    'code',
                    'storage',
                  ),
                ),
        );
        expect(checks, failure == 'staging' ? 1 : 2);
        expect(
          published,
          failure == 'staging' ? isEmpty : ['preferences.json'],
        );
        expect(await preferences.readAsBytes(), originalBytes);
        expect(
          (await PreferencesStore(directory).read()).toJson(),
          original.toJson(),
        );
        expect(actions.result, isEmpty);
        expect(platform.events, isEmpty);
        expect(platform.started, isNull);
        expect(platform.state, same(before));
        expect(platform.state.core, same(before.core));
        expect(
          platform.state.runningApplicationAccess,
          same(before.runningApplicationAccess),
        );
        expect(await platform.runningRecord(platform.state.core), beforeInput);
        final afterLoaded = (await RunningInput.read(
          platform,
          platform.state,
        ))!;
        expect(afterLoaded.entry.toJson(), beforeLoaded.entry.toJson());
        expect(
          afterLoaded.parts.map((entry) => entry.toJson()),
          beforeLoaded.parts.map((entry) => entry.toJson()),
        );
        expect(
          afterLoaded.preferences.toJson(),
          beforeLoaded.preferences.toJson(),
        );
        expect(afterLoaded.fallbackMode, beforeLoaded.fallbackMode);
        expect(await input.exists(), isFalse);
        expect(await temporary.exists(), isFalse);
        if (failure == 'staging') {
          // Preserve the pre-existing obstruction after failed staging.
          expect(await Directory(temporary.path).exists(), isTrue);
          expect(await Directory(temporary.path).list().toList(), isEmpty);
        } else {
          expect(
            await FileSystemEntity.type(temporary.path),
            FileSystemEntityType.notFound,
          );
        }
      },
    );
  }

  test('snapshot retains scheduling outcome independently from saved and applied results', () {
    for (final status in ['synced', 'failed']) {
      final snapshot = AppSnapshot.fromMap({
        'phase': 'STOPPED',
        'scheduleStatus': status,
        'configStatus': 'saved',
        'overrideStatus': 'applied',
        'resultSuccess': status == 'synced',
      });
      expect(snapshot.scheduleStatus, status);
      expect(snapshot.configStatus, 'saved');
      expect(snapshot.overrideStatus, 'applied');
      expect(snapshot.resultSuccess, status == 'synced');
    }
    expect(AppSnapshot.fromMap({'phase': 'STOPPED'}).scheduleStatus, isNull);
  });

  void expectActualMain({
    TunnelMode? fallbackMode = TunnelMode.rule,
    TunnelMode? routingOverride,
  }) {
    expect(platform.started!['body'], main.body);
    expect(platform.started!['revision'], 1);
    expect(platform.started!['mode'], fallbackMode?.name);
    expect(platform.started!['routingOverride'], routingOverride?.name);
    expect(platform.started!['access'], 'only');
    expect(platform.started!['packages'], ['fixture.loaded']);
    expect(platform.started!['choices'], platform.loaded['choices']);
  }

  test('manual fragment save applies only actual target without pending main or access', () async {
    platform.loadParts([part]);
    await configs.save(
      ConfigCollection(
        entries: [main.withContent('pending')],
        selectedId: 'one',
        mode: TunnelMode.direct,
      ),
    );
    await PreferencesStore(directory).save(
      const AppPreferences(
        access: ApplicationAccess.except,
        packages: ['pending'],
      ),
    );
    await parts.execute({
      'action': 'saveOverride',
      'id': 'part',
      'revision': 1,
      'body': 'dns: {}',
    });
    expect(parts.result['overrideStatus'], 'applied');
    expect(platform.events, ['stop', 'start']);
    expectActualMain(fallbackMode: TunnelMode.rule);
    expect((platform.started!['overrides'] as List).single['body'], 'dns: {}');
    expect(await input.exists(), isFalse);
  });

  for (final command in [
    {'action': 'changeOverride', 'id': 'part', 'enabled': false},
    {'action': 'changeOverride', 'id': 'part', 'mode': 'replace'},
    {'action': 'deleteOverride', 'id': 'part'},
  ]) {
    test(
      'manual ${command['action']} ${command['enabled'] ?? command['mode'] ?? 'delete'} reconnects',
      () async {
        platform.loadParts([part]);
        await parts.execute(command);
        expect(parts.result['overrideStatus'], 'applied');
        expect(platform.events, ['stop', 'start']);
        expectActualMain();
      },
    );
  }

  test('new local and successful remote imports are enabled', () async {
    platform.state = const AppSnapshot(phase: 'STOPPED');
    await parts.execute({
      'action': 'saveOverride',
      'name': 'Local',
      'body': '{}',
    });
    expect((await overrides.read()).last.enabled, isTrue);
    await parts.execute({
      'action': 'importOverride',
      'name': 'Remote',
      'source': 'https://fixture.test/part',
    });
    expect((await overrides.read()).last.enabled, isTrue);
    expect(platform.events, isEmpty);
  });

  test('failed save leaves the old VPN and data untouched', () async {
    await Directory('${directory.path}/overrides.json.tmp').create();
    await expectLater(
      parts.execute({
        'action': 'changeOverride',
        'id': 'part',
        'enabled': false,
      }),
      throwsA(isA<ConfigFailure>()),
    );
    expect((await overrides.read()).single.enabled, isTrue);
    expect(platform.events, isEmpty);
  });

  test(
    'saved fragment survives reconnect failure with structured partial result',
    () async {
      platform.loadParts([part]);
      platform.failStart = true;
      await parts.execute({
        'action': 'saveOverride',
        'id': 'part',
        'revision': 1,
        'body': 'dns: {}',
      });
      expect(parts.result['overrideStatus'], 'applyFailed');
      expect(parts.result['success'], isFalse);
      expect((await overrides.read()).single.revision, 2);
      expect(await input.exists(), isFalse);
    },
  );

  test('rename and identical content never reconnect', () async {
    await parts.execute({
      'action': 'changeOverride',
      'id': 'part',
      'name': 'Renamed',
    });
    await parts.execute({
      'action': 'saveOverride',
      'id': 'part',
      'revision': 1,
      'body': '{}',
    });
    expect(platform.events, isEmpty);
  });

  test('stopped fragment mutation releases preview but never starts', () async {
    platform.state = const AppSnapshot(
      phase: 'STOPPED',
      core: CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'PREVIEW',
        configId: 'one',
        revision: 1,
      ),
    );
    await parts.execute({
      'action': 'changeOverride',
      'id': 'part',
      'enabled': false,
    });
    expect(platform.events, ['release']);
  });

  test('mode reconnect replaces only actual mode', () async {
    await PreferencesStore(directory).save(
      AppPreferences.fromJson({
        ...const AppPreferences().toJson(),
        'reconnectOnRoutingChange': true,
      }),
    );
    await configs.save(
      ConfigCollection(
        entries: [main.withContent('pending')],
        selectedId: 'one',
      ),
    );
    await ConfigActions(
      configs,
      download,
      platform,
      input,
    ).execute({'action': 'setMode', 'mode': 'direct'});
    expect(platform.events, ['stop', 'start']);
    expect(platform.started!['body'], main.body);
    expect(platform.started!['mode'], 'direct');
    expect(platform.started!['routingOverride'], 'direct');
    expect(platform.started!['overrides'], isEmpty);
    expect(platform.started!['packages'], ['fixture.loaded']);
  });

  test(
    'manual successful import and update reconnect latest parts in saved order',
    () async {
      platform.loadParts([part]);
      await parts.execute({
        'action': 'importOverride',
        'name': 'New remote',
        'source': 'https://fixture.test/new-part',
      });
      expect(parts.result['overrideStatus'], 'applied');
      var saved = await overrides.read();
      final remote = saved.last;
      expect(remote.enabled, isTrue);
      expect((platform.started!['overrides'] as List).map((e) => e['id']), [
        part.id,
        remote.id,
      ]);
      download.body = 'dns: {enable: false}';
      await parts.execute({'action': 'updateOverride', 'id': remote.id});
      expect(parts.result['overrideStatus'], 'applied');
      expect(
        (platform.started!['overrides'] as List).last['body'],
        download.body,
      );
      await parts.execute({
        'action': 'reorderOverrides',
        'ids': [remote.id, part.id],
      });
      expect(parts.result['overrideStatus'], 'applied');
      expect((platform.started!['overrides'] as List).map((e) => e['id']), [
        remote.id,
        part.id,
      ]);
      saved = await overrides.read();
      expect(saved.map((e) => e.id), [remote.id, part.id]);
      expect(platform.events, [
        'stop',
        'start',
        'stop',
        'start',
        'stop',
        'start',
      ]);
      expectActualMain();
    },
  );

  test(
    'failed new import leaves no placeholder or composition change',
    () async {
      platform.loadParts([part]);
      download.fail = true;
      await expectLater(
        parts.execute({
          'action': 'importOverride',
          'name': 'Failed remote',
          'source': 'https://fixture.test/failure',
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await overrides.read()).map((entry) => entry.toJson()), [
        part.toJson(),
      ]);
      expect(platform.events, isEmpty);
    },
  );

  test(
    'disabled body changes and effective composition already loaded are no-ops',
    () async {
      await overrides.save([part.changed(enabled: false)]);
      await parts.execute({
        'action': 'saveOverride',
        'id': 'part',
        'revision': 1,
        'body': 'new',
      });
      expect(platform.events, isEmpty);
      await overrides.save([part]);
      await parts.execute({
        'action': 'changeOverride',
        'id': 'part',
        'enabled': false,
      });
      expect(platform.events, isEmpty);
      expect(parts.result['overrideStatus'], 'saved');
    },
  );

  test(
    'input failure and cancellation do not restart a manual composition change',
    () async {
      platform.loadParts([part]);
      await Directory(input.path).create();
      await parts.execute({
        'action': 'saveOverride',
        'id': 'part',
        'revision': 1,
        'body': 'new',
      });
      expect(parts.result['overrideStatus'], 'applyFailed');
      expect(platform.events, isEmpty);
      await Directory(input.path).delete();
      platform.afterStop = () => platform.expired = true;
      await parts.execute({
        'action': 'saveOverride',
        'id': 'part',
        'revision': 2,
        'body': 'newer',
      });
      expect(parts.result['overrideStatus'], 'applyFailed');
      expect(platform.events, ['stop']);
      expect(await input.exists(), isFalse);
    },
  );

  test(
    'same mode and choice save intent without restart even when enabled',
    () async {
      await PreferencesStore(directory)
          .save(const AppPreferences(reconnectOnRoutingChange: true));
      await ConfigActions(
        configs,
        download,
        platform,
        input,
      ).execute({'action': 'setMode', 'mode': 'global'});
      await StrategyActions(configs, platform, runInput: input).execute({
        'id': 'one',
        'revision': 1,
        'generation': 8,
        'composition': '["one",1]',
        'name': 'Proxy',
        'choice': {'type': 'select', 'member': 'A'},
      });
      expect(platform.events, isEmpty);
      expect((await configs.read()).mode, TunnelMode.global);
      expect((await configs.read()).selected!.choices['Proxy']!.member, 'A');
    },
  );

  test('routing changes use hot switching by default', () async {
    await ConfigActions(
      configs,
      download,
      platform,
      input,
    ).execute({'action': 'setMode', 'mode': 'direct'});
    await StrategyActions(configs, platform, runInput: input).execute({
      'id': 'one',
      'revision': 1,
      'generation': 8,
      'composition': '["one",1]',
      'name': 'Proxy',
      'choice': {'type': 'select', 'member': 'B'},
    });
    expect(platform.events, ['mode:direct', 'strategy:B']);
    expect(await input.exists(), isFalse);
  });

  test(
    'pending main cannot change actual group validation or reconnect input',
    () async {
      await PreferencesStore(directory)
          .save(const AppPreferences(reconnectOnRoutingChange: true));
      final pending = main.withContent(
        'proxies: []\nproxy-groups: [{name: Proxy, type: load-balance, proxies: [Other]}]',
      );
      await configs.save(
        ConfigCollection(entries: [pending], selectedId: 'one'),
      );
      await StrategyActions(configs, platform, runInput: input).execute({
        'id': 'one',
        'revision': 1,
        'generation': 8,
        'composition': '["one",1]',
        'name': 'Proxy',
        'choice': {'type': 'select', 'member': 'B'},
      });
      final saved = (await configs.read()).selected!;
      expect(saved.body, pending.body);
      expect(saved.revision, pending.revision);
      expect(saved.choices['Proxy']!.member, 'B');
      expect(platform.started!['body'], main.body);
      expect(platform.started!['revision'], 1);
      expect(platform.started!['overrides'], isEmpty);
      expect(platform.started!['access'], 'only');
    },
  );

  test(
    'reconnect failure and unconfirmed restored choice retain saved intent',
    () async {
      await PreferencesStore(directory)
          .save(const AppPreferences(reconnectOnRoutingChange: true));
      platform.mismatchChoice = true;
      await expectLater(
        StrategyActions(configs, platform, runInput: input).execute({
          'id': 'one',
          'revision': 1,
          'generation': 8,
          'composition': '["one",1]',
          'name': 'Proxy',
          'choice': {'type': 'select', 'member': 'B'},
        }),
        throwsA(
          isA<ConfigFailure>().having(
            (e) => e.message.id,
            'message',
            'strategySelectionUnconfirmed',
          ),
        ),
      );
      expect((await configs.read()).selected!.choices['Proxy']!.member, 'B');
      platform.failStart = true;
      await expectLater(
        ConfigActions(
          configs,
          download,
          platform,
          input,
        ).execute({'action': 'setMode', 'mode': 'direct'}),
        throwsA(
          isA<ConfigFailure>().having(
            (e) => e.message.id,
            'message',
            'modeNotConfirmed',
          ),
        ),
      );
      expect((await configs.read()).mode, TunnelMode.direct);
      expect(await input.exists(), isFalse);
    },
  );

  test('access reconnect replaces only access even with pending main and fragments', () async {
    platform.loadParts([part]);
    await configs.save(
      ConfigCollection(
        entries: [main.withContent('pending')],
        selectedId: 'one',
        mode: TunnelMode.direct,
      ),
    );
    await overrides.save([part.withContent('pending part')]);
    await ConfigActions(configs, download, platform, input).execute({
      'action': 'setApplicationAccess',
      'access': 'except',
      'packages': ['new.access'],
    });
    expect(platform.events, ['stop', 'start']);
    expect(platform.started!['body'], main.body);
    expect(platform.started!['revision'], 1);
    expect(platform.started!['mode'], 'rule');
    expect(platform.started!['routingOverride'], 'global');
    expect((platform.started!['overrides'] as List).single['body'], part.body);
    expect(platform.started!['access'], 'except');
    expect(platform.started!['packages'], ['new.access']);
    expect(platform.started!['choices'], {
      'Proxy': {'type': 'select', 'member': 'A'},
    });
  });

  test(
    'saving the actual access policy is a no-op without reconnect',
    () async {
      platform.state = AppSnapshot(
        phase: 'RUNNING',
        generation: 4,
        core: platform.state.core,
        runningApplicationAccess: RunningApplicationAccess(
          generation: 4,
          access: ApplicationAccess.only,
          packages: ['fixture.loaded'],
        ),
      );
      final result = await ConfigActions(configs, download, platform, input)
          .execute({
            'action': 'setApplicationAccess',
            'access': 'only',
            'packages': ['fixture.loaded'],
          });
      expect(result?.id, 'settingsSaved');
      expect(platform.events, isEmpty);
      expect((await PreferencesStore(directory).read()).packages, [
        'fixture.loaded',
      ]);
      expect(await input.exists(), isFalse);
    },
  );

  test(
    'unconfirmed access apply retains saved intent and same value can retry',
    () async {
      final command = <String, dynamic>{
        'action': 'setApplicationAccess',
        'access': 'except',
        'packages': ['new.access'],
      };
      platform.mismatchAccess = true;
      await expectLater(
        ConfigActions(configs, download, platform, input).execute(command),
        throwsA(
          isA<ConfigFailure>().having(
            (failure) => failure.message.id,
            'message',
            'accessSavedReconnectFailed',
          ),
        ),
      );
      final saved = await PreferencesStore(directory).read();
      expect(saved.access, ApplicationAccess.except);
      expect(saved.packages, ['new.access']);
      expect(
        platform.state.runningApplicationAccess!.access,
        ApplicationAccess.all,
      );
      expect(await input.exists(), isFalse);
      platform.mismatchAccess = false;
      final result = await ConfigActions(
        configs,
        download,
        platform,
        input,
      ).execute(command);
      expect(result?.id, 'accessSavedReconnected');
      expect(platform.events, ['stop', 'start', 'stop', 'start']);
      expect(
        platform.state.runningApplicationAccess!.matches(
          saved.access,
          saved.packages,
        ),
        isTrue,
      );
      expect(platform.started!['body'], main.body);
      expect(platform.started!['overrides'], isEmpty);
      expect(platform.started!['choices'], {
        'Proxy': {'type': 'select', 'member': 'A'},
      });
    },
  );

  test(
    'access start failure preserves intent for the next explicit connection',
    () async {
      platform.failStart = true;
      await expectLater(
        ConfigActions(configs, download, platform, input).execute({
          'action': 'setApplicationAccess',
          'access': 'except',
          'packages': ['new.access'],
        }),
        throwsA(
          isA<ConfigFailure>().having(
            (failure) => failure.message.id,
            'message',
            'accessSavedReconnectFailed',
          ),
        ),
      );
      expect((await PreferencesStore(directory).read()).packages, [
        'new.access',
      ]);
      expect(platform.state.running, isFalse);
      expect(platform.state.runningApplicationAccess, isNull);
      expect(await input.exists(), isFalse);
      final result = await ConfigActions(configs, download, platform, input)
          .execute({
            'action': 'setApplicationAccess',
            'access': 'except',
            'packages': ['new.access'],
          });
      expect(result?.id, 'accessSavedNextConnection');
      expect(platform.events, ['stop', 'start']);
    },
  );

  test(
    'running access projection rejects malformed and non-current observations',
    () {
      const policy = <String, Object?>{
        'generation': 4,
        'access': 'only',
        'packages': ['fixture.loaded'],
      };
      AppSnapshot decode(Object? value, {String phase = 'RUNNING'}) =>
          AppSnapshot.fromMap({
            'phase': phase,
            'generation': 4,
            'mode': 'rule',
            'runningApplicationAccess': value,
          });
      final actual = decode(policy).runningApplicationAccess!;
      expect(
        actual.matches(ApplicationAccess.only, ['fixture.loaded']),
        isTrue,
      );
      expect(() => actual.packages.clear(), throwsUnsupportedError);
      for (final phase in ['STOPPED', 'STARTING', 'STOPPING', 'UNKNOWN']) {
        expect(decode(policy, phase: phase).runningApplicationAccess, isNull);
      }
      for (final value in <Object?>[
        null,
        [],
        {},
        {...policy, 'generation': 3},
        {...policy, 'generation': 4.0},
        {...policy, 'generation': '4'},
        {...policy}..remove('generation'),
        {...policy, 'access': null},
        {...policy, 'access': true},
        {...policy, 'access': 'unknown'},
        {...policy}..remove('access'),
        {...policy}..remove('packages'),
        {...policy, 'packages': null},
        {...policy, 'packages': '[]'},
        {
          ...policy,
          'packages': [1],
        },
        {
          ...policy,
          'packages': [null],
        },
        {
          ...policy,
          'packages': [' '],
        },
        {
          ...policy,
          'packages': ['fixture.loaded', 'fixture.loaded'],
        },
        {...policy, 'packages': []},
      ]) {
        expect(
          decode(value).runningApplicationAccess,
          isNull,
          reason: '$value',
        );
      }
      expect(
        decode({...policy, 'access': 'all', 'packages': []})
            .runningApplicationAccess,
        isNotNull,
      );
      expect(
        decode({...policy, 'access': 'except', 'packages': []})
            .runningApplicationAccess,
        isNotNull,
      );
    },
  );

  test('source replacement preserves old VPN on failure and applies only successful body', () async {
    const remote = OverrideEntry(
      id: 'remote',
      name: 'Remote',
      kind: ConfigKind.remote,
      source: 'https://fixture.test/old',
      revision: 1,
      body: '{}',
      enabled: true,
    );
    await overrides.save([remote]);
    platform.loadParts([remote]);
    download.fail = true;
    await expectLater(
      parts.execute({
        'action': 'changeOverrideSource',
        'id': 'remote',
        'source': 'https://fixture.test/new',
      }),
      throwsA(isA<ConfigFailure>()),
    );
    expect((await overrides.read()).single.source, remote.source);
    expect(platform.events, isEmpty);
    download.fail = false;
    download.body = remote.body;
    await parts.execute({
      'action': 'changeOverrideSource',
      'id': 'remote',
      'source': 'https://fixture.test/new',
    });
    expect(platform.events, isEmpty);
    expect((await overrides.read()).single.revision, 1);
    download.body = 'dns: {}';
    await parts.execute({
      'action': 'changeOverrideSource',
      'id': 'remote',
      'source': 'https://fixture.test/last',
    });
    expect(parts.result['overrideStatus'], 'applied');
    expect(platform.events, ['stop', 'start']);
    expect(platform.started!['body'], main.body);
    final loaded = (platform.started!['overrides'] as List).single;
    expect(loaded['source'], 'https://fixture.test/last');
    expect(loaded['body'], download.body);
  });

  test('body edit preserves divergent actual members, positions, modes and saved revision', () async {
    const other = OverrideEntry(
      id: 'other',
      name: 'Other',
      kind: ConfigKind.local,
      revision: 3,
      body: 'actual-other',
      enabled: true,
    );
    const orphan = OverrideEntry(
      id: 'orphan',
      name: 'Orphan',
      kind: ConfigKind.local,
      revision: 8,
      body: 'actual-orphan',
      enabled: true,
      mode: OverrideMode.replace,
    );
    const savedOnly = OverrideEntry(
      id: 'saved-only',
      name: 'Saved only',
      kind: ConfigKind.local,
      revision: 1,
      body: 'pending-membership',
      enabled: true,
    );
    final savedTarget = OverrideEntry(
      id: part.id,
      name: part.name,
      kind: ConfigKind.local,
      revision: 4,
      body: 'pending-target',
      enabled: false,
    );
    final actualTarget = OverrideEntry(
      id: part.id,
      name: part.name,
      kind: ConfigKind.local,
      revision: 12,
      body: 'actual-target',
      enabled: true,
      mode: OverrideMode.replace,
    );
    platform.loadParts([orphan, actualTarget, other]);
    await overrides.save([
      other.withContent('pending-other').changed(mode: OverrideMode.replace),
      savedOnly,
      savedTarget,
    ]);
    await configs.save(
      ConfigCollection(
        entries: [main.withContent('pending-main')],
        selectedId: 'one',
        mode: TunnelMode.direct,
      ),
    );
    await PreferencesStore(directory).save(
      const AppPreferences(
        access: ApplicationAccess.except,
        packages: ['pending.access'],
      ),
    );
    await parts.execute({
      'action': 'saveOverride',
      'id': part.id,
      'revision': 4,
      'body': 'new-target',
    });
    expect(parts.result['overrideStatus'], 'applied');
    expect(parts.result['savedRevision'], 5);
    final actual = platform.started!['overrides'] as List;
    expect(actual.map((item) => item['id']), ['orphan', part.id, 'other']);
    expect(actual.map((item) => item['body']), [
      'actual-orphan',
      'new-target',
      'actual-other',
    ]);
    expect(actual.map((item) => item['mode']), [
      'replace',
      'replace',
      'prepend',
    ]);
    expect(actual[1]['revision'], 5); // Not actual revision 12 + 1.
    expectActualMain(fallbackMode: TunnelMode.rule);
    final saved = await overrides.read();
    expect(saved.last.enabled, isFalse);
    expect(saved.last.mode, OverrideMode.prepend);
    expect(saved.first.body, 'pending-other');
  });

  test('explicit same-body retry repairs only actual target after prior failed apply', () async {
    final saved = part.withContent('saved-target');
    const actualOther = OverrideEntry(
      id: 'other',
      name: 'Other',
      kind: ConfigKind.local,
      revision: 7,
      body: 'actual-other',
      enabled: true,
    );
    platform.loadParts([part.changed(mode: OverrideMode.replace), actualOther]);
    await overrides.save([saved, actualOther.withContent('pending-other')]);
    await parts.execute({
      'action': 'saveOverride',
      'id': part.id,
      'revision': saved.revision,
      'body': saved.body,
    });
    expect(parts.result['overrideStatus'], 'applied');
    expect((await overrides.read()).first.revision, saved.revision);
    final actual = platform.started!['overrides'] as List;
    expect(actual.first['body'], saved.body);
    expect(actual.first['mode'], 'replace');
    expect(actual.last['body'], actualOther.body);
    expectActualMain();
  });

  test(
    'explicit enable of actual member does not import its pending body or mode',
    () async {
      platform.loadParts([part.changed(mode: OverrideMode.replace)]);
      await overrides.save([
        part.withContent('pending').changed(enabled: false),
      ]);
      await parts.execute({
        'action': 'changeOverride',
        'id': part.id,
        'enabled': true,
      });
      expect(platform.events, isEmpty);
      expect((await overrides.read()).single.enabled, isTrue);
      expect((platform.loaded['overrides'] as List).single['body'], part.body);
      expect((platform.loaded['overrides'] as List).single['mode'], 'replace');
    },
  );

  test('deletion applies target removal before reporting independent schedule failure', () async {
    platform.loadParts([part]);
    platform.failSchedules = true;
    await expectLater(
      parts.execute({'action': 'deleteOverride', 'id': part.id}),
      throwsA(
        isA<ConfigFailure>()
            .having(
              (failure) => failure.message.id,
              'applied result',
              'overridesAppliedReconnected',
            )
            .having(
              (failure) => failure.message.detail,
              'schedule error',
              contains('schedule'),
            ),
      ),
    );
    expect(await overrides.read(), isEmpty);
    expect(platform.events, ['stop', 'start']);
    expect(platform.started!['overrides'], isEmpty);
    expect(parts.result['overrideStatus'], 'applied');
    expect(parts.result['scheduleStatus'], 'failed');
    expectActualMain();
  });

  test('explicit mode edit changes actual mode only, not pending body or membership', () async {
    const orphan = OverrideEntry(
      id: 'orphan',
      name: 'Orphan',
      kind: ConfigKind.local,
      revision: 7,
      body: 'actual-orphan',
      enabled: true,
    );
    const savedOnly = OverrideEntry(
      id: 'saved-only',
      name: 'Saved only',
      kind: ConfigKind.local,
      revision: 1,
      body: 'pending-membership',
      enabled: true,
    );
    platform.loadParts([orphan, part]);
    await overrides.save([savedOnly, part.withContent('pending-body')]);
    await parts.execute({
      'action': 'changeOverride',
      'id': part.id,
      'mode': 'replace',
    });
    final actual = platform.started!['overrides'] as List;
    expect(actual.map((item) => item['id']), ['orphan', part.id]);
    expect(actual.last['body'], part.body);
    expect(actual.last['revision'], part.revision);
    expect(actual.last['mode'], 'replace');
    expectActualMain();
  });

  test('mode edit never enables saved-only member', () async {
    await parts.execute({
      'action': 'changeOverride',
      'id': part.id,
      'mode': 'replace',
    });
    expect(platform.events, isEmpty);
    expect(platform.loaded['overrides'], isEmpty);
    expect((await overrides.read()).single.mode, OverrideMode.replace);
  });

  test(
    'enable inserts only target before nearest following actual saved anchor',
    () async {
      const a = OverrideEntry(
        id: 'a',
        name: 'A',
        kind: ConfigKind.local,
        revision: 1,
        body: 'actual-a',
        enabled: true,
      );
      const b = OverrideEntry(
        id: 'b',
        name: 'B',
        kind: ConfigKind.local,
        revision: 2,
        body: 'actual-b',
        enabled: true,
      );
      const orphan = OverrideEntry(
        id: 'orphan',
        name: 'Orphan',
        kind: ConfigKind.local,
        revision: 3,
        body: 'orphan',
        enabled: true,
      );
      const pending = OverrideEntry(
        id: 'pending',
        name: 'Pending',
        kind: ConfigKind.local,
        revision: 1,
        body: 'pending',
        enabled: true,
      );
      platform.loadParts([orphan, b, a]);
      await overrides.save([
        part.changed(enabled: false),
        pending,
        a.withContent('pending-a'),
        b.withContent('pending-b'),
      ]);
      await parts.execute({
        'action': 'changeOverride',
        'id': part.id,
        'enabled': true,
      });
      final actual = platform.started!['overrides'] as List;
      expect(actual.map((item) => item['id']), ['orphan', 'b', part.id, 'a']);
      expect(actual.map((item) => item['body']), [
        'orphan',
        'actual-b',
        part.body,
        'actual-a',
      ]);
      expectActualMain();
    },
  );

  test(
    'reorder changes intersection only and preserves unmentioned actual slots',
    () async {
      const a = OverrideEntry(
        id: 'a',
        name: 'A',
        kind: ConfigKind.local,
        revision: 1,
        body: 'actual-a',
        enabled: true,
      );
      const b = OverrideEntry(
        id: 'b',
        name: 'B',
        kind: ConfigKind.local,
        revision: 2,
        body: 'actual-b',
        enabled: true,
        mode: OverrideMode.replace,
      );
      const orphan = OverrideEntry(
        id: 'orphan',
        name: 'Orphan',
        kind: ConfigKind.local,
        revision: 3,
        body: 'orphan',
        enabled: true,
      );
      platform.loadParts([a, orphan, b]);
      await overrides.save([
        a.withContent('pending-a'),
        part,
        b.withContent('pending-b'),
      ]);
      await parts.execute({
        'action': 'reorderOverrides',
        'ids': ['b', part.id, 'a'],
      });
      final actual = platform.started!['overrides'] as List;
      expect(actual.map((item) => item['id']), ['b', 'orphan', 'a']);
      expect(actual.map((item) => item['body']), [
        'actual-b',
        'orphan',
        'actual-a',
      ]);
      expect(actual.first['mode'], 'replace');
      expectActualMain();
    },
  );

  for (final action in ['disable', 'delete']) {
    test(
      '$action removes only target from divergent actual composition',
      () async {
        const other = OverrideEntry(
          id: 'other',
          name: 'Other',
          kind: ConfigKind.local,
          revision: 3,
          body: 'actual-other',
          enabled: true,
          mode: OverrideMode.replace,
        );
        const orphan = OverrideEntry(
          id: 'orphan',
          name: 'Orphan',
          kind: ConfigKind.local,
          revision: 4,
          body: 'orphan',
          enabled: true,
        );
        platform.loadParts([other, part, orphan]);
        await overrides.save([part, other.withContent('pending-other')]);
        await parts.execute(
          action == 'delete'
              ? {'action': 'deleteOverride', 'id': part.id}
              : {'action': 'changeOverride', 'id': part.id, 'enabled': false},
        );
        final actual = platform.started!['overrides'] as List;
        expect(actual.map((item) => item['id']), ['other', 'orphan']);
        expect(actual.first['body'], other.body);
        expect(actual.first['mode'], 'replace');
        expectActualMain();
      },
    );
  }

  test('main manual same-body retry adopts saved revision and preserves actual plugins and choices', () async {
    const orphan = OverrideEntry(
      id: 'orphan',
      name: 'Orphan',
      kind: ConfigKind.local,
      revision: 7,
      body: 'actual-orphan',
      enabled: true,
      mode: OverrideMode.replace,
    );
    platform.loadParts([orphan, part]);
    final saved = main
        .withContent('first saved')
        .withContent('saved-main')
        .withChoice(
          'Proxy',
          const StrategyChoice(type: StrategyType.select, member: 'B'),
        );
    await configs.save(
      ConfigCollection(
        entries: [saved],
        selectedId: 'one',
        mode: TunnelMode.direct,
      ),
    );
    await overrides.save([part.withContent('pending-part')]);
    download.body = saved.body;
    final actions = ConfigActions(configs, download, platform, input);
    await actions.execute({'action': 'updateConfig', 'id': 'one'});
    expect(actions.result['configStatus'], 'applied');
    expect((await configs.read()).selected!.revision, saved.revision);
    expect(platform.started!['revision'], saved.revision);
    expect(platform.started!['body'], saved.body);
    expect(platform.started!['mode'], 'rule');
    expect((await configs.read()).mode, TunnelMode.direct);
    expect(platform.started!['routingOverride'], isNull);
    expect(platform.started!['access'], 'only');
    expect(platform.started!['packages'], ['fixture.loaded']);
    expect(platform.started!['choices'], {
      'Proxy': {'type': 'select', 'member': 'A'},
    });
    final actual = platform.started!['overrides'] as List;
    expect(actual.map((item) => item['id']), ['orphan', part.id]);
    expect(actual.last['body'], part.body);
    expect(actual.first['mode'], 'replace');
  });

  test('main source-only same-text replacement does not bump revision or reconnect', () async {
    platform.loadParts([part]);
    download.body = main.body;
    await ConfigActions(configs, download, platform, input).execute({
      'action': 'updateConfig',
      'id': 'one',
      'source': 'http://fixture.test/new-main',
    });
    final saved = (await configs.read()).selected!;
    expect(saved.source, 'http://fixture.test/new-main');
    expect(saved.revision, main.revision);
    expect(platform.events, isEmpty);
  });

  test(
    'application-access persistence retains the operation write guard',
    () async {
      final guarded = ConfigStore(
        directory,
        beforeWrite: () async {
          throw PlatformFailure(code: 'expired');
        },
      );
      await expectLater(
        ConfigActions(guarded, download, platform, input).execute({
          'action': 'setApplicationAccess',
          'access': 'except',
          'packages': ['new.access'],
        }),
        throwsA(isA<PlatformFailure>()),
      );
      expect(
        (await PreferencesStore(directory).read()).access,
        ApplicationAccess.all,
      );
      expect(
        await File('${directory.path}/preferences.json').exists(),
        isFalse,
      );
      expect(platform.events, isEmpty);
    },
  );

  for (final invalid in ['duplicate', 'empty-id', 'zero-revision']) {
    test(
      'malformed actual fragment $invalid cannot authorize reconnect',
      () async {
        platform.loadParts(
          invalid == 'duplicate'
              ? [part, part]
              : [
                  OverrideEntry(
                    id: invalid == 'empty-id' ? '' : part.id,
                    name: 'Invalid',
                    kind: ConfigKind.local,
                    revision: invalid == 'zero-revision' ? 0 : 1,
                    body: part.body,
                    enabled: true,
                  ),
                ],
        );
        await parts.execute({
          'action': 'saveOverride',
          'id': part.id,
          'revision': 1,
          'body': 'saved-new',
        });
        expect(parts.result['overrideStatus'], 'applyFailed');
        expect((await overrides.read()).single.body, 'saved-new');
        expect(platform.events, isEmpty);
        expect(await input.exists(), isFalse);
      },
    );
  }

  test('strategy reconnect replaces only actual choice', () async {
    await PreferencesStore(directory).save(
      AppPreferences.fromJson({
        ...const AppPreferences().toJson(),
        'reconnectOnRoutingChange': true,
      }),
    );
    await StrategyActions(configs, platform, runInput: input).execute({
      'id': 'one',
      'revision': 1,
      'generation': 8,
      'composition': '["one",1]',
      'name': 'Proxy',
      'choice': {'type': 'select', 'member': 'B'},
    });
    expect(platform.events, ['stop', 'start']);
    expect(platform.started!['body'], main.body);
    expect(platform.started!['choices'], {
      'Proxy': {'type': 'select', 'member': 'B'},
    });
    expect(platform.started!['overrides'], isEmpty);
    expect(platform.started!['mode'], 'rule');
    expect(platform.started!['routingOverride'], 'global');
  });
}
