import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:io';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../features/backup/backup_actions.dart';
import '../features/connections/connection_actions.dart';
import '../features/connections/connection_observer.dart';
import '../features/configs/config_actions.dart';
import '../features/configs/config_downloader.dart';
import '../features/configs/config_entry.dart';
import '../features/configs/config_store.dart';
import '../features/configs/config_text.dart';
import 'preferences_store.dart';
import 'schedule_actions.dart';
import '../features/overrides/override_actions.dart';
import '../features/overrides/local_custom_actions.dart';
import '../features/overrides/override_store.dart';
import '../features/strategies/strategy_actions.dart';
import '../l10n/messages.dart';
import '../platform/app_bridge.dart';
import '../platform/core_input.dart';
import 'running_input.dart';

class AppRuntime {
  AppBridge? _operation;
  final _observer = ConnectionObserver(AppBridge());

  Future<void> start() async {
    AppBridge.channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'cancel':
          if (_operation?.operationId == call.arguments) _operation?.cancel();
          return null;
        case 'runtimeState':
          _observer.updateState(
            Map<String, dynamic>.from(call.arguments as Map),
          );
          return {'retain': _observer.retained};
        case 'connections':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          return _observer.snapshot(
            Map<String, dynamic>.from(args['state'] as Map),
            args['detail'] as Map?,
          );
        case 'traffic':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          return _observer.trafficSnapshot(
            Map<String, dynamic>.from(args['state'] as Map),
          );
        case 'releaseDetail':
          _observer.window.pinDetail(null);
          return null;
        case 'execute':
          return encodeAppMessages(
            await _execute(Map<String, dynamic>.from(call.arguments as Map)),
          );
        default:
          throw MissingPluginException();
      }
    });
    await AppBridge.channel.invokeMethod<void>('ready');
  }

  Future<Map<String, Object?>> _updateResource(
    AppBridge platform,
    Map<String, dynamic> command,
  ) async {
    var status = 'unconfirmed';
    try {
      final core = (await platform.snapshot()).core;
      if (!core.ready ||
          !core.matchesWireIdentity(command) ||
          command['kind'] is! String ||
          command['name'] is! String) {
        throw const FormatException('Resource context changed');
      }
      await platform.checkOperation();
      final value = await platform.updateResource(
        core,
        kind: command['kind'] as String,
        name: command['name'] as String,
      );
      await platform.checkOperation();
      if (!core.matchesWireIdentity(value)) {
        throw const FormatException('Resource result context changed');
      }
      final update = value['update'];
      if (update is Map) {
        final error = update['error'];
        status = error == null && update['status'] == 'ok'
            ? 'ok'
            : error is String && error.isNotEmpty && error != 'ok'
            ? error
            : 'unconfirmed';
      }
    } catch (_) {
      // Confirm writes from the owning executor's actual result.
    }
    return {
      'success': status == 'ok',
      'resourceStatus': status,
      'message': status == 'ok'
          ? messages.resourceUpdateSuccess
          : status == 'stopped'
          ? messages.resourceUpdateStopped
          : messages.resourceUpdateFailed,
    };
  }

  Future<Map<String, Object?>> _execute(Map<String, dynamic> command) async {
    var durable = true;
    final outcome = await _executeOperation(
      command,
      publicationUnconfirmed: () => durable = false,
    );
    if (durable) return outcome;
    final message = outcome['message'];
    return {
      ...outcome,
      'success': false,
      'message': message is AppMessage
          ? messages.storageSyncWarning(message)
          : messages.storageSyncUnconfirmed,
    };
  }

  Future<Map<String, Object?>> _executeOperation(
    Map<String, dynamic> command, {
    required void Function() publicationUnconfirmed,
  }) async {
    if (_operation != null) {
      return {'success': false, 'message': messages.operationInProgress};
    }
    final platform = AppBridge(operationId: command['owner'] as String);
    final downloader = ConfigDownloader(
      remaining: platform.operationRemaining,
      cancelled: platform.whenCancelled,
    );
    _operation = platform;
    ConfigActions? actions;
    OverrideActions? overrides;
    final localDefinition = const [
      'saveLocalDefinition',
      'deleteLocalDefinition',
    ].contains(command['action']);
    final unsaved = command['action'] == 'saveOverride' || localDefinition
        ? <String, Object?>{
            'overrideStatus': 'notSaved',
            'targetId': command['id'],
          }
        : command['action'] == 'saveLocal'
        ? <String, Object?>{
            'configStatus': 'notSaved',
            'targetId': command['id'],
          }
        : const <String, Object?>{};
    try {
      if (localDefinition) {
        final payload = jsonDecode(
          utf8.decode(command.remove('definitionPayload') as Uint8List),
        );
        if (payload is! Map<String, dynamic> ||
            const [
              'owner',
              'action',
              'storageEpoch',
              'definitionPayload',
            ].any(payload.containsKey)) {
          throw const FormatException('Invalid local definition envelope');
        }
        command.addAll(payload);
        unsaved['targetId'] = command['id'];
      }
      if (command['action'] == 'saveLocal' ||
          command['action'] == 'saveOverride') {
        command['body'] = decodeConfigText(command['body'] as Uint8List);
      }
      if (command['action'] == 'updateResource') {
        return await _updateResource(platform, command);
      }
      if (command['action'] == 'closeConnection') {
        final outcome = await ConnectionActions(platform).execute(command);
        if (outcome['connectionStatus'] == 'closed' ||
            outcome['connectionStatus'] == 'absent') {
          _observer.closed(
            CoreSnapshot(
              generation: command['generation'] as int,
              phase: 'READY',
              purpose: 'VPN',
              configId: command['configId'] as String,
              revision: command['revision'] as int,
            ),
            command['connectionId'] as String,
          );
        }
        return outcome;
      }
      if (command['action'] == 'stop') {
        return {'success': true, 'message': await ConfigActions.stop(platform)};
      }
      final paths = await platform.paths();
      if (const [
        'prepareBackup',
        'inspectBackup',
        'restoreBackup',
      ].contains(command['action'])) {
        return await BackupActions(
          Directory(paths['configs'] as String),
          platform,
          File(paths['runInput'] as String),
          publicationUnconfirmed: publicationUnconfirmed,
        ).execute(command);
      }
      Future<void> publish(String file) async {
        final epoch = paths['storageEpoch'];
        if (epoch is! int) throw ConfigFailure(messages.storageUnavailable);
        if (!await platform.publishStore(file, epoch)) publicationUnconfirmed();
      }

      if (command['action'] == 'refreshRuntime') {
        final state = await platform.snapshot();
        if (!state.running ||
            command['sessionGeneration'] != state.generation ||
            command['coreGeneration'] != state.core.generation ||
            command['composition'] != state.core.composition) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        final loaded = await RunningInput.read(platform, state);
        if (loaded == null) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        await loaded.reconnect(
          platform,
          CoreInput(File(paths['runInput'] as String)),
          fallbackMode: loaded.fallbackMode,
          routingOverride: state.mode,
        );
        return {'success': true};
      }
      if (localDefinition ||
          const [
            'saveOverride',
            'importOverride',
            'updateOverride',
            'changeOverrideSource',
            'changeOverride',
            'reorderOverrides',
            'deleteOverride',
            'setOverrideUpdate',
          ].contains(command['action'])) {
        overrides = OverrideActions(
          OverrideStore(
            Directory(paths['configs'] as String),
            beforeWrite: platform.checkOperation,
            publish: publish,
          ),
          downloader,
          platform,
          runInput: File(paths['runInput'] as String),
        );
        final message = localDefinition
            ? await LocalCustomActions(overrides).execute(command)
            : await overrides.execute(command);
        return {'success': true, 'message': message, ...overrides.result};
      }
      if (command['action'] == 'syncSchedules' ||
          command['action'] == 'refreshSchedule') {
        final schedule = ScheduleActions(
          ConfigStore(
            Directory(paths['configs'] as String),
            beforeWrite: platform.checkOperation,
            publish: publish,
          ),
          OverrideStore(
            Directory(paths['configs'] as String),
            beforeWrite: platform.checkOperation,
            publish: publish,
          ),
          downloader,
          platform,
          runInput: File(paths['runInput'] as String),
        );
        if (command['action'] == 'syncSchedules') {
          return {'success': true, 'message': await schedule.sync()};
        }
        return {
          'success': true,
          ...await schedule.refresh(
            command['kind'] as String,
            command['id'] as String,
          ),
        };
      }
      if (command['action'] == 'setPreference') {
        final preferences = PreferencesStore(
          Directory(paths['configs'] as String),
          beforeWrite: platform.checkOperation,
          publish: publish,
        );
        final current = await preferences.read();
        final field = command['field'] as String;
        final updated = field == 'reconnectOnRoutingChange'
            ? current.withRoutingReconnect(command['value'] as bool)
            : current.withAppearance(field, command['value'] as String);
        await preferences.save(updated);
        await platform.refreshStrings();
        return {'success': true, 'message': messages.settingsSaved};
      }
      final store = ConfigStore(
        Directory(paths['configs'] as String),
        beforeWrite: platform.checkOperation,
        publish: publish,
      );
      if (command['action'] == 'setStrategy') {
        return {
          'success': true,
          'message': await StrategyActions(
            store,
            platform,
            runInput: File(paths['runInput'] as String),
          ).execute(command),
        };
      }
      actions = ConfigActions(
        store,
        downloader,
        platform,
        File(paths['runInput'] as String),
        systemInput: paths['systemInput'] == null
            ? null
            : File(paths['systemInput'] as String),
      );
      return {
        'success': true,
        'message': await actions.execute(command),
        ...actions.result,
      };
    } on ConfigFailure catch (error) {
      return {
        'success': false,
        'message': error.message,
        ...unsaved,
        ...?actions?.result,
        ...?overrides?.result,
      };
    } on PlatformException catch (error) {
      return {
        'success': false,
        'message': messageFromPlatform(
          error,
          fallback: messages.platformOperationFailed,
        ),
        ...unsaved,
        ...?actions?.result,
        ...?overrides?.result,
      };
    } catch (_) {
      return {
        'success': false,
        'message': messages.operationNotCompletedRetry,
        ...unsaved,
        ...?actions?.result,
        ...?overrides?.result,
      };
    } finally {
      await downloader.drained;
      _operation = null;
    }
  }
}
