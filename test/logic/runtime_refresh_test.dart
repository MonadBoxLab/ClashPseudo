import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/app_runtime.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late Map<String, Object?> state;
  late Map<String, Object?> input;
  late Map<String, Object?> command;
  final starts = <Map<String, dynamic>>[];
  final written = <Map<String, dynamic>>[];
  var stops = 0;
  Completer<void>? inputWait;

  Future<Map> send(String method, Object? arguments) async {
    final reply = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(
      AppBridge.channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      reply.complete,
    );
    return (codec.decodeEnvelope((await reply.future)!) as Map?) ?? {};
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('runtime-refresh-');
    // A refresh must work from the actual lease even if all saved stores are
    // unreadable. This also catches an accidental normal-start implementation.
    for (final name in ['configurations', 'overrides', 'preferences']) {
      await File('${directory.path}/$name.json').writeAsString('broken');
    }
    stops = 0;
    starts.clear();
    written.clear();
    inputWait = null;
    final composition = jsonEncode([
      'running',
      3,
      ['part', 7, 'replace'],
    ]);
    state = {
      'phase': 'RUNNING',
      'generation': 9,
      'configId': 'running',
      'revision': 3,
      'mode': 'global',
      'core': {
        'phase': 'READY',
        'purpose': 'VPN',
        'generation': 12,
        'configId': 'running',
        'revision': 3,
        'composition': composition,
      },
    };
    input = {
      'id': 'running',
      'revision': 3,
      'name': 'Actual main',
      'body': 'mode: rule\nrules: [MATCH,DIRECT]\n',
      'source': null,
      'mode': 'direct',
      'composition': composition,
      'overrides': [
        {
          'id': 'part',
          'revision': 7,
          'name': 'Actual part',
          'role': null,
          'body': 'dns: {enable: false}\n',
          'source': null,
          'mode': 'replace',
        },
      ],
      'choices': {},
      'access': 'except',
      'packages': ['test.controlled.client'],
    };
    command = {
      'owner': 'refresh',
      'action': 'refreshRuntime',
      'sessionGeneration': 9,
      'coreGeneration': 12,
      'composition': composition,
    };
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'ready':
        case 'checkOperation':
          return null;
        case 'paths':
          return {
            'configs': directory.path,
            'runInput': '${directory.path}/run.json',
          };
        case 'snapshot':
          return state;
        case 'runningInput':
          await inputWait?.future;
          return Uint8List.fromList(utf8.encode(jsonEncode(input)));
        case 'strategies':
          return jsonEncode({
            ...state['core'] as Map,
            'globalReferenced': false,
            'groups': [],
            'unrestored': [],
          });
        case 'stop':
          stops++;
          state = {...state, 'phase': 'STOPPED'};
          return null;
        case 'start':
          starts.add(args);
          written.add(
            jsonDecode(await File('${directory.path}/run.json').readAsString())
                as Map<String, dynamic>,
          );
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
    await AppRuntime().start();
  });

  tearDown(() async {
    if (inputWait != null && !inputWait!.isCompleted) inputWait!.complete();
    AppBridge.channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(AppBridge.channel, null);
    await directory.delete(recursive: true);
  });

  test('refresh uses only the running composition and actual mode', () async {
    final result = await send('execute', command);
    expect(result['success'], isTrue);
    expect(stops, 1);
    expect(starts, hasLength(1));
    final prepared = written.single;
    expect(prepared['id'], input['id']);
    expect(prepared['revision'], input['revision']);
    expect(prepared['body'], input['body']);
    expect(prepared['composition'], input['composition']);
    expect(prepared['mode'], 'direct');
    expect(prepared['routingOverride'], 'global');
    expect(prepared['access'], 'except');
    expect(prepared['packages'], input['packages']);
    final part = (prepared['overrides'] as List).single as Map;
    final original = (input['overrides'] as List).single as Map;
    for (final field in ['id', 'revision', 'body', 'mode']) {
      expect(part[field], original[field], reason: field);
    }
    expect(await File('${directory.path}/run.json').exists(), isFalse);
    for (final name in ['configurations', 'overrides', 'preferences']) {
      expect(
        await File('${directory.path}/$name.json').readAsString(),
        'broken',
      );
    }
  });

  for (final field in ['sessionGeneration', 'coreGeneration', 'composition']) {
    test('refresh rejects missing or changed $field before stopping', () async {
      for (final value in [null, field == 'composition' ? 'other' : 999]) {
        command[field] = value;
        expect((await send('execute', command))['success'], isFalse);
        expect(stops, 0);
        expect(starts, isEmpty);
      }
    });
  }

  test('a stopped lease cannot be started by a delayed refresh', () async {
    state = {...state, 'phase': 'STOPPED'};
    expect((await send('execute', command))['success'], isFalse);
    expect(stops, 0);
    expect(starts, isEmpty);
  });

  test('cancel during running-input read cannot restart the lease', () async {
    inputWait = Completer<void>();
    final pending = send('execute', command);
    await Future<void>.delayed(Duration.zero);
    await send('cancel', 'refresh');
    expect((await pending)['success'], isFalse);
    inputWait!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(stops, 0);
    expect(starts, isEmpty);
    expect(await File('${directory.path}/run.json').exists(), isFalse);
  });
}
