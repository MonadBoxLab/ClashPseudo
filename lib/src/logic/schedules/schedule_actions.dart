import 'package:clash_pseudo/src/logic/running_input.dart';

import 'dart:io';

import '../../model/messages.dart';
import '../../model/app_platform.dart';
import '../../platform/core/core_input.dart';
import '../configs/config_downloader.dart';
import '../../model/config_entry.dart';
import '../configs/config_store.dart';
import '../../model/config_text.dart';
import '../overrides/loon_converter.dart';
import '../overrides/override_actions.dart'
    show convertOverrideDownload, loonConversionMessage;
import '../../model/override_entry.dart';
import '../overrides/override_store.dart';
import 'schedule_targets.dart';

/// Android schedules targets; the logic engine remains their only data writer.
class ScheduleActions {
  ScheduleActions(
    this.configs,
    this.overrides,
    this.downloader,
    this.platform, {
    required this.runInput,
  });

  final ConfigStore configs;
  final OverrideStore overrides;
  final ConfigDownloader downloader;
  final AppPlatform platform;
  final File runInput;

  /// Retain completed work if a later diagnostic write fails. The runtime owns
  /// overall success and the original failure message.
  Map<String, Object?> result = const {};

  /// Reconcile each readable collection without cancelling the other kind.
  Future<AppMessage> sync() async {
    final failures = <Object>[];
    try {
      await platform.syncSchedules(
        scheduleTargets((await configs.read()).entries, const []),
        kind: 'config',
      );
    } catch (failure) {
      failures.add(failure);
    }
    try {
      await platform.syncSchedules(
        scheduleTargets(const [], await overrides.read()),
        kind: 'override',
      );
    } catch (failure) {
      failures.add(failure);
    }
    if (failures.isNotEmpty) {
      throw ConfigFailure(
        failures.fold(
          messages.operationNotCompletedRetry,
          (message, failure) => message.withDetail(failure),
        ),
      );
    }
    return messages.schedulesSynced;
  }

  Future<Map<String, Object?>> refresh(String kind, String id) {
    result = const {};
    return switch (kind) {
      'config' => _refreshConfig(id),
      'override' => _refreshOverride(id),
      _ => throw ConfigFailure(messages.unknownUpdateTarget),
    };
  }

  Future<Map<String, Object?>> _refreshConfig(String id) async {
    final entry = (await configs.read()).find(id);
    if (entry == null || !entry.remote || !entry.update.enabled) {
      return _outcome('skipped', messages.targetGoneOrDisabled);
    }
    final String body;
    try {
      body = await _download(entry.source!);
    } on ConfigFailure catch (error) {
      try {
        await _markConfig(entry, 'failed');
      } catch (failure) {
        throw ConfigFailure(error.message.withDetail(failure));
      }
      return _outcome('failed', error.message);
    }
    final collection = await configs.read();
    final saved = collection.find(id);
    if (saved == null ||
        !saved.remote ||
        !saved.update.enabled ||
        saved.source != entry.source ||
        saved.revision != entry.revision) {
      return _outcome('skipped', messages.configChangedDownloadUnapplied);
    }
    // Periodic unchanged-content checks preserve the current session; failed
    // application is retried by explicit user action.
    if (saved.body == body) {
      await _markConfig(saved, 'unchanged');
      return _outcome('unchanged', messages.configUnchanged);
    }
    final updated = saved
        .withContent(body)
        .withUpdate(
          saved.update.changed(
            lastAttempt: DateTime.now(),
            lastResult: 'updated',
          ),
        );
    await configs.save(collection.replace(updated));
    result = {
      'scheduleStatus': 'saved',
      'targetId': updated.id,
      'savedRevision': updated.revision,
    };
    try {
      final state = await platform.snapshot();
      if (!state.confirmed) {
        throw ConfigFailure(
          messages.statusUnconfirmedVerify.withDetail(state.errorMessage),
        );
      }
      if (!state.running || state.configId != id) {
        if (!state.running &&
            state.core.purpose == 'PREVIEW' &&
            state.core.configId == id) {
          await platform.releasePreview();
        }
        return _outcome('saved', messages.configUpdatedPending);
      }
      final loaded = await RunningInput.read(platform, state);
      if (loaded == null) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      if (loaded.entry.body == updated.body) {
        return _outcome('saved', messages.configUpdated);
      }
      await platform.stage(messages.stageApplyingConfigUpdate);
      await loaded.reconnect(
        platform,
        CoreInput(runInput),
        fallbackMode: collection.mode,
        entry: loaded.updatedEntry(updated),
        beforeStop: () => platform.finishScheduledDownload(
          loaded.state,
          kind: 'config',
          id: id,
        ),
      );
    } catch (failure) {
      result = {...result, 'scheduleStatus': 'applyFailed'};
      var message = messages.configSavedReconnectIncomplete.withDetail(failure);
      try {
        await _markConfig(updated, 'applyFailed');
      } catch (diagnosticFailure) {
        message = message.withDetail(diagnosticFailure);
      }
      return _outcome('applyFailed', message);
    }
    // Record diagnostics separately after confirmed application.
    result = {...result, 'scheduleStatus': 'applied'};
    try {
      await _markConfig(updated, 'applied');
    } catch (failure) {
      return _outcome(
        'applied',
        messages.configUpdatedReconnected.withDetail(failure),
        success: false,
      );
    }
    return _outcome('applied', messages.configUpdatedReconnected);
  }

