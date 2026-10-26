import 'package:clash_pseudo/src/logic/schedule_targets.dart';
import 'package:clash_pseudo/src/logic/running_input.dart';

import 'dart:io';
import 'dart:math';

import '../../l10n/messages.dart';
import '../../platform/app_bridge.dart';
import '../../platform/core_input.dart';
import '../configs/config_downloader.dart';
import '../configs/config_entry.dart';
import '../configs/config_store.dart';
import '../configs/config_text.dart';
import 'loon_converter.dart';
import 'override_entry.dart';
import 'override_store.dart';

/// Shared by the three explicit download actions and periodic refreshes.
/// The pure converter owns content recognition and both UTF-8 budgets.
LoonConversionResult convertOverrideDownload(
  String source, {
  required String proxyName,
  required bool addNoResolve,
}) {
  try {
    return convertLoonOverride(
      source,
      proxyName: proxyName,
      addNoResolve: addNoResolve,
    );
  } on LoonConversionException catch (error) {
    throw ConfigFailure(switch (error.reason) {
      LoonConversionError.invalidYaml => messages.overrideContentUnsupported,
      LoonConversionError.invalidProxyName => messages.loonProxyNameInvalid,
      LoonConversionError.inputTooLarge ||
      LoonConversionError.outputTooLarge => messages.textTooLargeSave,
    });
  }
}

AppMessage loonConversionMessage(
  AppMessage result,
  LoonConversionResult conversion,
) {
  if (!conversion.isLoon) return result;
  return conversion.ruleCount == 0
      ? messages.loonNoRulesResult(
          result: result,
          comments: conversion.commentCount,
        )
      : messages.loonConvertedResult(
          result: result,
          rules: conversion.ruleCount,
          comments: conversion.commentCount,
        );
}

class OverrideActions {
  OverrideActions(
    this.store,
    this.downloader,
    this.platform, {
    required this.runInput,
  });

  final File runInput;
  final OverrideStore store;
  final ConfigDownloader downloader;
  final AppBridge platform;
  Map<String, Object?> result = const {};

  Future<AppMessage> execute(Map<String, dynamic> command) async {
    final message = await _execute(command);
    if (const [
      'deleteOverride',
      'setOverrideUpdate',
    ].contains(command['action'])) {
      // Reconcile actual schedule edits and explicit same-value retries independently
      // of configuration application.
      await _syncSchedules(await store.read());
    }
    return message;
  }

  Future<AppMessage> _execute(Map<String, dynamic> command) async {
    result = {'overrideStatus': 'notSaved', 'targetId': command['id']};
    final entries = await store.read();
    final id = command['id'] as String?;
    final existing = entries.where((entry) => entry.id == id).firstOrNull;
    if (id != null && existing == null) {
      throw ConfigFailure(messages.overrideMissingRefresh);
    }
    switch (command['action']) {
      case 'saveOverride':
        final localCustom = command['localCustom'] == true;
        if (localCustom &&
            (existing != null
                ? existing.role != OverrideRole.localCustom
                : entries.any(
                    (entry) => entry.role == OverrideRole.localCustom,
                  ))) {
          throw ConfigFailure(messages.overrideChangedReopen);
        }
        if (existing?.remote == true) {
          throw ConfigFailure(messages.remoteOverrideReadOnly);
        }
        if (existing != null && command['revision'] != existing.revision) {
          throw ConfigFailure(messages.overrideChangedReopen);
        }
        final body = command['body'] as String;
        checkConfigText(body);
        final entry =
            existing?.withContent(body) ??
            OverrideEntry(
              id: _newId(),
              name: _name(command['name'] as String),
              kind: ConfigKind.local,
              role: localCustom ? OverrideRole.localCustom : null,
              revision: 1,
              body: body,
              enabled: true,
              updatedAt: DateTime.now(),
            );
        final after = localCustom && existing == null
            ? [entry, ...entries]
            : _replace(entries, entry);
        await _publish(
          entries,
          after,
          entry.id,
          apply: (loaded) => existing == null
              ? _insert(loaded.parts, entry, after)
              : loaded.updatedParts(entry),
        );
        return _message(messages.overrideSavedApplyLater);
      case 'importOverride':
      case 'updateOverride':
      case 'changeOverrideSource':
        if (command['action'] != 'importOverride' && existing == null) {
          throw ConfigFailure(messages.overrideMissingRefresh);
        }
        if (existing != null && !existing.remote) {
          throw ConfigFailure(messages.localOverrideNoRemoteUpdate);
        }
        return _download(entries, existing, command);
      case 'changeOverride':
        final entry = _require(existing);
        final changed = entry.changed(
          name: command.containsKey('name')
              ? _name(command['name'] as String)
              : entry.name,
          enabled: command['enabled'] as bool?,
          mode: command.containsKey('mode')
              ? OverrideMode.values.byName(command['mode'] as String)
              : entry.mode,
          error: entry.errorMessage,
        );
        final after = _replace(entries, changed);
        await _publish(
          entries,
          after,
          entry.id,
          apply: !command.containsKey('enabled') && !command.containsKey('mode')
              ? null
              : (loaded) {
                  var parts = loaded.parts;
                  if (command['enabled'] == false) {
                    parts = parts.where((part) => part.id != entry.id).toList();
                  } else if (command['enabled'] == true) {
                    parts = _insert(parts, changed, after);
                  }
                  if (command.containsKey('mode')) {
                    parts = [
                      for (final part in parts)
                        part.id == entry.id
                            ? part.changed(mode: changed.mode)
                            : part,
                    ];
                  }
                  return parts;
                },
        );
        return _message(messages.overrideSettingsSaved);
      case 'setOverrideUpdate':
        return _setUpdate(entries, existing, command);
      case 'reorderOverrides':
        final ids = (command['ids'] as List).cast<String>();
        final byId = {for (final entry in entries) entry.id: entry};
        if (ids.length != entries.length ||
            ids.toSet().length != ids.length ||
            ids.any((id) => !byId.containsKey(id))) {
          throw ConfigFailure(messages.overrideOrderChangedRefresh);
        }
        await _publish(
          entries,
          ids.map((id) => byId[id]!).toList(),
          null,
          apply: (loaded) => _reorder(loaded.parts, ids),
        );
        return _message(messages.overrideOrderSaved);
      case 'deleteOverride':
        final entry = _require(existing);
        await _publish(
          entries,
          entries.where((item) => item.id != entry.id).toList(),
          entry.id,
          apply: (loaded) =>
              loaded.parts.where((part) => part.id != entry.id).toList(),
        );
        return _message(messages.overrideDeleted);
      default:
        throw ConfigFailure(messages.unknownOverrideOperation);
    }
  }

