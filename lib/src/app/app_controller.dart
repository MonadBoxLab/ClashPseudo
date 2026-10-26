import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../features/configs/config_entry.dart';
import '../features/configs/config_store.dart';
import '../features/overrides/override_entry.dart';
import '../features/overrides/override_store.dart';
import '../model/app_preferences.dart';
import '../model/application_contract.dart';
import '../logic/preferences_store.dart';
import '../l10n/messages.dart';
import '../platform/app_bridge.dart';

class AppController extends ChangeNotifier {
  AppController(
    this.platform, {
    this.store,
    this.preferencesStore,
    this.overrideStore,
  });

  final PreferencesStore? preferencesStore;
  final OverrideStore? overrideStore;

  final AppBridge platform;
  ConfigCollection collection = ConfigCollection(entries: []);
  List<OverrideEntry> overrides = const [];
  bool overridesLoaded = false;
  AppMessage? overrideErrorMessage;
  String? get overrideError => overrideErrorMessage?.text;
  AppSnapshot state = const AppSnapshot();
  bool loading = true;
  bool configsLoaded = false;
  AppPreferences preferences = const AppPreferences();
  bool preferencesLoaded = false;
  int _storageEpoch = 0;
  int get storageEpoch => _storageEpoch;
  bool _overviewRequested = false;
  final _overviewLeaves = <Object, Future<bool> Function()>{};

  void requestOverview() {
    if (_disposed) return;
    _overviewRequested = true;
    notifyListeners();
  }

  bool takeOverviewRequest() {
    final requested = _overviewRequested;
    _overviewRequested = false;
    return requested;
  }

  void registerOverviewLeave(Object route, Future<bool> Function() leave) {
    if (!_disposed) _overviewLeaves[route] = leave;
  }

  void unregisterOverviewLeave(Object route, Future<bool> Function() leave) {
    if (identical(_overviewLeaves[route], leave)) _overviewLeaves.remove(route);
  }

  Future<bool> Function()? overviewLeaveFor(Object route) =>
      _overviewLeaves[route];
  AppMessage? preferencesErrorMessage;
  String? get preferencesError => preferencesErrorMessage?.text;
  bool get _storeReadsValid =>
      configErrorMessage == null &&
      overrideErrorMessage == null &&
      preferencesErrorMessage == null;
  bool get canChangePreferences =>
      !busy &&
      state.storageEpoch == _storageEpoch &&
      preferencesLoaded &&
      _storeReadsValid;
  AppMessage? platformErrorMessage;
  AppMessage? configErrorMessage;
  AppMessage? commandErrorMessage;
  String? get platformError => platformErrorMessage?.text;
  String? get configError => configErrorMessage?.text;
  String? get commandError => commandErrorMessage?.text;
  bool dispatching = false;
  Map<String, Object?>? lastCommand;
  Map<String, Object?>? _activeSubmission;
  bool lastCommandAutomatic = false;
  bool _refreshing = false;
  Completer<void>? _refreshDone;
  bool _refreshAgain = false;
  bool _disposed = false;
  bool _foreground = true;
  int _readRevision = 0;
  int _runner = 0;
  int _retryStep = 0;
  Timer? _retry;
  Completer<AppSnapshot?>? _pendingResult;
  Map<String, Object?>? _pendingCommand;
  String? _pendingOperationId;
  Timer? _pendingWait;
  ValueListenable<bool>? _feedbackOwner;
  Map<String, Object?>? _feedbackCommand;
  String? _feedbackOperationId;
  Map<String, Object?>? _handledSubmissionCommand;
  String? _handledFeedbackResultId;
  final ConfigStore? store;

  bool _uiReadinessPending = false;
  static const _readTimeout = Duration(seconds: 5);
  static const _retrySeconds = [1, 2, 5, 10, 30];

  bool _interactive = true;
  bool _windowSupported = true;
  final _interactionWaiters = <Completer<bool>>{};
  bool get foreground => _foreground;
  bool get interactive => _foreground && _interactive && _windowSupported;

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

