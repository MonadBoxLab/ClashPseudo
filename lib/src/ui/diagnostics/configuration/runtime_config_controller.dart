import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

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
  String text = '';
  CoreSnapshot? source;
  AppMessage? readError;
  Object? cancelError;
  bool loading = false;
  bool _disposed = false;
  bool _visible = false;
  bool _again = false;
  int _request = 0;
  Object? _observed;
  Object? _attempted;
  Timer? _deadline;
  Timer? _poll;
  int _failures = 0;
  int _pendingDelayMs = 250;

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
    _poll?.cancel();
    _request++;
    _again = false;
    if (!active || app.busy) {
      status = text.isEmpty
          ? RuntimeConfigStatus.loading
          : RuntimeConfigStatus.stale;
    } else if (app.platformError != null || !app.state.confirmed) {
      status = RuntimeConfigStatus.failed;
    } else if (core.ready) {
      _attempted = null;
      unawaited(_read(core));
      return;
    } else {
      status = text.isEmpty
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
    status = text.isEmpty
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
    var pending = false;
    var failed = false;
    try {
      final value = await app.platform.runtimeConfiguration(expected);
      if (_disposed) return;
      if (value['readPending'] == true) {
        pending = true;
        status = text.isEmpty
            ? RuntimeConfigStatus.loading
            : RuntimeConfigStatus.stale;
        return;
      }
      final configuration = value['configuration'];
      if (configuration is! String) {
        throw const FormatException('Runtime configuration is not text');
      }
      source = expected;
      text = configuration;
      cancelError = value['cancelError'];
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
      if (current) {
        _failures = 0;
        _pendingDelayMs = 250;
      }
    } catch (error) {
      if (_disposed) return;
      if (request == _request && _matches(expected, app.state.core)) {
        readError = error is PlatformFailure
            ? messageFromFailure(error, fallback: messages.operationFailed)
            : messages.operationFailed.withDetail(error);
        status = RuntimeConfigStatus.failed;
        failed = true;
      } else {
        status = RuntimeConfigStatus.stale;
      }
    } finally {
      deadline.cancel();
      _deadline = null;
      if (!_disposed) {
        loading = false;
        notifyListeners();
        if (_again) {
          _again = false;
          unawaited(_read(app.state.core));
        } else {
          _scheduleNext(pending: pending, failed: failed);
        }
      }
    }
  }

  void _scheduleNext({required bool pending, required bool failed}) {
    _poll?.cancel();
    if (!active || app.busy || !app.state.core.ready) return;
    final Duration delay;
    if (pending) {
      delay = Duration(milliseconds: _pendingDelayMs);
      _pendingDelayMs = (_pendingDelayMs * 2).clamp(250, 1000);
    } else if (failed) {
      const seconds = [5, 10, 30, 60];
      delay = Duration(
        seconds: seconds[_failures.clamp(0, seconds.length - 1)],
      );
      _failures++;
    } else {
      delay = const Duration(seconds: 30);
    }
    _poll = Timer(delay, () => unawaited(_read(app.state.core)));
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

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _deadline?.cancel();
    _poll?.cancel();
    app.removeListener(_changed);
    super.dispose();
  }
}
