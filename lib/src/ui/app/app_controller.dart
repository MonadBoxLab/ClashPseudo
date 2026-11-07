import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/foundation.dart';

import '../../logic/configs/config_store.dart';
import '../../logic/overrides/override_store.dart';
import '../../logic/storage/preferences_store.dart';
import '../../model/app_preferences.dart';
import '../../model/application_contract.dart';
import '../../model/config_entry.dart';
import '../../model/messages.dart';
import '../../model/override_entry.dart';
import '../../platform/channel/app_bridge.dart';
import '../locale/message_text.dart';
import '../navigation/system_navigation.dart';
import 'app_feedback_ownership.dart';
import 'app_read_projection.dart';

class AppController extends ChangeNotifier {
  AppController(
    this.platform, {
    this.store,
    this.preferencesStore,
    this.overrideStore,
  });

  final PreferencesStore? preferencesStore;
  final OverrideStore? overrideStore;

  final AppPlatform platform;
  late final _read = AppReadProjection(
    platform,
    store: store,
    preferencesStore: preferencesStore,
    overrideStore: overrideStore,
    changed: notifyListeners,
  );
  late final _feedback = AppFeedbackOwnership(notifyListeners);
  late final _navigation = SystemNavigationRequests(notifyListeners);

  ConfigCollection get collection => _read.collection;
  set collection(ConfigCollection value) => _read.collection = value;
  List<OverrideEntry> get overrides => _read.overrides;
  set overrides(List<OverrideEntry> value) => _read.overrides = value;
  bool get overridesLoaded => _read.overridesLoaded;
  set overridesLoaded(bool value) => _read.overridesLoaded = value;
  AppMessage? get overrideErrorMessage => _read.overrideErrorMessage;
  set overrideErrorMessage(AppMessage? value) =>
      _read.overrideErrorMessage = value;
  String? get overrideError => overrideErrorMessage?.text;
  AppSnapshot get state => _read.state;
  set state(AppSnapshot value) => _read.state = value;
  bool get loading => _read.loading;
  set loading(bool value) => _read.loading = value;
  bool get configsLoaded => _read.configsLoaded;
  set configsLoaded(bool value) => _read.configsLoaded = value;
  AppPreferences get preferences => _read.preferences;
  set preferences(AppPreferences value) => _read.preferences = value;
  bool get preferencesLoaded => _read.preferencesLoaded;
  set preferencesLoaded(bool value) => _read.preferencesLoaded = value;
  int get storageEpoch => _read.storageEpoch;
  AppMessage? get preferencesErrorMessage => _read.preferencesErrorMessage;
  set preferencesErrorMessage(AppMessage? value) =>
      _read.preferencesErrorMessage = value;
  String? get preferencesError => preferencesErrorMessage?.text;

  void requestOverview() => _navigation.requestOverview();
  bool takeOverviewRequest() => _navigation.takeOverviewRequest();
  void registerOverviewLeave(Object route, Future<bool> Function() leave) =>
      _navigation.registerLeave(route, leave);
  void unregisterOverviewLeave(Object route, Future<bool> Function() leave) =>
      _navigation.unregisterLeave(route, leave);
  Future<bool> Function()? overviewLeaveFor(Object route) =>
      _navigation.leaveFor(route);
  bool get canChangePreferences =>
      !_localBusy &&
      _storageCurrent &&
      preferencesLoaded &&
      preferencesErrorMessage == null;
  AppMessage? get platformErrorMessage => _read.platformErrorMessage;
  set platformErrorMessage(AppMessage? value) =>
      _read.platformErrorMessage = value;
  AppMessage? get configErrorMessage => _read.configErrorMessage;
  set configErrorMessage(AppMessage? value) => _read.configErrorMessage = value;
  AppMessage? commandErrorMessage;
  String? get platformError => platformErrorMessage?.text;
  String? get configError => configErrorMessage?.text;
  String? get commandError => commandErrorMessage?.text;
  bool dispatching = false;
  Map<String, Object?>? lastCommand;
  Map<String, Object?>? _activeSubmission;
  bool lastCommandAutomatic = false;
  bool _disposed = false;
  Completer<AppSnapshot?>? _pendingResult;
  Map<String, Object?>? _pendingCommand;
  String? _pendingOperationId;
  Timer? _pendingWait;
  final ConfigStore? store;

