import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import '../model/platform_failure.dart';

import 'backup/backup_actions.dart';
import 'connections/connection_actions.dart';
import 'connections/connection_observer.dart';
import 'configs/config_actions.dart';
import 'configs/config_downloader.dart';
import '../model/config_entry.dart';
import 'configs/config_store.dart';
import '../model/config_text.dart';
import 'storage/preferences_store.dart';
import 'schedules/schedule_actions.dart';
import 'overrides/override_actions.dart';
import 'overrides/local_custom_actions.dart';
import 'overrides/override_store.dart';
import 'configs/strategy_actions.dart';
import '../model/messages.dart';
import '../model/app_platform.dart';
import '../platform/core/core_input.dart';
import 'running_input.dart';
import 'core_runtime.dart';
import '../model/application_contract.dart';

class AppRuntime {
  AppRuntime(AppPlatform platform, {void Function()? changed})
    : _onChanged = changed {
    _core = CoreRuntime(
      platform,
      client: platform.coreClient,
      changed: _changed,
    );
    _platform = platform.withCore(_core);
    _observer = ConnectionObserver(_platform);
  }

  final void Function()? _onChanged;
  late final AppPlatform _platform;
  AppPlatform? _operation;
  late final ConnectionObserver _observer;
  late final CoreRuntime _core;
  CoreRuntime get core => _core;
  AppPlatform get platform => _platform;

  Map<String, Object?> get projection => {
    ..._core.projection,
    'retain': _observer.retained || _core.retained,
  };

  void _changed() => _onChanged?.call();

  Future<void> start() => _core.restoreExisting();

  void dispose() {
    _observer.dispose();
    _core.dispose();
  }

  Future<Object?> handle(String method, Object? arguments) async {
    switch (method) {
      case ApplicationContract.coreChannelEvents:
        _core.event(Map<String, dynamic>.from(arguments as Map));
        return null;
      case 'coreCleanupCandidates':
      case 'start':
      case 'stop':
      case 'prepareStrategies':
      case 'releasePreview':
      case 'strategies':
      case 'setStrategy':
      case 'setMode':
      case 'nodes':
      case 'rules':
      case 'runtimeConfig':
      case 'resources':
      case 'updateResource':
      case 'delayStart':
      case 'delayRead':
      case 'delayCancel':
      case 'logs':
      case 'appMemory':
      case 'coreMemory':
      case 'dnsQuery':
      case 'clearDnsCache':
      case 'flushFakeIp':
      case 'cancelDnsQuery':
      case 'sampleConnections':
      case 'closeConnection':
        return _core.read(
          method,
          Map<String, Object?>.from(arguments as Map? ?? const {}),
        );
      case 'cancel':
        if (_operation?.operationId == arguments) {
          _operation?.cancel();
          await _core.client.cancelOwner(arguments as String);
        }
        return null;
      case 'runtimeState':
        _observer.updateState(Map<String, dynamic>.from(arguments as Map));
        return projection;
      case 'connections':
      case 'clearInactiveConnections':
        final args = Map<String, dynamic>.from(arguments as Map);
        final state = Map<String, dynamic>.from(args['state'] as Map);
        if (method == 'clearInactiveConnections') {
          _observer.updateState(state);
          _observer.clearInactive();
        }
        return _observer.snapshot(
          state,
          args['detail'] as Map?,
          detailOwner: args['detailOwner'] as String?,
        );
      case 'traffic':
        final args = Map<String, dynamic>.from(arguments as Map);
        return _observer.trafficSnapshot(
          Map<String, dynamic>.from(args['state'] as Map),
        );
      case 'releaseDetail':
        final owner = (arguments as Map)['detailOwner'] as String;
        if (owner.isEmpty) throw ArgumentError.value(owner, 'detailOwner');
        _observer.releaseDetail(owner);
        return null;
      case 'execute':
        return encodeAppMessages(
          await _execute(Map<String, dynamic>.from(arguments as Map)),
        );
      default:
        throw UnsupportedError('AppRuntime 不支持 $method');
    }
  }

