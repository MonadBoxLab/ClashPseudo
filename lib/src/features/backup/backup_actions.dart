import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../l10n/messages.dart';
import '../../logic/preferences_store.dart';
import '../../logic/schedule_actions.dart';
import '../../model/app_preferences.dart';
import '../../model/app_snapshot.dart';
import '../../model/application_contract.dart';
import '../../platform/app_bridge.dart';
import '../configs/config_actions.dart';
import '../configs/config_downloader.dart';
import '../configs/config_entry.dart';
import '../configs/config_store.dart';
import '../overrides/override_store.dart';
import 'backup_data.dart';

const _partLimits = {
  ApplicationContract.backupConfigurationsFile:
      ApplicationContract.backupConfigurationsJsonBytes,
  ApplicationContract.backupOverridesFile:
      ApplicationContract.backupOverridesJsonBytes,
  ApplicationContract.backupPreferencesFile:
      ApplicationContract.backupPreferencesJsonBytes,
};

/// Runs only inside the existing LogicEngine writer. Android owns candidate
/// admission and the physical three-file transaction; these actions own the
/// normal Store semantics and the optional, full saved-input start afterwards.
class BackupActions {
  BackupActions(
    this.directory,
    this.platform,
    this.runInput, {
    this.publicationUnconfirmed,
  });

  final Directory directory;
  final AppBridge platform;
  final File runInput;
  final void Function()? publicationUnconfirmed;

  Future<Map<String, Object?>> execute(Map<String, dynamic> command) async {
    switch (command['action']) {
      case 'prepareBackup':
        return _prepare(command);
      case 'inspectBackup':
        return _inspect(command);
      case 'restoreBackup':
        return _restore(command);
      default:
        return _failure(messages.unknownOperation);
    }
  }

  Future<Map<String, Object?>> _prepare(Map<String, dynamic> command) async {
    String? token;
    var prepared = false;
    try {
      final epoch = _epoch(command);
      final request = _request(command);
      final created = command['createdAtMillis'];
      if (request == null ||
          created is! int ||
          created < 0 ||
          created > 8640000000000000) {
        throw const FormatException('Invalid backup preparation request');
      }
      await platform.checkOperation();
      // Native capture and its streaming structural guard precede Dart decode.
      // Nothing reaches CREATE_DOCUMENT until the captured Stores also validate.
      final response = await platform.backupPrepareExport(
        requestId: request,
        createdAtMillis: created,
        expectedEpoch: epoch,
        defaults: {
          'configurations.json': jsonEncode({
            'selectedId': null,
            'mode': null,
            'entries': const [],
          }),
          'overrides.json': jsonEncode({'entries': const []}),
          'preferences.json': jsonEncode(const AppPreferences().toJson()),
        },
      );
      if (isBackupToken(response['token'])) token = response['token'] as String;
      if (response['requestId'] != request) {
        throw const FormatException('Retired backup preparation request');
      }
      final material = _Material.fromNative(response);
      token = material.token;
      final summary = await _validate(material);
      await platform.checkOperation();
      final candidate = BackupCandidate(
        token: material.token,
        createdAtMillis: material.createdAtMillis,
        summary: summary,
      );
      prepared = true;
      return _candidateResult('prepared', candidate, requestId: request);
    } catch (error) {
      return _failure(_message(error), token: token);
    } finally {
      // Wait for these Store reads to return before candidate deletion.
      if (!prepared && token != null) await _discard(token);
    }
  }

  Future<Map<String, Object?>> _inspect(Map<String, dynamic> command) async {
    String? token;
    try {
      final request = _request(command);
      token = _token(command);
      final material = await _material(token);
      final summary = await _validate(material);
      return _candidateResult(
        'inspected',
        BackupCandidate(
          token: material.token,
          createdAtMillis: material.createdAtMillis,
          summary: summary,
        ),
        requestId: request,
      );
    } catch (error) {
      // The UI still owns this candidate, including on a temporary admission
      // refusal. It may retry explicitly or discard after its real read ends.
      return _failure(_message(error), token: token);
    }
  }

