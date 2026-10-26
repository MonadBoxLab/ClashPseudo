import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/app_runtime.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/logic/preferences_store.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late AppRuntime runtime;
  late List<String> inputOwners;
  late List<Map<String, dynamic>> preparedInputs;
  Completer<void>? stageWait;
  late Map<String, Object?> snapshot;
  PlatformException? writeFailure;
  PlatformException? stopFailure;
  int stops = 0;
  final schedules = <List>[];
  final starts = <Map<String, dynamic>>[];
  Map<String, dynamic>? submitted;
  final resourceUpdates = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? resourceReply;

  Future<Object?> send(String method, Object? arguments) {
    final result = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(
      AppBridge.channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      result.complete,
    );
    return result.future.then((value) => codec.decodeEnvelope(value!));
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-runtime-');
    inputOwners = [];
    preparedInputs = [];
    stageWait = null;
    snapshot = {'phase': 'STOPPED'};
    writeFailure = null;
    stopFailure = null;
    stops = 0;
    resourceUpdates.clear();
    resourceReply = null;
    schedules.clear();
    starts.clear();
    await ConfigStore(directory).save(
      ConfigCollection(
        entries: const [
          ConfigEntry(
            id: 'one',
            name: 'fixture',
            source: 'https://fixture.test/config',
            revision: 1,
            body: 'rules:\n  - MATCH,DIRECT\n',
          ),
        ],
        selectedId: 'one',
      ),
    );
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'submit':
          submitted = args;
          return {'operationId': 'save-codec', 'remainingMs': 120000};
        case 'operationRemaining':
          return 120000;
        case 'trustRoots':
          return Uint8List(0);
        case 'ready':
          return null;
        case 'refreshStrings':
          return null;
        case 'checkOperation':
          if (writeFailure != null) throw writeFailure!;
          return null;
        case 'stop':
          stops++;
          if (stopFailure != null) throw stopFailure!;
          return null;
        case 'paths':
          return {
            'configs': directory.path,
            'storageEpoch': 1,
            'runInput': '${directory.path}/${args['owner']}.input',
          };
        case 'publishStore':
          expect(args['epoch'], 1);
          final file = args['file'] as String;
          expect([
            'configurations.json',
            'overrides.json',
            'preferences.json',
          ], contains(file));
          final staged = File('${directory.path}/$file.tmp');
          expect(await staged.exists(), isTrue);
          await staged.rename('${directory.path}/$file');
          return {'saved': true, 'durable': true, 'epoch': 1};
        case 'updateResource':
          resourceUpdates.add(args);
          return jsonEncode(await resourceReply!.future);
        case 'runningInput':
          final core = snapshot['core'] as Map;
          return Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'id': snapshot['configId'],
                'name': 'Local',
                'revision': snapshot['revision'],
                'body': 'old',
                'mode': null,
                'routingOverride': null,
                'source': null,
                'overrides': [],
                'choices': {},
                'composition': core['composition'],
                'access': 'all',
                'packages': [],
              }),
            ),
          );
        case 'strategies':
          return jsonEncode({
            ...snapshot['core'] as Map,
            'globalReferenced': false,
            'groups': [],
            'unrestored': [],
          });
        case 'snapshot':
          return snapshot;
        case 'syncSchedules':
          schedules.add(args['targets'] as List);
          return null;
        case 'start':
          starts.add(args);
          return null;
        case 'stage':
          await stageWait?.future;
          return null;
        case 'prepareStrategies':
          final owner = args['owner'] as String;
          expect(await File('${directory.path}/$owner.input').exists(), isTrue);
          inputOwners.add(owner);
          preparedInputs.add(
            jsonDecode(
              await File('${directory.path}/$owner.input').readAsString(),
            ) as Map<String, dynamic>,
          );
          return '{}';
        default:
          throw MissingPluginException(call.method);
      }
    });
    runtime = AppRuntime();
    await runtime.start();
  });
  tearDown(() async {
    stageWait?.complete();
    AppBridge.channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(AppBridge.channel, null);
    await directory.delete(recursive: true);
  });

  const resourceCore = <String, Object?>{
    'generation': 7,
    'composition': '["actual",2]',
    'configId': 'actual',
    'revision': 2,
    'purpose': 'VPN',
  };
  Map<String, Object?> resourceCommand() => {
    'owner': 'resource-owner',
    'action': 'updateResource',
    ...resourceCore,
    'kind': 'proxyProvider',
    'name': 'remote',
  };

  for (final status in ['ok', 'updateFailed', 'stopped']) {
    test(
      'resource business admission waits for actual $status outcome',
      () async {
        snapshot = {
          'phase': 'RUNNING',
          'mode': 'rule',
          'core': {'phase': 'READY', ...resourceCore},
        };
        resourceReply = Completer<Map<String, dynamic>>();
        var settled = false;
        final pending = send('execute', resourceCommand()).then((value) {
          settled = true;
          return value as Map;
        });
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
        expect(resourceUpdates.single['owner'], 'resource-owner');
        expect(resourceUpdates.single['configId'], 'actual');
        expect(resourceUpdates.single['revision'], 2);
        expect(resourceUpdates.single['purpose'], 'VPN');
        resourceReply!.complete({
          ...resourceCore,
          'update': status == 'ok' ? {'status': 'ok'} : {'error': status},
        });
        final result = await pending;
        expect(result['success'], status == 'ok');
        expect(result['resourceStatus'], status);
        expect(starts, isEmpty);
        expect(stops, 0);
      },
    );
  }

  for (final field in resourceCore.keys) {
    test('resource business admission rejects stale $field', () async {
      snapshot = {
        'phase': 'RUNNING',
        'mode': 'rule',
        'core': {'phase': 'READY', ...resourceCore},
      };
      final command = resourceCommand()..remove(field);
      final result = await send('execute', command) as Map;
      expect(result['success'], isFalse);
      expect(result['resourceStatus'], 'unconfirmed');
      expect(resourceUpdates, isEmpty);
    });
  }

  for (final response in [
    <String, dynamic>{
      ...resourceCore,
      'composition': 'stale',
      'update': {'status': 'ok'},
    },
    <String, dynamic>{
      ...resourceCore,
      'update': {'status': 'ok', 'error': 'ok'},
    },
    <String, dynamic>{...resourceCore, 'update': <String, dynamic>{}},
  ]) {
    test(
      'resource malformed or stale completion is not confirmed ${response['update']}',
      () async {
        snapshot = {
          'phase': 'RUNNING',
          'mode': 'rule',
          'core': {'phase': 'READY', ...resourceCore},
        };
        resourceReply = Completer<Map<String, dynamic>>();
        final pending = send('execute', resourceCommand());
        await Future<void>.delayed(Duration.zero);
        resourceReply!.complete(response);
        final result = await pending as Map;
        expect(result['success'], isFalse);
        expect(result['resourceStatus'], 'unconfirmed');
      },
    );
  }

  test('resource canceled owner cannot report late native success', () async {
    snapshot = {
      'phase': 'RUNNING',
      'mode': 'rule',
      'core': {'phase': 'READY', ...resourceCore},
    };
    resourceReply = Completer<Map<String, dynamic>>();
    final pending = send('execute', resourceCommand());
    await Future<void>.delayed(Duration.zero);
    expect(resourceUpdates, hasLength(1));
    await send('cancel', 'resource-owner');
    final result = await pending as Map;
    expect(result['success'], isFalse);
    expect(result['resourceStatus'], 'unconfirmed');
    resourceReply!.complete({
      ...resourceCore,
      'update': {'status': 'ok'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(starts, isEmpty);
  });

  test(
    'override update policy reaches override actions and saved schedule sync',
    () async {
      await OverrideStore(directory).save(const [
        OverrideEntry(
          id: 'remote-part',
          name: 'Part',
          kind: ConfigKind.remote,
          revision: 1,
          body: '{}',
          source: 'https://fixture.test/part',
        ),
      ]);
      final result = await send('execute', {
        'owner': 'schedule-policy',
        'action': 'setOverrideUpdate',
        'id': 'remote-part',
        'enabled': true,
        'hours': 12,
      }) as Map;
      expect(result['success'], isTrue);
      final policy = (await OverrideStore(directory).read()).single.update;
      expect(policy.enabled, isTrue);
      expect(policy.hours, 12);
      expect(schedules.single.single['id'], 'remote-part');
      schedules.clear();
      final synced = await send('execute', {
        'owner': 'calibrate',
        'action': 'syncSchedules',
      }) as Map;
      expect(synced['success'], isTrue);
      expect(schedules.single, [
        {'kind': 'override', 'id': 'remote-part', 'hours': 12},
      ]);
      schedules.clear();
      final deleted = await send('execute', {
        'owner': 'delete-scheduled-part',
        'action': 'deleteOverride',
        'id': 'remote-part',
      }) as Map;
      expect(deleted['success'], isTrue);
      expect(schedules.single, isEmpty);
      expect(await OverrideStore(directory).read(), isEmpty);
    },
  );

  test('HTTP replacement reports ordinary download failure and preserves the saved record', () async {
    const part = OverrideEntry(
      id: 'remote',
      name: 'Remote',
      kind: ConfigKind.remote,
      source: 'https://fixture.test/old',
      revision: 1,
      body: '{}',
      enabled: true,
    );
    await OverrideStore(directory).save([part]);
    final result = await send('execute', {
      'owner': 'change-source',
      'action': 'changeOverrideSource',
      'id': 'remote',
      'source': 'http://fixture.test/new',
    }) as Map;
    expect(result['success'], isFalse);
    expect(result['overrideStatus'], 'notSaved');
    // The binding's HTTP400 client supplies a normal transport failure.
    expect(result['message'], messages.downloadHttpStatus('400').toMap());
    expect(
      (await OverrideStore(directory).read()).single.toJson(),
      part.toJson(),
    );
    expect(stops, 0);
    expect(starts, isEmpty);
  });

  test(
    'override save crosses both codecs without modifying original text',
    () async {
      const body = '\u{feff}dns:\r\n  enable: true\n';
      final admission = await AppBridge().submit({
        'action': 'saveOverride',
        'name': 'Part',
        'body': body,
      });
      final result = await send('execute', {
        ...submitted!,
        'owner': admission!.operationId,
      }) as Map;
      expect(result['success'], isTrue);
      expect(result['overrideStatus'], 'saved');
      expect(result['configStatus'], isNull);
      final part = (await OverrideStore(directory).read()).single;
      expect(part.body, body);
      expect(part.id, result['targetId']);
      expect(part.enabled, isTrue);
      expect(stops, 0);
      final enabled = await send('execute', {
        'owner': 'enable-part',
        'action': 'changeOverride',
        'id': part.id,
        'enabled': true,
      }) as Map;
      expect(enabled['success'], isTrue);
      expect((await OverrideStore(directory).read()).single.enabled, isTrue);
      final prepared = await send('execute', {
        'owner': 'preview-composed',
        'action': 'prepareStrategies',
        'id': 'one',
        'revision': 1,
      }) as Map;
      expect(prepared['success'], isTrue);
      final input = preparedInputs.single;
      expect((input['overrides'] as List).single['body'], body);
      expect((input['overrides'] as List).single['name'], part.name);
      expect((input['overrides'] as List).single['role'], isNull);
      expect(input['name'], 'fixture');
      expect(jsonDecode(input['composition'] as String), [
        'one',
        1,
        [part.id, 1, 'prepend'],
      ]);
      expect(
        input['body'],
        (await ConfigStore(directory).read()).selected!.body,
      );
      expect(
        await File('${directory.path}/preview-composed.input').exists(),
        isFalse,
      );
    },
  );

  test(
    'expired override write reports notSaved and cannot replace storage',
    () async {
      writeFailure = PlatformException(
        code: 'expired',
        message: 'Owner expired',
      );
      final result = await send('execute', {
        'owner': 'expired',
        'action': 'saveOverride',
        'name': 'Part',
        'body': utf8.encode('{}'),
      }) as Map;
      expect(result['success'], isFalse);
      expect(result['overrideStatus'], 'notSaved');
      expect(await OverrideStore(directory).read(), isEmpty);
      expect(stops, 0);
    },
  );

  test('both platform codec hops preserve BOM and mixed newlines', () async {
    const body = '\u{feff}# 中文🌐\r\nrules:\n  - MATCH,DIRECT\r\n';
    final command = <String, Object?>{
      'action': 'saveLocal',
      'name': 'Codec round trip',
      'body': body,
    };
    final admission = await AppBridge().submit(command);
    final result = await send('execute', {
      ...submitted!,
      'owner': admission!.operationId,
    }) as Map;
    expect(result['configStatus'], 'saved');
    expect((await ConfigStore(directory).read()).entries.last.body, body);
    expect(command['body'], body);
  });

  for (final extra in [0, 1]) {
    test(
      'codec round trip counts BOM at sixteen-mebibyte limit +$extra',
      () async {
        final body = '\u{feff}${'a' * (16 * 1024 * 1024 - 3 + extra)}';
        final admission = await AppBridge().submit({
          'action': 'saveLocal',
          'name': 'Boundary',
          'body': body,
        });
        final result = await send('execute', {
          ...submitted!,
          'owner': admission!.operationId,
        }) as Map;
        final collection = await ConfigStore(directory).read();
        expect(result['configStatus'], extra == 0 ? 'saved' : 'notSaved');
        if (extra == 0) {
          expect(collection.entries.last.body == body, isTrue);
        } else {
          expect(collection.entries, hasLength(1));
        }
        expect(stops, 0);
      },
    );
  }

  test('invalid transported UTF-8 fails before writing or stopping', () async {
    final result = await send('execute', {
      'owner': 'invalid-text',
      'action': 'saveLocal',
      'name': 'Invalid',
      'body': Uint8List.fromList([0xff]),
    }) as Map;
    expect(result['success'], isFalse);
    expect(result['configStatus'], 'notSaved');
    expect((await ConfigStore(directory).read()).entries, hasLength(1));
    expect(stops, 0);
  });

  test(
    'one runtime obtains a fresh owner and input for each command',
    () async {
      for (final owner in ['first', 'second']) {
        final result = await send('execute', {
          'owner': owner,
          'action': 'prepareStrategies',
          'id': 'one',
          'revision': 1,
        }) as Map;
        expect(result['success'], isTrue);
        expect(await File('${directory.path}/$owner.input').exists(), isFalse);
      }
      expect(inputOwners, ['first', 'second']);
    },
  );

  test(
    'runtime serializes saved target and revision with the final result',
    () async {
      final result = await send('execute', {
        'owner': 'save',
        'action': 'saveLocal',
        'name': 'Local',
        'body': utf8.encode(''),
      }) as Map;
      expect(result['success'], isTrue);
      expect(result['configStatus'], 'saved');
      expect(result['savedRevision'], 1);
      final collection = await ConfigStore(directory).read();
      expect(collection.entries.last.id, result['targetId']);
      expect(collection.entries.last.body, '');
      expect(collection.entries.last.kind, ConfigKind.local);
      expect(collection.selectedId, 'one');
      expect(stops, 0);
    },
  );

  test('runtime retains notSaved when owner check rejects the write', () async {
    writeFailure = PlatformException(code: 'expired', message: 'Owner expired');
    final result = await send('execute', {
      'owner': 'expired',
      'action': 'saveLocal',
      'name': 'Local',
      'body': utf8.encode('new'),
    }) as Map;
    expect(result['success'], isFalse);
    expect(result['configStatus'], 'notSaved');
    expect(result['savedRevision'], isNull);
    expect((await ConfigStore(directory).read()).entries, hasLength(1));
    expect(stops, 0);
  });

  test(
    'runtime preserves applyFailed instead of overwriting success field',
    () async {
      await ConfigStore(directory).save(
        ConfigCollection(
          entries: const [
            ConfigEntry(
              id: 'local',
              name: 'Local',
              kind: ConfigKind.local,
              revision: 1,
              body: 'old',
            ),
          ],
          selectedId: 'local',
        ),
      );
      snapshot = {
        'phase': 'RUNNING',
        'generation': 4,
        'configId': 'local',
        'revision': 1,
        'mode': 'rule',
        'core': {
          'phase': 'READY',
          'generation': 8,
          'purpose': 'VPN',
          'configId': 'local',
          'revision': 1,
          'composition': '["local",1]',
        },
      };
      stopFailure = PlatformException(
        code: 'unknown',
        message: 'Stop unconfirmed',
      );
      final result = await send('execute', {
        'owner': 'save-running',
        'action': 'saveLocal',
        'id': 'local',
        'revision': 1,
        'body': utf8.encode('new'),
      }) as Map;
      expect(result['success'], isFalse);
      expect(result['configStatus'], 'applyFailed');
      expect(result['targetId'], 'local');
      expect(result['savedRevision'], 2);
      expect((await ConfigStore(directory).read()).selected!.body, 'new');
      expect(stops, 1);
      expect(inputOwners, isEmpty);
    },
  );

  test(
    'cancel drains the active executor and rejects concurrent commands',
    () async {
      stageWait = Completer<void>();
      final first = send('execute', {'owner': 'first', 'action': 'stop'});
      await Future<void>.delayed(Duration.zero);
      final duplicate =
          await send('execute', {'owner': 'second', 'action': 'stop'}) as Map;
      expect(duplicate['success'], isFalse);
      await send('cancel', 'different');
      final stillBusy =
          await send('execute', {'owner': 'second', 'action': 'stop'}) as Map;
      expect(stillBusy['success'], isFalse);
      await send('cancel', 'first');
      expect((await first as Map)['success'], isFalse);
      stageWait!.complete();
      stageWait = null;
      final next =
          await send('execute', {'owner': 'second', 'action': 'stop'}) as Map;
      expect(next['success'], isTrue);
    },
  );

  test('routing reconnect preference accepts a boolean and preserves other settings', () async {
    for (final value in [true, false]) {
      final result = await send('execute', {
        'owner': 'routing-$value',
        'action': 'setPreference',
        'field': 'reconnectOnRoutingChange',
        'value': value,
      }) as Map;
      expect(result['success'], isTrue);
      final saved = await PreferencesStore(directory).read();
      expect(saved.reconnectOnRoutingChange, value);
      expect(saved.brand, BrandColor.cinnabar);
      expect(starts, isEmpty);
      expect(stops, 0);
    }
    final invalid = await send('execute', {
      'owner': 'invalid-routing',
      'action': 'setPreference',
      'field': 'reconnectOnRoutingChange',
      'value': 'true',
    }) as Map;
    expect(invalid['success'], isFalse);
    expect(
      (await PreferencesStore(directory).read()).reconnectOnRoutingChange,
      isFalse,
    );
  });

  test('language change returns a description resolved by the UI locale', () async {
    final result = await send('execute', {
      'owner': 'language',
      'action': 'setPreference',
      'field': 'language',
      'value': 'en',
    }) as Map;
    expect(result['success'], isTrue);
    expect(result['message'], messages.settingsSaved.toMap());
    final message = AppMessage.fromMap(result['message']);
    setMessageLanguage(AppLanguage.en);
    expect(message.text, 'Settings saved.');
    setMessageLanguage(AppLanguage.zh);
    expect(message.text, '应用设置已保存。');
    final saved = await PreferencesStore(directory).read();
    expect(saved.language, AppLanguage.en);
    // Restore the UI-only display locale; the headless result is untranslated.
    setMessageLanguage(AppLanguage.system);
  });

  test('recreated headless runtimes retain untranslated results independently of UI language', () async {
    addTearDown(() => setMessageLanguage(AppLanguage.system));
    for (final language in ['en', 'zh']) {
      // Keep UI snapshot construction independent of business-runtime initialization.
      setMessageLanguage(AppLanguage.zh);
      AppBridge.channel.setMethodCallHandler(null);
      runtime = AppRuntime();
      await runtime.start();
      final result = await send('execute', {
        'owner': 'recreated-$language',
        'action': 'setPreference',
        'field': 'language',
        'value': language,
      }) as Map;
      expect(result['success'], isTrue);
      expect(result['message'], messages.settingsSaved.toMap());
      expect(messages.settingsSaved.text, '应用设置已保存。');
      final saved = await PreferencesStore(directory).read();
      expect(saved.language.name, language);
      final invalid = await send('execute', {
        'owner': 'invalid-$language',
        'action': 'saveLocal',
        'name': 'Invalid',
        'body': Uint8List.fromList([0xff]),
      }) as Map;
      expect(invalid['success'], isFalse);
      expect(invalid['configStatus'], 'notSaved');
      expect(invalid['message'], messages.textNotUtf8.toMap());
    }
    expect((await ConfigStore(directory).read()).entries, hasLength(1));
    expect(stops, 0);
  });

  test('auto-update policy is stored and published without starting', () async {
    final result = await send('execute', {
      'owner': 'policy',
      'action': 'setConfigUpdate',
      'id': 'one',
      'enabled': true,
      'hours': 12,
    }) as Map;
    expect(result['success'], isTrue);
    final saved = (await ConfigStore(directory).read()).selected!;
    expect(saved.update.enabled, isTrue);
    expect(saved.update.hours, 12);
    expect(stops, 0);
    expect(schedules.last, [
      {'kind': 'config', 'id': 'one', 'hours': 12},
    ]);
  });

  test('HTTP auto-update policy follows the normal schedule path', () async {
    await ConfigStore(directory).save(
      ConfigCollection(
        entries: const [
          ConfigEntry(
            id: 'plain',
            name: 'plain',
            source: 'http://fixture.test/config',
            revision: 1,
            body: 'rules:\n  - MATCH,DIRECT\n',
          ),
        ],
        selectedId: 'plain',
      ),
    );
    final result = await send('execute', {
      'owner': 'http',
      'action': 'setConfigUpdate',
      'id': 'plain',
      'enabled': true,
      'hours': 24,
    }) as Map;
    expect(result['success'], isTrue);
    expect(
      (await ConfigStore(directory).read()).selected!.update.enabled,
      isTrue,
    );
    expect(schedules.single, [
      {'kind': 'config', 'id': 'plain', 'hours': 24},
    ]);
  });

  test(
    'cancelled schedule cannot publish even a failed-download status',
    () async {
      final collection = await ConfigStore(directory).read();
      await ConfigStore(directory).save(
        collection.replace(
          collection.selected!.withUpdate(const UpdatePolicy(enabled: true)),
        ),
      );
      await OverrideStore(directory).save(const [
        OverrideEntry(
          id: 'remote-part',
          name: 'Part',
          kind: ConfigKind.remote,
          source: 'https://fixture.test/part',
          revision: 1,
          body: '{}',
          update: UpdatePolicy(enabled: true),
        ),
      ]);
      writeFailure = PlatformException(
        code: 'expired',
        message: 'Owner expired',
      );
      for (final target in [
        {'kind': 'config', 'id': 'one'},
        {'kind': 'override', 'id': 'remote-part'},
      ]) {
        final result = await send('execute', {
          'owner': 'cancelled-${target['kind']}',
          'action': 'refreshSchedule',
          ...target,
        }) as Map;
        expect(result['success'], isFalse);
      }
      final config = (await ConfigStore(directory).read()).selected!;
      final part = (await OverrideStore(directory).read()).single;
      expect(config.revision, 1);
      expect(config.update.lastAttempt, isNull);
      expect(part.revision, 1);
      expect(part.update.lastAttempt, isNull);
      expect(stops, 0);
      expect(starts, isEmpty);
    },
  );

  test('periodic refresh keeps the old body when the source fails', () async {
    await ConfigStore(directory).save(
      ConfigCollection(
        entries: const [
          ConfigEntry(
            id: 'one',
            name: 'fixture',
            source: 'https://fixture.test/config',
            revision: 1,
            body: 'rules:\n  - MATCH,DIRECT\n',
            update: UpdatePolicy(enabled: true),
          ),
        ],
        selectedId: 'one',
      ),
    );
    final result = await send('execute', {
      'owner': 'refresh',
      'kind': 'config',
      'id': 'one',
      'action': 'refreshSchedule',
    }) as Map;
    expect(result['success'], isFalse);
    expect(result['scheduleStatus'], 'failed');
    final saved = (await ConfigStore(directory).read()).selected!;
    expect(saved.body, 'rules:\n  - MATCH,DIRECT\n');
    expect(saved.revision, 1);
    expect(saved.update.lastResult, 'failed');
    expect(starts, isEmpty);
    expect(stops, 0);
  });
}
