import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

class DownloadFake extends ConfigDownloader {
  String body = 'rules:\n  - MATCH,DIRECT\n';
  bool fail = false;
  int calls = 0;
  Completer<String>? pending;
  final started = Completer<void>();

  @override
  Future<String> download(String source) async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (fail) throw ConfigFailure(messages.downloadFailed);
    return pending == null ? body : pending!.future;
  }
}

class PlatformFake extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  final events = <String>[];
  bool grant = true;
  bool failStart = false;
  bool failStop = false;
  bool failSchedules = false;
  File? input;
  Map<String, dynamic> loaded = {};
  final inputs = <Map<String, dynamic>>[];
  int _coreGeneration = 0;
  final schedules = <List<Map<String, Object?>>>[];
  final scheduleKinds = <String>[];
  String? snapshotError;
  int snapshotReads = 0;

  void load(
    ConfigEntry entry, {
    TunnelMode mode = TunnelMode.rule,
    TunnelMode? fallbackMode,
    List<OverrideEntry> parts = const [],
    AppPreferences preferences = const AppPreferences(),
  }) {
    loaded = {
      'vpnIntent': true,
      'lanIntent': false,
      'id': entry.id,
      'name': entry.name,
      'revision': entry.revision,
      'body': entry.body,
      'source': entry.source,
      'mode': fallbackMode?.name,
      'routingOverride': null,
      'choices': entry.choices.map(
        (name, choice) => MapEntry(name, choice.toJson()),
      ),
      'overrides': [
        for (final part in parts.where((part) => part.enabled))
          {
            'id': part.id,
            'name': part.name,
            'role': part.role?.name,
            'revision': part.revision,
            'body': part.body,
            'source': part.source,
            'mode': part.mode.name,
          },
      ],
      'composition': jsonEncode([
        entry.id,
        entry.revision,
        for (final part in parts.where((part) => part.enabled))
          [part.id, part.revision, part.mode.name],
      ]),
      'access': preferences.access.name,
      'packages': preferences.packages,
    };
    _running(entry.id, entry.revision, mode);
  }

  void _running(String id, int revision, TunnelMode mode) {
    state = AppSnapshot(
      phase: 'RUNNING',
      generation: state.generation + 1,
      configId: id,
      revision: revision,
      mode: mode,
      core: CoreSnapshot(
        generation: ++_coreGeneration,
        phase: 'READY',
        purpose: 'RUNNING',
        configId: id,
        revision: revision,
        composition: loaded['composition'] as String?,
      ),
    );
  }

  @override
  Future<void> checkOperation() async {}

  @override
  Future<Map<String, dynamic>?> runningRecord(CoreSnapshot core) async => {
    ...jsonDecode(jsonEncode(loaded)) as Map<String, dynamic>,
    'inputId': core.inputId,
  };

  @override
  Future<StrategySnapshot> strategies(CoreSnapshot coreIdentity) async =>
      StrategySnapshot(
        generation: coreIdentity.generation,
        configId: state.configId!,
        revision: state.revision!,
        composition: state.core.composition!,
        purpose: 'RUNNING',
        globalReferenced: false,
        unrestored: const {},
        groups: const [],
      );

  @override
  Future<void> syncSchedules(
    List<Map<String, Object?>> targets, {
    required String kind,
  }) async {
    schedules.add(targets);
    scheduleKinds.add(kind);
    if (failSchedules) throw PlatformFailure(code: 'schedule');
  }

  @override
  Future<AppSnapshot> snapshot() async {
    snapshotReads++;
    if (snapshotError != null) throw StateError(snapshotError!);
    return state;
  }

  bool failModeStage = false;
  Object? stoppingStageFailure;
  @override
  Future<void> stage(AppMessage message) async {
    if (message == messages.stageStopping && stoppingStageFailure != null) {
      throw stoppingStageFailure!;
    }
    if (failModeStage && message == messages.stageSwitchingMode) {
      throw PlatformFailure(code: 'stage');
    }
  }

  @override
  Future<bool> authorize() async {
    events.add('authorize');
    return grant;
  }

  @override
  Future<void> stop({bool preserveLan = true}) async {
    events.add('stop');
    if (failStop) {
      state = const AppSnapshot(phase: 'UNKNOWN');
      throw PlatformFailure(
        code: 'cleanup',
        details: messages.androidErrorReleaseUnconfirmed.toMap(),
      );
    }
    state = AppSnapshot(phase: 'STOPPED', generation: state.generation);
  }

  @override
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode? mode,
    bool explicitStart = true,
    String? path,
  }) async {
    events.add('start:$id');
    if (failStart) {
      throw PlatformFailure(
        code: 'start',
        details: messages.androidErrorTakeoverStartFailed.toMap(),
      );
    }
    final source = path == null ? input : File(path);
    if (source != null) {
      loaded = jsonDecode(await source.readAsString()) as Map<String, dynamic>;
    }
    inputs.add(jsonDecode(jsonEncode(loaded)) as Map<String, dynamic>);
    final actual = loaded['routingOverride'] == null
        ? mode ?? TunnelMode.rule
        : TunnelMode.parse(loaded['routingOverride']);
    _running(id, revision, actual);
  }

  bool failMode = false;
  @override
  Future<TunnelMode> setMode(TunnelMode mode, CoreSnapshot coreIdentity) async {
    final generation = coreIdentity.generation;
    events.add('mode:${mode.name}:$generation');
    if (failMode || generation != state.generation || !state.running) {
      throw PlatformFailure(code: 'mode');
    }
    state = AppSnapshot(
      phase: state.phase,
      generation: generation,
      configId: state.configId,
      revision: state.revision,
      mode: mode,
      core: state.core,
    );
    return mode;
  }
}