  Future<Map<String, Object?>> _restore(Map<String, dynamic> command) async {
    final detail = <String, Object?>{
      'status': 'notRestored',
      'committed': false,
      'rolledBack': false,
      'connectionStatus': 'unchanged',
      'settingsStatus': 'notRun',
      'scheduleStatus': 'notRun',
    };
    try {
      final token = _token(command);
      final request = _request(command);
      final epoch = _epoch(command);
      detail['token'] = token;
      if (request != null) detail['requestId'] = request;
      final material = await _material(token);
      // Re-read the registered immutable candidate for complete validation.
      final summary = await _validate(material);
      detail.addAll(
        BackupCandidate(
          token: token,
          createdAtMillis: material.createdAtMillis,
          summary: summary,
        ).toMap(),
      );
      final before = await platform.snapshot();
      _requireStorage(before, epoch);
      if (!before.confirmed ||
          before.pendingStart ||
          before.pendingSystemStart ||
          before.scheduleBusy ||
          before.resourceBusy ||
          before.core.busy ||
          before.core.blocked) {
        throw ConfigFailure(messages.operationInProgress);
      }
      final restart = before.running;
      if (restart) {
        if (!_runningIdentity(before)) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        detail['connectionStatus'] = 'unconfirmed';
        await ConfigActions.stop(platform);
        final stopped = await platform.snapshot();
        if (!_released(stopped)) {
          throw ConfigFailure(messages.coreContextUnconfirmed);
        }
        detail['connectionStatus'] = 'stopped';
      } else if (before.core.phase != 'EMPTY') {
        if (!before.core.ready || before.core.purpose != 'PREVIEW') {
          throw ConfigFailure(messages.coreContextUnconfirmed);
        }
        await platform.releasePreview();
        detail['previewReleased'] = true;
      }
      final released = await platform.snapshot();
      if (!_released(released)) {
        throw ConfigFailure(messages.coreContextUnconfirmed);
      }
      _requireStorage(released, epoch);
      await platform.checkOperation();
      // After dispatch, settle installation from the actual native reply; transport
      // failure leaves its result unknown.
      detail['committed'] = null;
      detail['status'] = 'unconfirmed';
      final installed = await platform.backupInstall(
        token,
        expectedEpoch: epoch,
      );
      if (installed['committed'] is bool) {
        detail['committed'] = installed['committed'];
      }
      if (installed['rolledBack'] is bool) {
        detail['rolledBack'] = installed['rolledBack'];
      }
      detail['ready'] = installed['ready'] == true;
      if (installed['epoch'] is int && (installed['epoch'] as int) >= 0) {
        detail['epoch'] = installed['epoch'];
      }
      final code = installed['errorCode'];
      if (code is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(code)) {
        detail['errorCode'] = code;
      }
      final committed = detail['committed'];
      detail['status'] = committed == true
          ? 'restored'
          : committed == false
          ? 'notRestored'
          : 'unconfirmed';
      if (committed != true) {
        return _restoreResult(
          detail,
          committed == false
              ? const AppMessage('backupNotRestored')
              : const AppMessage('backupRestoreUnconfirmed'),
        );
      }
      final installedEpoch = installed['epoch'];
      if (installed['rolledBack'] != false ||
          installed['ready'] != true ||
          installedEpoch is! int ||
          installedEpoch <= epoch) {
        return _restoreResult(
          detail,
          messages.backupRestoredWithIssue(
            issue: installed['ready'] != true
                ? messages.storageUnavailable
                : const AppMessage('backupRestoreUnconfirmed'),
          ),
        );
      }
      // Preserve the committed restore fact and report subsequent failures separately.
      await _followup(detail, 'settings', platform.refreshStrings);
      await _followup(detail, 'schedule', () async {
        await ScheduleActions(
          _guardedStore(installedEpoch),
          OverrideStore(directory),
          ConfigDownloader(),
          platform,
          runInput: runInput,
        ).sync();
      });
      if (restart) {
        try {
          await platform.checkOperation();
          await ConfigActions(
            _guardedStore(installedEpoch),
            ConfigDownloader(),
            platform,
            runInput,
          ).execute({'action': 'start'});
          await platform.checkOperation();
          final actual = await platform.snapshot();
          if (!_runningIdentity(actual)) {
            throw ConfigFailure(messages.runningConfigUnavailable);
          }
          detail['connectionStatus'] = 'restored';
        } catch (error) {
          detail['connectionStatus'] = _expired(error) ? 'cancelled' : 'failed';
          detail['connectionMessage'] = _message(error, invalidBackup: false);
        }
      } else {
        detail['connectionStatus'] = 'notStarted';
      }
      final message = _completionMessage(detail);
      return _restoreResult(
        detail,
        detail.containsKey('errorCode')
            ? messages.storageSyncWarning(message)
            : message,
      );
    } catch (error) {
      // Retain the received commit when a later Stop or check fails.
      final failure = _message(
        error,
        invalidBackup: !detail.containsKey('summary'),
      );
      return _restoreResult(
        detail,
        detail['committed'] == true
            ? messages.backupRestoredWithIssue(issue: failure)
            : failure,
      );
    }
  }

  ConfigStore _guardedStore(int epoch) => ConfigStore(
    directory,
    beforeWrite: platform.checkOperation,
    publish: (file) async {
      if (!await platform.publishStore(file, epoch)) {
        publicationUnconfirmed?.call();
      }
    },
  );

