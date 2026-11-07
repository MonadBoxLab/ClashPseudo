import '../locale/message_text.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/app_controller.dart';
import '../../model/core_snapshot.dart';
import '../../model/config_entry.dart';
import '../../model/strategy_snapshot.dart';
import '../../model/connection_snapshot.dart';
import '../../logic/connections/connection_window.dart';
import '../../model/messages.dart';

enum ConnectionErrorSource { read, clearInactive, releaseDetail }

class ConnectionController extends ChangeNotifier {
  ConnectionController(this.app, {Stopwatch? clock, this._isActive})
    : _clock = clock ?? Stopwatch() {
    _clock.start();
    app.addListener(_changed);
  }
  final AppController app;
  final bool Function()? _isActive;
  final Stopwatch _clock;
  Timer? _expiry;
  Timer? _readDeadline;
  Timer? _clearDeadline;
  int _sampleReadAt = 0;
  ConnectionSnapshot? data;
  AppMessage? errorMessage;
  ConnectionErrorSource? errorSource;
  ({Object identity, Object source, AppMessage message})? operationError;

  void _operationFailure(Object source) {
    final message = errorMessage;
    if (message != null) {
      operationError = (identity: Object(), source: source, message: message);
    }
  }

  // Track explicit read results only; visibility cleanup and user actions do not imply
  // read recovery.
  int readRevision = 0;
  bool? readFailed;
  void _readResult(bool failed) {
    readRevision++;
    readFailed = failed;
  }

  String? get error => errorMessage?.text;
  bool clearing = false;
  bool closing = false;
  bool ruleLoading = false;
  AppMessage? closeMessageDescription;
  String? get closeMessage => closeMessageDescription?.text;
  String? _closeId;
  String? _closeStatus;
  bool _visible = false;
  bool _disposed = false;
  bool _flight = false;
  bool _fresh = false;
  int _request = 0;
  int _failures = 0;
  int _detailEpoch = 0;
  static int _nextDetailOwner = 0;
  String? _detailOwner;
  Object? _observed;
  Timer? _timer;
  ConnectionRecord? _detail;
  (int, String, int)? _detailIdentity;
  CoreSnapshot? _detailSource;
  int? _detailSession;
  int? _detailStorageEpoch;
  int? get detailStorageEpoch => _detailStorageEpoch;

  bool get available =>
      app.state.forwarding &&
      app.state.core.ready &&
      app.state.core.purpose == 'RUNNING';
  bool get active =>
      !_disposed && _visible && app.foreground && (_isActive?.call() ?? true);
  int? get _remainingMs {
    final age = data?.sampleAgeMs;
    if (age == null) return null;
    return ConnectionWindow.maxSpeedIntervalMs -
        age -
        (_clock.elapsedMilliseconds - _sampleReadAt);
  }

  bool get current =>
      _fresh &&
      data?.fresh == true &&
      (_remainingMs ?? -1) >= 0 &&
      available &&
      data!.matches(app.state.core);
  ConnectionRecord? get detail => _detail;
  Object? get detailLease => _detailOwner;
  CoreSnapshot? get detailSource => _detailSource;
  DateTime? get detailAt => detail?.observedAt;
  ConnectionRecord? get _latestDetail =>
      data?.find(_detail?.id ?? '') ??
      (data?.detail?.id == _detail?.id ? data?.detail : null);
  bool get detailActive =>
      current &&
      _latestDetail?.active == true &&
      _detailSource?.matchesIdentity(app.state.core) == true &&
      _detailIdentity == (data!.generation, data!.configId, data!.revision) &&
      _closeStatus != 'closed' &&
      _closeStatus != 'absent';
  bool get canClose =>
      active &&
      detailActive &&
      !closing &&
      !app.busy &&
      app.platformError == null;

  ConnectionRuleSuggestions? get ruleSuggestions {
    final value = _detail?.ruleMetadata;
    // Captured rule evidence outlives a covering form route. The form owns its
    // own live-route eligibility; source/selection/epoch checks remain here.
    if (!available ||
        value == null ||
        value.connectionId != _detail?.id ||
        _detailSession != data?.sessionGeneration ||
        _detailSession != app.state.generation ||
        _detailSource?.matchesIdentity(value.source) != true ||
        !value.matches(app.state.core)) {
      return null;
    }
    return value;
  }

