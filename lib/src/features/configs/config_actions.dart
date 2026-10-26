import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/logic/running_input.dart';

import 'dart:io';
import 'dart:math';

import '../../l10n/messages.dart';
import '../../platform/app_bridge.dart';
import '../../platform/core_input.dart';
import '../mode/tunnel_mode.dart';
import '../overrides/override_store.dart';
import '../../model/app_preferences.dart';
import '../../logic/preferences_store.dart';
import '../../logic/schedule_targets.dart';
import 'config_downloader.dart';
import 'config_entry.dart';
import 'config_store.dart';
import 'config_text.dart';

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
  final AppBridge platform;
  final File runInput;

  /// Prepared by a system Always-on start; read by the VPN service afterwards.
  final File? systemInput;
  Map<String, Object?> result = const {};

  static Future<AppMessage> stop(AppBridge platform) async {
    await platform.stage(messages.stageStopping);
    await platform.stop();
    return messages.tunnelStopped;
  }

  Future<AppMessage?> execute(Map<String, dynamic> command) async {
    final action = command['action'];
    result = const ['saveLocal', 'import', 'updateConfig'].contains(action)
        ? {'configStatus': 'notSaved', 'targetId': command['id']}
        : const {};
    if (action == 'stop') return stop(platform);
    final state = await platform.snapshot();
    if (!state.confirmed) throw ConfigFailure(messages.statusUnconfirmedVerify);
    final collection = await store.read();
    switch (action) {
      case 'prepareStrategies':
        return _prepareStrategies(collection, state, command);
      case 'setMode':
        return _setMode(collection, state, TunnelMode.parse(command['mode']));
      case 'import':
        return _import(collection, state, command);
      case 'updateConfig':
        final entry = _entry(collection, command['id'] as String);
        if (!entry.remote) {
          throw ConfigFailure(messages.localCannotRemoteUpdate);
        }
        return _import(collection, state, {
          ...command,
          'source': command['source'] ?? entry.source,
          'replace': true,
        });
      case 'setConfigUpdate':
        return _setUpdate(collection, command);
      case 'renameConfig':
        final entry = _entry(collection, command['id'] as String);
        final name = _localName(command['name'] as String);
        await store.save(collection.replace(entry.renamed(name)));
        return messages.configRenamed;
      case 'saveLocal':
        return _saveLocal(collection, state, command);
      case 'select':
        return _select(collection, state, command['id'] as String);
      case 'delete':
        return _delete(collection, state, command['id'] as String);
      case 'systemStart':
        return _systemStart(collection, state);
      case 'setApplicationAccess':
        return _setApplicationAccess(collection, state, command);
      case 'start':
        if (state.running) throw ConfigFailure(messages.alreadyRunning);
        final selected = collection.selected;
        if (selected == null) {
          throw ConfigFailure(messages.importAndSelectFirst);
        }
        await _start(selected, collection.mode);
        return messages.tunnelStarted;
      default:
        throw ConfigFailure(messages.unknownOperation);
    }
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
    if (state.running) {
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
    AppSnapshot state,
    Map<String, dynamic> command,
  ) async {
    final source = ConfigDownloader.sourceUri(command['source'] as String)
        .toString();
    final duplicate = collection.entries
        .where((entry) => entry.remote && entry.source == source)
        .firstOrNull;
    final existing = command['id'] == null
        ? duplicate
        : _entry(collection, command['id'] as String);
    if (existing != null && !existing.remote) {
      throw ConfigFailure(messages.localCannotChangeRemote);
    }
    if (duplicate != null && existing?.id != duplicate.id) {
      throw ConfigFailure(messages.sourceUsedBy(duplicate.name));
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
    if ((existing == null
            ? saved != null
            : saved == null ||
                  saved.source != existing.source ||
                  saved.revision != existing.revision) ||
        current.entries.any(
          (entry) => entry.remote && entry.id != id && entry.source == source,
        )) {
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
    final applied = await _applyContent(state, saved, entry, next.mode);
    if (result['configStatus'] == 'applyFailed') {
      return messages.configSavedReconnectIncomplete;
    }
    if (applied) return messages.configUpdatedRestarted;
    return existing == null
        ? messages.configSavedParsedAtStart
        : messages.configUpdated;
  }

  Future<AppMessage> _saveLocal(
    ConfigCollection collection,
    AppSnapshot state,
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
    final applied = await _applyContent(state, existing, entry, next.mode);
    if (result['configStatus'] == 'applyFailed') {
      return messages.configSavedApplyReleasePending;
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
    AppSnapshot state,
    ConfigEntry? before,
    ConfigEntry saved,
    TunnelMode? fallbackMode,
  ) async {
    try {
      if (state.running && state.configId == saved.id) {
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
          fallbackMode: fallbackMode,
          entry: loaded.updatedEntry(saved),
        );
        result = {...result, 'configStatus': 'applied'};
        return true;
      }
      if (!state.running &&
          state.core.purpose == 'PREVIEW' &&
          state.core.configId == saved.id &&
          before?.body != saved.body) {
        await platform.releasePreview();
      }
    } catch (_) {
      // Preserve the successful save and report application failure separately.
      result = {...result, 'configStatus': 'applyFailed', 'success': false};
    }
    return false;
  }

  /// Save periodic policy, then synchronize the platform schedule.
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
    await _syncSchedules(next);
    return enabled
        ? messages.autoUpdateEnabledResult
        : messages.autoUpdateDisabledResult;
  }

  Future<void> _syncSchedules(ConfigCollection collection) async {
    try {
      await platform.syncSchedules(
        scheduleTargets(
          collection.entries,
          await OverrideStore(store.directory).read(),
        ),
      );
      result = {...result, 'scheduleStatus': 'synced'};
    } catch (_) {
      result = {...result, 'scheduleStatus': 'failed'};
      rethrow;
    }
  }

  String _localName(String value) {
    final name = value.trim();
    if (!validConfigName(name)) {
      throw ConfigFailure(messages.configNameInvalid);
    }
    return name;
  }

  Future<AppMessage> _select(
    ConfigCollection collection,
    AppSnapshot state,
    String id,
  ) async {
    final entry = _entry(collection, id);
    // Persist the selection and prepare the complete new input before stopping.
    await store.save(
      ConfigCollection(
        entries: collection.entries,
        selectedId: id,
        mode: collection.mode,
      ),
    );
    if (state.running) {
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
        );
      }
      return messages.switchedConfig;
    }
    if (state.core.purpose == 'PREVIEW') await platform.releasePreview();
    return messages.configSelectedNotStarted;
  }

  Future<AppMessage> _delete(
    ConfigCollection collection,
    AppSnapshot state,
    String id,
  ) async {
    _entry(collection, id);
    if (state.running && state.configId == id) {
      throw ConfigFailure(messages.stopBeforeDelete);
    }
    final remaining = collection.entries
        .where((entry) => entry.id != id)
        .toList();
    final next = ConfigCollection(
      entries: remaining,
      mode: collection.mode,
      selectedId: collection.selectedId == id
          ? remaining.firstOrNull?.id
          : collection.selectedId,
    );
    await store.save(next);
    result = {'configStatus': 'saved', 'targetId': id};
    try {
      if (!state.running &&
          state.core.purpose == 'PREVIEW' &&
          state.core.configId == id) {
        await platform.releasePreview();
      }
    } catch (_) {
      result = {...result, 'configStatus': 'applyFailed', 'success': false};
      rethrow;
    } finally {
      // Release the removed preview even if schedule registration fails.
      await _syncSchedules(next);
    }
    return messages.configDeleted;
  }

  Future<AppMessage> _setMode(
    ConfigCollection collection,
    AppSnapshot state,
    TunnelMode mode,
  ) async {
    final changed = collection.mode != mode;
    final next = ConfigCollection(
      entries: collection.entries,
      selectedId: collection.selectedId,
      mode: mode,
    );
    if (changed) await store.save(next);
    if (!state.running) {
      final selected = next.selected;
      if (changed && state.core.purpose == 'PREVIEW' && selected != null) {
        // Prepare the normal preview with explicit YAML mode taking precedence over
        // the saved fallback.
        await _prepareStrategies(next, state, {
          'id': selected.id,
          'revision': selected.revision,
        });
      }
      return messages.modeSavedNextStart;
    }
    if (state.mode == mode) return messages.modeConfirmed;
    try {
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
        if (!actual.running || actual.mode != mode) {
          throw const FormatException('Mode not confirmed');
        }
      } else {
        final actual = await platform.setMode(mode, state.generation);
        if (actual != mode) throw const FormatException('Mode not confirmed');
      }
    } catch (_) {
      throw ConfigFailure(messages.modeNotConfirmed);
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
    result = {
      'systemStart': {
        'id': selected.id,
        'revision': selected.revision,
        'mode': collection.mode?.name,
      },
    };
    return messages.systemStartPrepared;
  }

  Future<AppMessage> _setApplicationAccess(
    ConfigCollection collection,
    AppSnapshot state,
    Map<String, dynamic> command,
  ) async {
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
    if (!state.running) {
      if (state.core.purpose == 'PREVIEW') await platform.releasePreview();
      return messages.accessSavedNextConnection;
    }
    if (state.runningApplicationAccess?.generation == state.generation &&
        state.runningApplicationAccess?.matches(access, packages) == true) {
      return messages.settingsSaved;
    }
    try {
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
      if (!actual.running ||
          actual.runningApplicationAccess?.generation != actual.generation ||
          actual.runningApplicationAccess?.matches(access, packages) != true) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
    } catch (_) {
      throw ConfigFailure(messages.accessSavedReconnectFailed);
    }
    return messages.accessSavedReconnected;
  }

  Future<void> _start(ConfigEntry entry, TunnelMode? mode) async {
    await platform.stage(messages.stageWaitingVpnAuth);
    if (!await platform.authorize()) {
      throw ConfigFailure(messages.authorizationCancelled);
    }
    await platform.stage(messages.stageStartingTunnel);
    final input = CoreInput(runInput);
    try {
      await input.write(
        entry,
        mode,
        overrides: await OverrideStore(store.directory).read(),
        preferences: await PreferencesStore(store.directory).read(),
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

  String _name(String? value, String source) {
    final name = value?.trim() ?? '';
    return _localName(
      name.isEmpty ? configNamePrefix(Uri.parse(source).host) : name,
    );
  }
}