  bool _interactive = true;
  int? localInterfacesRevision;
  String? localInterfacesError;
  int applicationsRevision = 0;
  String? changedApplication;
  final _interactionWaiters = <Completer<bool>>{};
  bool get foreground => _read.foreground;
  bool get interactive => foreground && _interactive;

  Future<bool> waitUntilInteractive() {
    if (_disposed) return Future.value(false);
    if (interactive) return Future.value(true);
    final result = Completer<bool>();
    _interactionWaiters.add(result);
    return result.future;
  }

  void _completeInteractionWaiters(bool value) {
    for (final waiter in _interactionWaiters) {
      waiter.complete(value);
    }
    _interactionWaiters.clear();
  }

  void setInteractive(bool value) {
    if (_disposed || _interactive == value) return;
    _interactive = value;
    if (interactive) _completeInteractionWaiters(true);
    notifyListeners();
  }

  AppMessage? get errorMessage =>
      platformErrorMessage ??
      ((!state.storageReady || state.storageRestoring)
          ? messages.storageUnavailable
          : null) ??
      configErrorMessage ??
      overrideErrorMessage ??
      preferencesErrorMessage ??
      (state.storageEpoch != storageEpoch
          ? messages.storageUnavailable
          : null) ??
      commandErrorMessage ??
      (!state.coreDataReady
          ? AppMessage.fromNullable(state.coreCleanup['error']) ??
                AppMessage(
                  state.coreCleanup['status'] == 'initializing'
                      ? 'coreCleanupInitializing'
                      : 'coreCleanupRequired',
                )
          : null) ??
      (state.core.blocked ? state.core.errorMessage : null);
  String? get error => errorMessage?.text;
  bool get _storageCurrent =>
      state.storageReady &&
      !state.storageRestoring &&
      state.storageEpoch == storageEpoch;
  bool get configsCurrent =>
      configsLoaded && configErrorMessage == null && _storageCurrent;
  bool get overridesCurrent =>
      overridesLoaded && overrideErrorMessage == null && _storageCurrent;
  bool get busy =>
      loading || dispatching || _activeSubmission != null || state.busy;
  bool get _localBusy =>
      dispatching ||
      _activeSubmission != null ||
      (!state.stale &&
          (state.resourceBusy ||
              state.writerBusy ||
              state.operationMessage != null)) ||
      !state.storageReady ||
      state.storageRestoring;
  bool get canEdit => !_localBusy && configsCurrent;
  bool get canEditOverrides => !_localBusy && overridesCurrent;
  bool get canManageStoredData => !_localBusy;
  bool get canChangeMode =>
      canEdit && (!state.usesRuntimeMode || state.mode != null);
  bool get canStopBackground =>
      !dispatching &&
      (!state.confirmed ||
          state.scheduleBusy ||
          state.running ||
          state.resourceBusy ||
          state.pendingSystemStart ||
          state.pendingStart ||
          state.pendingRestore ||
          state.phase == 'STARTING');
  bool get canToggle =>
      canStopBackground ||
      (!busy &&
          state.confirmed &&
          platformError == null &&
          (state.running ||
              (!state.core.blocked &&
                  state.coreDataReady &&
                  configsCurrent &&
                  collection.selected != null)));

