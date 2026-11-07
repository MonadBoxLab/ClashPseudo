import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/logic/running_input.dart';

import 'dart:io';
import 'dart:math';

import '../../model/messages.dart';
import '../../model/app_platform.dart';
import '../../platform/core/core_input.dart';
import '../../model/tunnel_mode.dart';
import '../../model/override_entry.dart';
import '../overrides/override_store.dart';
import '../../model/app_preferences.dart';
import '../storage/preferences_store.dart';
import '../schedules/schedule_targets.dart';
import 'config_downloader.dart';
import '../../model/config_entry.dart';
import 'config_store.dart';
import '../../model/config_text.dart';
import '../../model/platform_failure.dart';

class ConfigActions {
  ConfigActions(
    this.store,
    this.downloader,
    this.platform,
    this.runInput, {
    this.systemInput,
  });

  final ConfigStore store;
  final ConfigDownloader downloader;
  final AppPlatform platform;
  final File runInput;

  /// Prepared by a system Always-on start; read by the VPN service afterwards.
  final File? systemInput;
  Map<String, Object?> result = const {};

  static Future<AppMessage> stop(AppPlatform platform) async {
    Object? stageFailure;
    StackTrace? stageStack;
    try {
      await platform.stage(messages.stageStopping);
    } catch (failure, stack) {
      // Progress projection failure must not prevent the actual Stop.
      stageFailure = failure;
      stageStack = stack;
    }
    try {
      await platform.stop();
    } catch (failure, stack) {
      if (stageFailure == null) rethrow;
      throw ConfigFailure(
        messages.operationNotCompletedRetry
            .withDetail(failure)
            .withDetail(stageFailure),
        cause: {
          'cause': failureValue(failure, stack),
          'suppressed': [failureValue(stageFailure, stageStack)],
        },
        stackTrace: stack,
      );
    }
    return messages.tunnelStopped.withDetail(stageFailure);
  }

  Future<AppMessage?> execute(Map<String, dynamic> command) async {
    final action = command['action'];
    result =
        const [
          'saveLocal',
          'import',
          'updateConfig',
          'clearConfigurations',
        ].contains(action)
        ? {'configStatus': 'notSaved', 'targetId': command['id']}
        : const {};
    if (action == 'stop') return stop(platform);
    if (action == 'setApplicationAccess') {
      return _setApplicationAccess(command);
    }
    if (action == 'clearConfigurations') {
      return _saveRemoval(
        ConfigCollection(entries: const []),
        const AppMessage('configurationsCleared'),
        clear: true,
      );
    }
    final collection = await store.read();
    if (command['id'] case final String id) {
      final entry = _entry(collection, id);
      if ((command.containsKey('revision') &&
              command['revision'] != entry.revision) ||
          (command.containsKey('expectedSource') &&
              command['expectedSource'] != entry.source) ||
          (command.containsKey('expectedName') &&
              command['expectedName'] != entry.name)) {
        throw ConfigFailure(messages.configChangedReopen);
      }
    }
    switch (action) {
      case 'prepareStrategies':
        return _prepareStrategies(collection, await _state(), command);
      case 'setMode':
        return _setMode(collection, TunnelMode.parse(command['mode']));
      case 'import':
        return _import(collection, command);
      case 'updateConfig':
        final entry = _entry(collection, command['id'] as String);
        if (!entry.remote) {
          throw ConfigFailure(messages.localCannotRemoteUpdate);
        }
        return _import(collection, {
          ...command,
          'source': command['source'] ?? entry.source,
          'replace': true,
        });
      case 'setConfigUpdate':
        return _setUpdate(collection, command);
      case 'renameConfig':
        final entry = _entry(collection, command['id'] as String);
        final changed = entry.renamed(_localName(command['name'] as String));
        await store.save(collection.replace(changed));
        _saved(changed);
        return messages.configRenamed;
      case 'saveLocal':
        return _saveLocal(collection, command);
      case 'select':
        return _select(collection, command['id'] as String);
      case 'delete':
        return _delete(collection, command['id'] as String);
      case 'systemStart':
        return _systemStart(collection, await _state());
      case 'start':
        final state = await _state();
        if (state.running) throw ConfigFailure(messages.alreadyRunning);
        final selected = collection.selected;
        if (selected == null) {
          throw ConfigFailure(messages.importAndSelectFirst);
        }
        await _start(
          selected,
          collection.mode,
          vpnIntent: command['vpnIntent'] != false,
        );
        return messages.tunnelStarted;
      default:
        throw ConfigFailure(messages.unknownOperation);
    }
  }