  /// Save the periodic update policy while retaining the running tunnel.
  Future<AppMessage> _setUpdate(
    List<OverrideEntry> entries,
    OverrideEntry? existing,
    Map<String, dynamic> command,
  ) async {
    final entry = _require(existing);
    if (!entry.remote) throw ConfigFailure(messages.localOverrideNoAutoUpdate);
    final enabled = command['enabled'] == true;
    final hours = command['hours'] as int? ?? entry.update.hours;
    if (!UpdatePolicy.intervals.contains(hours)) {
      throw ConfigFailure(messages.chooseUpdateInterval);
    }
    final changed = entry.withUpdate(
      entry.update.changed(enabled: enabled, hours: hours),
    );
    await _publish(entries, _replace(entries, changed), entry.id);
    return enabled
        ? messages.overrideAutoUpdateEnabled
        : messages.overrideAutoUpdateDisabled;
  }

  Future<void> _syncSchedules(List<OverrideEntry> entries) async {
    try {
      final collection = await ConfigStore(store.directory).read();
      await platform.syncSchedules(
        scheduleTargets(collection.entries, entries),
      );
      result = {...result, 'scheduleStatus': 'synced'};
    } catch (_) {
      result = {...result, 'scheduleStatus': 'failed'};
      rethrow;
    }
  }

  Future<AppMessage> _download(
    List<OverrideEntry> entries,
    OverrideEntry? existing,
    Map<String, dynamic> command,
  ) async {
    if (existing != null &&
        ((command.containsKey('revision') &&
                command['revision'] != existing.revision) ||
            (command.containsKey('expectedSource') &&
                command['expectedSource'] != existing.source) ||
            (command.containsKey('expectedProxyName') &&
                command['expectedProxyName'] != existing.proxyName) ||
            (command.containsKey('expectedAddNoResolve') &&
                command['expectedAddNoResolve'] != existing.addNoResolve))) {
      throw ConfigFailure(messages.overrideChangedNotApplied);
    }
    final source = ConfigDownloader.sourceUri(
      command['source'] as String? ?? existing!.source!,
    ).toString();
    final proxyName =
        command['proxyName'] as String? ?? existing?.proxyName ?? '';
    final addNoResolve =
        command['addNoResolve'] as bool? ?? existing?.addNoResolve ?? false;
    if (entries.any(
      (entry) =>
          entry.remote && entry.source == source && entry.id != existing?.id,
    )) {
      throw ConfigFailure(messages.overrideSourceExists);
    }
    final id = existing?.id ?? _newId();
    final providedName = (command['name'] as String? ?? '').trim();
    final name =
        existing?.name ??
        _name(
          providedName.isEmpty
              ? configNamePrefix(Uri.parse(source).host)
              : providedName,
        );
    await platform.stage(messages.stageDownloading);
    final LoonConversionResult conversion;
    try {
      conversion = convertOverrideDownload(
        await downloader.download(source),
        proxyName: proxyName,
        addNoResolve: addNoResolve,
      );
      await platform.checkOperation();
    } on ConfigFailure catch (error) {
      await platform.checkOperation();
      if (existing != null) {
        final current = await store.read();
        final saved = current.where((entry) => entry.id == id).firstOrNull;
        if (saved == null || !saved.sameDownloadInput(existing)) {
          throw ConfigFailure(messages.overrideChangedNotApplied);
        }
        // Preserve source, options, body and runtime on candidate failure. Record
        // diagnostics only for checks of the current source/options.
        if (source == existing.source &&
            proxyName == existing.proxyName &&
            addNoResolve == existing.addNoResolve) {
          await store.save(
            _replace(current, saved.changed(error: error.message)),
          );
        }
      }
      rethrow;
    }
    final current = await store.read();
    final saved = current.where((entry) => entry.id == id).firstOrNull;
    if ((existing == null
            ? saved != null
            : saved == null || !saved.sameDownloadInput(existing)) ||
        current.any(
          (entry) => entry.remote && entry.id != id && entry.source == source,
        )) {
      throw ConfigFailure(messages.overrideChangedNotApplied);
    }
    final entry = saved == null
        ? OverrideEntry(
            id: id,
            name: name,
            kind: ConfigKind.remote,
            source: source,
            proxyName: proxyName,
            addNoResolve: addNoResolve,
            revision: 1,
            body: conversion.body,
            enabled: true,
            updatedAt: DateTime.now(),
          )
        : saved
              .changed(
                source: source,
                proxyName: proxyName,
                addNoResolve: addNoResolve,
              )
              .withContent(conversion.body);
    final after = _replace(current, entry);
    await _publish(
      current,
      after,
      id,
      apply: (loaded) => saved == null
          ? _insert(loaded.parts, entry, after)
          : loaded.updatedParts(entry),
    );
    return loonConversionMessage(
      _message(messages.overrideUpdatedApplyLater),
      conversion,
    );
  }

