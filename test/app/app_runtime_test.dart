import 'dart:async';
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
        case 'ready':
        case 'checkOperation':
        case 'stop':
          return null;
        case 'paths':
          return {
            'configs': directory.path,
            'runInput': '${directory.path}/${args['owner']}.input',
          };
        case 'snapshot':
          return {'phase': 'STOPPED'};
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
