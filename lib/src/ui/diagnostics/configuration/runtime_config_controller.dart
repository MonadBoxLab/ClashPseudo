import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../../model/messages.dart';
import '../../../model/application_contract.dart';

enum RuntimeConfigStatus { loading, live, preview, stale, empty, failed }

class RuntimeConfigController extends ChangeNotifier {
  RuntimeConfigController(this.app) {
    app.addListener(_changed);
  }

  final AppController app;
  RuntimeConfigStatus status = RuntimeConfigStatus.loading;
  List<String> lines = const [];
  Map<String, dynamic>? data;
  AppMessage? readError;
  bool loading = false;
  bool _disposed = false;
  bool _visible = false;
  bool _again = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  CoreSnapshot? _source;
  Timer? _deadline;

  bool get active => !_disposed && _visible && app.foreground;
  bool get canRefresh => active && !loading && !app.busy;

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
      app.state.confirmed,
      app.state.mode,
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
    if (!active || app.busy) {
      status = lines.isEmpty
          ? RuntimeConfigStatus.loading
          : RuntimeConfigStatus.stale;
    } else if (app.platformError != null || !app.state.confirmed) {
      status = RuntimeConfigStatus.failed;
    } else if (core.ready) {
      _attempted = null;
      unawaited(_read(core));
      return;
    } else {
      status = lines.isEmpty
          ? RuntimeConfigStatus.empty
          : RuntimeConfigStatus.stale;
      if (core.blocked || core.errorMessage != null || !app.configsCurrent) {
        status = RuntimeConfigStatus.failed;
      } else if (!app.state.running &&
          core.phase == 'EMPTY' &&
          selected?.body != null) {
        final identity = (selected!.id, selected.revision);
        if (_attempted != identity) {
          _attempted = identity;
          status = RuntimeConfigStatus.loading;
          // Use the existing single-writer preview preparation path.
          unawaited(
            app.submit({
              'action': 'prepareStrategies',
              'id': selected.id,
              'revision': selected.revision,
            }, automatic: true),
          );
        } else {
          status = RuntimeConfigStatus.failed;
        }
      }
    }
    notifyListeners();
  }

  bool _matches(CoreSnapshot left, CoreSnapshot right) =>
      right.ready && left.matchesIdentity(right);

  Future<void> _read(CoreSnapshot expected) async {
    if (!active ||
        app.busy ||
        app.platformError != null ||
        !app.state.confirmed ||
        !expected.ready) {
      return;
    }
    if (loading) {
      _again = true;
      status = RuntimeConfigStatus.stale;
      notifyListeners();
      return;
    }
    final request = ++_request;
    loading = true;
    status = lines.isEmpty
        ? RuntimeConfigStatus.loading
        : RuntimeConfigStatus.stale;
    notifyListeners();
    const grace = Duration(
      milliseconds: ApplicationContract.operationUiGraceMs,
    );
    final deadline = _deadline = Timer(grace, () {
      if (_disposed) return;
      status = RuntimeConfigStatus.stale;
      notifyListeners();
    });
    try {
      final value = await app.platform.runtimeConfiguration(expected);
      if (_disposed) return;
      data = Map.unmodifiable(value);
      lines = List.unmodifiable(
        const JsonEncoder.withIndent('  ')
            .convert(value['configuration'])
            .split('\n'),
      );
      _source = expected;
      readError = null;
      final current =
          active &&
          !app.busy &&
          app.platformError == null &&
          app.state.confirmed &&
          request == _request &&
          value['stale'] != true &&
          _matches(expected, app.state.core) &&
          expected.matchesWireIdentity(value);
      status = !current
          ? RuntimeConfigStatus.stale
          : expected.purpose == 'RUNNING'
          ? RuntimeConfigStatus.live
          : RuntimeConfigStatus.preview;
    } catch (error) {
      if (_disposed) return;
      readError = error is PlatformFailure
          ? messageFromFailure(error, fallback: messages.operationFailed)
          : messages.operationFailed.withDetail(error);
      status = RuntimeConfigStatus.failed;
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

  Future<void> refresh() async {
    if (!canRefresh) return;
    _attempted = null;
    _observed = null;
    await app.refresh();
    if (!active) return;
    // Retry preview preparation only after confirmed cleanup of the previous lease.
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

  bool get hasCurrentSource =>
      active &&
      !loading &&
      !app.busy &&
      app.platformError == null &&
      app.state.confirmed &&
      (status == RuntimeConfigStatus.live ||
          status == RuntimeConfigStatus.preview) &&
      _source != null &&
      _matches(_source!, app.state.core);

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _deadline?.cancel();
    app.removeListener(_changed);
    super.dispose();
  }
}
