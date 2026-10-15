import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import 'connection_snapshot.dart';

class ConnectionController extends ChangeNotifier {
  ConnectionController(this.app) {
    app.addListener(_changed);
  }

  final AppController app;
  ConnectionSnapshot? data;
  DateTime? observedAt;
  String? error;
  bool loading = false;
  bool paused = false;
  bool _visible = false;
  bool _disposed = false;
  bool _flight = false;
  bool _fresh = false;
  int _request = 0;
  int _failures = 0;
  Object? _observed;
  Timer? _timer;
  ConnectionSnapshot? _frozen;
  DateTime? _frozenAt;
  ConnectionRecord? _detail;
  ConnectionRecord? _frozenDetail;
  DateTime? _detailAt;
  DateTime? _frozenDetailAt;
  (int, String, int)? _detailIdentity;
  bool _missing = false;

  bool get available =>
      app.state.running &&
      app.state.core.ready &&
      app.state.core.purpose == 'VPN';
  bool get active => !_disposed && _visible && app.foreground && available;
  bool get current =>
      _fresh && available && data?.matches(app.state.core) == true;
  ConnectionSnapshot? get displayed => paused ? _frozen : data;
  DateTime? get displayedAt => paused ? _frozenAt : observedAt;
  ConnectionRecord? get detail => paused ? _frozenDetail : _detail;
  DateTime? get detailAt => paused ? _frozenDetailAt : _detailAt;

  String? get notice {
    if (app.state.phase == 'STOPPED') return '未接管';
    if (!available) return '接管状态未就绪，显示最近观察';
    if (error != null) return error;
    if (!current && data != null) return '最近观察已过期';
    if (paused) return '已暂停刷新';
    return null;
  }

  String get detailStatus {
    final core = app.state.core;
    if (app.state.phase == 'STOPPED') return '接管已停止 · 最后观察';
    if (!available) return '接管状态未确认 · 最近观察';
    if (_detailIdentity != (core.generation, core.configId, core.revision)) {
      return '接管上下文已变化 · 最后观察';
    }
    if (!current) return '最近观察已过期';
    if (paused) return '已暂停刷新';
    return _missing ? '已不在当前活动快照中' : '活跃';
  }

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    final core = app.state.core;
    final key = (
      _visible,
      app.foreground,
      app.state.phase,
      core.generation,
      core.phase,
      core.purpose,
      core.configId,
      core.revision,
    );
    if (_observed == key) return;
    _observed = key;
    _request++;
    _timer?.cancel();
    _fresh = false;
    loading = false;
    error = null;
    _failures = 0;
    if (!available || (data != null && !data!.matches(core))) {
      data = null;
      _frozen = null;
      observedAt = null;
      _frozenAt = null;
    }
    notifyListeners();
    if (active) unawaited(_read());
  }

  Future<void> _read() async {
    if (!active || _flight) return;
    _flight = true;
    final request = _request;
    final core = app.state.core;
    bool valid() => active && request == _request;
    loading = data == null;
    notifyListeners();
    try {
      final result = await app.platform
          .connections(core)
          .timeout(const Duration(seconds: 5));
      if (!valid()) return;
      if (!result.matches(app.state.core)) {
        throw const FormatException('Connection context changed');
      }
      data = result;
      observedAt = DateTime.now();
      _fresh = true;
      error = null;
      _failures = 0;
      if (_detailIdentity ==
              (result.generation, result.configId, result.revision) &&
          _detail != null) {
        final found = result.find(_detail!.id);
        _missing = found == null;
        if (found != null) {
          _detail = found;
          _detailAt = observedAt;
        }
      }
    } catch (_) {
      if (!valid()) return;
      _fresh = false;
      error = '连接数据暂不可用，前台将自动重试。';
      _failures++;
    } finally {
      _flight = false;
      if (!_disposed) {
        loading = false;
        notifyListeners();
        if (active) {
          const backoff = [1, 2, 5, 10, 30];
          final seconds = request != _request
              ? 0
              : _failures == 0
              ? 1
              : backoff[(_failures - 1).clamp(0, backoff.length - 1)];
          _timer = Timer(Duration(seconds: seconds), _read);
        }
      }
    }
  }

  void togglePaused() {
    paused = !paused;
    _frozen = paused ? data : null;
    _frozenAt = paused ? observedAt : null;
    _frozenDetail = paused ? _detail : null;
    _frozenDetailAt = paused ? _detailAt : null;
    notifyListeners();
  }

  void openDetail(ConnectionRecord record) {
    final source = displayed!;
    _detailIdentity = (source.generation, source.configId, source.revision);
    _detail = source.matches(app.state.core)
        ? data?.find(record.id) ?? record
        : record;
    _detailAt = source.matches(app.state.core) && data?.find(record.id) != null
        ? observedAt
        : displayedAt;
    _missing =
        source.matches(app.state.core) &&
        current &&
        data?.find(record.id) == null;
    _frozenDetail = paused ? record : null;
    _frozenDetailAt = paused ? displayedAt : null;
  }

  void closeDetail() {
    _detail = null;
    _frozenDetail = null;
    _detailAt = null;
    _frozenDetailAt = null;
    _detailIdentity = null;
    _missing = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _timer?.cancel();
    app.removeListener(_changed);
    super.dispose();
  }
}