  Future<AppSnapshot> _state() async {
    final state = await platform.snapshot();
    if (!state.confirmed) {
      throw ConfigFailure(
        messages.statusUnconfirmedVerify.withDetail(state.errorMessage),
      );
    }
    return state;
  }

  Future<AppMessage?> _prepareStrategies(
    ConfigCollection collection,
    AppSnapshot state,
    Map<String, dynamic> command,
  ) async {
    final selected = collection.selected;
    if (selected == null) throw ConfigFailure(messages.importAndSelectFirst);
    if (command['id'] != selected.id ||
        command['revision'] != selected.revision) {
      throw ConfigFailure(messages.configChangedWaitStrategies);
    }
    if (state.core.blocked) {
      throw ConfigFailure(messages.coreNotReadyStrategies);
    }
    if (state.forwarding) {
      if (state.configId != selected.id ||
          state.revision != selected.revision) {
        throw ConfigFailure(messages.previewMismatch);
      }
      return null;
    }
    await platform.stage(messages.stageLoadingStrategies);
    final input = CoreInput(runInput);
    try {
      await input.write(
        selected,
        collection.mode,
        overrides: await OverrideStore(store.directory).read(),
        vpnIntent: false,
        lanIntent: false,
      );
      await platform.prepareStrategies(
        id: selected.id,
        revision: selected.revision,
        mode: collection.mode,
      );
    } finally {
      await input.clear();
    }
    return null;
  }

  Future<AppMessage> _import(
    ConfigCollection collection,
    Map<String, dynamic> command,
  ) async {
    final source = command['source'] as String;
    ConfigDownloader.sourceUri(source);
    final existing = command['id'] == null
        ? null
        : _entry(collection, command['id'] as String);
    if (existing != null && !existing.remote) {
      throw ConfigFailure(messages.localCannotChangeRemote);
    }
    if (existing != null && command['replace'] != true) {
      throw ConfigFailure(messages.sourceSavedConfirmOverwrite);
    }
    final id = existing?.id ?? _newId();
    final name = existing?.name ?? _name(command['name'] as String?, source);
    await platform.stage(
      existing == null
          ? messages.stageDownloading
          : messages.stageUpdatingConfig,
    );
    // Neither the source nor the old body changes until the download succeeds.
    final body = await downloader.download(source);
    checkConfigText(body);
    final current = await store.read();
    final saved = current.find(id);
    if (existing == null
        ? saved != null
        : saved == null ||
              saved.source != existing.source ||
              saved.revision != existing.revision) {
      throw ConfigFailure(messages.configChangedDownloadUnapplied);
    }
    final entry = saved == null
        ? ConfigEntry(
            id: id,
            name: name,
            source: source,
            revision: 1,
            body: body,
            updatedAt: DateTime.now(),
          )
        : saved.withSource(source).withContent(body);
    final next = saved == null
        ? ConfigCollection(
            entries: [...current.entries, entry],
            selectedId: current.selectedId ?? entry.id,
            mode: current.mode,
          )
        : current.replace(entry);
    await store.save(next);
    _saved(entry);
    final applied = await _applyContent(
      saved,
      entry,
      next.mode,
      messages.configSavedReconnectIncomplete,
    );
    if (result['configStatus'] == 'applyFailed') {
      return result['message'] as AppMessage;
    }
    if (applied) return messages.configUpdatedRestarted;
    return existing == null
        ? messages.configSavedParsedAtStart
        : messages.configUpdated;
  }

