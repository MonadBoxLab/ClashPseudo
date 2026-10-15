import 'dart:convert';

import 'package:flutter/services.dart';

import '../features/mode/tunnel_mode.dart';
import '../features/strategies/strategy_choice.dart';
import '../features/strategies/strategy_snapshot.dart';

class AppBridge {
  static const channel = MethodChannel('io.github.monadboxlab.clashpseudo/app');

  Future<Map<String, dynamic>> paths() async =>
      Map<String, dynamic>.from(await channel.invokeMapMethod('paths') ?? {});

  Future<AppSnapshot> snapshot() async => AppSnapshot.fromMap(
    Map<String, dynamic>.from(await channel.invokeMapMethod('snapshot') ?? {}),
  );

  Future<void> submit(Map<String, Object?> command) =>
      channel.invokeMethod('submit', command);
  Future<void> stage(String message) => channel.invokeMethod('stage', message);
  Future<bool> authorize() async =>
      await channel.invokeMethod<bool>('authorize') ?? false;
  Future<void> stop() => channel.invokeMethod('stop');
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode mode,
  }) => channel.invokeMethod('start', {
    'id': id,
    'revision': revision,
    'mode': mode.name,
  });
  Future<StrategySnapshot> strategies(int generation) async {
    final value = await channel.invokeMethod<String>('strategies', {
      'generation': generation,
    });
    return StrategySnapshot.fromMap(jsonDecode(value!) as Map<String, dynamic>);
  }

  Future<void> prepareStrategies({
    required String id,
    required int revision,
    required TunnelMode mode,
  }) => channel.invokeMethod('prepareStrategies', {
    'id': id,
    'revision': revision,
    'mode': mode.name,
  });
  Future<void> releasePreview() => channel.invokeMethod('releasePreview');
  Future<void> setStrategy(
    int generation,
    String name,
    StrategyChoice choice,
  ) => channel.invokeMethod('setStrategy', {
    'generation': generation,
    'name': name,
    'choice': choice.toJson(),
  });

  Future<TunnelMode> setMode(TunnelMode mode, int generation) async =>
      TunnelMode.parse(
        await channel.invokeMethod<String>('setMode', {
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
