import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import 'connection_snapshot.dart';
import 'connection_window.dart';

enum ConnectionViewStatus {
  active,
  updating,
  failed,
  inactive,
  stopped,
  unknown,
  replaced,
  closed,
}

class ConnectionController extends ChangeNotifier {
  ConnectionController(this.app, {Stopwatch? clock})
    : _clock = clock ?? Stopwatch() {
    _clock.start();
    app.addListener(_changed);
  }
  final AppController app;
  final Stopwatch _clock;
  Timer? _expiry;
  int _sampleReadAt = 0;
  ConnectionSnapshot? data;
  DateTime? observedAt;
  String? error;
  bool loading = false;
  bool closing = false;
  String? closeMessage;
  String? _closeId;
  String? _closeStatus;
  bool _visible = false;
  bool _disposed = false;
  bool _flight = false;
  bool _fresh = false;
  int _request = 0;
  int _failures = 0;
  int _detailEpoch = 0;
  Object? _observed;
  Timer? _timer;
  ConnectionRecord? _detail;
  (int, String, int)? _detailIdentity;

  bool get available =>
      app.state.running &&
      app.state.core.ready &&
      app.state.core.purpose == 'VPN';
  bool get active => !_disposed && _visible && app.foreground;
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
  DateTime? get detailAt => detail?.observedAt;
  ConnectionRecord? get _latestDetail =>
      data?.find(_detail?.id ?? '') ??
      (data?.detail?.id == _detail?.id ? data?.detail : null);
  bool get detailActive =>
      current &&
      _latestDetail?.active == true &&
      _detailIdentity == (data!.generation, data!.configId, data!.revision) &&
      _closeStatus != 'closed' &&
      _closeStatus != 'absent';
  bool get canClose =>
      detailActive && !closing && !app.busy && app.platformError == null;

  ConnectionViewStatus get status {
    if (app.state.phase == 'STOPPED') return ConnectionViewStatus.stopped;
    if (!available) return ConnectionViewStatus.unknown;
    if (error != null || data?.failed == true) {
      return ConnectionViewStatus.failed;
    }
    if (!current) return ConnectionViewStatus.updating;
    return ConnectionViewStatus.active;
  }

  ConnectionViewStatus get detailStatus {
    final core = app.state.core;
    if (_closeStatus == 'closed') return ConnectionViewStatus.closed;
    if (app.state.phase == 'STOPPED') return ConnectionViewStatus.stopped;
    if (!available) return ConnectionViewStatus.unknown;
    if (_detailIdentity != (core.generation, core.configId, core.revision)) {
      return ConnectionViewStatus.replaced;
    }
    if (status != ConnectionViewStatus.active) return status;
    if (_detail?.active == false || _closeStatus == 'absent') {
      return ConnectionViewStatus.inactive;
    }
    if (_latestDetail == null) return ConnectionViewStatus.unknown;
    return ConnectionViewStatus.active;
  }

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
      core.generation,
      core.phase,
      core.purpose,
      core.configId,
      core.revision,
    );
    if (_observed == key) {
      notifyListeners();
      return;
    }
    _observed = key;
    _request++;
    _timer?.cancel();
    _expiry?.cancel();
    _fresh = false;
    loading = false;
    error = null;
    _failures = 0;
    if (data != null &&
        app.state.generation != data!.sessionGeneration &&
        (app.state.phase == 'STARTING' || app.state.running)) {
      data = null;
      observedAt = null;
    }
    notifyListeners();
    if (active) unawaited(_read());
  }

  Future<void> _read() async {
    if (!active || _flight) return;
    _flight = true;
    final request = _request;
    final began = _clock.elapsedMilliseconds;
    bool valid() => active && request == _request;
    if (data == null && !loading) {
      loading = true;
      notifyListeners();
    }
    try {
      final identity = _detailIdentity;
      final result = await app.platform
          .recentConnections(
            detail: identity == null || _detail == null
                ? null
                : {
                    'generation': identity.$1,
                    'configId': identity.$2,
                    'revision': identity.$3,
                    'id': _detail!.id,
                  },
          )
          .timeout(const Duration(seconds: 5));
      if (!valid()) return;
      if (app.state.running &&
          result.sessionGeneration != app.state.generation) {
        throw const FormatException('Observation session changed');
      }
      data = result;
      // Include the round trip; receiving the same sample must not renew it.
      _sampleReadAt = began;
      observedAt = result.observedAt;
      _fresh = true;
      error = null;
      _failures = 0;
      if (_detailIdentity ==
              (result.generation, result.configId, result.revision) &&
          _detail != null) {
        final found =
            result.find(_detail!.id) ??
            (result.detail?.id == _detail!.id ? result.detail : null);
        if (found != null) {
          _detail = found;
        } else if (result.missingDetailId == _detail!.id) {
          _detail = _detail!.observed(active: false);
        }
      }
    } catch (_) {
      if (!valid()) return;
      _fresh = false;
      error = '更新失败';
      _failures++;
    } finally {
      _flight = false;
      if (!_disposed) {
        loading = false;
        _expire();
        notifyListeners();
        if (active) {
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
    _detailEpoch++;
    _detailIdentity = (source.generation, source.configId, source.revision);
    _detail = source.find(record.id) ?? record;
    _closeId = null;
    _closeStatus = null;
    closeMessage = null;
    closing = false;
  }

  Future<void> disconnect() async {
    if (!canClose || _detailIdentity == null || _detail == null) return;
    final identity = _detailIdentity!;
    final epoch = _detailEpoch;
    closing = true;
    closeMessage = null;
    _closeStatus = null;
    notifyListeners();
    final id = await app.submit({
      'action': 'closeConnection',
      'generation': identity.$1,
      'configId': identity.$2,
      'revision': identity.$3,
      'connectionId': _detail!.id,
    });
    if (_disposed || epoch != _detailEpoch) return;
    _closeId = id;
    if (id == null) {
      closing = false;
      closeMessage = app.commandError ?? '请求未被受理';
    } else {
      _updateCloseResult();
    }
    notifyListeners();
  }

  void _updateCloseResult() {
    if (_closeId == null || !closing) return;
    if (app.state.resultId == _closeId) {
      _closeStatus = app.state.connectionStatus ?? 'unconfirmed';
      closeMessage = switch (_closeStatus) {
        'closed' => null,
        'absent' => null,
        'failed' => '断开失败',
        _ => '断开结果未确认',
      };
      closing = false;
    }
  }

  void closeDetail() {
    _detailEpoch++;
    _detail = null;
    _detailIdentity = null;
    _closeId = null;
    _closeStatus = null;
    closeMessage = null;
    closing = false;
    unawaited(app.platform.releaseConnectionDetail().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _timer?.cancel();
    _expiry?.cancel();
    _clock.stop();
    closeDetail();
    app.removeListener(_changed);
    super.dispose();
  }
}