  Future<AppMessage> _saveLocal(
    ConfigCollection collection,
    Map<String, dynamic> command,
  ) async {
    final id = command['id'] as String?;
    final existing = id == null ? null : _entry(collection, id);
    if (existing != null &&
        (existing.remote || command['revision'] != existing.revision)) {
      throw ConfigFailure(messages.configChangedReopen);
    }
    final body = command['body'] as String;
    checkConfigText(body);
    final entry =
        existing?.withContent(body) ??
        ConfigEntry(
          id: _newId(),
          name: _localName(command['name'] as String),
          kind: ConfigKind.local,
          revision: 1,
          body: body,
          updatedAt: DateTime.now(),
        );
    final next = existing == null
        ? ConfigCollection(
            entries: [...collection.entries, entry],
            selectedId: collection.selectedId ?? entry.id,
            mode: collection.mode,
          )
        : collection.replace(entry);
    await platform.stage(messages.stageSavingConfig);
    await store.save(next);
    _saved(entry);
    final applied = await _applyContent(
      existing,
      entry,
      next.mode,
      messages.configSavedApplyReleasePending,
    );
    if (result['configStatus'] == 'applyFailed') {
      return result['message'] as AppMessage;
    }
    return applied ? messages.configSavedApplied : messages.configSaved;
  }

  void _saved(ConfigEntry entry) {
    result = {
      'configStatus': 'saved',
      'targetId': entry.id,
      'savedRevision': entry.revision,
    };
  }

  Future<bool> _applyContent(
    ConfigEntry? before,
    ConfigEntry saved,
    TunnelMode? fallbackMode,
    AppMessage failed,
  ) async {
    try {
      final state = await _state();
      if (state.forwarding && state.core.configId == saved.id) {
        final loaded = await RunningInput.read(platform, state);
        if (loaded == null) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        if (loaded.entry.body == saved.body) {
          result = {...result, 'configStatus': 'applied'};
          return false;
        }
        await platform.stage(messages.stageApplyingConfigUpdate);
        await loaded.reconnect(
          platform,
          CoreInput(runInput),
          fallbackMode: loaded.fallbackMode,
          entry: loaded.updatedEntry(saved),
        );
        result = {...result, 'configStatus': 'applied'};
        return true;
      }
      if (!state.forwarding &&
          state.core.purpose == 'PREVIEW' &&
          state.core.configId == saved.id &&
          before?.body != saved.body) {
        await platform.releasePreview();
      }
    } catch (failure, stack) {
      result = {
        ...result,
        'failure': failureValue(failure, stack),
        'configStatus': 'applyFailed',
        'success': false,
        'message': failed.withDetail(failure),
      };
    }
    return false;
  }

  /// Save periodic policy, then synchronize only configuration schedules.
  Future<AppMessage> _setUpdate(
    ConfigCollection collection,
    Map<String, dynamic> command,
  ) async {
    final entry = _entry(collection, command['id'] as String);
    if (!entry.remote) throw ConfigFailure(messages.localNoAutoUpdate);
    final enabled = command['enabled'] == true;
    final hours = command['hours'] as int? ?? entry.update.hours;
    if (!UpdatePolicy.intervals.contains(hours)) {
      throw ConfigFailure(messages.chooseUpdateInterval);
    }
    final updated = entry.withUpdate(
      entry.update.changed(enabled: enabled, hours: hours),
    );
    final next = collection.replace(updated);
    await store.save(next);
    _saved(updated);
    final message = enabled
        ? messages.autoUpdateEnabledResult
        : messages.autoUpdateDisabledResult;
    try {
      await _syncSchedules(next);
    } catch (failure, stack) {
      throw ConfigFailure(
        messages.settingsSaved.withDetail(failure),
        cause: failure,
        stackTrace: stack,
      );
    }
    return message;
  }

  Future<void> _syncSchedules(ConfigCollection collection) async {
    try {
      await platform.syncSchedules(
        scheduleTargets(collection.entries, const []),
        kind: 'config',
      );
      result = {...result, 'scheduleStatus': 'synced'};
    } catch (_) {
      result = {...result, 'scheduleStatus': 'failed', 'success': false};
      rethrow;
    }
  }

  String _localName(String value) {
    if (!validConfigName(value)) {
      throw ConfigFailure(messages.configNameInvalid);
    }
    return value;
  }

