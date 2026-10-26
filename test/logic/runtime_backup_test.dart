import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/app_runtime.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  const token = '12345678-1234-4234-8234-123456789abc';
  const names = ['configurations.json', 'overrides.json', 'preferences.json'];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory candidate;
  var epoch = 7;
  var installs = 0;
  final calls = <String>[];

  Future<Map> execute(String action) async {
    final reply = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(
      AppBridge.channel.name,
      codec.encodeMethodCall(
        MethodCall('execute', {
          'owner': 'backup-runtime',
          'action': action,
          'requestId': 'runtime-backup-request',
          'token': token,
          'storageEpoch': 7,
        }),
      ),
      reply.complete,
    );
    return codec.decodeEnvelope((await reply.future)!) as Map;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-runtime-');
    candidate = await Directory('${root.path}/candidate').create();
    epoch = 7;
    installs = 0;
    calls.clear();
    for (final name in names) {
      await File('${root.path}/$name')
          .writeAsString('damaged old store: $name');
    }
    await File('${candidate.path}/configurations.json').writeAsString(
      jsonEncode({'selectedId': null, 'mode': null, 'entries': []}),
    );
    await File('${candidate.path}/overrides.json')
        .writeAsString('{"entries":[]}');
    await File('${candidate.path}/preferences.json')
        .writeAsString(jsonEncode(const AppPreferences().toJson()));
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'ready':
        case 'checkOperation':
        case 'stage':
        case 'refreshStrings':
        case 'syncSchedules':
          return null;
        case 'paths':
          return {
            'configs': root.path,
            'runInput': '${root.path}/run.json',
            'storageEpoch': epoch,
          };
        case 'snapshot':
          return {
            'phase': 'STOPPED',
            'generation': 0,
            'storageReady': true,
            'storageEpoch': epoch,
            'core': {'phase': 'EMPTY', 'generation': 0},
          };
        case 'backupCandidate':
          expect((call.arguments as Map)['token'], token);
          return {
            'status': 'ready', 'token': token, 'createdAtMillis': 1234,
            'paths': {
              for (final name in names) name: '${candidate.path}/$name',
            },
            // Native integrity checks have separate transaction tests. Here the
            // platform descriptor drives actual Dart Store reads and dispatch.
            'parts': {
              for (final name in names)
                name: {
                  'bytes': await File('${candidate.path}/$name').length(),
                  'sha256': '0' * 64,
                },
            },
            'structure': {
              'nodes': 20,
              'depth': 3,
              'configurations': 0,
              'overrides': 0,
            },
          };
        case 'backupInstall':
          expect((call.arguments as Map)['expectedEpoch'], 7);
          installs++;
          for (final name in names) {
            await File('${candidate.path}/$name').copy('${root.path}/$name');
          }
          epoch = 8;
          return {
            'committed': true,
            'rolledBack': false,
            'ready': true,
            'epoch': epoch,
          };
        default:
          throw MissingPluginException(call.method);
      }
    });
    await AppRuntime().start();
  });

  tearDown(() async {
    AppBridge.channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(AppBridge.channel, null);
    await root.delete(recursive: true);
  });

  test('inspection validates private candidate without decoding damaged old stores', () async {
    final result = await execute('inspectBackup');
    expect(result['success'], isTrue);
    final backup = result['backupResult'] as Map;
    expect(backup['status'], 'inspected');
    expect(backup['token'], token);
    expect(backup.containsKey('paths'), isFalse);
    expect((backup['summary'] as Map)['configurations'], 0);
    expect(installs, 0);
    expect(calls, isNot(contains('start')));
    for (final name in names) {
      expect(
        await File('${root.path}/$name').readAsString(),
        'damaged old store: $name',
      );
    }
  });

  test(
    'empty candidate replaces damaged stores and stopped runtime stays stopped',
    () async {
      final result = await execute('restoreBackup');
      expect(result['success'], isTrue);
      final backup = result['backupResult'] as Map;
      expect(backup['committed'], isTrue);
      expect(backup['status'], 'restored');
      expect(backup['epoch'], 8);
      expect(backup['connectionStatus'], 'notStarted');
      expect(installs, 1);
      expect(calls, isNot(contains('start')));
      expect(calls, isNot(contains('authorize')));
      for (final name in names) {
        expect(
          await File('${root.path}/$name').readAsBytes(),
          await File('${candidate.path}/$name').readAsBytes(),
        );
      }
    },
  );

  test('invalid candidate fails before install without hiding the damaged originals', () async {
    await File('${candidate.path}/preferences.json')
        .writeAsString('{"language":"invalid"}');
    final result = await execute('restoreBackup');
    expect(result['success'], isFalse);
    expect((result['backupResult'] as Map)['committed'], isFalse);
    expect(installs, 0);
    for (final name in names) {
      expect(
        await File('${root.path}/$name').readAsString(),
        'damaged old store: $name',
      );
    }
  });
}
