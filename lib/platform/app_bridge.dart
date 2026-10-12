import 'package:flutter/services.dart';

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
  Future<void> start({required String id, required int revision}) =>
      channel.invokeMethod('start', {'id': id, 'revision': revision});
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

  bool get running => phase == 'RUNNING';
  bool get busy =>
      operation != null || ['STARTING', 'STOPPING'].contains(phase);
  bool get confirmed => ['STOPPED', 'RUNNING'].contains(phase);

  factory AppSnapshot.fromMap(Map<String, dynamic> data) => AppSnapshot(
    phase: data['phase'] as String? ?? 'UNKNOWN',
    generation: data['generation'] as int? ?? 0,
    configId: data['configId'] as String?,
    revision: data['revision'] as int?,
    operation: data['operation'] as String?,
    error: data['error'] as String?,
    resultId: data['resultId'] as String?,
    resultMessage: data['resultMessage'] as String?,
    needsHttpConfirmation: data['needsHttpConfirmation'] == true,
  );
}