  Future<AppMessage> _select(ConfigCollection collection, String id) async {
    final entry = _entry(collection, id);
    // The saved selection and the running immutable input are separate results.
    await store.save(
      ConfigCollection(
        entries: collection.entries,
        selectedId: id,
        mode: collection.mode,
      ),
    );
    _saved(entry);
    try {
      final state = await _state();
      if (state.forwarding) {
        final loaded = await RunningInput.read(platform, state);
        if (loaded == null) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        final parts = await OverrideStore(store.directory).read();
        final preferences = await PreferencesStore(store.directory).read();
        if (!loaded.matchesSelection(
          entry,
          collection.mode,
          parts,
          preferences,
        )) {
          await platform.stage(messages.stageStoppingOld);
          await loaded.reconnect(
            platform,
            CoreInput(runInput),
            entry: entry,
            fallbackMode: collection.mode,
            parts: parts,
            preferences: preferences,
            lanIntent: parts.any(
              (part) => part.enabled && part.role == OverrideRole.lanProxy,
            ),
          );
        }
        result = {...result, 'configStatus': 'applied'};
        return messages.switchedConfig;
      }
      if (state.core.purpose == 'PREVIEW') await platform.releasePreview();
      return messages.configSelectedNotStarted;
    } catch (failure) {
      result = {
        ...result,
        'configStatus': 'applyFailed',
        'success': false,
        'message': messages.configSavedReconnectIncomplete.withDetail(failure),
      };
      rethrow;
    }
  }

  Future<AppMessage> _delete(ConfigCollection collection, String id) async {
    _entry(collection, id);
    final next = ConfigCollection(
      entries: collection.entries.where((entry) => entry.id != id).toList(),
      mode: collection.mode,
      selectedId: collection.selectedId == id ? null : collection.selectedId,
    );
    return _saveRemoval(next, messages.configDeleted, id: id);
  }

  Future<AppMessage> _saveRemoval(
    ConfigCollection next,
    AppMessage message, {
    String? id,
    bool clear = false,
  }) async {
    if (clear) {
      await store.clear();
    } else {
      await store.save(next);
    }
    result = {'configStatus': 'saved', 'targetId': ?id};
    final failures = <Object>[];
    try {
      final state = await _state();
      if (!state.forwarding &&
          state.core.purpose == 'PREVIEW' &&
          (id == null || state.core.configId == id)) {
        await platform.releasePreview();
      }
    } catch (failure) {
      result = {...result, 'configStatus': 'applyFailed', 'success': false};
      failures.add(failure);
    }
    try {
      await _syncSchedules(next);
    } catch (failure) {
      failures.add(failure);
    }
    return failures.fold<AppMessage>(
      message,
      (message, failure) => message.withDetail(failure),
    );
  }

  Future<AppMessage> _setMode(
    ConfigCollection collection,
    TunnelMode mode,
  ) async {
    final changed = collection.mode != mode;
    final next = ConfigCollection(
      entries: collection.entries,
      selectedId: collection.selectedId,
      mode: mode,
    );
    if (changed) await store.save(next);
    result = {'configStatus': 'saved'};
    try {
      final state = await _state();
      if (!state.forwarding) {
        final selected = next.selected;
        if (changed && state.core.purpose == 'PREVIEW' && selected != null) {
          await _prepareStrategies(next, state, {
            'id': selected.id,
            'revision': selected.revision,
          });
        }
        return messages.modeSavedNextStart;
      }
      if (state.mode == mode) return messages.modeConfirmed;
      await platform.stage(messages.stageSwitchingMode);
      final preferences = await PreferencesStore(store.directory).read();
      if (preferences.reconnectOnRoutingChange) {
        final loaded = await RunningInput.read(platform, state);
        if (loaded == null) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        await loaded.reconnect(
          platform,
          CoreInput(runInput),
          fallbackMode: mode,
          routingOverride: mode,
        );
        final actual = await platform.snapshot();
        if (!actual.confirmed || !actual.forwarding || actual.mode != mode) {
          throw const FormatException('Mode not confirmed');
        }
      } else {
        final actual = await platform.setMode(mode, state.core);
        if (actual != mode) throw const FormatException('Mode not confirmed');
      }
    } catch (failure) {
      result = {...result, 'configStatus': 'applyFailed', 'success': false};
      throw ConfigFailure(messages.modeNotConfirmed.withDetail(failure));
    }
    return messages.modeSwitchedResult;
  }

