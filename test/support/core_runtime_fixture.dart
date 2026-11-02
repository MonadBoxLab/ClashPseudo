import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/lan_proxy_settings.dart';
import 'package:clash_pseudo/src/platform/channel/method_channel_port.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/platform/app_bootstrap.dart';
import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/logic/configs/config_actions.dart';
import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/logic/configs/strategy_actions.dart';
import 'package:clash_pseudo/src/logic/core_runtime.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/platform/core/core_client.dart';
import 'package:clash_pseudo/src/platform/core/core_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const modeStrategyOriginal =
    'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture';

const modeStrategyEntry = ConfigEntry(
  id: 'one',
  name: '策略配置🌐',
  kind: ConfigKind.local,
  revision: 1,
  body: '',
);

/// 只模拟 Android 的 MethodChannel 和 FD 边界，业务使用真实 Dart 入口。
class CoreRuntimeFixture {
  CoreRuntimeFixture._(this.directory);

  final Directory directory;
  final requests = <CoreTestRequest>[];
  final channelCalls = <MethodCall>[];
  final exits = <Map<String, dynamic>>[];
  final publications = <Map<String, dynamic>>[];
  final notifications = <Map<String, dynamic>>[];
  final stages = <Map<String, dynamic>>[];
  final scripts = <int, Queue<FutureOr<void> Function(CoreTestRequest)>>{};
  final _waiters = <int, List<Completer<CoreTestRequest>>>{};
  final _records = <String, File>{};
  late final CoreClient client;
  late final CoreRuntime runtime;
  late AppPlatform operation;
  late ConfigStore store;
  late ConfigActions configActions;
  late StrategyActions strategyActions;
  AppBootstrap? appRuntime;
  late AppBootstrap bootstrap;
  int changes = 0;
  int nativeModeChanges = 0;
  int nativeStrategyChanges = 0;
  int nativeCacheWrites = 0;
  List<Map<String, dynamic>>? strategyGroups;
  int authorizations = 0;
  int _nextRequestId = 0;
  int _nextProcess = 1;
  int now = 100;
  int admittedAt = 100;
  int deadline = 60100;
  bool operationExpired = false;
  bool vpnIntent = true;
  bool lanIntent = false;
  bool lanRunning = false;
  String phase = 'RUNNING';
  String actualMode = 'rule';
  String actualMember = 'DIRECT';
  String groupName = '出口🌐';
  String memberName = '节点🌐';
  String groupType = 'select';
  String fixedMember = '';
  CoreSnapshot core = const CoreSnapshot(
    processId: 'process-1',
    inputId: 'input-1',
    generation: 1,
    networkRevision: 7,
    phase: 'READY',
    purpose: 'RUNNING',
    configId: 'one',
    revision: 1,
    composition: '["one",1]',
  );
  FutureOr<Object?> Function(MethodCall)? beforePlatformCall;
  FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>)? onExit;
  FutureOr<Map<String, dynamic>> Function(CoreTestRequest)? onCancel;

  File get runInput => File('${directory.path}/run.input');
  List<CoreTestRequest> calls(int operation) =>
      requests.where((request) => request.operation == operation).toList();
  Map<String, dynamic>? get modeProjection => runtime.projection['mode'] is Map
      ? Map<String, dynamic>.from(runtime.projection['mode'] as Map)
      : null;

  static Future<CoreRuntimeFixture> create({
    bool preview = false,
    bool lanOnly = false,
    TunnelMode? fallback,
    String body = '',
  }) async {
    final fixture = CoreRuntimeFixture._(
      await Directory.systemTemp.createTemp('pseudo-mode-strategy-'),
    );
    fixture.client = CoreClient(const MethodChannelPort(AppBridge.channel));
    final platform = AppPlatform(
      port: const MethodChannelPort(AppBridge.channel),
      coreClient: fixture.client,
    );
    fixture.bootstrap = AppBootstrap(
      platform: platform,
      changed: () => fixture.changes++,
    );
    fixture.runtime = fixture.bootstrap.runtime.core;
    fixture.operation = fixture.bootstrap.runtime.platform.forOperation(
      operationId: 'one',
      admittedAt: fixture.admittedAt,
      deadline: fixture.deadline,
    );
    fixture.store = ConfigStore(
      fixture.directory,
      beforeWrite: fixture.operation.checkOperation,
    );
    fixture.configActions = ConfigActions(
      fixture.store,
      ConfigDownloader(),
      fixture.operation,
      fixture.runInput,
    );
    fixture.strategyActions = StrategyActions(
      fixture.store,
      fixture.operation,
      runInput: fixture.runInput,
    );
    fixture.vpnIntent = !preview && !lanOnly;
    fixture.lanIntent = lanOnly;
    fixture.lanRunning = lanOnly;
    fixture.phase = preview || lanOnly ? 'STOPPED' : 'RUNNING';
    if (preview) fixture.replaceCore(purpose: 'PREVIEW');
    if (lanOnly) {
      fixture.replaceCore(
        composition: CoreInput.compositionOf('one', 1, [
          const OverrideEntry(
            id: 'lan',
            name: 'LAN',
            kind: ConfigKind.local,
            revision: 1,
            body: '',
            role: OverrideRole.lanProxy,
            enabled: true,
          ),
        ]),
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppBridge.channel, fixture._handle);
    await fixture.store.save(
      ConfigCollection(
        entries: [
          ConfigEntry(
            id: modeStrategyEntry.id,
            name: modeStrategyEntry.name,
            kind: modeStrategyEntry.kind,
            revision: modeStrategyEntry.revision,
            body: body,
          ),
        ],
        selectedId: 'one',
        mode: fallback,
      ),
    );
    await fixture.writeRecord({
      'mode': fallback?.name,
      'body': body,
      'vpnIntent': fixture.vpnIntent,
      'lanIntent': fixture.lanIntent,
    });
    return fixture;
  }

  Map<String, dynamic> coreMap([CoreSnapshot? source]) {
    final value = source ?? core;
    return {
      'protocol': ApplicationContract.coreIpcVersion,
      'processId': value.processId,
      'inputId': value.inputId,
      'generation': value.generation,
      'networkRevision': value.networkRevision,
      'phase': switch (value.phase) {
        'READY' => 'ready',
        'EMPTY' => 'exited',
        'LOADING' => 'loading',
        'RELEASING' => 'stopping',
        'FAILED' => 'recoveryRequired',
        'UNKNOWN' => 'communicationLost',
        _ => value.phase,
      },
      'purpose': value.purpose,
      if (value.errorMessage != null) 'error': value.errorMessage!.toMap(),
      'configId': value.configId,
      'revision': value.revision,
      'composition': value.composition,
    };
  }

  Map<String, Object?> identity([CoreSnapshot? source]) {
    final value = source ?? core;
    return {
      'processId': value.processId,
      'inputId': value.inputId,
      'generation': value.generation,
      'networkRevision': value.networkRevision,
      'configId': value.configId,
      'revision': value.revision,
      'composition': value.composition,
      'purpose': value.purpose,
    };
  }

  Map<String, dynamic> snapshotMap() => {
    'phase': phase,
    'generation': 11,
    'storageReady': true,
    'storageEpoch': 0,
    'elapsedRealtimeMs': now,
    'operationAdmittedAt': admittedAt,
    'operationDeadline': deadline,
    'networkEpoch': core.networkRevision,
    'configId': core.configId,
    'revision': core.revision,
    'mode': actualMode,
    'vpnIntent': vpnIntent,
    'lanIntent': lanIntent,
    'lanRunning': lanRunning,
    'core': coreMap(),
  };

  AppSnapshot get snapshot => AppSnapshot.fromMap(snapshotMap());

  Map<String, dynamic> strategyCommand({
    String? name,
    String? member,
    CoreSnapshot? source,
  }) => {
    'action': 'setStrategy',
    ...identity(source),
    'id': (source ?? core).configId,
    'name': name ?? groupName,
    'choice': {'type': groupType, 'member': member ?? memberName},
  };

  Future<void> writeRecord(Map<String, dynamic> changes) async {
    final record = <String, dynamic>{
      'inputId': core.inputId ?? 'input-1',
      'id': core.configId ?? 'one',
      'name': '策略配置🌐',
      'revision': core.revision ?? 1,
      'mode': null,
      'routingOverride': null,
      'body': '',
      'choices': <String, dynamic>{},
      'access': 'all',
      'packages': <String>[],
      'overrides': <Map<String, dynamic>>[
        if (lanIntent)
          {
            'id': 'lan',
            'name': 'LAN',
            'revision': 1,
            'mode': 'prepend',
            'role': 'lanProxy',
            'kind': 'local',
            'enabled': true,
            'source': null,
            'body': LanProxySettings(
              addresses: ['192.168.10.2'],
              interfaces: {'192.168.10.2': 'wlan0'},
            ).applyTo('{}'),
          },
      ],
      'composition': core.composition ?? '["one",1]',
      'vpnIntent': vpnIntent,
      'lanIntent': lanIntent,
      ...changes,
    };
    await CoreInput(runInput).writeRecord(record);
    final file = File('${directory.path}/retained-${_records.length}.input');
    await file.writeAsString(jsonEncode(record), flush: true);
    _records[record['inputId'] as String] = file;
  }

  void replaceCore({
    String? processId,
    String? inputId,
    int? generation,
    int? networkRevision,
    String? purpose,
    String? configId,
    int? revision,
    String? composition,
    String phase = 'READY',
  }) {
    core = CoreSnapshot(
      processId: processId ?? core.processId,
      inputId: inputId ?? core.inputId,
      generation: generation ?? core.generation,
      networkRevision: networkRevision ?? core.networkRevision,
      phase: phase,
      purpose: purpose ?? core.purpose,
      configId: configId ?? core.configId,
      revision: revision ?? core.revision,
      composition: composition ?? core.composition,
    );
  }

  void script(int operation, FutureOr<void> Function(CoreTestRequest) work) {
    scripts.putIfAbsent(operation, Queue.new).add(work);
  }

  Future<CoreTestRequest> next(int operation) {
    final waiter = Completer<CoreTestRequest>();
    _waiters.putIfAbsent(operation, () => []).add(waiter);
    return waiter.future.timeout(const Duration(seconds: 3));
  }

  Future<void> warmUp() async {
    await runtime.restoreExisting();
    await flush();
    changes = 0;
    notifications.clear();
  }

  Future<void> startAppRuntime() async {
    appRuntime = bootstrap;
    await appRuntime!.start();
    await flush();
    notifications.clear();
  }

  Future<Object?> invokeRuntime(String method, Object? arguments) async {
    final result = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          AppBridge.channel.name,
          AppBridge.channel.codec.encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (data) {
            try {
              result.complete(
                data == null
                    ? null
                    : AppBridge.channel.codec.decodeEnvelope(data),
              );
            } catch (error, stack) {
              result.completeError(error, stack);
            }
          },
        );
    return result.future;
  }

  Future<Map<String, dynamic>> execute(Map<String, dynamic> command) async =>
      Map<String, dynamic>.from(
        await invokeRuntime('execute', {
          'owner': 'one',
          'admittedAt': admittedAt,
          'deadline': deadline,
          ...command,
        }) as Map,
      );

  void expire() {
    now = deadline + 1;
    operationExpired = true;
  }

  Future<void> abandon() async {
    if (appRuntime != null) {
      await invokeRuntime('cancel', 'one');
    } else {
      operation.cancel();
    }
  }

  void emit(Map<String, dynamic> event) {
    runtime.event(event);
  }

  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
    if (appRuntime != null) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> dispose() async {
    for (final request in requests) {
      if (!request.actualExited) {
        request.terminal({'complete': false, 'exited': true});
        request.signalExit();
      }
    }
    await flush();
    bootstrap.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppBridge.channel, null);
    await directory.delete(recursive: true);
  }

  Future<Object?> handlePlatformCall(MethodCall call) => _handle(call);

  Future<void> replyDefault(CoreTestRequest request) => _defaultReply(request);

  Future<Object?> _handle(MethodCall call) async {
    channelCalls.add(call);
    final interceptor = beforePlatformCall;
    if (interceptor != null) {
      final value = await interceptor(call);
      if (value is PlatformCallResult) return value.value;
    }
    final arguments = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    switch (call.method) {
      case ApplicationContract.coreChannelLocalInterfaces:
        return {
          'addresses': [
            {
              'address': '192.168.10.2',
              'interfaceName': 'wlan0',
              'interfaceIndex': 7,
              'available': true,
              'selectable': true,
            },
          ],
        };
      case 'snapshot':
        return snapshotMap();
      case 'paths':
        return {
          'configs': directory.path,
          'runInput': runInput.path,
          'storageEpoch': 0,
        };
      case 'checkOperation':
        if (operationExpired || now >= deadline) {
          throw PlatformException(
            code: 'expired',
            details: {'deadline': deadline},
          );
        }
        return null;
      case 'operationRemaining':
        return (deadline - now).clamp(0, deadline);
      case 'publishStore':
        final name = arguments['file'] as String;
        await File('${directory.path}/$name.tmp')
            .rename('${directory.path}/$name');
        return {'saved': true, 'durable': true, 'epoch': arguments['epoch']};
      case 'stage':
        stages.add(arguments);
        return null;
      case 'authorize':
        authorizations++;
        return true;
      case 'ready':
      case 'syncSchedules':
        return null;
      case ApplicationContract.coreChannelRuntimeChanged:
        notifications.add(arguments);
        return null;
      case ApplicationContract.coreChannelStatus:
        return coreMap();
      case ApplicationContract.coreChannelHandshake:
        if (!core.ready) {
          replaceCore(
            processId: 'process-${++_nextProcess}',
            generation: 0,
            phase: 'EMPTY',
          );
        }
        return coreMap();
      case ApplicationContract.coreChannelReadRunInputRecord:
        final file = _records[arguments['inputId']];
        return {
          'inputId': arguments['inputId'],
          'saved': file != null,
          if (file != null) 'path': file.path,
        };
      case ApplicationContract.coreChannelPublishRunInput:
        final inputId = arguments['inputId'] as String;
        final file = File(
          '${directory.path}/published-${publications.length}.input',
        );
        await File(arguments['path'] as String).copy(file.path);
        _records[inputId] = file;
        final publication = {
          'saved': true,
          'durable': true,
          'path': file.path,
          'inputId': inputId,
        };
        publications.add(publication);
        return publication;
      case ApplicationContract.coreChannelSubmit:
        final request = CoreTestRequest._(this, ++_nextRequestId, arguments);
        requests.add(request);
        final waiters = _waiters.remove(request.operation);
        if (waiters != null) {
          for (final waiter in waiters) {
            waiter.complete(request);
          }
        }
        final queue = scripts[request.operation];
        if (queue != null && queue.isNotEmpty) {
          await queue.removeFirst()(request);
        } else {
          await _defaultReply(request);
        }
        return {
          'accepted': true,
          'processId': request.processId,
          'requestId': request.requestId,
        };
      case ApplicationContract.coreChannelRead:
        final request = requests.singleWhere(
          (request) =>
              request.requestId == arguments['requestId'] &&
              request.processId == arguments['processId'],
        );
        return request.read();
      case ApplicationContract.coreChannelCancel:
        final request = requests.singleWhere(
          (request) =>
              request.requestId == arguments['requestId'] &&
              request.processId == arguments['processId'],
        );
        request.cancellations++;
        return onCancel == null
            ? {'accepted': true, 'exited': request.actualExited}
            : await onCancel!(request);
      case ApplicationContract.coreChannelExit:
        exits.add(arguments);
        if (onExit != null) return onExit!(arguments);
        final process = arguments['processId'];
        if (core.processId == process) {
          replaceCore(phase: 'EMPTY');
          phase = 'STOPPED';
          lanRunning = false;
        }
        emit({'processId': process, 'phase': 'exited', 'exited': true});
        return {'exited': true};
      default:
        throw MissingPluginException('测试未提供平台方法 ${call.method}');
    }
  }

  Future<void> _defaultReply(CoreTestRequest request) async {
    switch (request.operation) {
      case ApplicationContract.coreOperationSnapshot:
        request.complete(coreMap());
      case ApplicationContract.coreOperationMode:
        request.complete({'mode': actualMode});
      case ApplicationContract.coreOperationModeSet:
        nativeModeChanges++;
        actualMode = request.arguments['mode'] as String;
        request.complete({'mode': actualMode});
      case ApplicationContract.coreOperationStrategies:
        request.strategies(strategyGroups ?? [strategyRecord()]);
      case ApplicationContract.coreOperationStrategySelect:
        nativeStrategyChanges++;
        if (request.arguments['restore'] != true) nativeCacheWrites++;
        final choice = request.arguments['choice'] as Map;
        if (choice['type'] == 'select') {
          actualMember = choice['member'] as String;
        } else {
          fixedMember = choice['member'] as String? ?? '';
        }
        final group = strategyGroups
            ?.where((group) => group['name'] == request.arguments['group'])
            .firstOrNull;
        if (group != null) {
          final raw = group['raw'] as Map;
          raw[choice['type'] == 'select' ? 'now' : 'fixed'] =
              choice['member'] ?? '';
        }
        request.complete(<String, dynamic>{});
      case ApplicationContract.coreOperationLogs:
        request.metadata({'source': request.source});
        request.terminal({
          'complete': true,
          'recordCount': 0,
          'source': request.source,
          'stale': false,
          'exited': true,
        });
      case ApplicationContract.coreOperationPrepare:
        final record = jsonDecode(
          await _records[request.wire['inputId']]!.readAsString(),
        ) as Map<String, dynamic>;
        final captured = request.wire['identity'] as Map;
        core = CoreSnapshot(
          processId: request.processId,
          inputId: request.wire['inputId'] as String,
          generation: captured['generation'] as int,
          networkRevision: captured['networkRevision'] as int,
          phase: 'READY',
          purpose: request.arguments['purpose'] as String,
          configId: record['id'] as String,
          revision: record['revision'] as int,
          composition: record['composition'] as String,
        );
        vpnIntent = request.arguments['vpnIntent'] == true;
        lanIntent = request.arguments['lanIntent'] == true;
        lanRunning = lanIntent;
        phase = vpnIntent ? 'RUNNING' : 'STOPPED';
        actualMode =
            record['routingOverride'] as String? ??
            record['mode'] as String? ??
            'rule';
        request.complete(coreMap());
      default:
        throw StateError('测试未提供 operation ${request.operation}');
    }
  }

  Map<String, dynamic> strategyRecord({
    Map<String, dynamic> extra = const {},
  }) => {
    'name': groupName,
    'sourceIdentity': 'group-source-1',
    'currentIdentity': 'member-identity-$actualMember',
    'raw': {
      'name': groupName,
      'type': groupType,
      'hidden': false,
      'now': actualMember,
      'fixed': fixedMember,
      'icon': '',
    },
    'members': [
      {'name': 'DIRECT', 'type': 'Direct', 'identity': 'direct-1'},
      {'name': memberName, 'type': 'Direct', 'identity': 'member-1'},
    ],
    ...extra,
  };
}