  Future<void> _followup(
    Map<String, Object?> detail,
    String phase,
    Future<void> Function() action,
  ) async {
    try {
      await platform.checkOperation();
      await action();
      detail['${phase}Status'] = 'done';
    } catch (error) {
      detail['${phase}Status'] = _expired(error) ? 'cancelled' : 'failed';
      detail['${phase}Message'] = _message(error, invalidBackup: false);
    }
  }

  Future<_Material> _material(String token) async {
    await platform.checkOperation();
    final result = _Material.fromNative(await platform.backupCandidate(token));
    if (result.token != token) {
      throw const FormatException('Backup token changed');
    }
    return result;
  }

  Future<BackupSummary> _validate(_Material material) async {
    for (final name in _partLimits.keys) {
      await platform.checkOperation();
      final file = File('${material.directory.path}/$name');
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != material.bytes[name]) {
        throw const FormatException('Private backup part changed');
      }
    }
    // Decode collections in completed helper scopes; return only counts and selection.
    final configs = await _configSummary(material.directory);
    await platform.checkOperation();
    final overrides = await _overrideCount(material.directory);
    await platform.checkOperation();
    await PreferencesStore(material.directory).read();
    await platform.checkOperation();
    if (configs.configurations != material.configurations ||
        overrides != material.overrides) {
      throw const FormatException('Backup structure disagrees with models');
    }
    return BackupSummary(
      configurations: configs.configurations,
      overrides: overrides,
      hasSelection: configs.hasSelection,
      selectedName: configs.selectedName,
    );
  }

  Future<BackupSummary> _configSummary(Directory candidate) async {
    try {
      final configs = await ConfigStore(candidate).read();
      if (configs.entries.length >
          ApplicationContract.backupCollectionEntries) {
        throw ConfigFailure(const AppMessage('backupTooLarge'));
      }
      return BackupSummary(
        configurations: configs.entries.length,
        overrides: 0,
        hasSelection: configs.selectedId != null,
        selectedName: configs.selected?.name.trim(),
      );
    } on ConfigFailure catch (failure) {
      if (failure.message.id == 'backupTooLarge') rethrow;
      throw ConfigFailure(const AppMessage('backupInvalid'));
    }
  }

  Future<int> _overrideCount(Directory candidate) async {
    try {
      final overrides = await OverrideStore(candidate).read();
      if (overrides.length > ApplicationContract.backupCollectionEntries) {
        throw ConfigFailure(const AppMessage('backupTooLarge'));
      }
      return overrides.length;
    } on ConfigFailure catch (failure) {
      if (failure.message.id == 'backupTooLarge') rethrow;
      throw ConfigFailure(const AppMessage('backupInvalid'));
    }
  }

  Future<void> _discard(String token) async {
    try {
      await platform.backupDiscard(token);
    } catch (_) {
      // Preserve the original preparation failure; native ownership and drain
      // determine material lifetime.
    }
  }
}

class _Material {
  _Material({
    required this.token,
    required this.createdAtMillis,
    required this.directory,
    required this.bytes,
    required this.configurations,
    required this.overrides,
  });

  final String token;
  final int createdAtMillis;
  final Directory directory;
  final Map<String, int> bytes;
  final int configurations;
  final int overrides;