  /// Write the user's latest saved selection for a subsequent system-initiated start.
  Future<AppMessage> _systemStart(
    ConfigCollection collection,
    AppSnapshot state,
  ) async {
    if (state.running) throw ConfigFailure(messages.alreadyRunningNoRestore);
    final target = systemInput;
    if (target == null) throw ConfigFailure(messages.systemStartUnsupported);
    final selected = collection.selected;
    if (selected == null) {
      throw ConfigFailure(messages.noConfigForSystemStart);
    }
    await platform.stage(messages.stagePreparingSystemStart);
    // Retain prepared input until the Service consumes it, including across process
    // death.
    await CoreInput(target).write(
      selected,
      collection.mode,
      overrides: await OverrideStore(store.directory).read(),
      preferences: await PreferencesStore(store.directory).read(),
    );
    await platform.start(
      id: selected.id,
      revision: selected.revision,
      mode: collection.mode,
      path: target.path,
      explicitStart: false,
    );
    result = {'configStatus': 'applied'};
    return messages.systemStartPrepared;
  }

  Future<AppMessage> _setApplicationAccess(Map<String, dynamic> command) async {
    final access = ApplicationAccess.values.byName(
      command['access'] as String? ?? '',
    );
    final packages = (command['packages'] as List).cast<String>();
    final preferences = PreferencesStore(
      store.directory,
      beforeWrite: store.beforeWrite,
      publish: store.publish,
    );
    final updated = (await preferences.read()).withAccess(access, packages);
    await preferences.save(updated);
    try {
      final state = await _state();
      if (!state.forwarding) {
        if (state.core.purpose == 'PREVIEW') await platform.releasePreview();
        return messages.accessSavedNextConnection;
      }
      if (state.runningApplicationAccess?.generation == state.generation &&
          state.runningApplicationAccess?.matches(access, packages) == true) {
        return messages.settingsSaved;
      }
      final loaded = await RunningInput.read(platform, state);
      if (loaded == null) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      await platform.stage(messages.stageReconnectAccess);
      await loaded.reconnect(
        platform,
        CoreInput(runInput),
        fallbackMode: loaded.fallbackMode,
        routingOverride: state.mode,
        preferences: loaded.preferences.withAccess(access, packages),
      );
      final actual = await platform.snapshot();
      if (!actual.confirmed ||
          !actual.running ||
          actual.runningApplicationAccess?.generation != actual.generation ||
          actual.runningApplicationAccess?.matches(access, packages) != true) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
    } catch (failure, stack) {
      result = {...result, 'success': false};
      throw ConfigFailure(
        messages.accessSavedReconnectFailed.withDetail(failure),
        cause: failure,
        stackTrace: stack,
      );
    }
    return messages.accessSavedReconnected;
  }

  Future<void> _start(
    ConfigEntry entry,
    TunnelMode? mode, {
    bool vpnIntent = true,
  }) async {
    if (vpnIntent) {
      await platform.stage(messages.stageWaitingVpnAuth);
      if (!await platform.authorize()) {
        throw ConfigFailure(messages.authorizationCancelled);
      }
    }
    await platform.stage(messages.stageStartingTunnel);
    final input = CoreInput(runInput);
    try {
      await input.write(
        entry,
        mode,
        overrides: await OverrideStore(store.directory).read(),
        preferences: await PreferencesStore(store.directory).read(),
        vpnIntent: vpnIntent,
      );
      await platform.start(id: entry.id, revision: entry.revision, mode: mode);
    } finally {
      await input.clear();
    }
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';

  ConfigEntry _entry(ConfigCollection collection, String id) =>
      collection.find(id) ??
      (throw ConfigFailure(messages.configMissingRefresh));

  String _name(String? value, String source) => _localName(
    value == null || value.isEmpty
        ? configNamePrefix(Uri.parse(source).host)
        : value,
  );
}
