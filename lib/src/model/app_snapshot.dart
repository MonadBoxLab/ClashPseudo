import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'tunnel_mode.dart';
import 'app_preferences.dart';
import 'messages.dart';

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
    this.stale = false,
    this.generation = 0,
    this.alwaysOn,
    this.vpnIntent = false,
    this.lanIntent = false,
    this.lanRunning = false,
    this.lanListeners = const [],
    this.recoveryRequired = false,
    this.coreLifecycle = const {},
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
    this.storageError,
    this.backup = const {},
    this.coreCleanup = const {},
    this.dnsBusy = false,
    this.dnsOperation = const {},
    this.networkEpoch,
    this.writerBusy = false,
    this.operationId,
    this.operationAdmittedAt,
    this.operationDeadline,
    this.operationRemainingMs,
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
  final bool stale;
  final int generation;
  final bool? alwaysOn;
  final bool vpnIntent;
  final bool lanIntent;
  final bool lanRunning;
  final List<Map<String, dynamic>> lanListeners;
  final bool recoveryRequired;
  final Map<String, dynamic> coreLifecycle;
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
  final AppMessage? storageError;
  final Map<String, dynamic> backup;
  final Map<String, dynamic> coreCleanup;
  bool get coreDataReady => coreCleanup['ready'] != false;
  final bool dnsBusy;
  final Map<String, dynamic> dnsOperation;
  final int? networkEpoch;
  final bool writerBusy;
  final String? operationId;
  final int? operationAdmittedAt;
  final int? operationDeadline;
  final int? operationRemainingMs;
  final AppMessage? operationMessage;
  final AppMessage? errorMessage;
  final String? resultId;
  final AppMessage? resultMessageDescription;
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
  final CoreSnapshot core;
  final CoreSnapshot? logSource;

  bool get running => phase == 'RUNNING';
  bool get forwarding =>
      core.ready && core.purpose == 'RUNNING' && (running || lanRunning);
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
  bool get confirmed => !stale && ['STOPPED', 'RUNNING'].contains(phase);

  AppSnapshot asStale({
    bool? storageReady,
    bool? storageRestoring,
    int? storageEpoch,
  }) => AppSnapshot(
    phase: phase,
    stale: true,
    generation: generation,
    alwaysOn: alwaysOn,
    vpnIntent: vpnIntent,
    lanIntent: lanIntent,
    lanRunning: lanRunning,
    lanListeners: lanListeners,
    recoveryRequired: recoveryRequired,
    coreLifecycle: coreLifecycle,
    runningSinceElapsedMs: runningSinceElapsedMs,
    elapsedRealtimeMs: elapsedRealtimeMs,
    observationClock: observationClock,
    configId: configId,
    revision: revision,
    scheduleBusy: scheduleBusy,
    resourceBusy: resourceBusy,
    runningApplicationAccess: runningApplicationAccess,
    pendingSystemStart: pendingSystemStart,
    pendingStart: pendingStart,
    pendingRestore: pendingRestore,
    storageReady: storageReady ?? this.storageReady,
    storageRestoring: storageRestoring ?? this.storageRestoring,
    storageEpoch: storageEpoch ?? this.storageEpoch,
    storageError: storageError,
    backup: backup,
    coreCleanup: coreCleanup,
    dnsBusy: dnsBusy,
    dnsOperation: dnsOperation,
    networkEpoch: networkEpoch,
    writerBusy: writerBusy,
    operationId: operationId,
    operationAdmittedAt: operationAdmittedAt,
    operationDeadline: operationDeadline,
    operationRemainingMs: operationRemainingMs,
    operation: operationMessage,
    error: errorMessage,
    resultId: resultId,
    resultMessage: resultMessageDescription,
    connectionStatus: connectionStatus,
    configStatus: configStatus,
    overrideStatus: overrideStatus,
    resourceStatus: resourceStatus,
    scheduleStatus: scheduleStatus,
    backupResult: backupResult,
    targetId: targetId,
    savedRevision: savedRevision,
    resultSuccess: resultSuccess,
    mode: mode,
    modeError: modeErrorMessage,
    core: core,
    logSource: logSource,
  );

  factory AppSnapshot.fromMap(Map<String, dynamic> data) {
    final phase = data['phase'] as String? ?? 'UNKNOWN';
    final core = data['core'] is Map
        ? CoreSnapshot.fromMap(Map<String, dynamic>.from(data['core'] as Map))
        : const CoreSnapshot();
    TunnelMode? mode;
    AppMessage? modeError;
    if (phase == 'RUNNING' ||
        (core.phase != 'EMPTY' && core.purpose == 'RUNNING')) {
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
      vpnIntent: data['vpnIntent'] == true,
      lanIntent: data['lanIntent'] == true,
      lanRunning: data['lanRunning'] == true,
      lanListeners: data['lanListeners'] is List
          ? List.unmodifiable(
              (data['lanListeners'] as List).map(
                (row) => Map<String, dynamic>.unmodifiable(row as Map),
              ),
            )
          : const [],
      recoveryRequired: data['recoveryRequired'] == true,
      coreLifecycle: data['coreLifecycle'] is Map
          ? Map<String, dynamic>.unmodifiable(data['coreLifecycle'] as Map)
          : const {},
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
      storageError: AppMessage.fromNullable(data['storageError']),
      backup: data['backup'] is Map
          ? Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(data['backup'] as Map),
            )
          : const {},
      coreCleanup: data['coreCleanup'] is Map
          ? Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(data['coreCleanup'] as Map),
            )
          : const {},
      dnsBusy: data['dnsBusy'] == true,
      networkEpoch:
          data['networkEpoch'] is int && (data['networkEpoch'] as int) >= 0
          ? data['networkEpoch'] as int
          : null,
      dnsOperation: data['dnsOperation'] is Map
          ? Map<String, dynamic>.unmodifiable(data['dnsOperation'] as Map)
          : const {},
      writerBusy: data['writerBusy'] == true,
      operationId: data['operationId'] as String?,
      operationAdmittedAt: data['operationAdmittedAt'] as int?,
      operationDeadline: data['operationDeadline'] as int?,
      operationRemainingMs: data['operationRemainingMs'] as int?,
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
      core: core,
    );
  }
}
