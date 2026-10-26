import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../model/definition_provenance.dart';

enum ResourcesStatus { loading, live, preview, stale, empty, failed }

class ResourcesController extends ChangeNotifier {
  ResourcesController(this.app, {this.expectedSource}) {
    app.addListener(_changed);
  }

  final AppController app;
  final CoreSnapshot? expectedSource;
  bool sourceExpired = false;
  ResourcesStatus status = ResourcesStatus.loading;
  List<Map<String, dynamic>> resources = const [];
  final Map<(String, String), String> _updateErrors = {};
  final Set<(String, String)> _updating = {};
  bool loading = false;
  bool _disposed = false;
  bool _visible = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;

  bool get active => !_disposed && _visible && app.foreground;
  bool get canRefresh =>
      active && !sourceExpired && !loading && !app.busy && !updating;

  CoreSnapshot? _source;
  CoreSnapshot? get source => _source;
  bool get current =>
      active &&
      !sourceExpired &&
      !loading &&
      !app.busy &&
      app.platformError == null &&
      app.state.confirmed &&
      _source != null &&
      _matches(_source!, app.state.core) &&
      (status == ResourcesStatus.live || status == ResourcesStatus.preview);

  /// A native update retains its accepted execution lifetime after page dismissal.
  bool get updating => _updating.isNotEmpty;

  bool isUpdating(String kind, String name) => _updating.contains((kind, name));

  String? updateError(String kind, String name) => _updateErrors[(kind, name)];

  /// Render the latest settled manual-update result in a fixed-height slot.
  String? resultKey;
  String? resultCode;

  static String keyOf(String kind, String name) => '$kind/$name';

