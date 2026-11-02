import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../locale/message_text.dart';
import '../../../model/core_snapshot.dart';
import '../../app/app_controller.dart';
import '../../../model/messages.dart';
import '../../../model/application_contract.dart';

enum CoreLogsStatus { loading, live, preview, recent, stale, empty, failed }

/// 页面只保留只读快照、筛选与跟随位置；历史窗口由 AppRuntime 保存。
class CoreLogsController extends ChangeNotifier {
  CoreLogsController(
    this.app, {
    this.poll = const Duration(milliseconds: 600),
  }) {
    app.addListener(_changed);
  }
  final AppController app;
  final Duration poll;
  static const capacity = ApplicationContract.logEntries;
  static const byteCapacity = ApplicationContract.logTextBytes;
  CoreLogsStatus status = CoreLogsStatus.loading;
  AppMessage? readError;
  Object? _readErrorSource;
  Object? get readErrorSource => _readErrorSource;
  String? get error => readError?.text;
  Map<String, dynamic>? data;
  Map<String, Object?>? dataQuery;
  List<Map<String, dynamic>> entries = const [];
  String level = 'info';
  String search = '';
  bool follow = true;
  int dropped = 0;
  int localDropped = 0;
  int total = 0;
  bool loading = false;
  bool _visible = false;
  bool _disposed = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  Timer? _timer;
  Timer? _grace;
  Object? _window;
  Completer<void>? _queuedClear;

  bool get active => !_disposed && _visible && app.foreground;
  bool get canRefresh => active && !loading && !app.busy;
  bool get canClear => active && !loading && _availableSource != null;
  CoreSnapshot? get _availableSource {
    final source = app.state.logSource;
    if (source == null ||
        !source.hasIdentity ||
        source.logWindow?.isNotEmpty != true) {
      return null;
    }
    return source;
  }

  static const levels = ['debug', 'info', 'warning', 'error'];
  static int rank(String value) => switch (value) {
    'debug' => 0,
    'info' => 1,
    'warning' => 2,
    'error' => 3,
    _ => 4,
  };

  bool matches(Map<String, dynamic> entry) {
    if (rank(entry['level']?.toString() ?? '') < rank(level)) return false;
    final query = search.trim().toLowerCase();
    return query.isEmpty ||
        (entry['text']?.toString() ?? '').toLowerCase().contains(query);
  }

