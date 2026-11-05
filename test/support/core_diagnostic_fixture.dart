import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:clash_pseudo/src/platform/channel/method_channel_port.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clash_pseudo/src/logic/core_runtime.dart';
import 'package:clash_pseudo/src/logic/diagnostics/dns_operations.dart';
import 'package:clash_pseudo/src/logic/strategies/delay_batches.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/platform/core/core_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const diagnosticSource = CoreSnapshot(
  processId: 'diagnostic-process',
  inputId: 'diagnostic-input',
  generation: 1,
  configId: 'main',
  revision: 1,
  composition: 'diagnostic-composition',
  purpose: 'PREVIEW',
  networkRevision: 7,
  phase: 'READY',
);

/// 仅替代平台传输；DNS、批次、身份校验和取消状态均由生产对象维护。
class CoreDiagnosticFixture {
  CoreDiagnosticFixture() {
    client = CoreClient(const MethodChannelPort(AppBridge.channel));
    runtime = CoreRuntime(
      AppBridge(),
      client: client,
      changed: () => changes++,
    );
    runtime.delays.setVisible(true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppBridge.channel, _handle);
  }

  late final CoreClient client;
  late final CoreRuntime runtime;
  AppPlatform get platform => AppBridge().withCore(runtime);
  DnsOperations get dns => runtime.dns;
  DelayBatches get delays => runtime.delays;
  CoreSnapshot core = diagnosticSource;
  int changes = 0;
  int _sequence = 0;
  int _nextBatch = 0;
  bool _closing = false;
  final requests = <CoreDiagnosticRequest>[];
  final cancellations = <CoreDiagnosticRequest>[];
  final _scripts =
      <int, Queue<FutureOr<void> Function(CoreDiagnosticRequest)>>{};
  final _gates = <Completer<void>>[];
  FutureOr<Map<String, dynamic>> Function(CoreDiagnosticRequest)? onCancel;
  String group = 'group';
  String groupIdentity = 'group-source-one';
  String groupType = 'select';
  String current = 'member';
  String currentIdentity = 'member-one';
  List<Map<String, Object?>> members = [
    {'name': 'member', 'type': 'Direct', 'identity': 'member-one'},
  ];

  List<CoreDiagnosticRequest> calls(int operation) =>
      requests.where((request) => request.operation == operation).toList();

  Map<String, Object?> identity([CoreSnapshot? source]) {
    final value = source ?? core;
    return {
      'processId': value.processId,
      'inputId': value.inputId,
      'generation': value.generation,
      'configId': value.configId,
      'revision': value.revision,
      'composition': value.composition,
      'purpose': value.purpose,
      'networkRevision': value.networkRevision,
    };
  }

  void replaceCore({
    String? processId,
    String? inputId,
    int? generation,
    String? configId,
    int? revision,
    String? composition,
    String? purpose,
    int? networkRevision,
    String? phase,
  }) {
    core = CoreSnapshot(
      processId: processId ?? core.processId,
      inputId: inputId ?? core.inputId,
      generation: generation ?? core.generation,
      configId: configId ?? core.configId,
      revision: revision ?? core.revision,
      composition: composition ?? core.composition,
      purpose: purpose ?? core.purpose,
      networkRevision: networkRevision ?? core.networkRevision,
      phase: phase ?? core.phase,
    );
  }

  void setMembers(Iterable<String> names) {
    members = [
      for (final name in names)
        {'name': name, 'type': 'Direct', 'identity': '$name-one'},
    ];
    if (members.isNotEmpty) {
      current = members.first['name'] as String;
      currentIdentity = members.first['identity'] as String;
    }
  }

  Map<String, Object?> strategyRecord() => {
    'name': group,
    'sourceIdentity': groupIdentity,
    'currentIdentity': currentIdentity,
    'members': members,
    'type': groupType,
    'hidden': false,
    'now': current,
    'fixed': '',
    'icon': '',
  };

  void script(
    int operation,
    FutureOr<void> Function(CoreDiagnosticRequest) work,
  ) {
    _scripts.putIfAbsent(operation, Queue.new).add(work);
  }