  static String key(Map<String, dynamic> resource) =>
      keyOf(resource['kind'] as String, resource['name'] as String);

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
      app.configsCurrent,
      app.state.phase,
      app.commandErrorMessage,
      app.state.resultId,
      core.identity,
      core.phase,
      selected?.id,
      selected?.revision,
      core.errorMessage,
    );
    if (_observed == key) return;
    _observed = key;
    if (_source != null && !_matches(_source!, core)) {
      _updateErrors.clear();
      resultKey = null;
      resultCode = null;
    }
    _request++;
    loading = false;
    final expected = expectedSource;
    if (sourceExpired || (expected != null && !_matches(expected, core))) {
      sourceExpired = true;
      status = ResourcesStatus.stale;
      notifyListeners();
      return;
    }
    if (!active || app.busy) {
      status = resources.isEmpty
          ? ResourcesStatus.loading
          : ResourcesStatus.stale;
    } else if (app.platformError != null || !app.state.confirmed) {
      status = ResourcesStatus.failed;
    } else if (core.ready) {
      _attempted = null;
      unawaited(_read(core));
      return;
    } else {
      status = resources.isEmpty
          ? ResourcesStatus.empty
          : ResourcesStatus.stale;
      if (core.blocked || core.error != null || !app.configsCurrent) {
        status = ResourcesStatus.failed;
      } else if (!app.state.running &&
          core.phase == 'EMPTY' &&
          selected?.body != null) {
        final identity = (selected!.id, selected.revision);
        if (_attempted != identity) {
          _attempted = identity;
          status = ResourcesStatus.loading;
          unawaited(
            app.submit({
              'action': 'prepareStrategies',
              'id': selected.id,
              'revision': selected.revision,
            }, automatic: true),
          );
        } else {
          status = ResourcesStatus.failed;
        }
      }
    }
    notifyListeners();
  }

  bool _matches(CoreSnapshot left, CoreSnapshot right) =>
      right.ready && left.matchesIdentity(right);

  /// Read the full list; keep preserves previous rows on failure.
  Future<void> _read(CoreSnapshot expected, {bool keep = false}) async {
    if (!active ||
        sourceExpired ||
        app.busy ||
        app.platformError != null ||
        !app.state.confirmed ||
        (expectedSource != null &&
            !expected.matchesIdentity(expectedSource!))) {
      return;
    }
    final request = ++_request;
    loading = true;
    if (!keep) {
      status = resources.isEmpty
          ? ResourcesStatus.loading
          : ResourcesStatus.stale;
    }
    notifyListeners();
    try {
      final value = await app.platform
          .resources(expected)
          .timeout(const Duration(seconds: 5));
      if (!active || request != _request) return;
      if (!_matches(expected, app.state.core) ||
          !expected.matchesWireIdentity(value) ||
          value['resources'] is! List) {
        throw const FormatException('Resource context changed');
      }
      final rows = (value['resources'] as List).map((item) {
        final row = Map<String, dynamic>.from(item as Map);
        if (row['kind'] is! String ||
            row['name'] is! String ||
            row['vehicleType'] is! String ||
            row['source'] is! String ||
            row['updateSupported'] is! bool) {
          throw const FormatException('Invalid resource');
        }
        final kind = row['kind'] as String;
        if (kind != 'proxyProvider' &&
            kind != 'ruleProvider' &&
            row['provenance'] != null) {
          throw const FormatException('Invalid resource definition provenance');
        }
        if (row.containsKey('provenance')) {
          row['provenance'] = DefinitionProvenance.fromValue(
            row['provenance'],
            section: kind == 'proxyProvider'
                ? 'proxy-providers'
                : 'rule-providers',
          );
        }
        return Map<String, dynamic>.unmodifiable(row);
      }).toList();
      resources = List.unmodifiable(rows);
      _source = expected;
      for (final key in _updateErrors.keys.toList()) {
        if (!rows.any((row) => (row['kind'], row['name']) == key)) {
          _updateErrors.remove(key);
        }
      }
      status = expected.purpose == 'VPN'
          ? ResourcesStatus.live
          : ResourcesStatus.preview;
    } catch (_) {
      if (!active || request != _request) return;
      status = ResourcesStatus.failed;
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Map<String, dynamic>? _find(String kind, String name) {
    for (final row in resources) {
      if (row['kind'] == kind && row['name'] == name) return row;
    }
    return null;
  }

  Future<void> update(String kind, String name) async {
    final row = _find(kind, name);
    final identity = (kind, name);
    if (!current || updating || row == null || row['updateSupported'] != true) {
      return;
    }
    final expected = _source!;
    _updating.add(identity);
    _updateErrors.remove(identity);
    resultKey = keyOf(kind, name);
    resultCode = null;
    notifyListeners();
    try {
      final result = await app.submitAndWait({
        'action': 'updateResource',
        'generation': expected.generation,
        'composition': expected.composition,
        'configId': expected.configId,
        'revision': expected.revision,
        'purpose': expected.purpose,
        'kind': kind,
        'name': name,
      });
      if (_disposed || !_matches(expected, app.state.core)) return;
      if (result?.resultSuccess != true || result?.resourceStatus != 'ok') {
        _updateErrors[identity] = result?.resourceStatus ?? 'updateFailed';
      }
    } catch (_) {
      if (!_disposed && _matches(expected, app.state.core)) {
        _updateErrors[identity] = 'updateFailed';
      }
    } finally {
      if (!_disposed) {
        _updating.remove(identity);
        if (_matches(expected, app.state.core)) {
          resultCode = _updateErrors[identity] ?? 'ok';
        } else {
          resultKey = null;
          resultCode = null;
        }
        notifyListeners();
      }
    }
    // Refresh actual core state after either outcome. Run this follow-up independently
    // of the settled update result; read failure preserves prior rows.
    if (!_disposed &&
        active &&
        !loading &&
        !app.busy &&
        _matches(expected, app.state.core)) {
      unawaited(_read(expected, keep: true));
    }
  }

  Future<void> refresh() async {
    if (!canRefresh) return;
    _attempted = null;
    _observed = null;
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
    app.removeListener(_changed);
    super.dispose();
  }
}
