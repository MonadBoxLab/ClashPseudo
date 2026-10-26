import 'package:clash_pseudo/src/model/core_snapshot.dart';

import '../features/mode/tunnel_mode.dart';
import 'app_preferences.dart';
import '../l10n/messages.dart';

class RunningApplicationAccess {
  RunningApplicationAccess({
    required this.generation,
    required this.access,
    required List<String> packages,
  }) : packages = List.unmodifiable(packages);

  final int generation;
  final ApplicationAccess access;
  final List<String> packages;

  bool matches(ApplicationAccess access, Iterable<String> packages) {
    final desired = packages.toSet();
    return this.access == access &&
        this.packages.length == desired.length &&
        desired.containsAll(this.packages);
  }

  static RunningApplicationAccess? fromMap(Object? value, int generation) {
    if (value is! Map ||
        generation <= 0 ||
        value['generation'] is! int ||
        value['generation'] != generation) {
      return null;
    }
    try {
      final access = ApplicationAccess.values.byName(value['access'] as String);
      final packages = (value['packages'] as List).cast<String>().toList();
      if (packages.any((name) => name.isEmpty || name != name.trim()) ||
          packages.toSet().length != packages.length ||
          (access == ApplicationAccess.only && packages.isEmpty)) {
        return null;
      }
      return RunningApplicationAccess(
        generation: generation,
        access: access,
        packages: packages,
      );
    } catch (_) {
      return null;
    }
  }
}

class AppSnapshot {
  const AppSnapshot({
    this.phase = 'UNKNOWN',
    this.generation = 0,
    this.alwaysOn,
    this.runningSinceElapsedMs,
    this.elapsedRealtimeMs,
    this.observationClock,
    this.configId,
    this.revision,
    this.scheduleBusy = false,
    this.resourceBusy = false,
    this.runningApplicationAccess,
    this.pendingSystemStart = false,
    this.pendingStart = false,
    this.pendingRestore = false,
    this.storageReady = true,
    this.storageRestoring = false,
    this.storageEpoch = 0,
    this.dnsBusy = false,
    this.networkEpoch,
    this.writerBusy = false,
    AppMessage? operation,
    AppMessage? error,
    this.resultId,
    AppMessage? resultMessage,
    this.connectionStatus,
    this.configStatus,
    this.overrideStatus,
    this.resourceStatus,
    this.scheduleStatus,
    this.backupResult,
    this.targetId,
    this.savedRevision,
    this.resultSuccess = false,
    this.mode,
    AppMessage? modeError,
    this.core = const CoreSnapshot(),
    this.logSource,
  }) : operationMessage = operation,
       errorMessage = error,
       resultMessageDescription = resultMessage,
       modeErrorMessage = modeError;

  final String phase;
  final int generation;
  final bool? alwaysOn;
  final int? runningSinceElapsedMs;
  final int? elapsedRealtimeMs;
  // Local monotonic age of the observed platform snapshot.
  final Stopwatch? observationClock;
  int get uptimeSampleAgeMilliseconds =>
      observationClock?.elapsedMilliseconds ?? 0;

  int? get uptimeMilliseconds {
    final start = runningSinceElapsedMs;
    final sample = elapsedRealtimeMs;
    if (!running ||
        start == null ||
        sample == null ||
        start < 0 ||
        sample < start) {
      return null;
    }
    return sample - start;
  }

  final String? configId;
  final int? revision;
  final bool scheduleBusy;
  final bool resourceBusy;
  final RunningApplicationAccess? runningApplicationAccess;
  final bool pendingSystemStart;
  final bool pendingStart;
  final bool pendingRestore;
  final bool storageReady;
  final bool storageRestoring;
  final int storageEpoch;
  final bool dnsBusy;
  final int? networkEpoch;
  final bool writerBusy;
  final AppMessage? operationMessage;
  final AppMessage? errorMessage;
  final String? resultId;
  final AppMessage? resultMessageDescription;
  String? get operation => operationMessage?.text;
  String? get error => errorMessage?.text;
  String? get resultMessage => resultMessageDescription?.text;
  final String? connectionStatus;
  final String? configStatus;
  final String? overrideStatus;
  final String? resourceStatus;
  final String? scheduleStatus;
  final Map<String, dynamic>? backupResult;
  final String? targetId;
  final int? savedRevision;
  final bool resultSuccess;
  final TunnelMode? mode;
  final AppMessage? modeErrorMessage;
  String? get modeError => modeErrorMessage?.text;
  final CoreSnapshot core;
  final CoreSnapshot? logSource;

