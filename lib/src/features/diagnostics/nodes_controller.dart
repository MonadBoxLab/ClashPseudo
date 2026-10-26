import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../model/definition_provenance.dart';

class NodesController extends ChangeNotifier {
  NodesController(this.app, {this.provider, this.expectedSource}) {
    app.addListener(_changed);
  }
  final AppController app;
  final String? provider;
  final CoreSnapshot? expectedSource;
  bool sourceExpired = false;
  List<Map<String, dynamic>> nodes = const [];
  int total = 0;
  int offset = 0;
  int nextOffset = -1;
  String search = '';
  String? token;
  bool loading = false;
  bool failed = false;
  bool current = false;
  bool _visible = false;
  bool _disposed = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  CoreSnapshot? _source;
  String? _loadedSearch;
  Timer? _debounce;
  Timer? _retry;
  bool _reading = false;
  int? _queuedStart;
  int _retryMs = 250;

  static const pageSize = 50;
  bool get active => !_disposed && _visible && app.foreground;
  bool get canRead =>
      active &&
      !sourceExpired &&
      !app.busy &&
      app.platformError == null &&
      app.state.confirmed;
  bool get canPage => canRead && current && !loading;
  bool get preview => _source?.purpose == 'PREVIEW';
  CoreSnapshot? get source => _source;

  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    if (!active) _attempted = null;
    final core = app.state.core;
    final selected = app.collection.selected;
    final key = (
      active,
      app.busy,
      app.platformErrorMessage,
      app.state.phase,
      core.identity,
      core.phase,
      core.errorMessage,
      app.configsCurrent,
      selected?.id,
      selected?.revision,
      app.commandErrorMessage,
      app.state.resultId,
    );
    if (_observed == key) return;
    _observed = key;
    _request++;
    _debounce?.cancel();
    _retry?.cancel();
    _queuedStart = null;
    _retryMs = 250;
    loading = false;
    current = false;
    final expected = expectedSource;
    if (sourceExpired ||
        (expected != null &&
            (!core.ready || !core.matchesIdentity(expected)))) {
      sourceExpired = true;
      failed = false;
      notifyListeners();
      return;
    }
    if (!canRead) {
      failed = active && !app.busy;
    } else if (core.ready) {
      _attempted = null;
      final sameSource =
          _source?.matchesIdentity(core) == true && _loadedSearch == search;
      unawaited(_read(sameSource ? offset : 0));
      return;
    } else if (core.blocked || core.error != null || !app.configsCurrent) {
      failed = true;
    } else if (!app.state.running &&
        core.phase == 'EMPTY' &&
        selected?.body != null) {
      final identity = (selected!.id, selected.revision);
      if (_attempted != identity) {
        _attempted = identity;
        failed = false;
        unawaited(
          app.submit({
            'action': 'prepareStrategies',
            'id': selected.id,
            'revision': selected.revision,
          }, automatic: true),
        );
      } else {
        failed = true;
      }
    }
    notifyListeners();
  }

  void filter(String text) {
    final value = text.trim();
    if (search == value || _disposed) return;
    search = value;
    _request++;
    current = false;
    loading = canRead && (loading || _reading);
    failed = false;
    _queuedStart = null;
    _retryMs = 250;
    _retry?.cancel();
    _debounce?.cancel();
    if (canRead && app.state.core.ready) {
      _debounce = Timer(const Duration(milliseconds: 250), () => _read(0));
    }
    notifyListeners();
  }

  Future<void> _read(int start) async {
    if (!canRead || !app.state.core.ready) return;
    if (_reading) {
      // Retain the latest intent while the native read slot is occupied.
      _queuedStart = start;
      loading = true;
      notifyListeners();
      return;
    }
    _reading = true;
    _queuedStart = null;
    _retry?.cancel();
    var waiting = false;
    final expected = app.state.core;
    final request = ++_request;
    loading = true;
    current = false;
    failed = false;
    notifyListeners();
    try {
      final value = await app.platform
          .nodes(expected, {
            if (provider != null) 'source': provider,
            'offset': start,
            'limit': pageSize,
            'search': search,
            'token': start == 0 ? '' : token,
          })
          .timeout(const Duration(seconds: 5));
      if (!active || request != _request) return;
      final core = app.state.core;
      if (!core.ready ||
          !core.matchesIdentity(expected) ||
          !expected.matchesWireIdentity(value)) {
        throw const FormatException('Node context changed');
      }
      if (value['readPending'] == true) {
        waiting = true;
        _retry = Timer(Duration(milliseconds: _retryMs), () => _read(start));
        _retryMs = (_retryMs * 2).clamp(250, 1000);
        return;
      }
      final page = value['page'] as Map;
      final count = page['total'] as int;
      final next = page['nextOffset'] as int;
      final version = page['token'] as String;
      final rows = (page['nodes'] as List).map((item) {
        final row = Map<String, dynamic>.from(item as Map);
        if (row['name'] is! String ||
            row['source'] is! String ||
            !const [
              'configuration',
              'proxyProvider',
            ].contains(row['sourceKind']) ||
            (provider != null &&
                (row['sourceKind'] != 'proxyProvider' ||
                    row['source'] != provider)) ||
            row['sourceVersion'] is! int ||
            (row['sourceVersion'] as int) < 0 ||
            (row['sourceVersion'] as int) > 0xffffffff ||
            (row['sourceKind'] == 'configuration' &&
                row['sourceVersion'] != 0) ||
            row['type'] is! String ||
            row['builtin'] is! bool) {
          throw const FormatException('Invalid node');
        }
        final provenance = DefinitionProvenance.fromValue(
          row['provenance'],
          section: 'proxies',
        );
        final providerProvenance = DefinitionProvenance.fromValue(
          row['providerProvenance'],
          section: 'proxy-providers',
        );
        if ((row['sourceKind'] == 'proxyProvider' && provenance != null) ||
            (row['sourceKind'] == 'configuration' &&
                providerProvenance != null) ||
            (row['builtin'] == true && provenance != null)) {
          throw const FormatException('Invalid node definition provenance');
        }
        if (row.containsKey('provenance')) row['provenance'] = provenance;
        if (row.containsKey('providerProvenance')) {
          row['providerProvenance'] = providerProvenance;
        }
        return Map<String, dynamic>.unmodifiable(row);
      }).toList();
      if (rows.length > pageSize ||
          count < start + rows.length ||
          version.length != 64 ||
          (start > 0 && version != token) ||
          (next != -1 &&
              (next != start + rows.length || next >= count || rows.isEmpty))) {
        throw const FormatException('Invalid node page');
      }
      nodes = List.unmodifiable(rows);
      total = count;
      offset = start;
      nextOffset = next;
      token = version;
      _source = expected;
      _loadedSearch = search;
      _retryMs = 250;
      current = true;
    } catch (_) {
      if (!active || request != _request) return;
      failed = true;
    } finally {
      _reading = false;
      if (!_disposed && request == _request) {
        loading = waiting;
        notifyListeners();
      }
      final queued = _queuedStart;
      _queuedStart = null;
      if (queued != null && canRead && app.state.core.ready) {
        unawaited(_read(queued));
      }
    }
  }

  Future<void> next() async {
    if (canPage && nextOffset >= 0) await _read(nextOffset);
  }

  Future<void> previous() async {
    if (canPage && offset > 0) {
      await _read((offset - pageSize).clamp(0, offset));
    }
  }

  Future<void> refresh() async {
    if (!active || loading || app.busy) return;
    _attempted = null;
    _observed = null;
    _loadedSearch = null;
    await app.refresh();
    if (!active) return;
    final selected = app.collection.selected;
    if (!app.busy &&
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
    _debounce?.cancel();
    _retry?.cancel();
    _queuedStart = null;
    app.removeListener(_changed);
    super.dispose();
  }
}