  factory _Material.fromNative(Map<String, dynamic> value) {
    if (value['status'] != 'ready') throw ConfigFailure(_nativeFailure(value));
    final token = value['token'];
    final created = value['createdAtMillis'];
    final paths = value['paths'];
    final parts = value['parts'];
    final structure = value['structure'];
    if (!isBackupToken(token) ||
        created is! int ||
        created < 0 ||
        created > 8640000000000000 ||
        paths is! Map ||
        parts is! Map ||
        structure is! Map ||
        paths.length != _partLimits.length ||
        parts.length != _partLimits.length) {
      throw const FormatException('Invalid private backup descriptor');
    }
    final nodes = structure['nodes'];
    final depth = structure['depth'];
    final configurations = structure['configurations'];
    final overrides = structure['overrides'];
    if (nodes is! int ||
        nodes < 1 ||
        nodes > ApplicationContract.backupJsonNodes ||
        depth is! int ||
        depth < 1 ||
        depth > ApplicationContract.backupJsonDepth ||
        configurations is! int ||
        configurations < 0 ||
        configurations > ApplicationContract.backupCollectionEntries ||
        overrides is! int ||
        overrides < 0 ||
        overrides > ApplicationContract.backupCollectionEntries) {
      throw ConfigFailure(const AppMessage('backupTooLarge'));
    }
    Directory? directory;
    var total = 0;
    final sizes = <String, int>{};
    for (final entry in _partLimits.entries) {
      final path = paths[entry.key];
      final part = parts[entry.key];
      if (path is! String ||
          File(path).absolute.path != path ||
          part is! Map ||
          part['bytes'] is! int ||
          (part['bytes'] as int) < 0 ||
          (part['bytes'] as int) > entry.value ||
          part['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(part['sha256'] as String)) {
        throw const FormatException('Invalid fixed backup part');
      }
      directory ??= File(path).parent;
      if (path != File('${directory.path}/${entry.key}').path) {
        throw const FormatException(
          'Backup part is not a fixed candidate path',
        );
      }
      sizes[entry.key] = part['bytes'] as int;
      total += part['bytes'] as int;
    }
    if (total > ApplicationContract.backupExpandedBytes) {
      throw ConfigFailure(const AppMessage('backupTooLarge'));
    }
    return _Material(
      token: token as String,
      createdAtMillis: created,
      directory: directory!,
      bytes: sizes,
      configurations: configurations,
      overrides: overrides,
    );
  }
}

Map<String, Object?> _candidateResult(
  String status,
  BackupCandidate value, {
  String? requestId,
}) => {
  'success': true,
  'backupResult': {'status': status, 'requestId': ?requestId, ...value.toMap()},
};

Map<String, Object?> _failure(AppMessage message, {String? token}) => {
  'success': false,
  'message': message,
  'backupResult': {'status': 'failed', 'token': ?token},
};

Map<String, Object?> _restoreResult(
  Map<String, Object?> detail,
  AppMessage message,
) => {
  'success':
      detail['committed'] == true &&
      detail['ready'] == true &&
      !detail.containsKey('errorCode') &&
      detail['settingsStatus'] == 'done' &&
      detail['scheduleStatus'] == 'done' &&
      const ['restored', 'notStarted'].contains(detail['connectionStatus']),
  'message': message,
  'backupResult': Map<String, Object?>.unmodifiable(detail),
};

AppMessage _completionMessage(Map<String, Object?> value) {
  final issue = switch (value) {
    {'connectionStatus': 'failed'} => const AppMessage(
      'backupConnectionFailed',
    ),
    {'connectionStatus': 'cancelled'} => const AppMessage(
      'backupConnectionCancelled',
    ),
    {'scheduleStatus': final status} when status != 'done' => const AppMessage(
      'backupSchedulesFailed',
    ),
    {'settingsStatus': final status} when status != 'done' => const AppMessage(
      'backupSettingsRefreshFailed',
    ),
    _ => null,
  };
  return issue == null
      ? const AppMessage('backupRestored')
      : messages.backupRestoredWithIssue(issue: issue);
}

String? _request(Map<String, dynamic> command) {
  final value = command['requestId'];
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > 128 ||
      utf8.encode(value).length > 128) {
    throw const FormatException('Invalid backup request identity');
  }
  return value;
}

int _epoch(Map<String, dynamic> command) {
  final epoch = command['storageEpoch'];
  if (epoch is! int || epoch < 0) {
    throw ConfigFailure(messages.storageContextChanged);
  }
  return epoch;
}

String _token(Map<String, dynamic> command) {
  final token = command['token'];
  if (!isBackupToken(token)) {
    throw ConfigFailure(const AppMessage('backupCandidateExpired'));
  }
  return token as String;
}

void _requireStorage(AppSnapshot state, int epoch) {
  if (!state.storageReady || state.storageRestoring) {
    throw ConfigFailure(messages.storageUnavailable);
  }
  if (state.storageEpoch != epoch) {
    throw ConfigFailure(messages.storageContextChanged);
  }
}

bool _released(AppSnapshot state) =>
    state.phase == 'STOPPED' &&
    !state.pendingStart &&
    !state.pendingSystemStart &&
    state.core.phase == 'EMPTY';

bool _runningIdentity(AppSnapshot state) =>
    state.running &&
    state.generation > 0 &&
    state.configId?.isNotEmpty == true &&
    state.revision != null &&
    state.revision! > 0 &&
    state.core.ready &&
    state.core.purpose == 'VPN' &&
    state.core.generation > 0 &&
    state.core.configId == state.configId &&
    state.core.revision == state.revision &&
    state.core.composition?.isNotEmpty == true;

bool _expired(Object error) =>
    error is PlatformException &&
    const ['expired', 'cancelled'].contains(error.code);

AppMessage _message(Object error, {bool invalidBackup = true}) =>
    switch (error) {
      ConfigFailure() => error.message,
      PlatformException() => messageFromPlatform(
        error,
        fallback: const AppMessage('backupFailed'),
      ),
      FormatException() when invalidBackup => const AppMessage('backupInvalid'),
      _ => const AppMessage('backupFailed'),
    };

AppMessage _nativeFailure(Map<String, dynamic> value) =>
    switch (value['status']) {
      'busy' => messages.operationInProgress,
      'expired' => const AppMessage('backupCandidateExpired'),
      'cancelled' => const AppMessage('backupCancelled'),
      _ => const AppMessage('backupFailed'),
    };
