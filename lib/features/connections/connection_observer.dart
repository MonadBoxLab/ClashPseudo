import 'dart:async';

import '../../platform/app_bridge.dart';
import '../overview/traffic_window.dart';
import '../strategies/strategy_snapshot.dart';
import 'connection_window.dart';

class ConnectionObserver {
  ConnectionObserver(this.platform);
  final AppBridge platform;
  final window = ConnectionWindow();
  final traffic = TrafficWindow();
  CoreSnapshot _core = const CoreSnapshot();
  String _phase = 'STOPPED';
  int _session = 0;
  int _now = 0;
  int _token = 0;
  int _failures = 0;
  int? _sampledAt;
  bool _running = false;
  bool _flight = false;
  bool _disposed = false;
  bool _retained = false;
  Timer? _timer;

  bool get retained => window.isNotEmpty;

  void updateState(Map<String, dynamic> value) {
    if (_disposed) return;
    final state = AppSnapshot.fromMap(value);
    final elapsed = value['elapsedMs'];
    if (elapsed is! int || elapsed < 0) {
      throw const FormatException('Missing monotonic time');
    }
    _now = elapsed;
    final running =
        state.running && state.core.ready && state.core.purpose == 'VPN';
    final newSession =
        state.generation != _session &&
        (state.phase == 'STARTING' || state.phase == 'RUNNING');
    final changed =
        newSession ||
        _phase != state.phase ||
        _running != running ||
        (running &&
            (_core.generation != state.core.generation ||
                _core.configId != state.core.configId ||
                _core.revision != state.core.revision));
    if (newSession) {
      window.clear();
      _session = state.generation;
      _core = const CoreSnapshot();
    }
    _phase = state.phase;
    _running = running;
    if (running) _core = state.core;
    if (changed) {
      traffic.clear();
      _token++;
      _sampledAt = null;
      _failures = 0;
      window.invalidate();
      _timer?.cancel();
    }
    if (_phase == 'STOPPED') window.stop(_now);
    window.prune(_now);
    if (changed && !_flight) _schedule(immediate: running);
    _retain();
  }

  Map<String, Object?> snapshot(Map<String, dynamic> state, Map? detail) {
    updateState(state);
    final same =
        detail != null &&
        detail['generation'] == _core.generation &&
        detail['configId'] == _core.configId &&
        detail['revision'] == _core.revision;
    window.pinDetail(same ? detail['id'] as String? : null);
    final sampleAgeMs = _sampledAt == null
        ? null
        : (_now - _sampledAt!).clamp(0, _now);
    final fresh =
        _running &&
        _failures == 0 &&
        sampleAgeMs != null &&
        sampleAgeMs <= ConnectionWindow.maxSpeedIntervalMs;
    if (!fresh) window.invalidate();
    return {
      'generation': _core.generation,
      'configId': _core.configId ?? '',
      'revision': _core.revision ?? 0,
      'sessionGeneration': _session,
      'phase': _phase,
      'fresh': fresh,
      'sampleAgeMs': sampleAgeMs,
      'failed': _failures > 0,
      'limited': window.limited,
      'observedAt': window.observedAt?.millisecondsSinceEpoch,
      'connections': [for (final row in window.records) row.toMap()],
      'detail': window.detail?.toMap(),
      'missingDetailId': window.missingDetailId,
    };
  }

  Map<String, Object?> trafficSnapshot(Map<String, dynamic> state) {
    updateState(state);
    return {
      'generation': _core.generation,
      'configId': _core.configId ?? '',
      'revision': _core.revision ?? 0,
      'sessionGeneration': _session,
      'phase': _phase,
      'failed': _failures > 0,
      ...traffic.snapshot(_now, fresh: _running && _failures == 0),
    };
  }

  void closed(CoreSnapshot core, String id) {
    if (_core.generation != core.generation ||
        _core.configId != core.configId ||
        _core.revision != core.revision) {
      return;
    }
    window.end(id, _now);
    // Discard any native sample begun before this acknowledged close.
    _token++;
    _retain();
  }

  Future<void> _read() async {
    if (_disposed || _flight) return;
    _flight = true;
    var token = _token;
    try {
      updateState(
        await platform.runtimeState().timeout(const Duration(seconds: 5)),
      );
      token = _token;
      if (!_running || _disposed) return;
      final core = _core;
      final parameters = window.parameters;
      final sample = await platform
          .sampleConnections(core, parameters)
          .timeout(const Duration(seconds: 5));
      if (_disposed || token != _token || !_running) return;
      window.accept(sample, core, parameters);
      traffic.accept(sample);
      _now = sample['elapsedMs'] as int;
      _sampledAt = _now;
      _failures = 0;
    } catch (_) {
      if (!_disposed && token == _token) {
        _failures++;
        _sampledAt = null;
        window.invalidate();
        traffic.invalidate();
      }
    } finally {
      _flight = false;
      if (!_disposed) {
        _retain();
        _schedule(immediate: token != _token && _running);
      }
    }
  }

  void _schedule({bool immediate = false}) {
    _timer?.cancel();
    if (_disposed) return;
    int? delay;
    if (_running) {
      const backoff = [1, 2, 5, 10, 30];
      delay = immediate
          ? 0
          : (_failures == 0 ? 1 : backoff[(_failures - 1).clamp(0, 4)]) * 1000;
    } else {
      delay = window.nextExpiry(_now);
      if (delay != null && _failures > 0) delay = delay < 1000 ? 1000 : delay;
    }
    if (delay != null) _timer = Timer(Duration(milliseconds: delay), _read);
  }

  void _retain() {
    final value = retained;
    if (_retained == value) return;
    _retained = value;
    unawaited(platform.retainObservation(value).catchError((Object _) {}));
  }

  void dispose() {
    _disposed = true;
    _token++;
    _timer?.cancel();
  }
}