class PlatformCallResult {
  const PlatformCallResult(this.value);
  final Object? value;
}

class CoreTestRequest {
  CoreTestRequest._(this.fixture, this.requestId, this.wire);
  final CoreRuntimeFixture fixture;
  final int requestId;
  final Map<String, dynamic> wire;
  final _frames = StreamController<Map<String, Object?>>();
  late final _reader = StreamIterator(_frames.stream);
  bool _closed = false;
  bool actualExited = false;
  int cancellations = 0;
  int get operation => wire['operation'] as int;
  String get processId => (wire['identity'] as Map)['processId'] as String;
  String get source => '$processId/${(wire['identity'] as Map)['inputId']}';
  Map<String, dynamic> get arguments =>
      Map<String, dynamic>.from(wire['arguments'] as Map);

  void frame(int kind, Object? value, {Map<String, dynamic>? receipt}) {
    bytes(
      kind,
      Uint8List.fromList(utf8.encode(jsonEncode(value))),
      receipt: receipt,
    );
  }

  void bytes(int kind, Uint8List payload, {Map<String, dynamic>? receipt}) {
    _frames.add({'kind': kind, 'payload': payload, 'nativeReceipt': ?receipt});
  }

  void data(Object? value) =>
      frame(ApplicationContract.coreIpcFrameData, value);
  void metadata(Map<String, dynamic> value) =>
      frame(ApplicationContract.coreIpcFrameMetadata, value);
  void record(Map<String, dynamic> value) =>
      frame(ApplicationContract.coreIpcFrameRecord, value);

