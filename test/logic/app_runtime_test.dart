import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import '../support/core_runtime_fixture.dart';

import 'package:clash_pseudo/src/model/application_contract.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/platform/app_bootstrap.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'configs/downloader_redirect_test.dart' show ClientFake;

import 'package:clash_pseudo/src/ui/locale/message_text.dart';

import '../support/connection_window_fixtures.dart' as connection_fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late AppBootstrap runtime;
  late CoreRuntimeFixture transport;
  late List<String> inputOwners;
  late List<Map<String, dynamic>> preparedInputs;
  Completer<void>? stageWait;
  late Map<String, Object?> snapshot;
  PlatformException? writeFailure;
  PlatformException? stopFailure;
  var finishReconnect = false;
  PlatformException? afterStartFailure;
  int stops = 0;
  final schedules = <List>[];
  final scheduleKinds = <String>[];
  final starts = <Map<String, dynamic>>[];
  Map<String, dynamic>? submitted;
  final resourceUpdates = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? resourceReply;
  final cleanupRequests = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? cleanupReply;
  int pathReads = 0;
  int connectionReads = 0;
  int connectionCloses = 0;
  Completer<Map<String, dynamic>>? connectionSample;
  Completer<String>? connectionClose;

  Future<Object?> send(String method, Object? arguments) {
    final raw = snapshot['core'];
    if (raw is Map) {
      snapshot['core'] = {
        'processId': 'runtime-process',
        'inputId': 'runtime-input',
        'networkRevision': 7,
        ...raw,
      };
    }
    if (method == 'runtimeState') arguments = snapshot;
    if (method == 'execute' && arguments is Map) {
      final source = snapshot['core'];
      arguments = {'admittedAt': 100, 'deadline': 60100, ...arguments};
      if (source is Map &&
          const [
            'updateResource',
            'closeConnection',
          ].contains(arguments['action'])) {
        arguments = {
          'processId': source['processId'],
          'inputId': source['inputId'],
          'networkRevision': source['networkRevision'],
          ...arguments,
        };
      }
    }
    final result = Completer<ByteData?>();
    ServicesBinding.instance.channelBuffers.push(
      AppBridge.channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      result.complete,
    );
    return result.future.then((value) => codec.decodeEnvelope(value!));
  }

  setUp(() async {
    transport = await CoreRuntimeFixture.create();
    directory = transport.directory;
    inputOwners = [];
    preparedInputs = [];
    stageWait = null;
    snapshot = {'phase': 'STOPPED'};
    writeFailure = null;
    stopFailure = null;
    finishReconnect = false;
    afterStartFailure = null;
    stops = 0;
    resourceUpdates.clear();
    resourceReply = null;
    cleanupRequests.clear();
    cleanupReply = null;
    pathReads = 0;
    connectionReads = 0;
    connectionCloses = 0;
    connectionSample = null;
    connectionClose = null;
    schedules.clear();
    scheduleKinds.clear();
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
    for (var index = 0; index < 8; index++) {
      transport.script(ApplicationContract.coreOperationResourceUpdate, (
        request,
      ) async {
        resourceUpdates.add({
          ...Map<String, dynamic>.from(snapshot['core'] as Map),
          ...Map<String, dynamic>.from(request.wire['identity'] as Map),
          ...request.arguments,
          'owner': request.wire['owner'],
        });
        try {
          request.complete(await resourceReply!.future);
        } on PlatformException catch (error) {
          request.interrupt(error);
          request.signalExit();
        }
      });
      transport.script(ApplicationContract.coreOperationConnections, (
        request,
      ) async {
        connectionReads++;
        request.complete(
          await connectionSample?.future ??
              connection_fixtures.sample([connection_fixtures.row('a')], 0),
        );
      });
      transport.script(ApplicationContract.coreOperationConnectionClose, (
        request,
      ) async {
        connectionCloses++;
        expectSync(request.arguments['id'], 'a');
        expectSync(request.wire['owner'], 'close-owner');
        request.complete({'status': await connectionClose!.future});
      });
      transport.script(ApplicationContract.coreOperationPrepare, (
        request,
      ) async {
        final args = {
          'id': request.arguments['configId'],
          'revision': request.arguments['revision'],
          'owner': request.wire['owner'],
          ...request.arguments,
        };
        if (request.arguments['purpose'] == 'PREVIEW') {
          inputOwners.add(args['owner'] as String);
          preparedInputs.add(
            jsonDecode(
              await File('${directory.path}/${args['owner']}.input')
                  .readAsString(),
            ) as Map<String, dynamic>,
          );
        } else {
          starts.add(args);
        }
        await transport.replyDefault(request);
        snapshot = {
          ...transport.snapshotMap(),
          'generation': finishReconnect ? 5 : snapshot['generation'] ?? 0,
        };
      });
      transport.script(ApplicationContract.coreOperationMode, (request) {
        request.complete({'mode': transport.actualMode});
        if (finishReconnect && starts.isNotEmpty) {
          writeFailure = afterStartFailure;
        }
      });
    }
    final registered = <String>{};
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if ((call.method.startsWith('core') &&
              call.method != ApplicationContract.coreChannelStatus) ||
          const [
            ApplicationContract.coreChannelReadRunInputRecord,
            ApplicationContract.coreChannelPublishRunInput,
            ApplicationContract.coreChannelLocalInterfaces,
          ].contains(call.method)) {
        final raw = snapshot['core'];
        if (raw is Map) {
          transport.core = CoreSnapshot.fromMap(Map<String, dynamic>.from(raw));
          transport.actualMode = snapshot['mode'] as String? ?? 'rule';
        }
        if (call.method == ApplicationContract.coreChannelReadRunInputRecord &&
            registered.add(args['inputId'] as String)) {
          await transport.writeRecord({
            'inputId': args['inputId'],
            'id': transport.core.configId,
            'revision': transport.core.revision,
            'body': 'old',
            'name': 'Local',
            'composition': transport.core.composition,
            'overrides': [],
            'choices': {},
            'vpnIntent': true,
            'lanIntent': false,
            'mode': null,
            'access': 'all',
            'packages': [],
          });
        }
        if (call.method == ApplicationContract.coreChannelExit) {
          stops++;
          if (stopFailure != null) throw stopFailure!;
          final result = await transport.handlePlatformCall(call);
          snapshot = {
            'phase': 'STOPPED',
            'generation': snapshot['generation'] ?? 0,
            'core': transport.coreMap(),
          };
          return result;
        }
        return transport.handlePlatformCall(call);
      }
      switch (call.method) {
        case 'runtimeState':
          return snapshot;
        case 'retain':
          expect(args['observationOwner'], isNotEmpty);
          return null;
        case 'sampleConnections':
          connectionReads++;
          return jsonEncode(
            await connectionSample?.future ??
                connection_fixtures.sample([connection_fixtures.row('a')], 0),
          );
        case 'closeConnection':
          connectionCloses++;
          expectSync(args, {
            'generation': 7,
            'configId': 'one',
            'revision': 1,
            'connectionId': 'a',
            'owner': 'close-owner',
          });
          return jsonEncode({'status': await connectionClose!.future});
        case 'submit':
          submitted = args;
          return {'operationId': 'save-codec', 'remainingMs': 120000};
        case 'operationRemaining':
          return 120000;
        case 'trustRoots':
          return Uint8List(0);
        case ApplicationContract.coreChannelStatus:
          return snapshot['core'] ?? {'phase': 'disconnected', 'generation': 0};
        case ApplicationContract.coreChannelRuntimeChanged:
          return null;
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
          if (finishReconnect) {
            snapshot = {
              'phase': 'STOPPED',
              'generation': snapshot['generation'],
            };
          }
          return null;
        case 'paths':
          pathReads++;
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
        case 'scheduleCoreCleanup':
          cleanupRequests.add(args);
          return await cleanupReply!.future;
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
          scheduleKinds.add(args['kind'] as String);
          return null;
        case 'start':
          starts.add(args);
          if (finishReconnect) {
            snapshot = {
              'phase': 'RUNNING',
              'generation': 5,
              'configId': args['id'],
              'revision': args['revision'],
              'mode': 'rule',
              'core': {
                'phase': 'READY',
                'generation': 9,
                'purpose': 'RUNNING',
                'configId': args['id'],
                'revision': args['revision'],
                'composition': jsonEncode([args['id'], args['revision']]),
              },
            };
            writeFailure = afterStartFailure;
          }
          return null;
        case 'finishScheduledDownload':
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
    runtime = transport.bootstrap;
    await runtime.start();
  });
  tearDown(() async {
    if (stageWait != null && !stageWait!.isCompleted) stageWait!.complete();
    await transport.dispose();
  });

  const resourceCore = <String, Object?>{
    'generation': 7,
    'composition': '["actual",2]',
    'configId': 'actual',
    'revision': 2,
    'purpose': 'RUNNING',
  };
  Map<String, Object?> resourceCommand() => {
    'owner': 'resource-owner',
    'action': 'updateResource',
    ...resourceCore,
    'kind': 'proxyProvider',
    'name': 'remote',
  };

  for (final status in ['closed', 'absent']) {
    testWidgets(
      'actual $status notifies the captured composition and retires an older sample',
      (tester) async {
        // ChannelBuffers retains the listener's registration zone. Register here
        // so runtime callbacks, observer timers and channel replies all run under
        // the same FakeAsync clock, rather than setUp's real async zone.
        await runtime.start();
        Future<Object?> reply(String method, Object? arguments) async {
          var settled = false;
          final pending = send(method, arguments);
          unawaited(
            pending.then<void>(
              (_) {
                settled = true;
              },
              onError: (Object _, StackTrace _) {
                settled = true;
              },
            ),
          );
          // Advance zero-duration observer timers as well as microtask replies.
          await tester.pump(Duration.zero);
          await tester.pump(const Duration(milliseconds: 1));
          expect(
            settled,
            isTrue,
            reason: '$method reply did not drain its microtasks',
          );
          return pending;
        }

        Future<Map> observedConnection() async {
          final result = await reply('connections', {'state': snapshot}) as Map;
          expect(result['generation'], 7);
          expect(result['configId'], 'one');
          expect(result['revision'], 1);
          expect(result['composition'], 'one');
          expect(result['purpose'], 'RUNNING');
          final row = (result['connections'] as List).single as Map;
          expect(row['id'], 'a');
          expect(row.containsKey('raw'), isFalse);
          return row;
        }

        final samples = <Completer<Map<String, dynamic>>>[];
        snapshot = {
          'phase': 'RUNNING',
          'generation': 4,
          'elapsedMs': 0,
          'elapsedRealtimeMs': 0,
          'configId': 'one',
          'revision': 1,
          'mode': 'rule',
          'core': {
            'processId': 'runtime-process',
            'inputId': 'runtime-input',
            'networkRevision': 7,
            'phase': 'READY',
            'generation': 7,
            'purpose': 'RUNNING',
            'configId': 'one',
            'revision': 1,
            'composition': 'one',
          },
        };
        try {
          await tester.runAsync(() => transport.runtime.restoreExisting());
          await reply('runtimeState', snapshot);
          expect(connectionReads, 1);
          expect((await observedConnection())['active'], isTrue);
          final oldSample = connectionSample =
              Completer<Map<String, dynamic>>();
          samples.add(oldSample);
          snapshot['elapsedMs'] = 1000;
          snapshot['elapsedRealtimeMs'] = 1000;
          await tester.pump(const Duration(seconds: 1));
          expect(connectionReads, 2);
          connectionClose = Completer<String>();
          var settled = false;
          final pending =
              send('execute', {
                'owner': 'close-owner',
                'action': 'closeConnection',
                'generation': 7,
                'configId': 'one',
                'revision': 1,
                'composition': 'one',
                'purpose': 'RUNNING',
                'connectionId': 'a',
              }).then((value) {
                settled = true;
                return value as Map;
              });
          await tester.pump();
          expect(connectionCloses, 1);
          await tester.pump(const Duration(seconds: 6));
          expect(
            settled,
            isFalse,
            reason: settled ? '实际提前回执：${await pending}' : null,
          );
          final concurrent = await reply('execute', {
            'owner': 'next',
            'action': 'stop',
          }) as Map;
          expect(concurrent['message'], messages.operationInProgress.toMap());
          expect(stops, 0);
          connectionClose!.complete(status);
          await tester.pump();
          // subscription.cancel 返回 Dart 的 root-zone Future，先完成真实 microtask，再检查同次 Reply。
          await tester.runAsync(() => Future<void>.value());
          await tester.pump();
          expect(
            settled,
            isTrue,
            reason: 'Actual close reply must drain the writer',
          );
          expect((await pending)['connectionStatus'], status);
          expect((await observedConnection())['active'], isFalse);
          final replacementSample = connectionSample =
              Completer<Map<String, dynamic>>();
          samples.add(replacementSample);
          oldSample.complete(
            connection_fixtures.sample(
              [connection_fixtures.row('a')],
              1000,
              presence: {'a': true},
            ),
          );
          await tester.pump();
          // This sample entered before close and cannot resurrect the ended row.
          expect((await observedConnection())['active'], isFalse);
          expect(pathReads, 0);
        } finally {
          snapshot = {'phase': 'STOPPED', 'generation': 4, 'elapsedMs': 2000};
          await reply('runtimeState', snapshot);
          if (connectionClose case final close? when !close.isCompleted) {
            close.complete(status);
          }
          for (final sample in samples) {
            if (!sample.isCompleted) {
              sample.complete(connection_fixtures.sample([], 2000));
            }
          }
          await tester.pump();
          await reply('clearInactiveConnections', {'state': snapshot});
          await tester.pump();
        }
      },
    );
  }

  for (final scope in ['cache', 'resource', 'all']) {
    test(
      'core cleanup $scope reaches its owner without reading damaged stores',
      () async {
        for (final name in [
          'configurations.json',
          'overrides.json',
          'preferences.json',
        ]) {
          await File('${directory.path}/$name').writeAsString('{broken 原文🙂');
        }
        final request = {
          'owner': 'cleanup-owner',
          'action': 'scheduleCoreCleanup',
          'paths': scope == 'all'
              ? ['cache.db', '原文.yaml']
              : ['$scope/原文.yaml'],
          'path': '/not-an-admitted-deletion-path',
        };
        cleanupReply = Completer<Map<String, dynamic>>();
        final pending = send('execute', request);
        await Future<void>.delayed(Duration.zero);
        expect(cleanupRequests.single, {
          'owner': 'cleanup-owner',
          'paths': request['paths'],
          'admittedAt': 100,
          'deadline': 60100,
        });
        final items = [
          {
            'path': '$scope/原文.yaml',
            'completed': true,
            'error': null,
            'detail': 'https://user:password@fixture.test/?token=原文🙂',
          },
        ];
        final native = {'success': true, 'items': items};
        cleanupReply!.complete(native);
        final result = await pending as Map;
        expect(result['success'], isTrue);
        expect(result['cleanup'], native);
        expect(
          result['message'],
          const AppMessage('coreCleanupCompleted').withDetail(items).toMap(),
        );
        expect(pathReads, 0);
        expect(stops, 0);
        expect(starts, isEmpty);
        expect(schedules, isEmpty);
        for (final name in [
          'configurations.json',
          'overrides.json',
          'preferences.json',
        ]) {
          expect(
            await File('${directory.path}/$name').readAsString(),
            '{broken 原文🙂',
          );
        }
      },
    );
  }

  for (final (status, items, message)
      in <(String, List<Map<String, Object?>>, String)>[
        (
          'completed',
          [
            {'path': 'cache.db', 'completed': true, 'error': null},
          ],
          'coreCleanupCompleted',
        ),
        (
          'failed',
          [
            {'path': 'cache.db', 'completed': true, 'error': null},
            {
              'path': '原文.yaml',
              'completed': false,
              'error': {
                'message': '原始删除错误',
                'future': [false, null],
              },
            },
          ],
          'coreCleanupPartial',
        ),
        ('needsSelection', [], 'coreCleanupNeedsSelection'),
        (
          'failed',
          [
            {'path': 'cache.db', 'completed': true, 'error': null},
          ],
          'coreCleanupFailed',
        ),
      ]) {
    test('cleanup $status 的 $message 使用实际 items，完整保留文件与记录错误且不自动重启', () async {
      cleanupReply = Completer<Map<String, dynamic>>();
      final pending = send('execute', {
        'owner': 'cleanup-owner',
        'action': 'scheduleCoreCleanup',
        'paths': ['cache.db', '原文.yaml'],
      });
      await Future<void>.delayed(Duration.zero);
      final outcome = {
        'success': status == 'completed',
        'status': status,
        'items': items,
        'error': status == 'failed'
            ? {
                'message': '原始清理记录错误',
                'future': [false, null],
              }
            : null,
      };
      cleanupReply!.complete(outcome);
      final result = await pending as Map;
      expect(result['success'], status == 'completed');
      expect(result['cleanup'], outcome);
      expect(result['message'], AppMessage(message).withDetail(items).toMap());
      expect(stops, 0);
      expect(starts, isEmpty);
      expect(pathReads, 0);
    });
  }

  test('published cleanup keeps its actual reply and drain after owner cancellation', () async {
    cleanupReply = Completer<Map<String, dynamic>>();
    var settled = false;
    final pending =
        send('execute', {
          'owner': 'cleanup-owner',
          'action': 'scheduleCoreCleanup',
          'paths': ['cache.db'],
        }).then((value) {
          settled = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    expect(cleanupRequests, hasLength(1));
    await send('cancel', 'cleanup-owner');
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    final concurrent =
        await send('execute', {'owner': 'next', 'action': 'stop'}) as Map;
    expect(concurrent['success'], isFalse);
    expect(concurrent['message'], messages.operationInProgress.toMap());
    expect(stops, 0);
    final native = {'success': true, 'items': <Object?>[]};
    cleanupReply!.complete(native);
    final result = await pending as Map;
    expect(result['success'], isTrue);
    expect(result['cleanup'], native);
    expect(
      result['message'],
      const AppMessage('coreCleanupCompleted')
          .withDetail(native['items'])
          .toMap(),
    );
    expect(settled, isTrue);
    expect(
      (await send('execute', {'owner': 'next', 'action': 'stop'})
          as Map)['success'],
      isTrue,
    );
  });

  test('core cleanup failure retains the native original detail', () async {
    cleanupReply = Completer<Map<String, dynamic>>();
    const failure = AppMessage(
      'coreCleanupFailed',
      detail: 'rename failed https://user:password@fixture.test/?token=原文🙂',
    );
    final pending = send('execute', {
      'owner': 'cleanup-owner',
      'action': 'scheduleCoreCleanup',
      'scope': 'all',
    });
    await Future<void>.delayed(Duration.zero);
    cleanupReply!.completeError(
      PlatformException(code: 'coreCleanup', details: failure.toMap()),
    );
    final result = await pending as Map;
    expect(result['success'], isFalse);
    expect(
      result['message'],
      messageFromFailure(
        PlatformFailure(code: 'coreCleanup', details: failure.toMap()),
        fallback: messages.platformOperationFailed,
      ).toMap(),
    );
    expect((result['failure'] as Map)['details'], failure.toMap());
    expect(stops, 0);
    expect(starts, isEmpty);
  });

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
        final admitted = transport.next(
          ApplicationContract.coreOperationResourceUpdate,
        );
        final pending = send('execute', resourceCommand()).then((value) {
          settled = true;
          return value as Map;
        });
        await admitted;
        expect(settled, isFalse);
        expect(resourceUpdates.single['owner'], 'resource-owner');
        expect(resourceUpdates.single['configId'], 'actual');
        expect(resourceUpdates.single['revision'], 2);
        expect(resourceUpdates.single['purpose'], 'RUNNING');
        resourceReply!.complete({
          if (status == 'ok') 'status': 'ok' else 'error': status,
          'future': {'private': 'resource-response-only'},
        });
        final result = await pending;
        expect(result['success'], status == 'ok');
        expect(result['resourceStatus'], status);
        expect(jsonEncode(result), isNot(contains('resource-response-only')));
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
    <String, dynamic>{'status': 'invalid'},
    <String, dynamic>{'status': 'ok', 'error': 'ok'},
    <String, dynamic>{},
  ]) {
    test(
      'resource malformed or stale completion is not confirmed $response',
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

  for (final status in ['ok', 'updateFailed']) {
    test('resource canceled owner waits for the actual $status result and drain', () async {
      const original =
          'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture';
      snapshot = {
        'phase': 'RUNNING',
        'mode': 'rule',
        'core': {'phase': 'READY', ...resourceCore},
      };
      resourceReply = Completer<Map<String, dynamic>>();
      var settled = false;
      final admitted = transport.next(
        ApplicationContract.coreOperationResourceUpdate,
      );
      final pending = send('execute', resourceCommand()).then((value) {
        settled = true;
        return value as Map;
      });
      await admitted;
      expect(resourceUpdates, hasLength(1));
      await send('cancel', 'resource-owner');
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      final concurrent =
          await send('execute', {'owner': 'next', 'action': 'stop'}) as Map;
      expect(concurrent['success'], isFalse);
      expect(concurrent['message'], messages.operationInProgress.toMap());
      expect(stops, 0);
      writeFailure = PlatformException(
        code: 'expired',
        message: 'The owner ended after the native write entered',
      );
      snapshot = {'phase': 'STOPPED'};
      resourceReply!.complete(
        status == 'ok'
            ? {'status': 'ok'}
            : {'error': status, 'detail': original},
      );
      final result = await pending;
      expect(result['success'], status == 'ok');
      expect(result['resourceStatus'], status);
      expect(
        result['message'],
        (status == 'ok'
                ? messages.resourceUpdateSuccess
                : messages.resourceUpdateFailed.withDetail(original))
            .toMap(),
      );
      expect(settled, isTrue);
      expect(starts, isEmpty);
      expect(pathReads, 0);
      expect(stops, 0);
    });
  }

  test('resource bridge failure keeps its original typed message', () async {
    const failure = AppMessage(
      'androidErrorNativeReadUnavailable',
      detail: 'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture',
    );
    snapshot = {
      'phase': 'RUNNING',
      'core': {'phase': 'READY', ...resourceCore},
    };
    resourceReply = Completer<Map<String, dynamic>>();
    final admitted = transport.next(
      ApplicationContract.coreOperationResourceUpdate,
    );
    final pending = send('execute', resourceCommand());
    await admitted;
    resourceReply!.completeError(
      PlatformException(code: 'updateResource', details: failure.toMap()),
    );
    final result = await pending as Map;
    expect(result['success'], isFalse);
    expect(result['resourceStatus'], 'unconfirmed');
    expect((result['message'] as Map)['id'], failure.id);
    expect((result['message'] as Map)['detail'], contains(failure.detail));
    expect(
      jsonEncode(result['failure']),
      contains('androidErrorNativeReadUnavailable'),
    );
    expect(jsonEncode(result['failure']), contains('updateResource'));
    expect(starts, isEmpty);
    expect(stops, 0);
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
      expect(scheduleKinds, ['override']);
      expect(schedules.single, [
        {'kind': 'override', 'id': 'remote-part', 'hours': 12},
      ]);
      schedules.clear();
      scheduleKinds.clear();
      final synced = await send('execute', {
        'owner': 'calibrate',
        'action': 'syncSchedules',
      }) as Map;
      expect(synced['success'], isTrue);
      expect(scheduleKinds, ['config', 'override']);
      expect(schedules, [
        [],
        [
          {'kind': 'override', 'id': 'remote-part', 'hours': 12},
        ],
      ]);
      schedules.clear();
      scheduleKinds.clear();
      final deleted = await send('execute', {
        'owner': 'delete-scheduled-part',
        'action': 'deleteOverride',
        'id': 'remote-part',
      }) as Map;
      expect(deleted['success'], isTrue);
      expect(scheduleKinds, ['override']);
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
        await ConfigStore(directory).save(
          ConfigCollection(
            entries: [
              ConfigEntry(
                id: 'one',
                name: 'fixture',
                kind: ConfigKind.local,
                revision: 1,
                body: owner,
              ),
            ],
            selectedId: 'one',
          ),
        );
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
      expect(preparedInputs.map((input) => input['body']), ['first', 'second']);
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
          'purpose': 'RUNNING',
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
      var settled = false;
      final first = send('execute', {'owner': 'first', 'action': 'stop'}).then((
        value,
      ) {
        settled = true;
        return value as Map;
      });

      await Future<void>.delayed(Duration.zero);
      final duplicate =
          await send('execute', {'owner': 'second', 'action': 'stop'}) as Map;
      expect(duplicate['success'], isFalse);
      await send('cancel', 'different');
      final stillBusy =
          await send('execute', {'owner': 'second', 'action': 'stop'}) as Map;
      expect(stillBusy['success'], isFalse);
      await send('cancel', 'first');
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      final draining =
          await send('execute', {'owner': 'second', 'action': 'stop'}) as Map;
      expect(draining['success'], isFalse);
      expect(draining['message'], messages.operationInProgress.toMap());
      expect(stops, 0);
      stageWait!.complete();
      expect((await first)['success'], isFalse);
      expect(settled, isTrue);
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
      runtime = AppBootstrap();
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
      expect(
        invalid['message'],
        messages.textNotUtf8
            .withDetail(const FormatException('Invalid UTF-8 byte', null, 0))
            .toMap(),
      );
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

  for (final outcome in ['saved', 'applyFailed', 'applied']) {
    test('scheduled $outcome facts survive runtime result settlement', () async {
      const original = 'diagnostic write original cause / 原文🙂';
      final collection = await ConfigStore(directory).read();
      await ConfigStore(directory).save(
        collection.replace(
          collection.selected!.withUpdate(const UpdatePolicy(enabled: true)),
        ),
      );
      if (outcome != 'saved') {
        snapshot = {
          'phase': 'RUNNING',
          'generation': 4,
          'configId': 'one',
          'revision': 1,
          'mode': 'rule',
          'core': {
            'phase': 'READY',
            'generation': 8,
            'purpose': 'RUNNING',
            'configId': 'one',
            'revision': 1,
            'composition': '["one",1]',
          },
        };
      }
      if (outcome == 'applyFailed') {
        stopFailure = PlatformException(code: 'stop', message: original);
      }
      if (outcome == 'applied') {
        finishReconnect = true;
        afterStartFailure = PlatformException(
          code: 'diagnostic',
          message: original,
        );
      }
      final client = ClientFake('/downloaded');
      final result = await HttpOverrides.runZoned(() async {
        // Register the runtime callback in the same controlled transport zone.
        await runtime.start();
        return await send('execute', {
          'owner': 'scheduled-$outcome',
          'action': 'refreshSchedule',
          'kind': 'config',
          'id': 'one',
        }) as Map;
      }, createHttpClient: (_) => client);
      expect(client.requests, hasLength(2));
      expect(result['scheduleStatus'], outcome);
      expect(result['targetId'], 'one');
      expect(result['savedRevision'], 2);
      expect(result['success'], outcome == 'saved');
      if (outcome != 'saved') {
        expect((result['message'] as Map)['detail'], contains(original));
      }
      final saved = (await ConfigStore(directory).read()).selected!;
      expect(saved.revision, 2);
      expect(saved.body, 'rules: []');
      expect(starts, hasLength(outcome == 'applied' ? 1 : 0));
    });
  }

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
