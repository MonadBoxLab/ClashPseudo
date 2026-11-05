import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:convert';

import 'dart:typed_data';
import 'dart:io';

import '../platform/trust/trust_context.dart';

import 'platform_failure.dart';
import 'platform_port.dart';

import 'connection_snapshot.dart';
import 'traffic_snapshot.dart';
import 'tunnel_mode.dart';
import 'strategy_choice.dart';
import 'strategy_snapshot.dart';
import 'messages.dart';
import 'application_contract.dart';
import 'operation_admission.dart';
import '../platform/core/core_client.dart';

abstract interface class RuntimeCore {
  Future<Object?> read(
    String method,
    Map<String, Object?> arguments, {
    AppPlatform? operation,
  });
  Future<Map<String, dynamic>?> inputFor(CoreSnapshot source);
}

/// 复用应用的平台操作方法；channel 与 core 均由调用方注入。
class AppPlatform {
  AppPlatform({
    required this.port,
    required this.coreClient,
    this.core,
    this.operationId,
    this.admittedAt,
    this.deadline,
  });

  final PlatformPort port;
  final CoreClient coreClient;
  final RuntimeCore? core;
  late final _trust = TrustContext(rootsLoader: trustRoots);
  Future<HttpClient> createHttpClient() => _trust.createClient();

  AppPlatform withCore(RuntimeCore value) => AppPlatform(
    port: port,
    coreClient: coreClient,
    core: value,
    operationId: operationId,
    admittedAt: admittedAt,
    deadline: deadline,
  );

  AppPlatform forOperation({
    String? operationId,
    int? admittedAt,
    int? deadline,
  }) {
    if (operationId == this.operationId &&
        admittedAt == this.admittedAt &&
        deadline == this.deadline) {
      return this;
    }
    return AppPlatform(
      port: port,
      coreClient: coreClient,
      core: core,
      operationId: operationId,
      admittedAt: admittedAt,
      deadline: deadline,
    );
  }

  Future<Map<String, dynamic>?> runningRecord(CoreSnapshot source) async =>
      core?.inputFor(source);
  final String? operationId;
  final int? admittedAt;
  final int? deadline;
  final _cancelled = Completer<void>();
  Future<void> get whenCancelled => _cancelled.future;
  Future<void>? _operationDrain;
  Future<void>? get operationDrain => _operationDrain;
  Map<String, Object?> _operationResult = const {};
  Map<String, Object?> get operationResult => _operationResult;