  Future<Map<String, Object?>> _updateResource(
    AppPlatform platform,
    Map<String, dynamic> command,
  ) async {
    Map<String, Object?>? failure;
    var status = 'unconfirmed';
    var message = messages.resourceUpdateFailed;
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
      if (!core.matchesWireIdentity(value)) {
        throw FormatException(
          'Resource result context changed: ${jsonEncode(value)}',
        );
      }
      final update = value['update'];
      if (update is! Map) {
        throw FormatException(
          'Invalid resource update result: ${jsonEncode(value)}',
        );
      }
      final error = update['error'];
      status = error == null && update['status'] == 'ok'
          ? 'ok'
          : error is String && error.isNotEmpty && error != 'ok'
          ? error
          : 'unconfirmed';
      message = status == 'ok'
          ? messages.resourceUpdateSuccess
          : status == 'stopped'
          ? messages.resourceUpdateStopped
          : messages.resourceUpdateFailed;
      if (status != 'ok') {
        message = message.withDetail(update['detail'] ?? jsonEncode(update));
      }
    } on PlatformFailure catch (error, stack) {
      failure = failureValue(error, stack);
      message = messageFromFailure(error, fallback: message);
    } catch (error, stack) {
      failure = failureValue(error, stack);
      message = message.withDetail(error);
    }
    return {
      'success': status == 'ok',
      'resourceStatus': status,
      'failure': ?failure,
      'message': message,
    };
  }

  Future<Map<String, Object?>> _execute(Map<String, dynamic> command) async {
    AppMessage? publicationIssue;
    final outcome = await _executeOperation(
      command,
      publicationUnconfirmed: (message) {
        publicationIssue = publicationIssue == null
            ? message
            : publicationIssue!.withDetail(message.detail);
      },
    );
    if (publicationIssue == null) return outcome;
    final message = outcome['message'];
    return {
      ...outcome,
      'success': false,
      'message':
          (message is AppMessage
                  ? messages.storageSyncWarning(message)
                  : messages.storageSyncUnconfirmed)
              .withDetail(publicationIssue!.detail),
    };
  }

  Future<Map<String, Object?>> _executeOperation(
    Map<String, dynamic> command, {
    required void Function(AppMessage) publicationUnconfirmed,
  }) async {
    if (_operation != null) {
      return {'success': false, 'message': messages.operationInProgress};
    }
    final platform = _platform.forOperation(
      operationId: command['owner'] as String,
      admittedAt: command['admittedAt'] as int?,
      deadline: command['deadline'] as int?,
    );
    final downloader = ConfigDownloader(
      createClient: _platform.createHttpClient,
      remaining: platform.operationRemaining,
      cancelled: platform.whenCancelled,
    );
    _operation = platform;
    ConfigActions? actions;
    OverrideActions? overrides;
    ScheduleActions? schedule;
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
          command['action'] == 'saveOverride' ||
          command['action'] == 'saveLanProxy' && command['body'] is Uint8List) {
        command['body'] = decodeConfigText(command['body'] as Uint8List);
      }
      if (command['action'] == 'scheduleCoreCleanup') {
        final before = await platform.snapshot();
        final outcome = await platform.scheduleCoreCleanup({
          'paths': command['paths'],
          if (command['admittedAt'] != null)
            'admittedAt': command['admittedAt'],
          if (command['deadline'] != null) 'deadline': command['deadline'],
        });
        final success = outcome['success'] == true;
        final items = outcome['items'];
        final cleanupMessage = success
            ? 'coreCleanupCompleted'
            : outcome['status'] == 'needsSelection'
            ? 'coreCleanupNeedsSelection'
            : items is List &&
                  items.any(
                    (item) => item is Map && item['completed'] == true,
                  ) &&
                  items.any((item) => item is Map && item['completed'] != true)
            ? 'coreCleanupPartial'
            : 'coreCleanupFailed';
        if (success && command['restart'] == true) {
          final paths = await platform.paths();
          final actions = ConfigActions(
            ConfigStore(Directory(paths['configs'] as String)),
            downloader,
            platform,
            File(paths['runInput'] as String),
          );
          try {
            await actions.execute({
              'action': 'start',
              'vpnIntent': before.vpnIntent || !before.lanIntent,
            });
          } catch (error, stack) {
            return {
              'success': false,
              'cleanup': outcome,
              'failure': failureValue(error, stack),
              'message': const AppMessage('coreCleanupCompleted')
                  .withDetail(items)
                  .withDetail(error),
            };
          }
        }
        return {
          'success': success,
          'cleanup': outcome,
          'message': AppMessage(cleanupMessage).withDetail(items ?? outcome),
        };
      }
      if (command['action'] == 'updateResource') {
        return await _updateResource(platform, command);
      }
      if (command['action'] == 'closeConnection') {
        final source = CoreSnapshot(
          processId: command['processId'] as String?,
          inputId: command['inputId'] as String?,
          networkRevision: command['networkRevision'] as int? ?? 0,
          generation: command['generation'] as int,
          phase: 'READY',
          purpose: command['purpose'] as String,
          configId: command['configId'] as String,
          revision: command['revision'] as int,
          composition: command['composition'] as String,
        );
        final connectionId = command['connectionId'] as String;
        if (!source.hasIdentity || source.purpose != 'RUNNING') {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        final outcome = await ConnectionActions(platform).execute(command);
        if (outcome['connectionStatus'] == 'closed' ||
            outcome['connectionStatus'] == 'absent') {
          _observer.closed(source, connectionId);
        }
        return outcome;
      }
      if (command['action'] == 'systemRevoked') {
        final restored = await _core.read(
          'systemRevoked',
          command,
          operation: platform,
        );
        return {'success': true, 'lanRestored': restored == true};
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
        final result = await platform.publishStore(file, epoch);
        if (result['durable'] != true) {
          publicationUnconfirmed(
            messages.storageSyncUnconfirmed.withDetail(
              result['errorDetail'] ?? result['errorCode'],
            ),
          );
        }
      }

      if (command['action'] == 'refreshRuntime') {
        final state = await platform.snapshot();
        if (!state.core.ready ||
            !state.core.matchesWireIdentity(command) ||
            command['sessionGeneration'] != state.generation ||
            command['networkRevision'] != state.core.networkRevision ||
            state.recoveryRequired ||
            (!state.forwarding &&
                state.core.purpose != ApplicationContract.corePurposePreview)) {
          throw ConfigFailure(messages.runningConfigUnavailable);
        }
        if (!_core.refreshCurrent(command)) return {'success': true};
        if (state.core.purpose == ApplicationContract.corePurposePreview) {
          await _core.refreshPreview(
            platform,
            File(paths['runInput'] as String),
          );
          return {'success': true};
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
          beforeStop: () async {
            if (!_core.refreshCurrent(command)) {
              throw ConfigFailure(messages.runningConfigUnavailable);
            }
          },
        );
        return {'success': true};
      }
      if (localDefinition ||
          const [
            'saveOverride',
            'saveLanProxy',
            'setLanProxyEnabled',
            'importOverride',
            'updateOverride',
            'changeOverrideSource',
            'changeOverride',
            'reorderOverrides',
            'deleteOverride',
            'clearOverrides',
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
        schedule = ScheduleActions(
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
        try {
          await platform.refreshStrings();
        } catch (error, stack) {
          // 偏好已发布；通知刷新失败不改变保存结果。
          return {
            'failure': failureValue(error, stack),
            'success': false,
            'message': messages.settingsSaved.withDetail(error),
          };
        }
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
        ...platform.operationResult,
      };
    } on ConfigFailure catch (error, stack) {
      return {
        'failure': failureValue(error, stack),
        'success': false,
        'message': error.message,
        ...unsaved,
        ...?actions?.result,
        ...?overrides?.result,
        ...?schedule?.result,
      };
    } on PlatformFailure catch (error, stack) {
      return {
        'failure': failureValue(error, stack),
        'success': false,
        'message': messageFromFailure(
          error,
          fallback: messages.platformOperationFailed,
        ),
        ...unsaved,
        ...?actions?.result,
        ...?overrides?.result,
        ...?schedule?.result,
      };
    } catch (error, stack) {
      return {
        'failure': failureValue(error, stack),
        'success': false,
        'message': messages.operationNotCompletedRetry.withDetail(error),
        ...unsaved,
        ...?actions?.result,
        ...?overrides?.result,
        ...?schedule?.result,
      };
    } finally {
      await downloader.drained;
      void release() {
        if (identical(_operation, platform)) _operation = null;
        _core.refreshFinished();
      }

      final drain = platform.operationDrain;
      if (drain == null) {
        release();
      } else {
        unawaited(drain.then((_) => release()));
      }
    }
  }
}
