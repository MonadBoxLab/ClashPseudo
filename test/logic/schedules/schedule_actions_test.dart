import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/logic/schedules/schedule_actions.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configs/downloader_redirect_test.dart' show ClientFake;

import 'package:clash_pseudo/src/ui/locale/message_text.dart';

class _PendingClient extends ClientFake {
  _PendingClient() : super('/downloaded');

  final started = Completer<void>();
  final returned = Completer<void>();

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final request = super.getUrl(url);
    if (!started.isCompleted) started.complete();
    final result = await request;
    if (!returned.isCompleted) returned.complete();
    return result;
  }
}

class _Download extends ConfigDownloader {
  String body = 'rules: [MATCH,REJECT]';
  final started = Completer<void>();
  Completer<String>? pending;

  @override
  Future<String> download(String source) async {
    if (!started.isCompleted) started.complete();
    return pending == null ? body : pending!.future;
  }
}

class _Platform extends AppBridge {
  _Platform(this.input);
  final File input;
  Map<String, dynamic> loaded = {
    'vpnIntent': true,
    'lanIntent': false,
    'id': 'one',
    'name': 'One',
    'revision': 1,
    'source': 'https://fixture.test/config',
    'body': 'rules: [MATCH,DIRECT]',
    'mode': 'rule',
    'choices': <String, dynamic>{},
    'overrides': <Map<String, dynamic>>[],
    'composition': '["one",1]',
    'access': 'all',
    'packages': <String>[],
  };
  void loadParts(List<Map<String, dynamic>> parts) {
    loaded['overrides'] = parts;
    final composition = jsonEncode([
      'one',
      1,
      for (final part in parts) [part['id'], part['revision'], part['mode']],
    ]);
    loaded['composition'] = composition;
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
        composition: composition,
      ),
    );
  }

  @override
  Future<Map<String, dynamic>?> runningRecord(CoreSnapshot core) async => {
    ...jsonDecode(jsonEncode(loaded)) as Map<String, dynamic>,
    'inputId': core.inputId,
  };
  Map<String, dynamic>? actualChoices;
  @override
  Future<StrategySnapshot> strategies(CoreSnapshot coreIdentity) async =>
      StrategySnapshot(
        generation: coreIdentity.generation,
        configId: 'one',
        revision: 1,
        purpose: 'RUNNING',
        composition: loaded['composition'] as String,
        globalReferenced: false,
        unrestored: const {},
        groups: [
          for (final item
              in (actualChoices ?? loaded['choices'] as Map<String, dynamic>)
                  .entries)
            StrategyGroup(
              name: item.key,
              rawType: item.value['type'] as String,
              hidden: false,
              now: item.value['member'] as String? ?? 'Auto',
              fixed: item.value['type'] == 'select'
                  ? ''
                  : item.value['member'] as String? ?? '',
              members: const [],
            ),
        ],
      );
  final events = <String>[];
  List<Map<String, Object?>>? publishedTargets;
  final publishedKinds = <String>[];
  @override
  Future<void> syncSchedules(
    List<Map<String, Object?>> targets, {
    required String kind,
  }) async {
    publishedKinds.add(kind);
    publishedTargets = [
      for (final target in publishedTargets ?? const <Map<String, Object?>>[])
        if (target['kind'] != kind) target,
      ...targets,
    ];
  }

  Map<String, dynamic>? startedInput;
  AppSnapshot state = AppSnapshot(
    phase: 'RUNNING',
    generation: 4,
    configId: 'one',
    revision: 1,
    mode: TunnelMode.global,
    core: const CoreSnapshot(
      generation: 8,
      phase: 'READY',
      purpose: 'RUNNING',
      configId: 'one',
      revision: 1,
      composition: '["one",1]',
    ),
  );
  Completer<void>? stageWait;
  bool expired = false;
  bool failStart = false;
  void Function()? afterStop;

  int snapshotCalls = 0;
  void Function(int)? beforeSnapshot;
  @override
  Future<AppSnapshot> snapshot() async {
    beforeSnapshot?.call(++snapshotCalls);
    return state;
  }

  @override
  Future<void> stage(dynamic message) async => stageWait?.future;
  @override
  Future<void> checkOperation() async {
    if (expired) throw PlatformFailure(code: 'expired');
  }

  int handoffCalls = 0;
  Map<String, Object?>? handedOff;
  Future<void> Function()? beforeScheduledApply;
  @override
  Future<void> finishScheduledDownload(
    AppSnapshot expected, {
    required String kind,
    required String id,
  }) async {
    handoffCalls++;
    handedOff = {'expected': expected, 'kind': kind, 'id': id};
    await beforeScheduledApply?.call();
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
    startedInput =
        jsonDecode(await input.readAsString()) as Map<String, dynamic>;
    expect(startedInput!['mode'], mode?.name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ConfigStore configs;
  late OverrideStore overrides;
  late _Download download;
  late _Platform platform;
  late ScheduleActions actions;
  const config = ConfigEntry(
    id: 'one',
    name: 'One',
    source: 'https://fixture.test/config',
    revision: 1,
    body: 'rules: [MATCH,DIRECT]',
    update: UpdatePolicy(enabled: true),
  );
  const part = OverrideEntry(
    id: 'part',
    name: 'Part',
    kind: ConfigKind.remote,
    source: 'https://fixture.test/part',
    revision: 1,
    body: 'dns: {enable: true}',
    enabled: true,
    update: UpdatePolicy(enabled: true),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('schedule-actions-');
    configs = ConfigStore(directory);
    overrides = OverrideStore(directory);
    download = _Download();
    platform = _Platform(File('${directory.path}/owned.input'));
    actions = ScheduleActions(
      configs,
      overrides,
      download,
      platform,
      runInput: platform.input,
    );
    await configs.save(ConfigCollection(entries: [config], selectedId: 'one'));
  });
  tearDown(() => directory.delete(recursive: true));

  for (final kind in ['config', 'override']) {
    test(
      '$kind body refresh adopts saved mode fallback without routing override',
      () async {
        await configs.save(
          ConfigCollection(
            entries: [config],
            selectedId: config.id,
            mode: TunnelMode.direct,
          ),
        );
        await overrides.save([part]);
        platform.loadParts([
          {
            'id': part.id,
            'name': part.name,
            'role': null,
            'revision': part.revision,
            'mode': 'replace',
            'body': part.body,
            'source': part.source,
          },
        ]);
        final result = await actions.refresh(
          kind,
          kind == 'config' ? config.id : part.id,
        );
        expect(result['scheduleStatus'], 'applied');
        expect(platform.startedInput!['mode'], 'direct');
        expect(platform.startedInput!['routingOverride'], isNull);
        expect(
          platform.startedInput!['body'],
          kind == 'config' ? download.body : config.body,
        );
      },
    );
  }

  test(
    'sync replaces the full saved target set after disable and delete',
    () async {
      await overrides.save([part]);
      await actions.sync();
      expect(platform.publishedTargets, [
        {'kind': 'config', 'id': 'one', 'hours': 24},
        {'kind': 'override', 'id': 'part', 'hours': 24},
      ]);
      await configs.save(
        ConfigCollection(
          entries: [config.withUpdate(config.update.changed(enabled: false))],
          selectedId: 'one',
        ),
      );
      await overrides.save([]);
      await actions.sync();
      expect(platform.publishedTargets, isEmpty);
      expect(platform.events, isEmpty);
    },
  );

  for (final brokenKind in ['config', 'override']) {
    test('unreadable $brokenKind keeps its tasks while the other kind reconciles', () async {
      await configs.save(ConfigCollection(entries: []));
      await overrides.save([]);
      final broken = File(
        '${directory.path}/${brokenKind == 'config' ? 'configurations' : 'overrides'}.json',
      );
      await broken.writeAsString('{broken');
      platform.publishedTargets = [
        {'kind': 'config', 'id': 'previous-config', 'hours': 6},
        {'kind': 'override', 'id': 'previous-override', 'hours': 12},
      ];
      await expectLater(
        actions.sync(),
        throwsA(
          isA<ConfigFailure>()
              .having(
                (failure) => failure.message.id,
                'overall result',
                'operationNotCompletedRetry',
              )
              .having(
                (failure) => failure.message.detail,
                'original error',
                contains('FormatException'),
              ),
        ),
      );
      expect(platform.publishedKinds, [
        brokenKind == 'config' ? 'override' : 'config',
      ]);
      expect(platform.publishedTargets, [
        {
          'kind': brokenKind,
          'id': 'previous-$brokenKind',
          'hours': brokenKind == 'config' ? 6 : 12,
        },
      ]);
      expect(await broken.readAsString(), '{broken');
      expect(platform.snapshotCalls, 0);
      expect(platform.events, isEmpty);
    });
  }

  test('disabled and deleted targets do not download or reconnect', () async {
    await configs.save(
      ConfigCollection(
        entries: [config.withUpdate(config.update.changed(enabled: false))],
        selectedId: 'one',
      ),
    );
    expect(
      (await actions.refresh('config', 'one'))['scheduleStatus'],
      'skipped',
    );
    expect(
      (await actions.refresh('override', 'missing'))['scheduleStatus'],
      'skipped',
    );
    expect(download.started.isCompleted, isFalse);
    expect(platform.events, isEmpty);
  });

  test(
    'auto-apply writes operation input before starting and clears it',
    () async {
      final outcome = await actions.refresh('config', 'one');
      expect(outcome['scheduleStatus'], 'applied');
      expect(platform.events, ['stop', 'start']);
      expect(platform.startedInput!['body'], download.body);
      expect(platform.startedInput!['mode'], isNull);
      expect(platform.startedInput!['routingOverride'], isNull);
      expect(await platform.input.exists(), isFalse);
      expect((await configs.read()).selected!.update.lastResult, 'applied');
    },
  );

  for (final kind in ['config', 'override']) {
    test(
      '$kind hands off only the saved input before reconnect Stop',
      () async {
        await overrides.save([part]);
        platform.loadParts([
          {
            'id': part.id,
            'name': part.name,
            'role': null,
            'revision': part.revision,
            'mode': 'replace',
            'body': part.body,
            'source': part.source,
          },
        ]);
        final running = platform.state;
        final id = kind == 'config' ? config.id : part.id;
        platform.beforeScheduledApply = () async {
          expect(platform.events, isEmpty);
          expect(platform.handoffCalls, 1);
          expect(platform.handedOff, {
            'expected': running,
            'kind': kind,
            'id': id,
          });
          final saved = kind == 'config'
              ? (await configs.read()).find(id)!.body
              : (await overrides.read()).single.body;
          expect(saved, download.body);
          final input = jsonDecode(await platform.input.readAsString()) as Map;
          if (kind == 'config') {
            expect(input['revision'], 2);
            expect(input['body'], saved);
          } else {
            expect((input['overrides'] as List).single['revision'], 2);
            expect((input['overrides'] as List).single['body'], saved);
          }
        };
        expect((await actions.refresh(kind, id))['scheduleStatus'], 'applied');
        expect(platform.events, ['stop', 'start']);
        expect(platform.handoffCalls, 1);
        expect(await platform.input.exists(), isFalse);
      },
    );

    test('$kind rejected handoff preserves the running VPN', () async {
      await overrides.save([part]);
      platform.loadParts([
        {
          'id': part.id,
          'name': part.name,
          'role': null,
          'revision': part.revision,
          'mode': 'replace',
          'body': part.body,
          'source': part.source,
        },
      ]);
      final running = platform.state;
      platform.beforeScheduledApply = () async {
        throw PlatformException(code: 'expired');
      };
      final outcome = await actions.refresh(
        kind,
        kind == 'config' ? config.id : part.id,
      );
      expect(outcome['scheduleStatus'], 'applyFailed');
      expect(platform.handoffCalls, 1);
      expect(platform.events, isEmpty);
      expect(platform.state, same(running));
      expect(await platform.input.exists(), isFalse);
      final policy = kind == 'config'
          ? (await configs.read()).find(config.id)!.update
          : (await overrides.read()).single.update;
      expect(policy.lastResult, 'applyFailed');
    });
  }

  test(
    'saved enabled override outside running composition does not reconnect',
    () async {
      await overrides.save([part]);
      final outcome = await actions.refresh('override', 'part');
      expect(outcome['scheduleStatus'], 'saved');
      expect(platform.events, isEmpty);
      expect((await overrides.read()).single.revision, 2);
    },
  );

  test('download finishing after user stop saves without restarting', () async {
    download.pending = Completer<String>();
    final refresh = actions.refresh('config', 'one');
    await download.started.future;
    platform.state = const AppSnapshot(phase: 'STOPPED', generation: 4);
    download.pending!.complete(download.body);
    expect((await refresh)['scheduleStatus'], 'saved');
    expect(platform.events, isEmpty);
  });

  test(
    'config auto-apply preserves loaded fragments, access and choices',
    () async {
      platform.loadParts([
        {
          'id': 'part',
          'name': part.name,
          'role': null,
          'revision': 1,
          'mode': 'replace',
          'body': part.body,
          'source': part.source,
        },
        {
          'id': 'local',
          'name': 'Loaded local',
          'role': null,
          'revision': 3,
          'mode': 'prepend',
          'body': 'ipv6: false',
          'source': null,
        },
      ]);
      platform.loaded['access'] = 'only';
      platform.loaded['packages'] = ['fixture.loaded'];
      platform.loaded['choices'] = {
        'Proxy': {'type': 'select', 'member': 'Loaded'},
      };
      await overrides.save([
        part
            .changed(mode: OverrideMode.prepend)
            .withContent('dns: {enable: false}'),
      ]);
      final outcome = await actions.refresh('config', 'one');
      expect(outcome['scheduleStatus'], 'applied');
      expect(platform.startedInput!['overrides'], platform.loaded['overrides']);
      expect(platform.startedInput!['access'], 'only');
      expect(platform.startedInput!['packages'], ['fixture.loaded']);
      expect(platform.startedInput!['choices'], platform.loaded['choices']);
      expect(platform.startedInput!['mode'], isNull);
      expect(platform.startedInput!['routingOverride'], isNull);
    },
  );

  test('override auto-apply does not import pending main, order, mode or membership', () async {
    platform.loadParts([
      {
        'id': 'local',
        'name': 'Loaded local',
        'role': null,
        'revision': 3,
        'mode': 'prepend',
        'body': 'ipv6: false',
        'source': null,
      },
      {
        'id': 'part',
        'name': part.name,
        'role': null,
        'revision': 1,
        'mode': 'replace',
        'body': part.body,
        'source': part.source,
      },
    ]);
    await configs.save(
      ConfigCollection(
        entries: [config.withContent('rules: [MATCH,REJECT]')],
        selectedId: 'one',
      ),
    );
    await overrides.save([
      part.changed(enabled: false, mode: OverrideMode.prepend),
    ]);
    final outcome = await actions.refresh('override', 'part');
    expect(outcome['scheduleStatus'], 'applied');
    expect(platform.startedInput!['revision'], 1);
    expect(platform.startedInput!['body'], config.body);
    expect(
      platform.startedInput!['composition'],
      '["one",1,["local",3,"prepend"],["part",2,"replace"]]',
    );
    final parts = platform.startedInput!['overrides'] as List;
    expect(parts.first, (platform.loaded['overrides'] as List).first);
    expect(parts.last['body'], download.body);
    expect(parts.last['mode'], 'replace');
    final saved = (await overrides.read()).single;
    expect(saved.enabled, isFalse);
    expect(saved.mode, OverrideMode.prepend);
    expect(saved.update.lastResult, 'applied');
  });

  test('target content update uses actual saved revision despite loaded divergence', () async {
    platform.loaded['source'] = 'https://fixture.test/old-source';
    expect(
      (await actions.refresh('config', 'one'))['scheduleStatus'],
      'applied',
    );
    expect(platform.startedInput!['revision'], 2);
    expect(platform.events, ['stop', 'start']);
    platform.events.clear();
    platform.loadParts([
      {
        'id': 'part',
        'name': part.name,
        'role': null,
        'revision': 7,
        'mode': 'prepend',
        'body': part.body,
        'source': part.source,
      },
    ]);
    await overrides.save([part]);
    expect(
      (await actions.refresh('override', 'part'))['scheduleStatus'],
      'applied',
    );
    expect(platform.events, ['stop', 'start']);
    expect((platform.startedInput!['overrides'] as List).single['revision'], 2);
  });

  test('changed source during download cannot publish old response', () async {
    download.pending = Completer<String>();
    final refresh = actions.refresh('config', 'one');
    await download.started.future;
    await configs.save(
      ConfigCollection(
        entries: [config.withSource('https://fixture.test/new')],
        selectedId: 'one',
      ),
    );
    download.pending!.complete(download.body);
    expect((await refresh)['scheduleStatus'], 'skipped');
    expect((await configs.read()).selected!.body, config.body);
    expect(platform.events, isEmpty);
  });

  for (final kind in ['config', 'override']) {
    test(
      'late failed $kind response cannot annotate a changed target',
      () async {
        await overrides.save([part]);
        download.pending = Completer<String>();
        final pending = actions.refresh(
          kind,
          kind == 'config' ? config.id : part.id,
        );
        await download.started.future;
        if (kind == 'config') {
          await configs.save(
            ConfigCollection(
              entries: [config.withSource('https://new.test/main')],
              selectedId: config.id,
            ),
          );
        } else {
          await overrides.save([part.changed(source: 'https://new.test/part')]);
        }
        download.pending!.completeError(ConfigFailure(messages.downloadFailed));
        final result = await pending;
        expect(
          result['scheduleStatus'],
          kind == 'override' ? 'skipped' : 'failed',
        );
        if (kind == 'override') {
          // C6 conversion failures, like successes, belong to the captured
          // source/revision/options rather than the replacement record.
          expect(result['message'], messages.overrideChangedNotApplied);
        }
        expect((await configs.read()).selected!.update.lastResult, isNull);
        expect((await overrides.read()).single.update.lastResult, isNull);
        expect(platform.events, isEmpty);
      },
    );
  }

  for (final kind in ['config', 'override']) {
    for (final afterDeadline in [false, true]) {
      test(
        afterDeadline
            ? '$kind deletion after download deadline survives late transport drain'
            : 'late successful $kind download cannot revive an externally deleted target',
        () async {
          await overrides.save([part]);
          platform.loadParts([
            {
              'id': part.id,
              'name': part.name,
              'role': null,
              'revision': part.revision,
              'mode': 'replace',
              'body': part.body,
              'source': part.source,
            },
          ]);
          final running = platform.state;
          final transport = Completer<void>();
          final client = _PendingClient()..getGate = transport;
          addTearDown(() {
            if (!transport.isCompleted) transport.complete();
          });
          final scheduled = ScheduleActions(
            configs,
            overrides,
            ConfigDownloader(
              timeout: afterDeadline
                  ? const Duration(seconds: 1)
                  : const Duration(seconds: 10),
              createClient: () => client,
            ),
            platform,
            runInput: platform.input,
          );
          var settled = false;
          final refresh = scheduled
              .refresh(kind, kind == 'config' ? config.id : part.id)
              .whenComplete(() => settled = true);
          await client.started.future.timeout(const Duration(seconds: 5));
          expect(settled, isFalse);
          expect(client.uris, [
            Uri.parse(kind == 'config' ? config.source! : part.source!),
          ]);
          expect(client.requests, isEmpty);
          expect(client.closed, isFalse);
          expect(client.closeCalls, 0);

          if (afterDeadline) {
            // The deadline settles the operation result, not the pending transport.
            final result = await refresh.timeout(const Duration(seconds: 5));
            expect(result['scheduleStatus'], 'failed');
            final message = result['message'] as AppMessage;
            expect(message.id, messages.downloadTimeout.id);
            expect(message.detail, contains('TimeoutException'));
            expect(message.detail, contains('Future not completed'));
            expect(client.closed, isTrue);
            expect(client.closeCalls, 1);
            expect(client.requests, isEmpty);
            expect(transport.isCompleted, isFalse);
            final saved = (await configs.read()).selected!;
            expect(saved.revision, config.revision);
            expect(saved.body, config.body);
            final savedPart = (await overrides.read()).single;
            expect(savedPart.revision, part.revision);
            expect(savedPart.body, part.body);
          }

          // Change persisted identity externally to test invalidation during refresh;
          // ordinary commands use the writer gate.
          if (kind == 'config') {
            await configs.save(ConfigCollection(entries: []));
          } else {
            await overrides.save([]);
          }
          final deleted = {
            for (final name in ['configurations.json', 'overrides.json'])
              name: await File('${directory.path}/$name').readAsString(),
          };
          transport.complete();
          if (afterDeadline) {
            await client.returned.future.timeout(const Duration(seconds: 5));
            await Future<void>.delayed(Duration.zero);
            expect(client.requests.single.aborted, isTrue);
            expect(client.uris, hasLength(1));
          } else {
            final result = await refresh.timeout(const Duration(seconds: 5));
            expect(result['scheduleStatus'], 'skipped');
            expect(
              result['message'],
              kind == 'config'
                  ? messages.configChangedDownloadUnapplied
                  : messages.overrideChangedNotApplied,
            );
            expect(
              client.requests.map((request) => request.response.statusCode),
              [HttpStatus.found, HttpStatus.ok],
            );
            expect(
              client.requests.every((request) => !request.aborted),
              isTrue,
            );
          }

          expect(client.closed, isTrue);
          expect(client.closeCalls, 1);
          for (final entry in deleted.entries) {
            expect(
              await File('${directory.path}/${entry.key}').readAsString(),
              entry.value,
            );
            expect(
              await File('${directory.path}/${entry.key}.tmp').exists(),
              isFalse,
            );
          }
          if (kind == 'config') {
            final saved = await configs.read();
            expect(saved.find(config.id), isNull);
            expect(saved.entries, isEmpty);
            expect(saved.selectedId, isNull);
            expect(saved.selected, isNull);
          } else {
            expect(await overrides.read(), isEmpty);
            expect((await configs.read()).selected!.toJson(), config.toJson());
          }
          expect(platform.events, isEmpty);
          expect(platform.snapshotCalls, 0);
          expect(platform.state, same(running));
          expect(platform.startedInput, isNull);
          expect(await platform.input.exists(), isFalse);
        },
      );
    }
  }

  test('input write failure never tears down the running tunnel', () async {
    await Directory(platform.input.path).create();
    expect(
      (await actions.refresh('config', 'one'))['scheduleStatus'],
      'applyFailed',
    );
    expect(platform.events, isEmpty);
  });

  test(
    'failed reconnect clears input and is not retried for unchanged content',
    () async {
      platform.failStart = true;
      expect(
        (await actions.refresh('config', 'one'))['scheduleStatus'],
        'applyFailed',
      );
      expect(await platform.input.exists(), isFalse);
      expect((await configs.read()).selected!.update.lastResult, 'applyFailed');
      expect(
        (await actions.refresh('config', 'one'))['scheduleStatus'],
        'unchanged',
      );
      expect(platform.events, ['stop', 'start']);
    },
  );

  test(
    'override reconnect failure records applyFailed and clears input',
    () async {
      platform.loadParts([
        {
          'id': 'part',
          'name': part.name,
          'role': null,
          'revision': 1,
          'mode': 'prepend',
          'body': part.body,
          'source': part.source,
        },
      ]);
      await overrides.save([part]);
      platform.failStart = true;
      expect(
        (await actions.refresh('override', 'part'))['scheduleStatus'],
        'applyFailed',
      );
      expect((await overrides.read()).single.update.lastResult, 'applyFailed');
      expect(await platform.input.exists(), isFalse);
    },
  );

  test(
    'reconnect preserves actual choices rather than failed desired choices',
    () async {
      platform.loaded['choices'] = {
        'Proxy': {'type': 'select', 'member': 'Failed desired'},
        'Automatic': {'type': 'url-test', 'member': 'Failed fixed'},
      };
      platform.actualChoices = {
        'Proxy': {'type': 'select', 'member': 'Actual'},
        'Automatic': {'type': 'url-test', 'member': null},
      };
      expect(
        (await actions.refresh('config', 'one'))['scheduleStatus'],
        'applied',
      );
      expect(platform.startedInput!['choices'], platform.actualChoices);
    },
  );

  test('owner cancellation after internal stop cannot start again', () async {
    platform.afterStop = () => platform.expired = true;
    expect(
      (await actions.refresh('config', 'one'))['scheduleStatus'],
      'applyFailed',
    );
    expect(platform.events, ['stop']);
    expect(await platform.input.exists(), isFalse);
  });

  for (final changed in ['session', 'core', 'composition', 'mode', 'phase']) {
    test(
      'a changed running $changed is rejected before internal stop',
      () async {
        platform.beforeSnapshot = (calls) {
          if (calls != 2) return;
          platform.state = AppSnapshot(
            phase: 'RUNNING',
            generation: changed == 'session' ? 5 : 4,
            configId: 'one',
            revision: 1,
            mode: changed == 'mode' ? TunnelMode.direct : TunnelMode.global,
            core: CoreSnapshot(
              generation: changed == 'core' ? 9 : 8,
              phase: changed == 'phase' ? 'FAILED' : 'READY',
              purpose: 'RUNNING',
              configId: 'one',
              revision: 1,
              composition: changed == 'composition'
                  ? '["one",1,["other",1,"prepend"]]'
                  : '["one",1]',
            ),
          );
        };
        expect(
          (await actions.refresh('config', 'one'))['scheduleStatus'],
          'applyFailed',
        );
        expect(platform.events, isEmpty);
        expect(await platform.input.exists(), isFalse);
      },
    );
  }

  for (final kind in ['config', 'override']) {
    for (final failApply in [false, true]) {
      test(
        '$kind diagnostic failure retains saved body and actual application $failApply',
        () async {
          await overrides.save([part]);
          platform.loadParts([
            {
              'id': part.id,
              'name': part.name,
              'role': null,
              'revision': part.revision,
              'mode': 'replace',
              'body': part.body,
              'source': part.source,
            },
          ]);
          var applying = false;
          platform.beforeScheduledApply = () async {
            applying = true;
          };
          platform.failStart = failApply;
          final failure = StateError('diagnostic write failed');
          Future<void> beforeWrite() async {
            if (applying) throw failure;
          }

          final action = ScheduleActions(
            kind == 'config'
                ? ConfigStore(directory, beforeWrite: beforeWrite)
                : configs,
            kind == 'override'
                ? OverrideStore(directory, beforeWrite: beforeWrite)
                : overrides,
            download,
            platform,
            runInput: platform.input,
          );
          final id = kind == 'config' ? config.id : part.id;
          final outcome = await action.refresh(kind, id);
          final status = failApply ? 'applyFailed' : 'applied';
          expect(outcome['scheduleStatus'], status);
          expect(outcome['success'], isFalse);
          expect(outcome['targetId'], id);
          expect(outcome['savedRevision'], 2);
          expect(action.result, {
            'scheduleStatus': status,
            'targetId': id,
            'savedRevision': 2,
          });
          final message = outcome['message'] as AppMessage;
          expect(message.text, contains('diagnostic write failed'));
          if (failApply) expect(message.text, contains('start'));
          expect(platform.events, ['stop', 'start']);
          expect(await platform.input.exists(), isFalse);
          if (kind == 'config') {
            final saved = (await configs.read()).selected!;
            expect(saved.body, download.body);
            expect(saved.revision, 2);
            expect(saved.update.lastResult, 'updated');
          } else {
            final saved = (await overrides.read()).single;
            expect(saved.body, download.body);
            expect(saved.revision, 2);
            expect(saved.update.lastResult, 'updated');
          }
        },
      );
    }
  }

  test('unchanged override checks never retry failed application', () async {
    platform.loadParts([
      {
        'id': part.id,
        'name': part.name,
        'role': null,
        'revision': part.revision,
        'mode': 'replace',
        'source': part.source,
        'body': part.body,
      },
    ]);
    await overrides.save([part]);
    platform.failStart = true;
    expect(
      (await actions.refresh('override', part.id))['scheduleStatus'],
      'applyFailed',
    );
    platform.failStart = false;
    platform.loadParts([
      {
        'id': part.id,
        'name': part.name,
        'role': null,
        'revision': part.revision,
        'mode': 'replace',
        'source': part.source,
        'body': part.body,
      },
    ]);
    expect(
      (await actions.refresh('override', part.id))['scheduleStatus'],
      'unchanged',
    );
    expect(platform.events, ['stop', 'start']);
    expect((await overrides.read()).single.revision, 2);
  });

  test('owner cancellation before reconnect never stops or starts', () async {
    platform.stageWait = Completer<void>();
    final refresh = actions.refresh('config', 'one');
    while ((await configs.read()).selected!.revision == 1) {
      await Future<void>.delayed(Duration.zero);
    }
    platform.expired = true;
    platform.stageWait!.complete();
    final outcome = await refresh;
    expect(outcome['scheduleStatus'], 'applyFailed');
    expect(platform.events, isEmpty);
  });
}