  bool get canCreateRule =>
      active &&
      !ruleLoading &&
      !closing &&
      !app.busy &&
      app.platformError == null &&
      ruleSuggestions?.candidates.isNotEmpty == true &&
      _detailStorageEpoch != null &&
      isRuleSourceCurrent(ruleSuggestions!, _detailStorageEpoch!);

  bool isRuleSourceCurrent(
    ConnectionRuleSuggestions source,
    int storageEpoch, {
    ConnectionRuleCandidate? candidate,
  }) {
    final latest = ruleSuggestions;
    return !_disposed &&
        app.foreground &&
        app.configsCurrent &&
        app.state.storageReady &&
        !app.state.storageRestoring &&
        app.storageEpoch == storageEpoch &&
        app.state.storageEpoch == storageEpoch &&
        _detailStorageEpoch == storageEpoch &&
        latest != null &&
        latest.connectionId == source.connectionId &&
        latest.source.matchesIdentity(source.source) &&
        (candidate == null || latest.candidates.contains(candidate));
  }

  Future<StrategySnapshot> loadRuleTargets(
    ConnectionRuleSuggestions source,
    int storageEpoch,
    ConnectionRuleCandidate candidate,
  ) async {
    if (!canCreateRule ||
        !isRuleSourceCurrent(source, storageEpoch, candidate: candidate)) {
      throw ConfigFailure(messages.strategyContextChangedRetry);
    }
    ruleLoading = true;
    notifyListeners();
    try {
      final result = await app.platform.strategies(source.source);
      if (!isRuleSourceCurrent(source, storageEpoch, candidate: candidate) ||
          !result.matches(source.source)) {
        throw ConfigFailure(messages.strategyContextChangedRetry);
      }
      return result;
    } finally {
      ruleLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  String? get closeResult => _closeStatus;

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    _updateCloseResult();
    final core = app.state.core;
    final key = (
      _visible,
      app.foreground,
      app.state.phase,
      app.state.generation,
      core.processId,
      core.inputId,
      core.generation,
      core.phase,
      core.purpose,
      core.configId,
      core.revision,
      core.composition,
      app.state.storageEpoch,
    );
    if (_observed == key) {
      notifyListeners();
      return;
    }
    _observed = key;
    if (app.state.forwarding &&
        data != null &&
        (data!.sessionGeneration != app.state.generation ||
            data!.source.processId != core.processId)) {
      data = null;
      closeDetail();
    }
    _request++;
    _timer?.cancel();
    _expiry?.cancel();
    _fresh = false;
    errorMessage = null;
    errorSource = null;
    _failures = 0;
    notifyListeners();
    if (active) unawaited(_read());
  }

  Map<String, Object?>? get _detailQuery {
    final identity = _detailIdentity;
    if (identity == null || _detail == null) return null;
    return {
      'processId': _detailSource?.processId,
      'inputId': _detailSource?.inputId,
      'generation': identity.$1,
      'configId': identity.$2,
      'revision': identity.$3,
      'composition': _detailSource?.composition,
      'purpose': _detailSource?.purpose,
      'id': _detail!.id,
    };
  }

  void _accept(
    ConnectionSnapshot result,
    int began,
    String? detailOwner,
    ConnectionErrorSource origin,
  ) {
    if (app.state.forwarding &&
        result.sessionGeneration != app.state.generation) {
      throw const FormatException('Observation session changed');
    }
    data = result;
    // Sample age includes the round trip and uses the original sample time.
    _sampleReadAt = began;
    _fresh = true;
    errorMessage = result.error == null
        ? null
        : messages.trafficUpdateFailed.withDetail(result.error);
    errorSource = errorMessage != null ? origin : null;
    if (origin == ConnectionErrorSource.read &&
        result.matches(app.state.core)) {
      if (errorMessage != null) {
        _readResult(true);
      } else if (current) {
        _readResult(false);
      }
    }
    _failures = 0;
    if (detailOwner == _detailOwner &&
        _detailIdentity ==
            (result.generation, result.configId, result.revision) &&
        _detailSource?.matchesIdentity(result.source) == true &&
        _detail != null) {
      final found =
          result.find(_detail!.id) ??
          (result.detail?.id == _detail!.id ? result.detail : null);
      if (found != null) {
        _detail = found.retainingRulesFrom(_detail);
      } else if (result.releasedDetailId == _detail!.id) {
        closeDetail();
      } else if (result.missingDetailId == _detail!.id) {
        _detail = _detail!.observed(active: false);
      }
    }
  }

  Future<void> clearInactive() async {
    if (!active || clearing) return;
    clearing = true;
    final detailOwner = _detailOwner;
    final detailQuery = _detailQuery;
    final source = (
      app.storageEpoch,
      app.state.generation,
      app.state.core.identity,
    );
    final request = ++_request;
    final began = _clock.elapsedMilliseconds;
    _timer?.cancel();
    notifyListeners();
    final deadline = _clearDeadline = Timer(const Duration(seconds: 5), () {
      if (_disposed || request != _request) return;
      errorMessage = messages.trafficUpdateFailed.withDetail(
        TimeoutException('Clearing connection records is still in progress'),
      );
      errorSource = ConnectionErrorSource.clearInactive;
      _operationFailure(source);
      notifyListeners();
    });
    try {
      // A reply deadline is not proof that the runtime's clear has drained.
      if (detailOwner != _detailOwner) return;
      final result = await app.platform.clearInactiveConnections(
        detail: detailQuery,
        detailOwner: detailOwner,
      );
      if (_disposed || request != _request) return;
      _accept(result, began, detailOwner, ConnectionErrorSource.clearInactive);
      if (errorSource == ConnectionErrorSource.clearInactive) {
        _operationFailure(source);
      }
    } catch (failure) {
      if (_disposed || request != _request) return;
      errorMessage = messages.trafficUpdateFailed.withDetail(failure);
      errorSource = ConnectionErrorSource.clearInactive;
      _operationFailure(source);
    } finally {
      deadline.cancel();
      clearing = false;
      if (!_disposed) {
        _expire();
        notifyListeners();
        if (active && !_flight) unawaited(_read());
      }
    }
  }

  Future<void> _read() async {
    if (!active || _flight || clearing) return;
    _flight = true;
    final detailOwner = _detailOwner;
    final detailQuery = _detailQuery;
    final request = _request;
    final began = _clock.elapsedMilliseconds;
    bool valid() => active && request == _request;
    final deadline = _readDeadline = Timer(const Duration(seconds: 5), () {
      if (!valid()) return;
      _fresh = false;
      errorMessage = messages.trafficUpdateFailed.withDetail(
        TimeoutException('Connection observation is still in progress'),
      );
      errorSource = ConnectionErrorSource.read;
      _readResult(true);
      notifyListeners();
    });
    try {
      // Keep the slot until the submitted Future actually settles.
      if (detailOwner != _detailOwner) return;
      final result = await app.platform.recentConnections(
        detail: detailQuery,
        detailOwner: detailOwner,
      );
      if (!valid()) return;
      _accept(result, began, detailOwner, ConnectionErrorSource.read);
    } catch (failure) {
      if (!valid()) return;
      _fresh = false;
      errorMessage = messages.trafficUpdateFailed.withDetail(failure);
      errorSource = ConnectionErrorSource.read;
      _readResult(true);
      _failures++;
    } finally {
      deadline.cancel();
      _flight = false;
      if (!_disposed) {
        _expire();
        notifyListeners();
        if (active && !clearing) {
          const backoff = [1, 2, 5, 10, 30];
          final seconds = request != _request
              ? 0
              : _failures == 0
              ? 1
              : backoff[(_failures - 1).clamp(0, 4)];
          _timer = Timer(Duration(seconds: seconds), _read);
        }
      }
    }
  }

  void _expire() {
    _expiry?.cancel();
    if (!active || !current) return;
    _expiry = Timer(Duration(milliseconds: _remainingMs! + 1), () {
      if (!active) return;
      _fresh = false;
      notifyListeners();
    });
  }

  void openDetail(ConnectionRecord record) {
    final source = data!;
    _releaseDetail();
    _detailOwner =
        'connection-detail:${DateTime.now().microsecondsSinceEpoch}:${_nextDetailOwner++}';
    _detailEpoch++;
    _detailIdentity = (source.generation, source.configId, source.revision);
    _detailSource = source.source;
    _detailStorageEpoch = app.storageEpoch;
    _detailSession = source.sessionGeneration;
    _detail = source.find(record.id) ?? record;
    _closeId = null;
    _closeStatus = null;
    closeMessageDescription = null;
    closing = false;
  }

  Future<void> disconnect() async {
    if (!canClose || _detailIdentity == null || _detail == null) return;
    final identity = _detailIdentity!;
    final source = _detailSource!;
    final connectionId = _detail!.id;
    final epoch = _detailEpoch;
    closing = true;
    closeMessageDescription = null;
    _closeStatus = null;
    notifyListeners();
    if (!active || epoch != _detailEpoch || !detailActive || app.busy) {
      if (epoch == _detailEpoch) {
        closing = false;
        notifyListeners();
      }
      return;
    }
    final id = await app.submit({
      'action': 'closeConnection',
      'processId': source.processId,
      'inputId': source.inputId,
      'networkRevision': source.networkRevision,
      'generation': identity.$1,
      'configId': identity.$2,
      'revision': identity.$3,
      'composition': source.composition,
      'purpose': source.purpose,
      'connectionId': connectionId,
    });
    if (_disposed || epoch != _detailEpoch) return;
    _closeId = id;
    if (id == null) {
      closing = false;
      closeMessageDescription =
          app.commandErrorMessage ?? messages.requestNotAccepted;
    } else {
      _updateCloseResult();
    }
    notifyListeners();
  }

  void _updateCloseResult() {
    if (_closeId == null || !closing) return;
    if (app.state.resultId == _closeId) {
      _closeStatus = app.state.connectionStatus ?? 'unconfirmed';
      closeMessageDescription = switch (_closeStatus) {
        'closed' => null,
        'absent' => null,
        'failed' =>
          app.state.resultMessageDescription ?? messages.disconnectFailedShort,
        _ =>
          app.state.resultMessageDescription ??
              messages.disconnectUnconfirmedShort,
      };
      closing = false;
    } else if (!app.state.stale &&
        app.state.operationId == _closeId &&
        app.state.operationRemainingMs == 0 &&
        app.state.operationMessage != null) {
      closeMessageDescription = messages.disconnectUnconfirmedShort.withDetail(
        app.state.operationMessage!.toMap(),
      );
    }
  }

  void closeDetail() {
    _detailEpoch++;
    _releaseDetail();
    _detail = null;
    _detailIdentity = null;
    _detailSource = null;
    _detailSession = null;
    _detailStorageEpoch = null;
    _closeId = null;
    _closeStatus = null;
    closeMessageDescription = null;
    closing = false;
  }

  void _releaseDetail() {
    final owner = _detailOwner;
    if (owner == null) return;
    final source = (
      _detailStorageEpoch,
      _detailSession,
      _detailSource?.identity,
    );
    _detailOwner = null;
    unawaited(() async {
      try {
        await app.platform.releaseConnectionDetail(owner: owner);
      } catch (failure) {
        if (_disposed ||
            source !=
                (
                  app.storageEpoch,
                  app.state.generation,
                  app.state.core.identity,
                )) {
          return;
        }
        errorMessage = messages.trafficUpdateFailed.withDetail(failure);
        errorSource = ConnectionErrorSource.releaseDetail;
        _operationFailure(source);
        notifyListeners();
      }
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _timer?.cancel();
    _expiry?.cancel();
    _readDeadline?.cancel();
    _clearDeadline?.cancel();
    _clock.stop();
    closeDetail();
    app.removeListener(_changed);
    super.dispose();
  }
}
