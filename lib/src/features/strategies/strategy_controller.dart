import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import '../../model/core_snapshot.dart';
import 'delay_result.dart';
import '../mode/tunnel_mode.dart';
import 'strategy_choice.dart';
import 'strategy_snapshot.dart';
import '../../l10n/messages.dart';

class StrategyController extends ChangeNotifier {
  StrategyController(this.app, {this.allGroups = false}) {
    app.addListener(_changed);
  }
  final AppController app;
  final bool allGroups;
  StrategySnapshot? data;
  AppMessage? readErrorMessage;
  String? get readError => readErrorMessage?.text;
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
  // Retain one small current observation per group.
  final _cardDelays =
      <String, ({CoreSnapshot source, DelayMemberResult result})>{};

  DelayMemberResult? cardDelay(StrategyGroup group) {
    final saved = _cardDelays[group.name];
    if (!current ||
        !group.selectable ||
        saved == null ||
        !saved.source.matchesIdentity(app.state.core) ||
        group.currentIdentity.isEmpty ||
        saved.result.name != group.now ||
        saved.result.identity != group.currentIdentity) {
      return null;
    }
    return saved.result;
  }

  void rememberDelay(
    String name,
    CoreSnapshot source,
    Map<String, DelayMemberResult> results,
  ) {
    if (_disposed || !current || !source.matchesIdentity(app.state.core)) {
      return;
    }
    final group = data?.find(name);
    final result = results[group?.now];
    if (group == null || !group.selectable || result == null) return;
    if (result.status == DelayMemberStatus.expired) {
      if (_cardDelays.remove(name) != null) notifyListeners();
      return;
    }
    if (result.identity.isEmpty || result.identity != group.currentIdentity) {
      return;
    }
    if (identical(_cardDelays[name]?.result, result)) return;
    _cardDelays[name] = (source: source, result: result);
    notifyListeners();
  }

  // Called during popup teardown; its route completion rebuilds the cards.
  void finishCardDelay(String name, {bool expired = false}) {
    final result = _cardDelays[name]?.result;
    if (expired ||
        result?.status == DelayMemberStatus.pending ||
        result?.status == DelayMemberStatus.running) {
      _cardDelays.remove(name);
    }
  }

  void _pruneCardDelays() {
    _cardDelays.removeWhere((name, saved) {
      final group = data?.find(name);
      return group == null ||
          !group.selectable ||
          !saved.source.matchesIdentity(app.state.core) ||
          group.currentIdentity.isEmpty ||
          group.currentIdentity != saved.result.identity ||
          group.now != saved.result.name;
    });
  }

  bool get active => !_disposed && _visible && app.foreground;
  bool get current => _fresh && data?.matches(app.state.core) == true;
  bool get canChoose =>
      active &&
      current &&
      app.canEdit &&
      changingGroup == null &&
      app.collection.find(data!.configId) != null &&
      (app.state.running
          ? data!.purpose == 'VPN' &&
                app.state.configId == data!.configId &&
                app.state.revision == data!.revision
          : app.collection.find(data!.configId)?.revision == data!.revision);
  TunnelMode? get mode => app.state.running
      ? app.state.mode
      : current && app.state.core.purpose == 'PREVIEW'
      ? data!.mode
      : null;
  bool _showHidden = false;
  bool get showHidden => _showHidden;

  void setShowHidden(bool value) {
    if (_disposed || _showHidden == value) return;
    _showHidden = value;
    notifyListeners();
  }

  List<StrategyGroup> get groups => allGroups
      ? data?.groups ?? []
      : data?.groups
                .where(
                  (group) =>
                      (_showHidden || !group.hidden) &&
                      (group.name != 'GLOBAL' ||
                          mode == TunnelMode.global ||
                          (mode == TunnelMode.rule && data!.globalReferenced)),
                )
                .toList() ??
            [];
  AppMessage? get operationErrorMessage {
    if (app.commandErrorMessage != null) return app.commandErrorMessage;
    if (const [
          'prepareStrategies',
          'setStrategy',
        ].contains(app.lastCommand?['action']) &&
        app.state.resultId != null &&
        !app.state.resultSuccess) {
      return app.state.resultMessageDescription;
    }
    return null;
  }

  String? get operationError => operationErrorMessage?.text;

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
    if (!active) _attempted = null;
    final state = app.state;
    final core = state.core;
    final selected = app.collection.selected;
    final key = (
      active,
      app.busy,
      app.configsCurrent,
      app.platformErrorMessage,
      app.commandErrorMessage,
      state.phase,
      state.operationMessage,
      state.resultId,
      state.mode,
      core.identity,
      core.phase,
      core.errorMessage,
      selected?.id,
      selected?.revision,
      app.collection.mode,
    );
    if (_observed == key) {
      // Merge saved choices arriving after the platform result within the same
      // context.
      notifyListeners();
      return;
    }
    _observed = key;
    if (data != null && !data!.matches(core)) {
      _cardDelays.clear();
      data = null;
      readErrorMessage = null;
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
    } else if (!state.running && core.phase == 'EMPTY' && selected != null) {
      final identity = (selected.id, selected.revision);
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
      _pruneCardDelays();
      readErrorMessage = null;
      _fresh = true;
      _retryStep = 0;
    } catch (_) {
      if (_disposed || !active || request != _request) return;
      readErrorMessage = messages.strategyStatusStale;
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

  Future<void> choose(String name, String? member, {int? storageEpoch}) async {
    final epoch = storageEpoch ?? app.storageEpoch;
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
      'storageEpoch': epoch,
      'id': actual.configId,
      'revision': actual.revision,
      'generation': actual.generation,
      'composition': actual.composition,
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
    _cardDelays.clear();
    _request++;
    _timer?.cancel();
    app.removeListener(_changed);
    super.dispose();
  }
}