  Future<void> _publish(
    List<OverrideEntry> before,
    List<OverrideEntry> after,
    String? id, {
    List<OverrideEntry> Function(RunningInput)? apply,
  }) async {
    await store.save(after);
    final saved = after.where((entry) => entry.id == id).firstOrNull;
    result = {
      'overrideStatus': 'saved',
      'targetId': id,
      if (saved != null) 'savedRevision': saved.revision,
    };
    if (apply == null) return;
    try {
      final state = await platform.snapshot();
      if (!state.confirmed) {
        throw ConfigFailure(messages.statusUnconfirmedVerify);
      }
      if (!state.running) {
        if (state.core.purpose == 'PREVIEW' &&
            !RunningInput.sameParts(before, after)) {
          await platform.releasePreview();
        }
        return;
      }
      final loaded = await RunningInput.read(platform, state);
      if (loaded == null) {
        throw ConfigFailure(messages.runningConfigUnavailable);
      }
      final parts = apply(loaded);
      if (RunningInput.sameParts(loaded.parts, parts)) return;
      await platform.stage(messages.stageApplyingOverrideUpdate);
      await loaded.reconnect(
        platform,
        CoreInput(runInput),
        fallbackMode: (await ConfigStore(store.directory).read()).mode,
        parts: parts,
      );
      result = {...result, 'overrideStatus': 'applied'};
    } catch (_) {
      result = {...result, 'overrideStatus': 'applyFailed', 'success': false};
    }
  }

  /// Enable/new import uses only this target, anchored before the nearest
  /// following saved item that is actually running. Other members stay intact.
  List<OverrideEntry> _insert(
    List<OverrideEntry> running,
    OverrideEntry entry,
    List<OverrideEntry> saved,
  ) {
    if (running.any((part) => part.id == entry.id)) return running;
    final parts = List<OverrideEntry>.of(running);
    final index = saved.indexWhere((part) => part.id == entry.id);
    for (final candidate in saved.skip(index + 1)) {
      final anchor = parts.indexWhere((part) => part.id == candidate.id);
      if (anchor >= 0) {
        parts.insert(anchor, entry.changed(enabled: true));
        return parts;
      }
    }
    return [...parts, entry.changed(enabled: true)];
  }

  /// Reorder the intersection only; unmentioned actual members keep their slot.
  List<OverrideEntry> _reorder(List<OverrideEntry> running, List<String> ids) {
    final byId = {for (final part in running) part.id: part};
    final ordered = ids.where(byId.containsKey).map((id) => byId[id]!).toList();
    final submitted = ids.toSet();
    var index = 0;
    return [
      for (final part in running)
        if (submitted.contains(part.id)) ordered[index++] else part,
    ];
  }

  AppMessage _message(AppMessage saved) => switch (result['overrideStatus']) {
    'applied' => messages.overridesAppliedReconnected,
    'applyFailed' => messages.overrideSavedReconnectIncomplete,
    _ => saved,
  };

  List<OverrideEntry> _replace(
    List<OverrideEntry> entries,
    OverrideEntry entry,
  ) => entries.any((item) => item.id == entry.id)
      ? entries.map((item) => item.id == entry.id ? entry : item).toList()
      : [...entries, entry];

  OverrideEntry _require(OverrideEntry? entry) =>
      entry ?? (throw ConfigFailure(messages.overrideMissingRefresh));

  String _name(String value) {
    final name = value.trim();
    if (!validConfigName(name)) {
      throw ConfigFailure(messages.overrideNameInvalid);
    }
    return name;
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
}