  List<Map<String, dynamic>> get visible =>
      List.unmodifiable(entries.where(matches));

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _changed();
  }

  void setLevel(String value) {
    if (level == value) return;
    level = value;
    follow = true;
    notifyListeners();
  }

  void filter(String value) {
    if (search == value) return;
    search = value;
    notifyListeners();
  }

  void setFollow(bool value) {
    if (follow == value) return;
    follow = value;
    notifyListeners();
  }

  Future<void> clear() async {
    if (!active || _availableSource == null) return;
    if (loading) {
      final queued = _queuedClear ??= Completer<void>();
      return queued.future;
    }
    await _read(clear: true);
  }

  void _retireClear() {
    _queuedClear?.complete();
    _queuedClear = null;
  }

  void _schedule() {
    _timer?.cancel();
    if (active && _availableSource != null) {
      _timer = Timer(poll, () => _read());
    }
  }

  void _changed() {
    if (_disposed) return;
    final source = _availableSource;
    final window = source == null ? null : (source.identity, source.logWindow);
    if (window != null && window != _window) {
      _retireClear();
      _window = window;
      entries = const [];
      data = null;
      dataQuery = null;
      dropped = localDropped = total = 0;
      readError = null;
      _readErrorSource = null;
    }
    if (!active || source == null) _retireClear();
    final selected = app.collection.selected;
    final key = (
      active,
      app.busy,
      app.platformErrorMessage,
      app.configsCurrent,
      app.state.recoveryRequired,
      app.state.core.identity,
      app.state.core.phase,
      source?.identity,
      source?.phase,
      source?.logWindow,
      selected?.id,
      selected?.revision,
    );
    if (_observed == key) return;
    _observed = key;
    _request++;
    if (source != null) _attempted = null;
    if (!active) {
      status = entries.isEmpty ? CoreLogsStatus.empty : CoreLogsStatus.stale;
    } else if (source != null) {
      // 旧窗口可直接阅读，不因停止或刷新重新创建内核。
      _attempted = null;
      unawaited(_read());
    } else if (app.state.recoveryRequired ||
        app.platformError != null ||
        !app.state.confirmed ||
        app.state.core.blocked) {
      status = entries.isEmpty ? CoreLogsStatus.failed : CoreLogsStatus.stale;
    } else if (entries.isNotEmpty) {
      status = CoreLogsStatus.recent;
    } else if (!app.busy &&
        app.configsCurrent &&
        selected != null &&
        !app.state.forwarding &&
        app.state.core.phase == 'EMPTY') {
      final identity = (selected.id, selected.revision, app.storageEpoch);
      if (_attempted != identity) {
        _attempted = identity;
        status = CoreLogsStatus.loading;
        unawaited(
          app.submit({
            'action': 'prepareStrategies',
            'id': selected.id,
            'revision': selected.revision,
          }, automatic: true),
        );
      } else {
        status = CoreLogsStatus.empty;
      }
    }
    _schedule();
    notifyListeners();
  }

  Future<void> _read({bool clear = false}) async {
    final expected = _availableSource;
    if (!active || loading || expected == null) return;
    final request = _request;
    final errorSource = (
      app.storageEpoch,
      expected.identity,
      expected.logWindow,
    );
    loading = true;
    _grace = Timer(const Duration(seconds: 5), () {
      if (_disposed || !loading) return;
      readError = const AppMessage('coreReadFailed')
          .withDetail('Log read is still pending');
      _readErrorSource = errorSource;
      status = entries.isEmpty ? CoreLogsStatus.failed : CoreLogsStatus.stale;
      notifyListeners();
    });
    notifyListeners();
    final query = <String, Object?>{if (clear) 'clear': true};
    try {
      final value = await app.platform.logs(expected, query);
      if (_disposed) return;
      final page = value['logs'] as Map;
      final current = _availableSource;
      if (page['window'] != expected.logWindow ||
          !expected.matchesWireIdentity(value) ||
          current?.logWindow != expected.logWindow ||
          !expected.matchesIdentity(current!)) {
        status = CoreLogsStatus.stale;
        return;
      }
      if (!clear && _queuedClear != null) return;
      final previous = data?['logs'] as Map?;
      if (previous != null &&
          (page['cleared'] as int? ?? 0) < (previous['cleared'] as int? ?? 0)) {
        return;
      }
      final rows = (page['entries'] as List)
          .map((row) => Map<String, dynamic>.unmodifiable(row as Map))
          .toList(growable: false);
      entries = List.unmodifiable(rows);
      data = Map.unmodifiable(value);
      dataQuery = Map.unmodifiable({...query, 'window': expected.logWindow});
      dropped = page['dropped'] as int? ?? 0;
      localDropped = page['windowDropped'] as int? ?? 0;
      total = page['total'] as int? ?? rows.length;
      readError = value['error'] == null
          ? null
          : const AppMessage('coreReadFailed').withDetail(value['error']);
      _readErrorSource = readError == null ? null : errorSource;
      status = !active
          ? CoreLogsStatus.stale
          : !current.ready
          ? CoreLogsStatus.recent
          : expected.purpose == 'RUNNING'
          ? CoreLogsStatus.live
          : CoreLogsStatus.preview;
    } catch (error) {
      if (_disposed) return;
      readError = error is PlatformFailure
          ? messageFromFailure(
              error,
              fallback: const AppMessage('coreReadFailed'),
            )
          : const AppMessage('coreReadFailed').withDetail(error);
      _readErrorSource = errorSource;
      status = entries.isEmpty ? CoreLogsStatus.failed : CoreLogsStatus.stale;
    } finally {
      _grace?.cancel();
      loading = false;
      if (!_disposed) {
        final queued = _queuedClear;
        _queuedClear = null;
        if (queued != null) {
          unawaited(_read(clear: true).whenComplete(queued.complete));
        } else if (request != _request && active && _availableSource != null) {
          unawaited(_read());
        } else {
          _schedule();
        }
        notifyListeners();
      }
    }
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    _observed = null;
    await app.refresh();
    if (active) {
      if (_availableSource != null) {
        await _read();
      } else {
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _timer?.cancel();
    _grace?.cancel();
    _retireClear();
    app.removeListener(_changed);
    super.dispose();
  }
}