  void terminal(Map<String, dynamic> value) {
    if (_closed) return;
    frame(ApplicationContract.coreIpcFrameTerminal, value);
    actualExited = value['exited'] == true;
    _closed = true;
    unawaited(_frames.close());
  }

  void complete(Object? value, {Map<String, dynamic> terminal = const {}}) {
    data(value);
    this.terminal({'complete': true, 'exited': true, ...terminal});
  }

  void strategies(
    List<Map<String, dynamic>> groups, {
    Map<String, dynamic> metadata = const {},
    Map<String, dynamic> terminal = const {},
  }) {
    this.metadata({
      'source': source,
      'mode': fixture.actualMode,
      'globalReferenced': false,
      ...metadata,
    });
    for (final group in groups) {
      record(group);
    }
    this.terminal({
      'complete': true,
      'recordCount': groups.length,
      'source': source,
      'stale': false,
      'exited': true,
      ...terminal,
    });
  }

  void interrupt(PlatformException error, {Map<String, dynamic>? receipt}) {
    if (receipt != null) {
      bytes(
        ApplicationContract.coreIpcFrameData,
        Uint8List(0),
        receipt: receipt,
      );
    }
    _frames.addError(error);
    _closed = true;
    unawaited(_frames.close());
  }

  void signalExit({Map<String, dynamic> receipt = const {}}) {
    actualExited = true;
    fixture.emit({
      'processId': processId,
      'requestId': requestId,
      'exited': true,
      'receipt': receipt,
    });
  }

