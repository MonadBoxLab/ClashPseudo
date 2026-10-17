import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/app/app_runtime.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
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
  Completer<void>? stageWait;
  late Map<String, Object?> snapshot;
  PlatformException? writeFailure;
  PlatformException? stopFailure;
  int stops = 0;
  Map<String, dynamic>? submitted;

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
    stageWait = null;
    snapshot = {'phase': 'STOPPED'};
    writeFailure = null;
    stopFailure = null;
    stops = 0;
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
          return 'save-codec';
        case 'ready':
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
            'runInput': '${directory.path}/${args['owner']}.input',
          };
        case 'snapshot':
          return snapshot;
        case 'stage':
          await stageWait?.future;
          return null;
        case 'prepareStrategies':
          final owner = args['owner'] as String;
          expect(await File('${directory.path}/$owner.input').exists(), isTrue);
          inputOwners.add(owner);
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

  test('both platform codec hops preserve BOM and mixed newlines', () async {
    const body = '\u{feff}# 中文🌐\r\nrules:\n  - MATCH,DIRECT\r\n';
    final command = <String, Object?>{
      'action': 'saveLocal',
      'name': 'Codec round trip',
      'body': body,
    };
    final owner = await AppBridge().submit(command);
    final result =
        await send('execute', {...submitted!, 'owner': owner}) as Map;
    expect(result['configStatus'], 'saved');
    expect((await ConfigStore(directory).read()).entries.last.body, body);
    expect(command['body'], body);
  });

  for (final extra in [0, 1]) {
    test(
      'codec round trip counts BOM at sixteen-mebibyte limit +$extra',
      () async {
        final body = '\u{feff}${'a' * (16 * 1024 * 1024 - 3 + extra)}';
        final owner = await AppBridge().submit({
          'action': 'saveLocal',
          'name': 'Boundary',
          'body': body,
        });
        final result =
            await send('execute', {...submitted!, 'owner': owner}) as Map;
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
      snapshot = {'phase': 'RUNNING', 'configId': 'local', 'revision': 1};
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
}