  bool get running => phase == 'RUNNING';
  bool get busy =>
      !storageReady ||
      storageRestoring ||
      writerBusy ||
      scheduleBusy ||
      resourceBusy ||
      pendingSystemStart ||
      pendingStart ||
      pendingRestore ||
      operationMessage != null ||
      core.busy ||
      ['STARTING', 'STOPPING'].contains(phase);
  bool get confirmed => ['STOPPED', 'RUNNING'].contains(phase);

  factory AppSnapshot.fromMap(Map<String, dynamic> data) {
    final phase = data['phase'] as String? ?? 'UNKNOWN';
    TunnelMode? mode;
    AppMessage? modeError;
    if (phase == 'RUNNING') {
      try {
        mode = TunnelMode.parse(data['mode']);
      } on FormatException {
        modeError =
            AppMessage.fromNullable(data['modeError']) ??
            messages.temporaryModeUnknown;
      }
    }
    return AppSnapshot(
      observationClock: Stopwatch()..start(),
      phase: phase,
      generation: data['generation'] as int? ?? 0,
      alwaysOn: data['alwaysOn'] is bool ? data['alwaysOn'] as bool : null,
      runningSinceElapsedMs: data['runningSinceElapsedMs'] is int
          ? data['runningSinceElapsedMs'] as int
          : null,
      elapsedRealtimeMs: data['elapsedRealtimeMs'] is int
          ? data['elapsedRealtimeMs'] as int
          : null,
      configId: data['configId'] as String?,
      revision: data['revision'] as int?,
      scheduleBusy: data['scheduleBusy'] == true,
      resourceBusy: data['resourceBusy'] == true,
      runningApplicationAccess: phase == 'RUNNING'
          ? RunningApplicationAccess.fromMap(
              data['runningApplicationAccess'],
              data['generation'] as int? ?? 0,
            )
          : null,
      pendingSystemStart: data['pendingSystemStart'] == true,
      pendingStart: data['pendingStart'] == true,
      pendingRestore: data['pendingRestore'] == true,
      storageReady:
          data['storageReady'] == true &&
          data['storageEpoch'] is int &&
          (data['storageEpoch'] as int) >= 0,
      storageRestoring: data['storageRestoring'] == true,
      storageEpoch: data['storageEpoch'] is int
          ? data['storageEpoch'] as int
          : 0,
      dnsBusy: data['dnsBusy'] == true,
      networkEpoch:
          data['networkEpoch'] is int && (data['networkEpoch'] as int) >= 0
          ? data['networkEpoch'] as int
          : null,
      writerBusy: data['writerBusy'] == true,
      operation: AppMessage.fromNullable(data['operation']),
      error: AppMessage.fromNullable(data['error']),
      resultId: data['resultId'] as String?,
      resultMessage: AppMessage.fromNullable(data['resultMessage']),
      connectionStatus: data['connectionStatus'] as String?,
      configStatus: data['configStatus'] as String?,
      overrideStatus: data['overrideStatus'] as String?,
      resourceStatus: data['resourceStatus'] as String?,
      scheduleStatus: data['scheduleStatus'] as String?,
      backupResult: data['backupResult'] is Map
          ? Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(data['backupResult'] as Map),
            )
          : null,
      targetId: data['targetId'] as String?,
      savedRevision: data['savedRevision'] as int?,
      resultSuccess: data['resultSuccess'] == true,
      mode: mode,
      modeError: modeError,
      logSource: data['logSource'] is Map
          ? CoreSnapshot.fromMap(
              Map<String, dynamic>.from(data['logSource'] as Map),
            )
          : null,
      core: data['core'] is Map
          ? CoreSnapshot.fromMap(Map<String, dynamic>.from(data['core'] as Map))
          : const CoreSnapshot(),
    );
  }
}