  Future<Map<String, Object?>> read() async {
    if (await _reader.moveNext()) return _reader.current;
    throw PlatformException(
      code: ApplicationContract.coreErrorTransportInterrupted,
      details: {'reason': 'EOF', 'requestId': requestId},
    );
  }
}

class FutureProbe<T> {
  FutureProbe(Future<T> future) {
    done = future.then<void>(
      (value) {
        this.value = value;
        replies++;
      },
      onError: (Object error, StackTrace stack) {
        this.error = error;
        this.stack = stack;
        replies++;
      },
    );
  }
  late final Future<void> done;
  T? value;
  Object? error;
  StackTrace? stack;
  int replies = 0;
  bool get settled => replies != 0;
}

Map<String, dynamic> nativeFailure(String kind, {String? stack}) => {
  'type': kind,
  'message': modeStrategyOriginal,
  'stack':
      stack ??
      '$kind: $modeStrategyOriginal\n\tat fixture.Native.invoke(Native.kt:27)\n',
  'cause': null,
  'suppressed': <Map<String, dynamic>>[],
  'code': ApplicationContract.coreErrorCallFailed,
  'future': {'Authorization': modeStrategyOriginal},
  'values': [false, null],
};

String errorText(Object? error) => switch (error) {
  ConfigFailure() => error.message.detail ?? error.message.toString(),
  PlatformException() =>
    '${error.code}\n${error.message}\n${error.details}\n${error.stacktrace}',
  PlatformFailure() => error.toString(),
  FormatException() => '${error.message}\n${error.source}',
  _ => error.toString(),
};

void expectOriginalError(Object? actual, Map<String, dynamic> expected) {
  expect(actual, isNotNull);
  final text = errorText(actual);
  expect(text, contains(modeStrategyOriginal));
  expect(text, contains(expected.toString()));
  expect(text, contains(expected['stack'] as String));
}