  void setWindowSupported(bool value) {
    if (_disposed || _windowSupported == value) return;
    _windowSupported = value;
    if (interactive) _completeInteractionWaiters(true);
    notifyListeners();
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
      (state.storageEpoch != _storageEpoch
          ? messages.storageUnavailable
          : null) ??
      commandErrorMessage ??
      (state.core.blocked ? state.core.errorMessage : null);
  String? get error => errorMessage?.text;
  bool get configsCurrent =>
      configsLoaded &&
      _storeReadsValid &&
      state.storageReady &&
      !state.storageRestoring &&
      state.storageEpoch == _storageEpoch;
  bool get busy =>
      loading || dispatching || _activeSubmission != null || state.busy;
  bool get canEdit =>
      !busy && state.confirmed && platformError == null && configsCurrent;
  bool get canChangeMode => canEdit && (!state.running || state.mode != null);
  bool get canStopBackground =>
      !loading &&
      !dispatching &&
      platformError == null &&
      (state.scheduleBusy ||
          ((!state.storageReady || state.storageRestoring) && state.running) ||
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
                  configsCurrent &&
                  collection.selected != null)));

  Future<void> initialize() async {
    AppBridge.channel.setMethodCallHandler((call) async {
      if (call.method == 'openOverview') {
        requestOverview();
        return true;
      }
      if (call.method == 'changed') await refresh();
      return null;
    });
    _uiReadinessPending = true;
    await refresh();
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (interactive) _completeInteractionWaiters(true);
    _retry?.cancel();
    if (foreground) {
      _retryStep = 0;
      unawaited(refresh());
    } else {
      // Invalidate the pending platform/file invocation and let its Future finish.
      _runner++;
      _readRevision++;
      _refreshing = false;
      _refreshAgain = false;
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed || !_foreground) return;
    _retry?.cancel();
    if (_refreshing) {
      _refreshAgain = true;
      _readRevision++;
      await _refreshDone!.future;
      return;
    }
    _refreshing = true;
    final done = Completer<void>();
    _refreshDone = done;
    final runner = ++_runner;
    try {
      do {
        _refreshAgain = false;
        final revision = _readRevision;
        bool current() =>
            !_disposed &&
            _foreground &&
            runner == _runner &&
            revision == _readRevision;
        try {
          if (_uiReadinessPending) {
            await platform.uiReady().timeout(_readTimeout);
            if (!current()) continue;
            _uiReadinessPending = false;
          }
          final snapshot = await platform.snapshot().timeout(_readTimeout);
          if (current()) {
            state = snapshot;
            platformErrorMessage = null;
            // An already running/preparing service must remain stoppable even
            // on first attachment while the three stores are still being read.
            if (snapshot.running ||
                snapshot.pendingStart ||
                snapshot.pendingSystemStart ||
                snapshot.pendingRestore ||
                snapshot.scheduleBusy ||
                snapshot.resourceBusy ||
                snapshot.phase == 'STARTING') {
              loading = false;
            }
            notifyListeners();
          }
        } catch (_) {
          if (current()) {
            state = const AppSnapshot();
            platformErrorMessage = messages.temporaryStatusUnavailable;
            loading = false;
            notifyListeners();
          }
        }
        if (runner != _runner || _disposed) return;
        if (current() &&
            platformErrorMessage == null &&
            state.storageReady &&
            !state.storageRestoring) {
          final epoch = state.storageEpoch;
          ConfigCollection? configs;
          List<OverrideEntry>? parts;
          AppPreferences? settings;
          AppMessage? configFailure;
          AppMessage? overrideFailure;
          AppMessage? preferencesFailure;
          try {
            configs = await _readConfigs().timeout(_readTimeout);
          } catch (failure) {
            configFailure = failure is ConfigFailure
                ? failure.message
                : messages.temporaryConfigsUnreadable;
          }
          if (!current()) continue;
          try {
            parts = await _readOverrides().timeout(_readTimeout);
          } catch (failure) {
            overrideFailure = failure is ConfigFailure
                ? failure.message
                : messages.temporaryOverridesUnreadable;
          }
          if (!current()) continue;
          try {
            settings = await _readPreferences().timeout(_readTimeout);
          } catch (failure) {
            preferencesFailure = failure is ConfigFailure
                ? failure.message
                : messages.temporarySettingsUnreadable;
          }
          if (!current()) continue;
          try {
            final after = await platform.snapshot().timeout(_readTimeout);
            if (!current()) continue;
            state = after;
            if (!after.storageReady ||
                after.storageRestoring ||
                after.storageEpoch != epoch) {
              // Keep the last complete projection through restore; a ready new epoch
              // triggers a fresh whole read.
              _refreshAgain = after.storageReady && !after.storageRestoring;
              if (!after.storageReady && !after.storageRestoring) {
                loading = false;
              }
              notifyListeners();
              continue;
            }
            if (configs != null && parts != null && settings != null) {
              collection = configs;
              overrides = parts;
              preferences = settings;
              _storageEpoch = epoch;
              configsLoaded = true;
              overridesLoaded = true;
              preferencesLoaded = true;
              setMessageLanguage(settings.language);
            }
            configErrorMessage = configFailure;
            overrideErrorMessage = overrideFailure;
            preferencesErrorMessage = preferencesFailure;
          } catch (_) {
            if (current()) {
              platformErrorMessage = messages.temporaryStatusUnavailable;
            }
          }
          if (current()) {
            loading = false;
            notifyListeners();
          }
        } else if (current() && !state.storageRestoring) {
          // Treat a closed gate or failed platform read as the settled startup error.
          loading = false;
          notifyListeners();
        }
      } while (_refreshAgain && !_disposed && runner == _runner && _foreground);
      if (_disposed || runner != _runner) return;
      _refreshing = false;
      if (!state.storageReady ||
          state.storageRestoring ||
          platformError != null ||
          configError != null ||
          preferencesError != null ||
          overrideError != null ||
          state.modeError != null) {
        final seconds = _retrySeconds[_retryStep];
        if (_retryStep < _retrySeconds.length - 1) _retryStep++;
        if (_foreground) {
          _retry = Timer(
            Duration(seconds: seconds),
            () => unawaited(refresh()),
          );
        }
      } else {
        _retryStep = 0;
      }
    } finally {
      if (runner == _runner) {
        _refreshing = false;
        _refreshDone = null;
      }
      done.complete();
    }
  }

  Future<AppPreferences> _readPreferences() async {
    final source = preferencesStore;
    if (source != null) return source.read();
    final directory =
        store?.directory ??
        Directory((await platform.paths())['configs'] as String);
    return PreferencesStore(directory).read();
  }

  Future<List<OverrideEntry>> _readOverrides() async {
    final source = overrideStore;
    if (source != null) return source.read();
    final directory =
        store?.directory ??
        Directory((await platform.paths())['configs'] as String);
    return OverrideStore(directory).read();
  }

  Future<ConfigCollection> _readConfigs() async {
    final source = store;
    if (source != null) return source.read();
    final paths = await platform.paths();
    // Keep the result local and publish only while the invocation remains current.
    return ConfigStore(Directory(paths['configs'] as String)).read();
  }

  /// Global feedback yields only while this command still has a local reader.
  bool get hasLocalFeedbackOwner =>
      _feedbackOwner != null && identical(_feedbackCommand, lastCommand);

  bool feedbackHandledLocally(
    Map<String, Object?> command, {
    required bool submissionFailed,
    String? resultId,
  }) => submissionFailed
      ? identical(command, _handledSubmissionCommand)
      : resultId != null && resultId == _handledFeedbackResultId;

  /// Acknowledge the actual result after local feedback or inline presentation; a
  /// timeout leaves later feedback pending.
  void acknowledgeLocalFeedback(
    ValueListenable<bool> owner, {
    AppSnapshot? result,
  }) {
    if (_disposed ||
        !identical(owner, _feedbackOwner) ||
        !identical(_feedbackCommand, lastCommand)) {
      return;
    }
    if (result != null &&
        (result.resultId == null || result.resultId != _feedbackOperationId)) {
      return;
    }
    if (result != null) {
      _handledFeedbackResultId = result.resultId;
    } else if (_feedbackOperationId == null && commandErrorMessage != null) {
      _handledSubmissionCommand = lastCommand;
    }
    _detachFeedbackOwner();
    _notifyFeedbackChanged();
  }

  void _attachFeedbackOwner(
    ValueListenable<bool>? owner,
    Map<String, Object?> command,
  ) {
    _detachFeedbackOwner();
    if (owner == null || !owner.value || !identical(command, lastCommand)) {
      return;
    }
    _feedbackOwner = owner;
    _feedbackCommand = command;
    owner.addListener(_feedbackOwnerChanged);
  }

  void _feedbackOwnerChanged() {
    if (_feedbackOwner?.value != false) return;
    _detachFeedbackOwner();
    _notifyFeedbackChanged();
  }

  void _detachFeedbackOwner() {
    _feedbackOwner?.removeListener(_feedbackOwnerChanged);
    _feedbackOwner = null;
    _feedbackCommand = null;
    _feedbackOperationId = null;
  }

  void _notifyFeedbackChanged() {
    // A route may release its marker during dispose, inside a widget build.
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
  }

  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    if (_disposed ||
        (busy && !(command['action'] == 'stop' && canStopBackground))) {
      return null;
    }
    _detachFeedbackOwner();
    _handledSubmissionCommand = null;
    lastCommandAutomatic = automatic;
    String? operationId;
    final submittedCommand = <String, Object?>{
      ...command,
      if (command['action'] != 'stop' && !command.containsKey('storageEpoch'))
        'storageEpoch': _storageEpoch,
    };
    lastCommand = submittedCommand;
    _activeSubmission = submittedCommand;
    dispatching = true;
    commandErrorMessage = null;
    _readRevision++;
    notifyListeners();
    try {
      final admission = await platform.submit(submittedCommand);
      operationId = admission?.operationId;
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
    } on PlatformException catch (failure) {
      if (!_disposed) {
        commandErrorMessage = messageFromPlatform(
          failure,
          fallback: messages.requestNotAccepted,
        );
      }
    } catch (_) {
      if (!_disposed) commandErrorMessage = messages.requestNotAccepted;
    } finally {
      if (!_disposed) {
        dispatching = false;
        notifyListeners();
      }
    }
    // 受理及状态回读保持同一等待身份，停止请求按原有准入条件接管。
    try {
      if (!_disposed) await refresh();
    } finally {
      if (identical(_activeSubmission, submittedCommand)) {
        _activeSubmission = null;
        if (!_disposed) notifyListeners();
      }
    }
    return operationId;
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
    if (_disposed || busy || _pendingResult != null) return null;
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
      if (submittedCommand != null &&
          identical(_feedbackCommand, submittedCommand)) {
        _feedbackOperationId = id;
      }
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
      if (submittedCommand != null &&
          identical(_feedbackCommand, submittedCommand)) {
        _detachFeedbackOwner();
        _notifyFeedbackChanged();
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
    _overviewRequested = false;
    _overviewLeaves.clear();
    _detachFeedbackOwner();
    _handledSubmissionCommand = null;
    _handledFeedbackResultId = null;
    final pending = _pendingResult;
    _pendingWait?.cancel();
    _pendingWait = null;
    _pendingResult = null;
    _pendingCommand = null;
    _pendingOperationId = null;
    if (pending?.isCompleted == false) pending!.complete(null);
    _runner++;
    _retry?.cancel();
    AppBridge.channel.setMethodCallHandler(null);
    super.dispose();
  }
}