  Future<Map<String, Object?>> _refreshOverride(String id) async {
    final entry = (await overrides.read())
        .where((item) => item.id == id)
        .firstOrNull;
    if (entry == null || !entry.remote || !entry.update.enabled) {
      return _outcome('skipped', messages.targetGoneOrDisabled);
    }
    final LoonConversionResult conversion;
    try {
      conversion = convertOverrideDownload(
        await downloader.download(entry.source!),
        proxyName: entry.proxyName,
        addNoResolve: entry.addNoResolve,
      );
      await platform.checkOperation();
    } on ConfigFailure catch (error) {
      final bool current;
      try {
        await platform.checkOperation();
        current = await _markOverride(entry, 'failed');
      } catch (failure) {
        throw ConfigFailure(error.message.withDetail(failure));
      }
      return current
          ? _outcome('failed', error.message)
          : _outcome('skipped', messages.overrideChangedNotApplied);
    }
    final current = await overrides.read();
    final saved = current.where((item) => item.id == id).firstOrNull;
    if (saved == null ||
        !saved.update.enabled ||
        !saved.sameDownloadInput(entry)) {
      return _outcome('skipped', messages.overrideChangedNotApplied);
    }
    if (saved.body == conversion.body) {
      if (!await _markOverride(saved, 'unchanged')) {
        return _outcome('skipped', messages.overrideChangedNotApplied);
      }
      return _outcome(
        'unchanged',
        messages.overrideUnchanged,
        conversion: conversion,
      );
    }
    final updated = saved
        .withContent(conversion.body)
        .withUpdate(
          saved.update.changed(
            lastAttempt: DateTime.now(),
            lastResult: 'updated',
          ),
        );
    await overrides.save([
      for (final item in current) item.id == id ? updated : item,
    ]);
    result = {
      'scheduleStatus': 'saved',
      'targetId': updated.id,
      'savedRevision': updated.revision,
    };
    try {
      final state = await platform.snapshot();
      if (!state.confirmed) {
        throw ConfigFailure(
          messages.statusUnconfirmedVerify.withDetail(state.errorMessage),
        );
      }
      if (!state.running) {
        if (state.core.purpose == 'PREVIEW') await platform.releasePreview();
        return _outcome(
          'saved',
          messages.overrideUpdatedPending,
          conversion: conversion,
        );
      }
      final loaded = await RunningInput.read(platform, state);
      if (loaded == null) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      final parts = loaded.updatedParts(updated);
      if (RunningInput.sameParts(loaded.parts, parts)) {
        return _outcome(
          'saved',
          messages.overrideUpdatedPending,
          conversion: conversion,
        );
      }
      await platform.stage(messages.stageApplyingOverrideUpdate);
      await loaded.reconnect(
        platform,
        CoreInput(runInput),
        fallbackMode: (await configs.read()).mode,
        parts: parts,
        beforeStop: () => platform.finishScheduledDownload(
          loaded.state,
          kind: 'override',
          id: id,
        ),
      );
    } catch (failure) {
      result = {...result, 'scheduleStatus': 'applyFailed'};
      var message = messages.overrideSavedReconnectIncomplete.withDetail(
        failure,
      );
      try {
        await _markOverride(updated, 'applyFailed');
      } catch (diagnosticFailure) {
        message = message.withDetail(diagnosticFailure);
      }
      return _outcome('applyFailed', message, conversion: conversion);
    }
    result = {...result, 'scheduleStatus': 'applied'};
    try {
      await _markOverride(updated, 'applied');
    } catch (failure) {
      return _outcome(
        'applied',
        messages.overrideUpdatedReconnected.withDetail(failure),
        conversion: conversion,
        success: false,
      );
    }
    return _outcome(
      'applied',
      messages.overrideUpdatedReconnected,
      conversion: conversion,
    );
  }

  Future<String> _download(String source) async {
    final body = await downloader.download(source);
    checkConfigText(body);
    return body;
  }

  Future<void> _markConfig(ConfigEntry expected, String result) async {
    final collection = await configs.read();
    final entry = collection.find(expected.id);
    if (entry == null ||
        entry.source != expected.source ||
        entry.revision != expected.revision ||
        !entry.update.enabled) {
      return;
    }
    await configs.save(
      collection.replace(
        entry.withUpdate(
          entry.update.changed(lastAttempt: DateTime.now(), lastResult: result),
        ),
      ),
    );
  }

  Future<bool> _markOverride(OverrideEntry expected, String result) async {
    final entries = await overrides.read();
    final entry = entries.where((item) => item.id == expected.id).firstOrNull;
    if (entry == null ||
        !entry.sameDownloadInput(expected) ||
        !entry.update.enabled) {
      return false;
    }
    await overrides.save([
      for (final item in entries)
        item.id == entry.id
            ? item.withUpdate(
                item.update.changed(
                  lastAttempt: DateTime.now(),
                  lastResult: result,
                ),
              )
            : item,
    ]);
    return true;
  }

  Map<String, Object?> _outcome(
    String status,
    AppMessage message, {
    LoonConversionResult? conversion,
    bool? success,
  }) => {
    ...result,
    'scheduleStatus': status,
    'message': conversion == null
        ? message
        : loonConversionMessage(message, conversion),
    'success': success ?? (status != 'applyFailed' && status != 'failed'),
  };
}