  Completer<void> gate() {
    final result = Completer<void>();
    _gates.add(result);
    return result;
  }

  Future<Map<String, dynamic>> read(
    String method, {
    Map<String, Object?> arguments = const {},
    CoreSnapshot? source,
  }) async {
    final result = await runtime.read(method, {
      ...identity(source),
      ...arguments,
    });
    return Map<String, dynamic>.from(jsonDecode(result as String) as Map);
  }

  Future<Map<String, dynamic>> query({
    String name = 'test.test',
    String type = 'A',
    String owner = 'owner-one',
    CoreSnapshot? source,
  }) => read(
    'dnsQuery',
    source: source,
    arguments: {
      'queryOwner': owner,
      'query': {'name': name, 'type': type},
    },
  );

  Future<Map<String, dynamic>> start({
    List<String>? names,
    String? url,
    String? id,
  }) => delays.startBatch(core, {
    'id': id ?? (++_nextBatch).toRadixString(16).padLeft(32, '0'),
    'group': group,
    'members': ?names,
    'url': ?url,
  });

  Future<Map<String, dynamic>> batch(String id) async =>
      Map<String, dynamic>.from((await delays.read(id))['batch'] as Map);

  void emit(Map<String, dynamic> event) => runtime.event(event);

  Future<void> warmUp(WidgetTester tester) async {
    await runtime.restoreExisting();
    await tester.pump();
    changes = 0;
  }

  Future<Object?> _handle(MethodCall call) async {
    final arguments = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    switch (call.method) {
      case 'snapshot':
        return {
          'phase': 'STOPPED',
          'generation': 1,
          'storageReady': true,
          'storageEpoch': 0,
          'networkEpoch': core.networkRevision,
          'core': {'phase': core.phase, ...identity()},
        };
      case ApplicationContract.coreChannelStatus:
      case ApplicationContract.coreChannelHandshake:
        return {
          'protocol': ApplicationContract.coreIpcVersion,
          'phase': core.phase,
          ...identity(),
        };
      case ApplicationContract.coreChannelReadRunInputRecord:
        return {'inputId': arguments['inputId'], 'saved': false};
      case ApplicationContract.coreChannelSubmit:
        final request = CoreDiagnosticRequest._(
          this,
          ++_sequence,
          arguments['operation'] as int,
          Map<String, dynamic>.from(arguments['identity'] as Map),
          Map<String, dynamic>.from(arguments['arguments'] as Map? ?? {}),
        );
        requests.add(request);
        final scripts = _scripts[request.operation];
        if (scripts != null && scripts.isNotEmpty) {
          await scripts.removeFirst()(request);
        } else {
          _defaultReply(request);
        }
        if (_closing && !request.hasTerminal) {
          request.complete(null, terminal: {'complete': false});
          request.signalExit();
        }
        return {
          'accepted': true,
          'processId': request.identity['processId'],
          'requestId': request.id,
        };
      case ApplicationContract.coreChannelRead:
        return _request(arguments).readFrame();
      case ApplicationContract.coreChannelCancel:
        final request = _request(arguments);
        cancellations.add(request);
        return await onCancel?.call(request) ?? {'cancelRequested': true};
      default:
        throw MissingPluginException(call.method);
    }
  }

  CoreDiagnosticRequest _request(Map<String, dynamic> arguments) =>
      requests.singleWhere(
        (request) =>
            request.id == arguments['requestId'] &&
            request.identity['processId'] == arguments['processId'],
      );

