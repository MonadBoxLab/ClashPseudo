import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../features/connections/connection_snapshot.dart';
import '../features/mode/tunnel_mode.dart';
import '../features/strategies/strategy_choice.dart';
import '../features/strategies/strategy_snapshot.dart';

class AppBridge {
  AppBridge({this.operationId});

  static const channel = MethodChannel('io.github.monadboxlab.clashpseudo/app');
  final String? operationId;
  final _cancelled = Completer<void>();

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) {
    if (_cancelled.isCompleted) {
      return Future.error(
        PlatformException(code: 'expired', message: '操作已结束。'),
      );
    }
    final pending = channel.invokeMethod<T>(method, {
      ...?arguments,
      if (operationId != null) 'owner': operationId,
    });
    if (operationId == null) return pending;
    return Future.any([
      pending,
      _cancelled.future.then<T?>(
        (_) => throw PlatformException(code: 'expired', message: '操作已结束。'),
      ),
    ]);
  }

  Future<void> checkOperation() async {
    if (operationId != null) await _call<void>('checkOperation');
  }

  Future<Map<String, dynamic>> paths() async =>
      Map<String, dynamic>.from(await _call<Map>('paths') ?? {});

  Future<AppSnapshot> snapshot() async => AppSnapshot.fromMap(
    Map<String, dynamic>.from(await _call<Map>('snapshot') ?? {}),
  );

  Future<String?> submit(Map<String, Object?> command) =>
      _call<String>('submit', command);
  Future<void> stage(String message) =>
      _call<void>('stage', {'message': message});
  Future<bool> authorize() async => await _call<bool>('authorize') ?? false;
  Future<void> stop() => _call<void>('stop');
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode mode,
  }) =>
      _call<void>('start', {'id': id, 'revision': revision, 'mode': mode.name});
  Future<StrategySnapshot> strategies(int generation) async {
    final value = await _call<String>('strategies', {'generation': generation});
    return StrategySnapshot.fromMap(jsonDecode(value!) as Map<String, dynamic>);
  }

  Future<void> releaseConnectionDetail() => _call<void>('releaseDetail');

  Future<Map<String, dynamic>> runtimeState() async =>
      Map<String, dynamic>.from(await _call<Map>('runtimeState') ?? {});

  Future<void> retainObservation(bool value) =>
      _call<void>('retain', {'value': value});

  Future<Map<String, dynamic>> sampleConnections(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) async {
    final value = await _call<String>('sampleConnections', {
      'generation': core.generation,
      'configId': core.configId,
      'revision': core.revision,
      'query': query,
    });
    return jsonDecode(value!) as Map<String, dynamic>;
  }

  Future<ConnectionSnapshot> recentConnections({
    Map<String, Object?>? detail,
  }) async {
    final value = await _call<Map>('connections', {'detail': detail});
    return ConnectionSnapshot.fromMap(Map<String, dynamic>.from(value!));
  }

  Future<String> closeConnection(CoreSnapshot core, String id) async {
    final value = await _call<String>('closeConnection', {
      'generation': core.generation,
      'configId': core.configId,
      'revision': core.revision,
      'connectionId': id,
    });
    return (jsonDecode(value!) as Map<String, dynamic>)['status'] as String;
  }

  Future<void> prepareStrategies({
    required String id,
    required int revision,
    required TunnelMode mode,
  }) => _call<void>('prepareStrategies', {
    'id': id,
    'revision': revision,
    'mode': mode.name,
  });
  Future<void> releasePreview() => _call<void>('releasePreview');
  Future<void> setStrategy(
    int generation,
    String name,
    StrategyChoice choice,
  ) => _call<void>('setStrategy', {
    'generation': generation,
    'name': name,
    'choice': choice.toJson(),
  });

  Future<TunnelMode> setMode(TunnelMode mode, int generation) async =>
      TunnelMode.parse(
        await _call<String>('setMode', {
          'mode': mode.name,
          'generation': generation,
        }),
      );
}

class AppSnapshot {
  const AppSnapshot({
    this.phase = 'UNKNOWN',
    this.generation = 0,
    this.configId,
    this.revision,
    this.operation,
    this.error,
    this.resultId,
    this.resultMessage,
    this.connectionStatus,
    this.needsHttpConfirmation = false,
    this.resultSuccess = false,
    this.mode,
    this.modeError,
    this.core = const CoreSnapshot(),
  });

  final String phase;
  final int generation;
  final String? configId;
  final int? revision;
  final String? operation;
  final String? error;
  final String? resultId;
  final String? resultMessage;
  final String? connectionStatus;
  final bool needsHttpConfirmation;
  final bool resultSuccess;
  final TunnelMode? mode;
  final String? modeError;
  final CoreSnapshot core;

  bool get running => phase == 'RUNNING';
  bool get busy =>
      operation != null ||
      core.busy ||
      ['STARTING', 'STOPPING'].contains(phase);
  bool get confirmed => ['STOPPED', 'RUNNING'].contains(phase);

  factory AppSnapshot.fromMap(Map<String, dynamic> data) {
    final phase = data['phase'] as String? ?? 'UNKNOWN';
    TunnelMode? mode;
    String? modeError;
    if (phase == 'RUNNING') {
      try {
        mode = TunnelMode.parse(data['mode']);
      } on FormatException {
        modeError = '暂时无法确认运行模式，前台将自动重试。';
      }
    }
    return AppSnapshot(
      phase: phase,
      generation: data['generation'] as int? ?? 0,
      configId: data['configId'] as String?,
      revision: data['revision'] as int?,
      operation: data['operation'] as String?,
      error: data['error'] as String?,
      resultId: data['resultId'] as String?,
      resultMessage: data['resultMessage'] as String?,
      connectionStatus: data['connectionStatus'] as String?,
      needsHttpConfirmation: data['needsHttpConfirmation'] == true,
      resultSuccess: data['resultSuccess'] == true,
      mode: mode,
      modeError: modeError,
      core: data['core'] is Map
          ? CoreSnapshot.fromMap(Map<String, dynamic>.from(data['core'] as Map))
          : const CoreSnapshot(),
    );
  }
}
