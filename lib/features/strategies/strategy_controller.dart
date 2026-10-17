import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../mode/tunnel_mode.dart';
import 'strategy_choice.dart';
import 'strategy_snapshot.dart';

class StrategyController extends ChangeNotifier {
  StrategyController(this.app) {
    app.addListener(_changed);
  }
  final AppController app;
  StrategySnapshot? data;
  String? readError;
  String? changingGroup;
  bool loading = false;
  bool _visible = false;
  bool _fresh = false;
  bool _disposed = false;
  bool _again = false;
  bool _allowRetry = false;
  int _request = 0;
  int _retryStep = 0;
  Timer? _timer;
  Object? _observed;
  (String, int)? _attempted;

  bool get active => !_disposed && _visible && app.foreground;
  bool get current => _fresh && data?.matches(app.state.core) == true;
  bool get canChoose =>
      active &&
      current &&
      app.canEdit &&
      changingGroup == null &&
      app.collection.find(data!.configId)?.revision == data!.revision &&
      app.collection.find(data!.configId)?.body != null;
  TunnelMode? get mode => app.state.running
      ? app.state.mode
      : app.configsCurrent
      ? app.collection.mode
      : null;
  List<StrategyGroup> get groups =>
      data?.groups
          .where(
            (group) =>
                !group.hidden &&
                (group.name != 'GLOBAL' ||
                    mode == TunnelMode.global ||
                    (mode == TunnelMode.rule && data!.globalReferenced)),
          )
          .toList() ??
      [];
  String? get operationError {
    if (app.commandError != null) return app.commandError;
    if (const [
          'prepareStrategies',
          'setStrategy',
        ].contains(app.lastCommand?['action']) &&
        app.state.resultId != null &&
        !app.state.resultSuccess) {
      return app.state.resultMessage;
    }
    return null;
  }

  void setVisible(bool visible) {
    if (_disposed || _visible == visible) return;
    _visible = visible;
    _observed = null;
    _invalidate();
    _changed();
  }

  void _invalidate() {
    _request++;
    _timer?.cancel();
    loading = false;
    _again = false;
    _fresh = false;
  }

  void _changed() {
    if (_disposed) return;
    final state = app.state;
    final core = state.core;
    final selected = app.collection.selected;
    final key = (
      active,
      app.loading,
      app.dispatching,
      app.configsCurrent,
      app.platformError,
      app.commandError,
      state.phase,
      state.operation,
      state.resultId,
      state.mode,
      core.generation,
      core.phase,
      core.purpose,
      core.configId,
      core.revision,
      core.error,
      selected?.id,
      selected?.revision,
      selected?.body == null,
      app.collection.mode,
    );
    if (_observed == key) {
      // Saved choices can arrive after the platform result without a new context.
      notifyListeners();
      return;
    }
    _observed = key;
    if (data != null && !data!.matches(core)) {
      data = null;
      readError = null;
      changingGroup = null;
      _invalidate();
    }
    if (!active ||
        app.busy ||
        !app.configsCurrent ||
        app.platformError != null ||
        !state.confirmed) {
      _invalidate();
      notifyListeners();
      return;
    }
    if (core.ready) {
      _attempted = null;
      unawaited(_read());
    } else if (!state.running &&
        !state.needsHttpConfirmation &&
        core.phase == 'EMPTY' &&
        selected?.body != null) {
      final identity = (selected!.id, selected.revision);
      final failedHere =
          core.error != null &&
          core.configId == selected.id &&
          core.revision == selected.revision;
      if (_attempted != identity && (!failedHere || _allowRetry)) {
        _attempted = identity;
        final automatic = !_allowRetry;
        _allowRetry = false;
        unawaited(
          app.submit({
            'action': 'prepareStrategies',
            'id': selected.id,
            'revision': selected.revision,
          }, automatic: automatic),
        );
      }
    }
    notifyListeners();
  }

  Future<void> _read() async {
    if (_disposed || !active || app.busy || !app.state.core.ready) return;
    _timer?.cancel();
    if (loading) {
      _again = true;
      return;
    }
    loading = true;
    final request = ++_request;
    final expected = app.state.core;
    try {
      final value = await app.platform
          .strategies(expected.generation)
          .timeout(const Duration(seconds: 5));
      if (_disposed || !active || request != _request) return;
      if (!value.matches(app.state.core)) {
        throw const FormatException('Strategy context changed');
      }
      data = value;
      readError = null;
      _fresh = true;
      _retryStep = 0;
    } catch (_) {
      if (_disposed || !active || request != _request) return;
      readError = '策略状态暂未更新，前台将自动重试；旧记录不能用于切换。';
      _fresh = false;
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        if (!app.busy) changingGroup = null;
        notifyListeners();
        if (active) {
          if (_again) {
            _again = false;
            unawaited(_read());
          } else {
            const backoff = [1, 2, 5, 10, 30];
            final seconds = readError == null ? 5 : backoff[_retryStep];
            if (readError != null && _retryStep < backoff.length - 1) {
              _retryStep++;
            }
            _timer = Timer(
              Duration(seconds: seconds),
              () => unawaited(_read()),
            );
          }
        }
      }
    }
  }

  Future<void> retry() async {
    if (_disposed || !active || app.busy || app.state.core.blocked) return;
    _attempted = null;
    _allowRetry = true;
    _observed = null;
    await app.refresh();
    _changed();
  }

  Future<void> choose(String name, String? member) async {
    if (!canChoose) return;
    final group = data!.find(name);
    if (group == null ||
        !group.selectable ||
        (member == null && !group.automatic) ||
        (member != null && !group.hasMember(member))) {
      return;
    }
    final actual = data!;
    changingGroup = name;
    notifyListeners();
    await app.submit({
      'action': 'setStrategy',
      'id': actual.configId,
      'revision': actual.revision,
      'generation': actual.generation,
      'name': name,
      'choice': StrategyChoice(type: group.type!, member: member).toJson(),
    });
    if (_disposed) return;
    if (app.commandError != null) changingGroup = null;
    notifyListeners();
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
