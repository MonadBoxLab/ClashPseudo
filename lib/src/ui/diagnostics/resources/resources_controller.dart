import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../../model/messages.dart';
import '../../../model/application_contract.dart';

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
  Map<String, dynamic>? data;
  final Map<(String, String), AppMessage> _updateErrors = {};
  AppMessage? readError;
  AppMessage? resultMessage;
  CoreSnapshot? resultSource;
  final Set<(String, String)> _updating = {};
  bool loading = false;
  bool _disposed = false;
  bool _visible = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  bool _again = false;
  Timer? _deadline;

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

  bool get _sameUpdateSource =>
      _source != null && resultSource?.matchesIdentity(_source!) == true;

  bool isUpdating(String kind, String name) =>
      _sameUpdateSource && _updating.contains((kind, name));

  AppMessage? updateError(String kind, String name) =>
      _sameUpdateSource ? _updateErrors[(kind, name)] : null;

  /// Latest settled manual-update result, bound to its accepted source.
  String? resultKey;
  String? resultCode;

  static String keyOf(String kind, String name) => '$kind/$name';

  static String key(Map<String, dynamic> resource) => keyOf(
    resource['kind']?.toString() ?? '',
    resource['name']?.toString() ?? '',
  );

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
      app.state.coreDataReady,
      app.state.phase,
      app.state.confirmed,
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
    _request++;
    _again = false;
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
      if (core.blocked ||
          core.errorMessage != null ||
          !app.state.coreDataReady ||
          !app.configsCurrent) {
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
    if (loading) {
      _again = true;
      status = ResourcesStatus.stale;
      notifyListeners();
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
    const grace = Duration(
      milliseconds: ApplicationContract.operationUiGraceMs,
    );
    final deadline = _deadline = Timer(grace, () {
      if (_disposed) return;
      status = ResourcesStatus.stale;
      readError = messages.coreContextUnconfirmed.withDetail(
        TimeoutException('Resource read is still pending', grace),
      );
      notifyListeners();
    });
    try {
      final value = await app.platform.resources(expected);
      if (_disposed) return;
      data = Map.unmodifiable(value);
      final rows = (value['resources'] as List)
          .map((item) => Map<String, dynamic>.unmodifiable(item as Map))
          .toList();
      resources = List.unmodifiable(rows);
      _source = expected;
      readError = null;
      final current =
          active &&
          !sourceExpired &&
          !app.busy &&
          request == _request &&
          value['stale'] != true &&
          _matches(expected, app.state.core) &&
          expected.matchesWireIdentity(value);
      status = !current
          ? ResourcesStatus.stale
          : expected.purpose == 'RUNNING'
          ? ResourcesStatus.live
          : ResourcesStatus.preview;
    } catch (error) {
      if (_disposed) return;
      readError = error is PlatformFailure
          ? messageFromFailure(
              error,
              fallback: const AppMessage('coreReadFailed'),
            )
          : const AppMessage('coreReadFailed').withDetail(error);
      status = ResourcesStatus.failed;
    } finally {
      deadline.cancel();
      _deadline = null;
      if (!_disposed) {
        loading = false;
        notifyListeners();
        if (_again) {
          _again = false;
          unawaited(_read(app.state.core));
        }
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
    if (resultSource?.matchesIdentity(expected) != true) {
      _updateErrors.clear();
    }
    resultSource = expected;
    _updating.add(identity);
    _updateErrors.remove(identity);
    resultKey = keyOf(kind, name);
    resultCode = null;
    resultMessage = null;
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
      if (_disposed) return;
      resultCode = result?.resourceStatus ?? 'unconfirmed';
      resultMessage =
          result?.resultMessageDescription ??
          (result?.resultSuccess == true && resultCode == 'ok'
              ? messages.resourceUpdateSuccess
              : messages.resourceUpdateFailed.withDetail(resultCode));
      if (result?.resultSuccess != true || resultCode != 'ok') {
        _updateErrors[identity] = resultMessage!;
      }
    } catch (error) {
      if (!_disposed) {
        resultCode = 'unconfirmed';
        resultMessage = error is PlatformFailure
            ? messageFromFailure(error, fallback: messages.resourceUpdateFailed)
            : messages.resourceUpdateFailed.withDetail(error);
        _updateErrors[identity] = resultMessage!;
      }
    } finally {
      if (!_disposed) {
        _updating.remove(identity);
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
        app.state.core.errorMessage != null &&
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
    _deadline?.cancel();
    app.removeListener(_changed);
    super.dispose();
  }
}
