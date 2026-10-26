import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';

enum CoreLogsStatus { loading, live, preview, recent, stale, empty, failed }

class CoreLogsController extends ChangeNotifier {
  CoreLogsController(
    this.app, {
    this.poll = const Duration(milliseconds: 600),
  }) {
    app.addListener(_changed);
  }

  final AppController app;
  final Duration poll;
  CoreLogsStatus status = CoreLogsStatus.loading;

  /// Bounded local window: the core keeps at most 1000 entries and 1 MiB; the
  /// client keeps only what it can show and drops oldest first.
  static const capacity = 1000;
  static const byteCapacity = 1024 * 1024;
  int _textBytes = 0;
  final List<Map<String, dynamic>> entries = [];
  String level = 'info';
  String search = '';
  bool follow = true;
  int dropped = 0;
  int total = 0;
  bool loading = false;
  int _next = 0;
  int _request = 0;
  bool _disposed = false;
  bool _visible = false;
  Object? _observed;
  Object? _attempted;
  Timer? _timer;

  bool get active => !_disposed && _visible && app.foreground;
  bool get canRefresh => active && !loading && !app.busy;

  CoreSnapshot? get _availableSource {
    final source = app.state.logSource;
    if (source == null ||
        !source.hasIdentity ||
        source.logWindow?.isNotEmpty != true ||
        !const ['READY', 'EMPTY'].contains(source.phase)) {
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
    if (rank(entry['level'] as String) < rank(level)) return false;
    final query = search.trim().toLowerCase();
    if (query.isEmpty) return true;
    return (entry['text'] as String).toLowerCase().contains(query);
  }

  List<Map<String, dynamic>> get visible =>
      List.unmodifiable(entries.where(matches));

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _schedule();
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

  /// Preserve the reading anchor until explicit back-to-latest or a level-filter change
  /// resets follow.
  void setFollow(bool value) {
    if (follow == value) return;
    follow = value;
    notifyListeners();
  }

  void clear() {
    entries.clear();
    _textBytes = 0;
    dropped = 0;
    total = 0;
    notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    if (!active || _availableSource == null) return;
    _timer = Timer.periodic(poll, (_) => unawaited(_read()));
  }

  void _changed() {
    if (_disposed) return;
    if (!active) _attempted = null;
    final core = app.state.core;
    final source = _availableSource;
    final selected = app.collection.selected;
    final key = (
      active,
      app.busy,
      app.platformErrorMessage,
      app.configsCurrent,
      app.state.phase,
      app.state.resultId,
      core.identity,
      core.phase,
      core.errorMessage,
      source?.logWindow,
      source?.identity,
      source?.phase,
      selected?.id,
      selected?.revision,
    );
    if (_observed == key) return;
    _observed = key;
    _request++;
    if (!active || app.busy) {
      status = entries.isEmpty ? CoreLogsStatus.loading : CoreLogsStatus.stale;
    } else if (app.platformError != null || !app.state.confirmed) {
      status = CoreLogsStatus.failed;
    } else if (source != null) {
      _attempted = null;
      // Read the captured current/recent window, including after lease release.
      if (_source != null && !_sameSource(_source!, source)) {
        entries.clear();
        _textBytes = 0;
        dropped = 0;
        total = 0;
        _next = 0;
      }
      _schedule();
      unawaited(_read());
      return;
    } else {
      status = entries.isEmpty ? CoreLogsStatus.empty : CoreLogsStatus.stale;
      if (app.state.logSource != null ||
          core.blocked ||
          core.error != null ||
          !app.configsCurrent) {
        status = CoreLogsStatus.failed;
      } else if (!app.state.running &&
          core.phase == 'EMPTY' &&
          selected?.body != null) {
        final identity = (selected!.id, selected.revision);
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
          status = CoreLogsStatus.failed;
        }
      }
    }
    _schedule();
    notifyListeners();
  }

  CoreSnapshot? _source;

  bool _sameSource(CoreSnapshot left, CoreSnapshot right) =>
      left.matchesIdentity(right) && left.logWindow == right.logWindow;

  Future<void> _read() async {
    final expected = _availableSource;
    if (!active ||
        loading ||
        app.busy ||
        app.platformError != null ||
        !app.state.confirmed ||
        expected == null) {
      return;
    }
    if (_source != null && !_sameSource(_source!, expected)) {
      entries.clear();
      _textBytes = 0;
      dropped = 0;
      total = 0;
      _next = 0;
    }
    final request = ++_request;
    loading = true;
    notifyListeners();
    try {
      final value = await app.platform
          .logs(expected, {'after': _next, 'limit': 200})
          .timeout(const Duration(seconds: 3));
      if (!active || request != _request) return;
      final current = _availableSource;
      if (current == null ||
          !_sameSource(expected, current) ||
          !expected.matchesWireIdentity(value)) {
        throw const FormatException('Log context changed');
      }
      final page = value['logs'] as Map;
      if (page['window'] != expected.logWindow) {
        throw const FormatException('Log window changed');
      }
      final rows = (page['entries'] as List).map((item) {
        final row = Map<String, dynamic>.from(item as Map);
        if (row['seq'] is! int ||
            row['level'] is! String ||
            row['time'] is! String ||
            row['text'] is! String) {
          throw const FormatException('Invalid log entry');
        }
        return Map<String, dynamic>.unmodifiable(row);
      }).toList();
      final next = page['next'] as int;
      if (rows.isNotEmpty && next != rows.last['seq']) {
        throw const FormatException('Invalid log page');
      }
      _source = expected;
      total = page['total'] as int;
      dropped = page['dropped'] as int;
      if (rows.isNotEmpty) {
        entries.addAll(rows);
        for (final row in rows) {
          _textBytes += utf8.encode(row['text'] as String).length;
        }
        _next = next;
        var remove = 0;
        while (entries.length - remove > capacity ||
            _textBytes > byteCapacity) {
          _textBytes -= utf8.encode(entries[remove]['text'] as String).length;
          remove++;
        }
        if (remove > 0) entries.removeRange(0, remove);
      }
      status = !expected.ready
          ? CoreLogsStatus.recent
          : expected.purpose == 'VPN'
          ? CoreLogsStatus.live
          : CoreLogsStatus.preview;
    } catch (_) {
      if (!active || request != _request) return;
      status = entries.isEmpty ? CoreLogsStatus.failed : CoreLogsStatus.stale;
    } finally {
      if (!_disposed) {
        loading = false;
        if (request != _request) {
          _observed = null;
          _changed();
        } else {
          notifyListeners();
        }
      }
    }
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    _request++;
    _next = 0;
    entries.clear();
    _textBytes = 0;
    dropped = 0;
    total = 0;
    _attempted = null;
    _observed = null;
    await app.refresh();
    if (!active) return;
    final selected = app.collection.selected;
    if (!app.busy &&
        app.state.logSource == null &&
        !app.state.running &&
        app.state.core.phase == 'EMPTY' &&
        app.state.core.error != null &&
        app.configsCurrent &&
        selected?.body != null) {
      _attempted = (selected!.id, selected.revision);
      await app.submit({
        'action': 'prepareStrategies',
        'id': selected.id,
        'revision': selected.revision,
      });
    } else {
      _changed();
    }
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
