import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../model/definition_provenance.dart';

class RulesController extends ChangeNotifier {
  RulesController(this.app, {String? provider, this.expectedSource}) {
    if (provider != null) {
      kind = 'provider';
      name = provider;
    }
    app.addListener(_changed);
  }
  final AppController app;
  final CoreSnapshot? expectedSource;
  bool sourceExpired = false;
  List<Map<String, dynamic>> rows = const [];
  List<Map<String, dynamic>> scopes = const [];
  String kind = 'main';
  String name = '';
  String search = '';
  String origin = '';
  DefinitionProvenance? providerProvenance;
  String? sourceError;
  int offset = 0;
  int total = 0;
  int nextOffset = -1;
  String? token;
  String? sourceToken;
  bool loading = false;
  bool failed = false;
  bool current = false;
  bool _visible = false;
  bool _disposed = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  CoreSnapshot? _source;
  Object? _loadedQuery;
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
      final same = _source?.matchesIdentity(core) == true;
      if (!same && _source != null) {
        kind = 'main';
        name = '';
      }
      unawaited(
        _read(same && _loadedQuery == (kind, name, search) ? offset : 0),
      );
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

  void selectScope(String scopeKind, String scopeName) {
    if (!canRead ||
        (kind == scopeKind && name == scopeName) ||
        !scopes.any(
          (scope) => scope['kind'] == scopeKind && scope['name'] == scopeName,
        )) {
      return;
    }
    kind = scopeKind;
    name = scopeName;
    _request++;
    _queuedStart = null;
    _retryMs = 250;
    _retry?.cancel();
    _debounce?.cancel();
    unawaited(_read(0));
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
    sourceError = null;
    notifyListeners();
    try {
      final value = await app.platform
          .rules(expected, {
            'kind': kind,
            'name': name,
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
        throw const FormatException('Rule context changed');
      }
      if (value['readPending'] == true) {
        waiting = true;
        _retry = Timer(Duration(milliseconds: _retryMs), () => _read(start));
        _retryMs = (_retryMs * 2).clamp(250, 1000);
        return;
      }
      final page = value['page'] as Map;
      if (page['error'] != null) {
        sourceError = page['error'] as String?;
        throw FormatException('Rule source: $sourceError');
      }
      final count = page['total'] as int;
      final next = page['nextOffset'] as int;
      final version = page['token'] as String;
      final sourceVersion = page['sourceToken'] as String;
      final items = (page['rows'] as List).map((item) {
        final row = Map<String, dynamic>.from(item as Map);
        if (row['index'] is! int ||
            row['type'] is! String ||
            row['payload'] is! String ||
            row['target'] is! String ||
            row['providers'] is! List ||
            (row['providers'] as List).any((name) => name is! String) ||
            (row['resources'] != null &&
                (row['resources'] is! List ||
                    (row['resources'] as List).any(
                      (name) => !const [
                        'GeoIP',
                        'MMDB',
                        'GeoSite',
                        'ASN',
                      ].contains(name),
                    )))) {
          throw const FormatException('Invalid rule row');
        }
        if (kind == 'provider' && row['provenance'] != null) {
          throw const FormatException('Provider content is not a definition');
        }
        if (row.containsKey('provenance')) {
          row['provenance'] = DefinitionProvenance.fromValue(
            row['provenance'],
            section: kind == 'sub' ? 'sub-rules' : 'rules',
          );
        }
        return Map<String, dynamic>.unmodifiable(row);
      }).toList();
      final choices = (page['scopes'] as List).map((item) {
        final scope = Map<String, dynamic>.from(item as Map);
        if (scope['kind'] != 'provider' && scope['provenance'] != null) {
          throw const FormatException('Invalid rule scope provenance');
        }
        if (scope.containsKey('provenance')) {
          scope['provenance'] = DefinitionProvenance.fromValue(
            scope['provenance'],
            section: 'rule-providers',
          );
        }
        return Map<String, dynamic>.unmodifiable(scope);
      }).toList();
      if (kind != 'provider' && page['providerProvenance'] != null) {
        throw const FormatException('Invalid rule provider provenance');
      }
      final providerOrigin = DefinitionProvenance.fromValue(
        page['providerProvenance'],
        section: 'rule-providers',
      );
      if (items.length > pageSize ||
          count < start + items.length ||
          version.length != 64 ||
          sourceVersion.length != 64 ||
          (start > 0 && version != token) ||
          (next != -1 &&
              (next != start + items.length ||
                  next >= count ||
                  items.isEmpty)) ||
          choices.any(
            (scope) =>
                scope['name'] is! String ||
                scope['count'] is! int ||
                !const ['main', 'sub', 'provider'].contains(scope['kind']),
          )) {
        throw const FormatException('Invalid rule page');
      }
      origin = page['origin'] as String;
      providerProvenance = providerOrigin;
      rows = List.unmodifiable(items);
      scopes = List.unmodifiable(choices);
      total = count;
      offset = start;
      nextOffset = next;
      token = version;
      sourceToken = sourceVersion;
      _source = expected;
      _loadedQuery = (kind, name, search);
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
    if (canPage && nextOffset >= 0) {
      await _read(nextOffset);
    }
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
    _loadedQuery = null;
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