  void _defaultReply(CoreDiagnosticRequest request) {
    switch (request.operation) {
      case ApplicationContract.coreOperationSnapshot:
        request.complete({});
        request.signalExit();
      case ApplicationContract.coreOperationMode:
        request.complete({'mode': 'rule'});
        request.signalExit();
      case ApplicationContract.coreOperationLogs:
        request.complete(null);
        request.signalExit();
      case ApplicationContract.coreOperationStrategies:
        final source =
            '${request.identity['processId']}/${request.identity['inputId']}';
        request.frame(ApplicationContract.coreIpcFrameMetadata, {
          'source': source,
          'globalReferenced': false,
        });
        request.frame(ApplicationContract.coreIpcFrameRecord, strategyRecord());
        request.terminal({
          'complete': true,
          'recordCount': 1,
          'source': source,
        });
        request.signalExit();
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    _closing = true;
    onCancel = null;
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    // 结束测试端持有的传输和退出通知，生产对象自行解除 Timer 与占用。
    for (var pass = 0; pass < 8; pass++) {
      for (final request in requests.toList()) {
        if (!request.hasTerminal) {
          request.complete(
            null,
            terminal: {'complete': false, 'error': 'fixtureClosed'},
          );
        }
        if (!request.actualExited) request.signalExit();
      }
      await tester.pump();
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppBridge.channel, null);
  }
}

/// 每个 coreRead 回执来自一帧完整的 FD 字节；terminal 与实际退出分别控制。
class CoreDiagnosticRequest {
  CoreDiagnosticRequest._(
    this.fixture,
    this.id,
    this.operation,
    this.identity,
    this.arguments,
  );
  final CoreDiagnosticFixture fixture;
  final int id;
  final int operation;
  final Map<String, dynamic> identity;
  final Map<String, dynamic> arguments;
  final _wire = Queue<Uint8List>();
  Completer<Map<String, dynamic>>? _reader;
  bool hasTerminal = false;
  bool actualExited = false;
  int reads = 0;

  void frame(int kind, Object? value) =>
      bytes(kind, Uint8List.fromList(utf8.encode(jsonEncode(value))));

  void bytes(int kind, Uint8List payload) {
    final wire = Uint8List(5 + payload.length);
    ByteData.sublistView(wire).setUint32(0, payload.length, Endian.big);
    wire[4] = kind;
    wire.setRange(5, wire.length, payload);
    _wire.add(wire);
    _deliver();
  }

  void terminal(Map<String, Object?> value) {
    if (hasTerminal) throw StateError('该请求已有 terminal');
    hasTerminal = true;
    frame(ApplicationContract.coreIpcFrameTerminal, {
      'exited': false,
      ...value,
    });
  }

  void complete(Object? value, {Map<String, Object?> terminal = const {}}) {
    if (value != null) frame(ApplicationContract.coreIpcFrameData, value);
    this.terminal({'complete': true, ...terminal});
  }

  void measurement(int delay) => complete({
    'name': arguments['name'],
    'identity': arguments['identity'],
    'delay': delay,
  });

  void signalExit({Map<String, Object?> receipt = const {}}) {
    actualExited = true;
    fixture.emit({
      'processId': identity['processId'],
      'requestId': id,
      'exited': true,
      'receipt': receipt,
    });
  }

  Future<Map<String, dynamic>> readFrame() {
    if (_reader != null) throw StateError('同一请求存在两个 coreRead');
    reads++;
    final reader = Completer<Map<String, dynamic>>();
    _reader = reader;
    _deliver();
    return reader.future;
  }

  void _deliver() {
    if (_reader == null || _wire.isEmpty) return;
    final wire = _wire.removeFirst();
    final length = ByteData.sublistView(wire).getUint32(0, Endian.big);
    if (wire.length != length + 5) throw StateError('FD frame 长度不符');
    final reader = _reader!;
    _reader = null;
    reader.complete({
      'kind': wire[4],
      'payload': Uint8List.fromList(wire.sublist(5)),
    });
  }
}

void diagnosticTest(
  String description,
  Future<void> Function(WidgetTester, CoreDiagnosticFixture) body,
) {
  testWidgets(description, (tester) async {
    final fixture = CoreDiagnosticFixture();
    try {
      await body(tester, fixture);
    } finally {
      await fixture.dispose(tester);
    }
  });
}

String diagnosticBatchId(Map<String, dynamic> reply) =>
    (reply['start'] as Map)['id'] as String;

List<Map<String, dynamic>> diagnosticRows(Map<String, dynamic> batch) =>
    (batch['members'] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
