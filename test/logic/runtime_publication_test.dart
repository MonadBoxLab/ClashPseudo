import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/logic/overrides/lan_proxy_settings.dart';
import 'package:yaml/yaml.dart';
import 'package:clash_pseudo/src/platform/app_bootstrap.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppBootstrap bootstrap;
  late Directory directory;
  var durable = true;
  var storageClosed = false;
  var rejectPublication = false;
  var rejectRefresh = false;
  const original =
      'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture';
  var stops = 0;
  var pathReads = 0;
  final publications = <String>[];

  Future<Map> execute(Map<String, Object?> command) async {
    final reply = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(
      AppBridge.channel.name,
      codec.encodeMethodCall(
        MethodCall('execute', {'owner': 'publication-test', ...command}),
      ),
      reply.complete,
    );
    return codec.decodeEnvelope((await reply.future)!) as Map;
  }

  Map<String, Object?> save() => {
    'action': 'saveLocal',
    'name': 'Local',
    'body': utf8.encode('rules:\n  - MATCH,DIRECT\n'),
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('runtime-publication-');
    durable = true;
    storageClosed = false;
    rejectPublication = false;
    rejectRefresh = false;
    stops = 0;
    pathReads = 0;
    publications.clear();
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case ApplicationContract.coreChannelStatus:
          return {'phase': 'disconnected', 'generation': 0};
        case ApplicationContract.coreChannelRuntimeChanged:
          return null;
        case 'ready':
        case 'stage':
        case 'checkOperation':
          return null;
        case 'refreshStrings':
          if (rejectRefresh) {
            throw PlatformException(
              code: 'notification',
              details: {
                'id': 'androidErrorNotificationUpdate',
                'args': <String, Object?>{},
                'detail': original,
              },
            );
          }
          return null;
        case 'snapshot':
          return {'phase': 'STOPPED'};
        case 'paths':
          pathReads++;
          if (storageClosed) throw PlatformException(code: 'storage');
          return {
            'configs': directory.path,
            'runInput': '${directory.path}/run.json',
            'storageEpoch': 4,
          };
        case 'publishStore':
          expect(args['owner'], 'publication-test');
          expect(args['epoch'], 4);
          expect(
            args['file'],
            isIn(['configurations.json', 'overrides.json', 'preferences.json']),
          );
          if (rejectPublication) throw PlatformException(code: 'expired');
          final name = args['file'] as String;
          publications.add(name);
          final temporary = File('${directory.path}/$name.tmp');
          expect(await temporary.exists(), isTrue);
          await temporary.rename('${directory.path}/$name');
          return {
            'saved': true,
            'durable': durable,
            'epoch': 4,
            if (!durable) ...{
              'errorCode': 'publishedDirectorySyncFailed',
              'errorDetail': original,
            },
          };
        case 'stop':
          stops++;
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    bootstrap = AppBootstrap();
    await bootstrap.start();
  });

  tearDown(() async {
    bootstrap.dispose();
    messenger.setMockMethodCallHandler(AppBridge.channel, null);
    await directory.delete(recursive: true);
  });

  test('LAN 保存经真实 AppRuntime 返回顶层成功，snapshot 按 resultSuccess 读取', () async {
    final result = await execute({
      'action': 'saveLanProxy',
      'name': 'Local network proxy',
      'addresses': ['10.0.2.16'],
      'interfaces': {'10.0.2.16': 'wlan0'},
      'port': 7890,
      'udp': true,
    });
    expect(result['success'], isTrue);
    expect(result['overrideStatus'], 'saved');
    expect(result['savedRevision'], 1);
    expect((result['message'] as Map)['id'], 'overrideSettingsSaved');
    expect(result.containsKey('resultSuccess'), isFalse);
    final saved = (await OverrideStore(directory).read()).single;
    expect(saved.id, result['targetId']);
    expect(saved.enabled, isFalse);
    final listener =
        ((loadYaml(saved.body) as YamlMap)['listeners'] as YamlList).single
            as YamlMap;
    expect(listener['listen'], '10.0.2.16');
    expect(LanProxySettings.fromBody(saved.body).interfaces, {
      '10.0.2.16': 'wlan0',
    });
    expect(publications, ['overrides.json']);
    final snapshot = AppSnapshot.fromMap({
      'resultId': 'publication-test',
      'resultSuccess': result['success'],
      'overrideStatus': result['overrideStatus'],
      'resultMessage': result['message'],
      'targetId': result['targetId'],
      'savedRevision': result['savedRevision'],
    });
    expect(snapshot.resultSuccess, isTrue);
    expect(snapshot.overrideStatus, 'saved');
    expect(snapshot.resultMessageDescription!.id, 'overrideSettingsSaved');
    expect(snapshot.targetId, saved.id);
    expect(snapshot.savedRevision, saved.revision);
  });

  test('LAN 保存后 enable 的实际应用失败仍返回 false，不按 saved 状态改为成功', () async {
    final saved = await execute({
      'action': 'saveLanProxy',
      'name': 'Local network proxy',
      'addresses': ['10.0.2.16'],
      'interfaces': {'10.0.2.16': 'wlan0'},
      'port': 7890,
      'udp': true,
    });
    expect(saved['success'], isTrue);
    final result = await execute({
      'action': 'setLanProxyEnabled',
      'name': 'Local network proxy',
      'id': saved['targetId'],
      'revision': saved['savedRevision'],
      'enabled': true,
    });
    // 当前没有已选配置；设置保存成功与实际启动失败分别保留。
    expect(result['success'], isFalse);
    expect(result['overrideStatus'], 'applyFailed');
    expect(result['targetId'], saved['targetId']);
    expect(
      (result['message'] as Map)['id'],
      'overrideSavedReconnectIncomplete',
    );
    expect((await OverrideStore(directory).read()).single.enabled, isTrue);
    expect(publications, ['overrides.json', 'overrides.json']);
    final snapshot = AppSnapshot.fromMap({
      'resultSuccess': result['success'],
      'overrideStatus': result['overrideStatus'],
      'resultMessage': result['message'],
    });
    expect(snapshot.resultSuccess, isFalse);
    expect(snapshot.overrideStatus, 'applyFailed');
    expect(
      snapshot.resultMessageDescription!.detail,
      (result['message'] as Map)['detail'],
    );
  });

  test('LAN 保存后的 directory sync warning 保留 saved 与失败反馈', () async {
    durable = false;
    final result = await execute({
      'action': 'saveLanProxy',
      'name': 'Local network proxy',
      'addresses': ['10.0.2.16'],
      'interfaces': {'10.0.2.16': 'wlan0'},
      'port': 7890,
      'udp': true,
    });
    expect(result['success'], isFalse);
    expect(result['overrideStatus'], 'saved');
    expect(result['savedRevision'], 1);
    expect((result['message'] as Map)['id'], 'storageSyncWarning');
    expect((result['message'] as Map)['detail'], original);
    final saved = (await OverrideStore(directory).read()).single;
    expect(saved.id, result['targetId']);
    expect(publications, ['overrides.json']);
    final snapshot = AppSnapshot.fromMap({
      'resultSuccess': result['success'],
      'overrideStatus': result['overrideStatus'],
      'resultMessage': result['message'],
    });
    expect(snapshot.resultSuccess, isFalse);
    expect(snapshot.overrideStatus, 'saved');
    expect(snapshot.resultMessageDescription!.detail, original);
  });

  test(
    'GUI definition bytes preserve nested BOM values in the real saved YAML',
    () async {
      final result = await execute({
        'action': 'saveLocalDefinition',
        'storageEpoch': 4,
        'definitionPayload': utf8.encode(
          jsonEncode({
            'id': null,
            'revision': null,
            'name': 'Local custom',
            'section': 'proxies',
            'definition': {
              'name': 'Proxy',
              'type': 'http',
              'server': 'example.test',
              'port': 8080,
              'password': '\u{feff}\u{feff}secret🌐',
              'headers': {'X-Name': '\u{feff}header-value'},
            },
          }),
        ),
      });
      expect(result['success'], isTrue);
      expect(publications, ['overrides.json']);
      final saved = (await OverrideStore(directory).read()).single;
      expect(saved.id, result['targetId']);
      final proxy = (loadYaml(saved.body) as YamlMap)['proxies'][0] as YamlMap;
      expect(proxy['password'], '\u{feff}\u{feff}secret🌐');
      expect((proxy['headers'] as YamlMap)['X-Name'], '\u{feff}header-value');
    },
  );

  for (final reserved in [
    'owner',
    'action',
    'storageEpoch',
    'definitionPayload',
  ]) {
    test('GUI payload cannot replace outer $reserved authority', () async {
      final result = await execute({
        'action': 'saveLocalDefinition',
        'definitionPayload': utf8.encode(jsonEncode({reserved: 'replacement'})),
      });
      expect(result['success'], isFalse);
      expect(result['overrideStatus'], 'notSaved');
      expect(publications, isEmpty);
      expect(await File('${directory.path}/overrides.json').exists(), isFalse);
    });
  }

  test(
    'real configuration save uses the owner-bound publication hook',
    () async {
      final result = await execute(save());
      expect(result['success'], isTrue);
      expect(result['configStatus'], 'saved');
      expect(publications, ['configurations.json']);
      final saved = (await ConfigStore(directory).read()).selected!;
      expect(saved.id, result['targetId']);
      expect(saved.revision, result['savedRevision']);
      expect(saved.body, 'rules:\n  - MATCH,DIRECT\n');
      expect(stops, 0);
    },
  );

  test(
    'a post-rename sync failure preserves saved identity and reports warning',
    () async {
      durable = false;
      final result = await execute(save());
      expect(result['success'], isFalse);
      expect(result['configStatus'], 'saved');
      expect(result['savedRevision'], 1);
      expect((result['message'] as Map)['id'], 'storageSyncWarning');
      expect((result['message'] as Map)['detail'], original);
      final saved = (await ConfigStore(directory).read()).selected!;
      expect(saved.id, result['targetId']);
      expect(saved.body, 'rules:\n  - MATCH,DIRECT\n');
      expect(publications, ['configurations.json']);
      expect(stops, 0);

      durable = true;
      final next = await execute({
        'action': 'saveLocal',
        'id': saved.id,
        'revision': saved.revision,
        'body': utf8.encode(saved.body),
      });
      expect(next['success'], isTrue);
      expect(next['savedRevision'], saved.revision);
      expect((await ConfigStore(directory).read()).entries, hasLength(1));
    },
  );

  test(
    'publication rejection does not rename or leave a staged body',
    () async {
      rejectPublication = true;
      final result = await execute(save());
      expect(result['success'], isFalse);
      expect(result['configStatus'], 'notSaved');
      expect(publications, isEmpty);
      expect(
        await File('${directory.path}/configurations.json').exists(),
        isFalse,
      );
      expect(
        await File('${directory.path}/configurations.json.tmp').exists(),
        isFalse,
      );
      expect(stops, 0);
    },
  );

  test(
    'Stop does not read closed business storage or a run-input path',
    () async {
      storageClosed = true;
      final result = await execute({'action': 'stop'});
      expect(result['success'], isTrue);
      expect(stops, 0);
      expect(pathReads, 0);
      expect(publications, isEmpty);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'notification refresh failure cannot erase an already saved preference',
    () async {
      rejectRefresh = true;
      final result = await execute({
        'action': 'setPreference',
        'field': 'language',
        'value': 'en',
      });
      expect(result['success'], isFalse);
      final message = result['message'] as Map;
      expect(message['id'], 'settingsSaved');
      expect(message['detail'], contains('notification'));
      expect(message['detail'], contains(original));
      expect(publications, ['preferences.json']);
      final saved = jsonDecode(
        await File('${directory.path}/preferences.json').readAsString(),
      ) as Map;
      expect(saved['language'], 'en');
      expect(stops, 0);

      rejectRefresh = false;
      final next = await execute({
        'action': 'setPreference',
        'field': 'language',
        'value': 'zh',
      });
      expect(next['success'], isTrue);
      expect((next['message'] as Map)['id'], 'settingsSaved');
      expect(publications, ['preferences.json', 'preferences.json']);
    },
  );

  test(
    'settings and local definitions use their respective fixed files',
    () async {
      final settings = await execute({
        'action': 'setPreference',
        'field': 'language',
        'value': 'en',
      });
      expect(settings['success'], isTrue);
      final custom = await execute({
        'action': 'saveLocalDefinition',
        'definitionPayload': utf8.encode(
          jsonEncode({
            'name': 'Local customizations',
            'section': 'rules',
            'rule': 'DOMAIN,example.test,DIRECT',
          }),
        ),
      });
      expect(custom['success'], isTrue);
      expect(custom['overrideStatus'], 'saved');
      expect(publications, ['preferences.json', 'overrides.json']);
    },
  );
}