  void retainUntil(Future<void> drain) {
    final previous = _operationDrain;
    _operationDrain = previous == null
        ? drain
        : Future.wait([previous, drain]).then<void>((_) {});
  }

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) {
    if (_cancelled.isCompleted &&
        !const ['snapshot', 'strategies'].contains(method)) {
      return Future.error(
        PlatformFailure(
          code: 'expired',
          details: messages.operationFinished.toMap(),
        ),
      );
    }
    // Cancellation revokes subsequent work, not a submitted operation's result.
    // A read-only snapshot may still confirm that result after its actual reply.
    final request = <String, Object?>{
      ...?arguments,
      if (operationId != null) 'owner': operationId,
      if (admittedAt != null) 'admittedAt': admittedAt,
      if (deadline != null) 'deadline': deadline,
    };
    return port.invoke<T>(method, request);
  }

  Future<T?> _coreCall<T>(String method, [Map<String, Object?>? arguments]) {
    final runtime = core;
    if (runtime == null) return _call<T>(method, arguments);
    if (_cancelled.isCompleted && !const ['strategies'].contains(method)) {
      return Future.error(
        PlatformFailure(
          code: 'expired',
          details: messages.operationFinished.toMap(),
        ),
      );
    }
    return runtime
        .read(method, {
          ...?arguments,
          if (operationId != null) 'owner': operationId,
          if (admittedAt != null) 'admittedAt': admittedAt,
          if (deadline != null) 'deadline': deadline,
        }, operation: this)
        .then((value) {
          if (method == 'prepareStrategies' && value is Map) {
            _operationResult = Map<String, Object?>.unmodifiable(value);
            return null;
          }
          return value as T?;
        });
  }

  /// Re-reads the saved language for Android-owned notification text.
  /// Application messages remain untranslated until displayed.
  Future<void> refreshStrings() async {
    if (operationId == null) return;
    await _call<void>('refreshStrings');
  }

  Future<void> checkOperation() async {
    if (operationId != null) await _call<void>('checkOperation');
    checkCancellation();
  }

  /// 提交 native 前检查本地取消，不再等待平台调用。
  void checkCancellation() {
    if (_cancelled.isCompleted) {
      throw PlatformFailure(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
  }

  Future<Duration> operationRemaining() async {
    final milliseconds = await _call<int>('operationRemaining');
    if (milliseconds == null ||
        milliseconds < 0 ||
        milliseconds > ApplicationContract.operationBackupTimeoutMs) {
      throw const FormatException('Invalid operation budget');
    }
    return Duration(milliseconds: milliseconds);
  }

  Future<Map<String, int>> operationTiming() async {
    final state = await _call<Map>('snapshot');
    final admitted = admittedAt ?? state?['operationAdmittedAt'];
    final end = deadline ?? state?['operationDeadline'];
    if (admitted is! int || end is! int || admitted < 0 || end < admitted) {
      throw const FormatException('操作没有有效的原受理时钟');
    }
    return {'admittedAt': admitted, 'deadline': end};
  }

  Future<void> uiReady() => _call<void>('uiReady');

  Future<Map<String, dynamic>> paths() async =>
      Map<String, dynamic>.from(await _call<Map>('paths') ?? {});

  Future<Map<String, dynamic>> coreCleanupCandidates() async =>
      Map<String, dynamic>.from(
        await _coreCall<Map>('coreCleanupCandidates') ?? const {},
      );

  Future<Map<String, dynamic>> scheduleCoreCleanup(
    Map<String, Object?> request,
  ) async {
    if (operationId == null) {
      throw PlatformFailure(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
    return Map<String, dynamic>.from(
      await _call<Map>('scheduleCoreCleanup', request) ?? {},
    );
  }

  Future<Map<String, dynamic>> storageUsage() async =>
      Map<String, dynamic>.from(await _call<Map>('storageUsage') ?? {});

  Future<Map<String, dynamic>> publishStore(String file, int epoch) async {
    if (operationId == null) {
      throw PlatformFailure(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
    final value = await _call<Map>('publishStore', {
      'file': file,
      'epoch': epoch,
    });
    if (value?['saved'] != true ||
        value?['epoch'] is! int ||
        value?['epoch'] != epoch ||
        value?['durable'] is! bool) {
      throw PlatformFailure(
        code: 'storage',
        details: messages.storageUnavailable.withDetail({
          'expectedEpoch': epoch,
          if (value?['epoch'] is int) 'epoch': value!['epoch'],
          if (value?['epoch'] is! int)
            'epochType': value?['epoch'].runtimeType.toString(),
          if (value?['saved'] is bool) 'saved': value!['saved'],
          if (value?['saved'] is! bool)
            'savedType': value?['saved'].runtimeType.toString(),
          if (value?['durable'] is bool) 'durable': value!['durable'],
          if (value?['durable'] is! bool)
            'durableType': value?['durable'].runtimeType.toString(),
          if (value?['errorCode'] != null) 'errorCode': value!['errorCode'],
          if (value?['errorDetail'] != null)
            'errorDetail': value!['errorDetail'],
        }).toMap(),
      );
    }
    return Map<String, dynamic>.from(value!);
  }

  Future<Map<String, dynamic>> backupPrepareExport({
    required String requestId,
    required int createdAtMillis,
    required int expectedEpoch,
    required Map<String, String> defaults,
  }) async => Map<String, dynamic>.from(
    await _call<Map>('backupPrepareExport', {
          'requestId': requestId,
          'createdAtMillis': createdAtMillis,
          'expectedEpoch': expectedEpoch,
          'defaults': defaults,
        }) ??
        {},
  );

  Future<Map<String, dynamic>> backupCandidate(String token) async =>
      Map<String, dynamic>.from(
        await _call<Map>('backupCandidate', {'token': token}) ?? {},
      );

  Future<Map<String, dynamic>> backupInstall(
    String token, {
    required int expectedEpoch,
  }) async {
    if (operationId == null) {
      throw PlatformFailure(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
    final value = await _call<Map>('backupInstall', {
      'token': token,
      'expectedEpoch': expectedEpoch,
    });
    return Map<String, dynamic>.from(value ?? {});
  }

  Future<Map<String, dynamic>> backupPickImport(String requestId) async =>
      Map<String, dynamic>.from(
        await _call<Map>('backupPickImport', {'requestId': requestId}) ?? {},
      );

  Future<Map<String, dynamic>> backupSaveExport({
    required String requestId,
    required String token,
    required String title,
  }) async => Map<String, dynamic>.from(
    await _call<Map>('backupSaveExport', {
          'requestId': requestId,
          'token': token,
          'title': title,
        }) ??
        {},
  );

  Future<void> backupCancel(String requestId) =>
      _call<void>('backupCancel', {'requestId': requestId});

  Future<void> backupDiscard(String token) =>
      _call<void>('backupDiscard', {'token': token});

  Future<Uint8List> trustRoots() async {
    final roots = await _call<Uint8List>('trustRoots');
    if (roots == null) {
      throw PlatformFailure(
        code: 'trust',
        details: const AppMessage('trustedRootsUnavailable').toMap(),
      );
    }
    return roots;
  }

  /// Only an explicit false confirms that this installation has no shown marker.
  Future<bool> privacyNoticeShown() async {
    final shown = await _call<bool>('privacyNoticeShown');
    if (shown == null) {
      throw const FormatException(
        'Privacy notice display status is unconfirmed',
      );
    }
    return shown;
  }

  Future<void> markPrivacyNoticeShown() =>
      _call<void>('markPrivacyNoticeShown');

  Future<Map<String, dynamic>> applicationInfo() async =>
      Map<String, dynamic>.from(await _call<Map>('appInfo') ?? {});

  Future<AppSnapshot> snapshot() async => AppSnapshot.fromMap(
    Map<String, dynamic>.from(await _call<Map>('snapshot') ?? {}),
  );

  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    final Map<String, Object?> request;
    if (const [
      'saveLocalDefinition',
      'deleteLocalDefinition',
    ].contains(command['action'])) {
      final payload = <String, Object?>{
        for (final entry in command.entries)
          if (!const ['action', 'storageEpoch', 'owner'].contains(entry.key))
            entry.key: entry.value,
      };
      request = {
        'action': command['action'],
        if (command.containsKey('storageEpoch'))
          'storageEpoch': command['storageEpoch'],
        // Validate nested strings and mapping keys as well as the final YAML body.
        'definitionPayload': utf8.encode(jsonEncode(payload)),
      };
    } else {
      request = {
        ...command,
        // StandardMessageCodec's string decoder consumes a leading UTF-8 BOM.
        if (command['action'] == 'saveLocal' ||
            command['action'] == 'saveOverride')
          'body': utf8.encode(command['body'] as String),
      };
    }
    final value = await _call<Map>('submit', request);
    return value == null ? null : OperationAdmission.fromMap(value);
  }

  Future<void> stage(AppMessage message) =>
      _call<void>('stage', {'message': message.toMap()});
  Future<bool> authorize() async => await _call<bool>('authorize') ?? false;
  Future<void> stop({bool preserveLan = true}) =>
      _coreCall<void>('stop', {'preserveLan': preserveLan});
  Future<void> finishScheduledDownload(
    AppSnapshot expected, {
    required String kind,
    required String id,
  }) => _call<void>('finishScheduledDownload', {
    'kind': kind,
    'id': id,
    'sessionGeneration': expected.generation,
    'generation': expected.core.generation,
    'composition': expected.core.composition,
    'configId': expected.configId,
    'revision': expected.revision,
  });
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode? mode,
    bool explicitStart = true,
    String? path,
  }) => _coreCall<void>('start', {
    'id': id,
    'revision': revision,
    'mode': mode?.name,
    'explicitStart': explicitStart,
    'path': ?path,
  });
  Future<StrategySnapshot> strategies(CoreSnapshot core) async {
    final value = await _coreCall<String>('strategies', _dnsIdentity(core));
    try {
      return StrategySnapshot.fromMap(
        jsonDecode(value!) as Map<String, dynamic>,
      );
    } catch (error) {
      throw PlatformFailure(
        code: 'strategies',
        details: messages.strategyStatusStale
            .withDetail(
              error is FormatException
                  ? FormatException(error.message, null, error.offset)
                  : error,
            )
            .toMap(),
      );
    }
  }

  Map<String, dynamic> _decodeResponse(String? value) {
    try {
      return jsonDecode(value!) as Map<String, dynamic>;
    } on FormatException catch (error) {
      throw FormatException(error.message, null, error.offset);
    }
  }

  Map<String, dynamic> _decodeCoreRead(String method, String? value) {
    try {
      return _decodeResponse(value);
    } catch (error) {
      throw PlatformFailure(
        code: method,
        details: const AppMessage('coreReadFailed').withDetail(error).toMap(),
      );
    }
  }

  Future<Map<String, dynamic>> nodes(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _coreCall<String>('nodes', {
      ..._dnsIdentity(core),
      'query': query,
    });
    return _decodeCoreRead('nodes', value);
  }

  Future<Map<String, dynamic>> rules(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _coreCall<String>('rules', {
      ..._dnsIdentity(core),
      'query': query,
    });
    return _decodeCoreRead('rules', value);
  }

  Future<Map<String, dynamic>> runtimeConfiguration(CoreSnapshot core) async {
    final value = await _coreCall<String>('runtimeConfig', {
      ..._dnsIdentity(core),
    });
    return _decodeCoreRead('runtimeConfig', value);
  }

  Future<Map<String, dynamic>> readRunInputRecord(CoreSnapshot core) async {
    if (core.inputId?.isNotEmpty != true) {
      throw PlatformFailure(
        code: ApplicationContract.coreErrorIdentityMismatch,
      );
    }
    return coreClient.readRunInputRecord(core.inputId!);
  }

  Future<Map<String, dynamic>> localInterfaces() =>
      coreClient.localInterfaces();

  Future<Map<String, dynamic>> resources(CoreSnapshot core) async {
    final value = await _coreCall<String>('resources', {..._dnsIdentity(core)});
    return _decodeCoreRead('resources', value);
  }

  Future<Map<String, dynamic>> startDelayTest(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _coreCall<String>('delayStart', {
      ..._dnsIdentity(core),
      'query': query,
    });
    return _decodeCoreRead('delayStart', value);
  }

  Future<Map<String, dynamic>> delayTest(
    CoreSnapshot core,
    String batch,
  ) async {
    final value = await _coreCall<String>('delayRead', {
      ..._dnsIdentity(core),
      'batch': batch,
    });
    return _decodeCoreRead('delayRead', value);
  }

  Future<void> cancelDelayTest(String batch) =>
      _coreCall<void>('delayCancel', {'batch': batch});

  Future<Map<String, dynamic>> logs(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _coreCall<String>('logs', {
      ..._dnsIdentity(core),
      'query': {...query, 'window': core.logWindow},
    });
    return _decodeCoreRead('logs', value);
  }

  Future<Map<String, dynamic>> updateResource(
    CoreSnapshot core, {
    required String kind,
    required String name,
  }) async {
    if (operationId == null) {
      throw PlatformFailure(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
    final value = await _coreCall<String>('updateResource', {
      ..._dnsIdentity(core),
      'configId': core.configId,
      'revision': core.revision,
      'purpose': core.purpose,
      'query': {'kind': kind, 'name': name},
    });
    return _decodeResponse(value);
  }

  Future<TrafficSnapshot> traffic() async {
    final value = await _call<Map>('traffic');
    return TrafficSnapshot.fromMap(Map<String, dynamic>.from(value!));
  }

  Future<Map<String, dynamic>> appMemory() async {
    final value = await _coreCall<String>('appMemory');
    return _decodeResponse(value);
  }

  Future<Map<String, dynamic>> coreMemory(CoreSnapshot source) async {
    final value = await _coreCall<String>('coreMemory', {
      'processId': source.processId,
    });
    return _decodeResponse(value);
  }

  Map<String, Object?> _dnsIdentity(CoreSnapshot core) => {
    'processId': core.processId,
    'inputId': core.inputId,
    'networkRevision': core.networkRevision,
    'generation': core.generation,
    'composition': core.composition,
    'configId': core.configId,
    'revision': core.revision,
    'purpose': core.purpose,
  };

  Future<Map<String, dynamic>> dnsQuery(
    CoreSnapshot core, {
    required String name,
    required String type,
    required String queryOwner,
  }) async {
    final value = await _coreCall<String>('dnsQuery', {
      ..._dnsIdentity(core),
      'queryOwner': queryOwner,
      'query': {'name': name, 'type': type},
    });
    return _decodeResponse(value);
  }

  Future<Map<String, dynamic>> clearDnsCache(CoreSnapshot core) async {
    final value = await _coreCall<String>('clearDnsCache', _dnsIdentity(core));
    return _decodeResponse(value);
  }

  Future<Map<String, dynamic>> flushFakeIp(CoreSnapshot core) async {
    final value = await _coreCall<String>('flushFakeIp', _dnsIdentity(core));
    return _decodeResponse(value);
  }

  Future<void> cancelDnsQuery(
    CoreSnapshot core, {
    required String queryOwner,
  }) => _coreCall<void>('cancelDnsQuery', {
    ..._dnsIdentity(core),
    'queryOwner': queryOwner,
  });

  Future<void> releaseConnectionDetail({required String owner}) {
    if (owner.isEmpty) throw ArgumentError.value(owner, 'owner');
    return _call<void>('releaseDetail', {'detailOwner': owner});
  }

  Future<List<Map<String, dynamic>>> applications() async {
    final value = await _call<List>('applications') ?? const [];
    return value.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  /// One installed application's icon as PNG bytes, or null when unavailable.
  Future<Uint8List?> applicationIcon(String package) async {
    final value = await _call<Uint8List>('applicationIcon', {
      'package': package,
    });
    return value;
  }

  Future<Map<String, dynamic>> vpnStatus() async =>
      Map<String, dynamic>.from(await _call<Map>('vpnStatus') ?? {});

  Future<void> openVpnSettings() => _call<void>('openVpnSettings');

  /// Publishes one collection's enabled targets without changing the other kind.
  Future<void> syncSchedules(
    List<Map<String, Object?>> targets, {
    required String kind,
  }) => _call<void>('syncSchedules', {'kind': kind, 'targets': targets});

  Future<Map<String, dynamic>> refreshSchedule({
    required String kind,
    required String id,
  }) async => Map<String, dynamic>.from(
    await _call<Map>('refreshSchedule', {'kind': kind, 'id': id}) ?? {},
  );

  Future<Map<String, dynamic>> runtimeState() async =>
      Map<String, dynamic>.from(await _call<Map>('runtimeState') ?? {});

  Future<void> retainObservation(bool value, {required String owner}) {
    if (owner.isEmpty) throw ArgumentError.value(owner, 'owner');
    return _call<void>('retain', {'value': value, 'observationOwner': owner});
  }

  Future<Map<String, dynamic>> sampleConnections(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _coreCall<String>('sampleConnections', {
      ..._dnsIdentity(core),
      'query': query,
    });
    return _decodeResponse(value);
  }

  Future<ConnectionSnapshot> recentConnections({
    Map<String, Object?>? detail,
    String? detailOwner,
  }) async {
    if (detail != null && (detailOwner == null || detailOwner.isEmpty)) {
      throw ArgumentError.value(detailOwner, 'detailOwner');
    }
    final value = await _call<Map>('connections', {
      'detail': detail,
      'detailOwner': detailOwner,
    });
    return ConnectionSnapshot.fromMap(Map<String, dynamic>.from(value!));
  }

  Future<ConnectionSnapshot> clearInactiveConnections({
    Map<String, Object?>? detail,
    String? detailOwner,
  }) async {
    if (detail != null && (detailOwner == null || detailOwner.isEmpty)) {
      throw ArgumentError.value(detailOwner, 'detailOwner');
    }
    final value = await _call<Map>('clearInactiveConnections', {
      'detail': detail,
      'detailOwner': detailOwner,
    });
    return ConnectionSnapshot.fromMap(Map<String, dynamic>.from(value!));
  }

  Future<String> closeConnection(CoreSnapshot core, String id) async {
    final value = await _coreCall<String>('closeConnection', {
      ..._dnsIdentity(core),
      'connectionId': id,
    });
    return (jsonDecode(value!) as Map<String, dynamic>)['status'] as String;
  }

  Future<void> prepareStrategies({
    required String id,
    required int revision,
    required TunnelMode? mode,
  }) => _coreCall<void>('prepareStrategies', {
    'id': id,
    'revision': revision,
    'mode': mode?.name,
  });
  Future<void> releasePreview() => _coreCall<void>('releasePreview');
  Future<void> setStrategy(
    CoreSnapshot core,
    String name,
    StrategyChoice choice,
  ) => _coreCall<void>('setStrategy', {
    ..._dnsIdentity(core),
    'name': name,
    'choice': choice.toJson(),
  });

  Future<TunnelMode> setMode(TunnelMode mode, CoreSnapshot core) async =>
      TunnelMode.parse(
        await _coreCall<String>('setMode', {
          'mode': mode.name,
          ..._dnsIdentity(core),
        }),
      );
}