  Future<void> initialize() async {
    AppBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'openOverview') {
        requestOverview();
        return true;
      }
      if (call.method == 'changed') await refresh();
      if (call.method == ApplicationContract.uiEventLocalInterfacesChanged) {
        final value = call.arguments;
        if (value is Map &&
            value['revision'] is int &&
            value['revision'] >= 0 &&
            (value['error'] == null || value['error'] is String)) {
          final revision = value['revision'] as int;
          final error = value['error'] as String?;
          if ((localInterfacesRevision, localInterfacesError) !=
              (revision, error)) {
            localInterfacesRevision = revision;
            localInterfacesError = error;
            if (!_disposed) notifyListeners();
          }
        }
      }
      if (call.method == ApplicationContract.uiEventApplicationsChanged) {
        final value = call.arguments;
        if (value is Map &&
            value['package'] is String &&
            (value['package'] as String).isNotEmpty) {
          changedApplication = value['package'] as String;
          applicationsRevision++;
          if (!_disposed) notifyListeners();
        }
      }
      return null;
    });
    _read.prepareUiReadiness();
    await refresh();
  }

  void setForeground(bool value) {
    if (_disposed || foreground == value) return;
    _read.setForeground(value);
    if (interactive) _completeInteractionWaiters(true);
    if (value) unawaited(refresh());
    notifyListeners();
  }

  Future<void> refresh() => _read.refresh();

  /// When a page owns command feedback, global notices wait until it confirms display
  /// or relinquishes ownership.
  bool get hasLocalFeedbackOwner => _feedback.owns(lastCommand);

  bool feedbackHandledLocally(
    Map<String, Object?> command, {
    required bool submissionFailed,
    String? resultId,
  }) => _feedback.handledLocally(
    command,
    submissionFailed: submissionFailed,
    resultId: resultId,
  );

  void acknowledgeLocalFeedback(
    ValueListenable<bool> owner, {
    AppSnapshot? result,
  }) {
    if (_disposed) return;
    _feedback.acknowledge(
      owner,
      command: lastCommand,
      submissionFailed: commandErrorMessage != null,
      result: result,
    );
  }

  void _attachFeedbackOwner(
    ValueListenable<bool>? owner,
    Map<String, Object?> command,
  ) {
    if (identical(command, lastCommand)) _feedback.attach(owner, command);
  }

  bool _canSubmit(Map<String, Object?> command) {
    final action = command['action'];
    if (action == 'stop') return !dispatching;
    return const {
          'import',
          'updateConfig',
          'renameConfig',
          'saveLocal',
          'select',
          'delete',
          'clearConfigurations',
          'clearOverrides',
          'scheduleCoreCleanup',
          'prepareBackup',
          'inspectBackup',
          'setMode',
          'setConfigUpdate',
          'setPreference',
          'setApplicationAccess',
          'saveOverride',
          'saveLanProxy',
          'setLanProxyEnabled',
          'importOverride',
          'updateOverride',
          'changeOverrideSource',
          'changeOverride',
          'reorderOverrides',
          'deleteOverride',
          'setOverrideUpdate',
          'saveLocalDefinition',
          'deleteLocalDefinition',
        }.contains(action)
        ? !_localBusy
        : !busy;
  }

  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async => (await _submit(command, automatic: automatic)).operationId;

  /// Wait for admission and its state readback, not the operation's final result.
  /// The caller retains feedback ownership until its route retires or it actually
  /// presents and acknowledges a rejection; acceptance never consumes a result.
  Future<
    ({Map<String, Object?>? command, String? operationId, AppMessage? error})
  >
  submitForReceipt(
    Map<String, Object?> command, {
    required ValueListenable<bool> feedbackOwner,
  }) => _submit(command, feedbackOwner: feedbackOwner);

  Future<
    ({Map<String, Object?>? command, String? operationId, AppMessage? error})
  >
  _submit(
    Map<String, Object?> command, {
    bool automatic = false,
    ValueListenable<bool>? feedbackOwner,
  }) async {
    if (_disposed || !_canSubmit(command)) {
      return (command: null, operationId: null, error: null);
    }
    _feedback.beginCommand();
    lastCommandAutomatic = automatic;
    String? operationId;
    AppMessage? submissionError;
    final submittedCommand = <String, Object?>{
      ...command,
      if (command['action'] != 'stop' && !command.containsKey('storageEpoch'))
        'storageEpoch': storageEpoch,
    };
    lastCommand = submittedCommand;
    _activeSubmission = submittedCommand;
    dispatching = true;
    commandErrorMessage = null;
    _read.invalidate();
    _attachFeedbackOwner(feedbackOwner, submittedCommand);
    notifyListeners();
    try {
      final admission = await platform.submit(submittedCommand);
      operationId = admission?.operationId;
      _feedback.admitted(submittedCommand, operationId);
      if (admission != null && identical(command, _pendingCommand)) {
        _pendingOperationId = operationId;
        final pending = _pendingResult!;
        _pendingWait = Timer(
          admission.remaining +
              const Duration(
                milliseconds: ApplicationContract.operationUiGraceMs,
              ),
          () {
            if (identical(_pendingResult, pending) && !pending.isCompleted) {
              pending.completeError(
                TimeoutException('Operation result wait expired'),
              );
            }
          },
        );
      } else if (operationId != null &&
          submittedCommand['action'] == 'stop' &&
          _pendingOperationId != null &&
          operationId != _pendingOperationId &&
          _pendingResult?.isCompleted == false) {
        // Stop admission retires the old UI wait while the native executor continues
        // draining.
        _pendingResult!.complete(null);
      }
    } on PlatformFailure catch (failure) {
      submissionError = messageFromFailure(
        failure,
        fallback: messages.requestNotAccepted,
      );
      if (!_disposed && identical(lastCommand, submittedCommand)) {
        commandErrorMessage = submissionError;
      }
    } catch (failure) {
      submissionError = messages.requestNotAccepted.withDetail(failure);
      if (!_disposed && identical(lastCommand, submittedCommand)) {
        commandErrorMessage = submissionError;
      }
    } finally {
      if (!_disposed) {
        dispatching = false;
        notifyListeners();
      }
    }
    // Retain the same submission record while submitting and reading state; Stop
    // requests still follow admission rules.
    try {
      if (!_disposed) await refresh();
    } finally {
      if (identical(_activeSubmission, submittedCommand)) {
        _activeSubmission = null;
        if (!_disposed) notifyListeners();
      }
    }
    return (
      command: submittedCommand,
      operationId: operationId,
      error: submissionError,
    );
  }

  Future<AppSnapshot?> saveLocal(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) => submitAndWait({
    'action': 'saveLocal',
    ...command,
  }, feedbackOwner: feedbackOwner);

  Future<AppSnapshot?> saveOverride(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) => submitAndWait({
    'action': 'saveOverride',
    ...command,
  }, feedbackOwner: feedbackOwner);

  /// Wait for this submission's final result. A local presenter retains its liveness
  /// marker through feedback and acknowledgment; releasing it hands pending feedback
  /// back globally.
  Future<AppSnapshot?> submitAndWait(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    if (_disposed || !_canSubmit(command) || _pendingResult != null) {
      return null;
    }
    final completed = Completer<AppSnapshot?>();
    _pendingResult = completed;
    _pendingCommand = command;
    _pendingOperationId = null;
    String? id;
    Map<String, Object?>? submittedCommand;
    void observe() {
      if (id != null && state.resultId == id && !completed.isCompleted) {
        completed.complete(state);
      }
    }

    addListener(observe);
    try {
      final submitting = submit(command);
      submittedCommand = lastCommand;
      if (submittedCommand != null) {
        _attachFeedbackOwner(feedbackOwner, submittedCommand);
      }
      // Stop may be accepted while submit is still re-reading local files.
      id = await Future.any<String?>([
        submitting,
        completed.future.then((_) => null),
      ]);
      if (submittedCommand != null) _feedback.admitted(submittedCommand, id);
      if (id == null) return null;
      observe();
      final result = await completed.future;
      // Cancellation releases this UI wait immediately.
      if (result == null && completed.isCompleted) return null;
      // Read the original operation's result before deciding any further action.
      await refresh();
      return result;
    } on TimeoutException {
      await refresh();
      return null;
    } catch (_) {
      if (submittedCommand != null && _feedback.owns(submittedCommand)) {
        _feedback.detach();
        _feedback.changed();
      }
      rethrow;
    } finally {
      if (identical(_pendingResult, completed)) {
        _pendingWait?.cancel();
        _pendingWait = null;
        _pendingResult = null;
        _pendingCommand = null;
        _pendingOperationId = null;
      }
      if (!_disposed) removeListener(observe);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _completeInteractionWaiters(false);
    _navigation.dispose();
    _feedback.dispose();
    final pending = _pendingResult;
    _pendingWait?.cancel();
    _pendingWait = null;
    _pendingResult = null;
    _pendingCommand = null;
    _pendingOperationId = null;
    if (pending?.isCompleted == false) pending!.complete(null);
    _read.dispose();
    AppBridge.channel.setMethodCallHandler(null);
    super.dispose();
  }
}
