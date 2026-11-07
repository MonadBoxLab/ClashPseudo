import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import '../../model/app_platform.dart';
import 'traffic_window.dart';
import 'connection_window.dart';

class ConnectionObserver {
  ConnectionObserver(this.platform);
  static int _nextOwner = 0;
  final String _owner =
      'connections-observer:${DateTime.now().microsecondsSinceEpoch}:${_nextOwner++}';
  String? _detailOwner;
  final AppPlatform platform;
  final window = ConnectionWindow();
  final traffic = TrafficWindow();
  CoreSnapshot _core = const CoreSnapshot();
  String _phase = 'STOPPED';
  int _session = 0;
  int _now = 0;
  int _token = 0;
  int _failures = 0;
  String? _error;
  int? _sampledAt;
  bool _running = false;
  bool _flight = false;
  bool _disposed = false;
  bool? _retained = false;
  Future<void>? _retainFlight;
  String? _retainError;
  Timer? _timer;
  Timer? _deadline;

  String? get _latestError {
    final errors = [?_error, ?_retainError];
    return errors.isEmpty ? null : errors.join('\n');
  }

  bool get retained => window.isNotEmpty;

  void updateState(Map<String, dynamic> value) {
    if (_disposed) return;
    final state = AppSnapshot.fromMap(value);
    final elapsed = value['elapsedMs'];
    if (elapsed is! int || elapsed < 0) {
      throw const FormatException('Missing monotonic time');
    }
    _now = elapsed;
    final running = state.forwarding;
    final newSession =
        running &&
        (_core.processId != state.core.processId ||
            state.generation != _session);
    final phase = running ? 'RUNNING' : state.phase;
    final changed =
        newSession ||
        _phase != phase ||
        _running != running ||
        (running &&
            (_core.generation != state.core.generation ||
                _core.configId != state.core.configId ||
                _core.revision != state.core.revision ||
                _core.composition != state.core.composition));
    if (newSession) {
      window.clear();
      _session = state.generation;
      _core = const CoreSnapshot();
    }
    _phase = phase;
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

  Map<String, Object?> snapshot(
    Map<String, dynamic> state,
    Map? detail, {
    String? detailOwner,
  }) {
    if (detail != null && (detailOwner == null || detailOwner.isEmpty)) {
      throw ArgumentError.value(detailOwner, 'detailOwner');
    }
    updateState(state);
    final same =
        detail != null &&
        detail['processId'] == _core.processId &&
        detail['inputId'] == _core.inputId &&
        detail['generation'] == _core.generation &&
        detail['configId'] == _core.configId &&
        detail['revision'] == _core.revision &&
        detail['composition'] == _core.composition &&
        detail['purpose'] == _core.purpose;
    if (same) {
      _detailOwner = detailOwner;
      window.pinDetail(detail['id'] as String?);
    } else if (detail != null && detailOwner == _detailOwner) {
      releaseDetail(detailOwner!);
    }
    // A list/traffic reader is not a detail owner and cannot revoke its lease.
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
      'processId': _core.processId,
      'inputId': _core.inputId,
      'networkRevision': _core.networkRevision,
      'generation': _core.generation,
      'configId': _core.configId ?? '',
      'revision': _core.revision ?? 0,
      'sessionGeneration': _session,
      'fresh': fresh,
      'sampleAgeMs': sampleAgeMs,
      'error': _latestError,
      'limited': window.limited,
      'activeCount': window.activeCount,
      'omitted': window.omitted,
      'retainedBytes': window.retainedBytes,
      'connections': [for (final row in window.records) row.toMap()],
      'detail': window.detail?.toMap(),
      'missingDetailId': window.missingDetailId,
      'releasedDetailId': same && window.detail == null ? detail['id'] : null,
      'composition': _core.composition,
      'purpose': _core.purpose,
    };
  }

  void releaseDetail(String owner) {
    if (owner != _detailOwner) return;
    _detailOwner = null;
    window.pinDetail(null);
    _retain();
  }

  Map<String, Object?> trafficSnapshot(Map<String, dynamic> state) {
    updateState(state);
    return {
      'processId': _core.processId,
      'inputId': _core.inputId,
      'networkRevision': _core.networkRevision,
      'generation': _core.generation,
      'configId': _core.configId ?? '',
      'revision': _core.revision ?? 0,
      'sessionGeneration': _session,
      'phase': _phase,
      'failed': _failures > 0,
      'error': _latestError,
      'composition': _core.composition,
      ...traffic.snapshot(_now, fresh: _running && _failures == 0),
    };
  }

  void clearInactive() {
    window.clearInactive();
    _token++;
    _retain();
    if (!_flight) _schedule(immediate: _running);
  }

  void closed(CoreSnapshot core, String id) {
    if (!_core.matchesIdentity(core)) return;
    window.end(id, _now);
    // Discard any native sample begun before this acknowledged close.
    _token++;
    _retain();
  }

  Future<void> _read() async {
    if (_disposed || _flight) return;
    _flight = true;
    final admission = Stopwatch()..start();
    var token = _token;
    var expired = false;
    final deadline = _deadline = Timer(const Duration(seconds: 5), () {
      if (_disposed || token != _token) return;
      expired = true;
      _error = TimeoutException('Connection observation is still in progress')
          .toString();
      _failures++;
      _sampledAt = null;
      window.invalidate();
      traffic.invalidate();
    });
    try {
      // Keep the slot occupied until the Future exits; do not run or accept this
      // read-only sample after expiry.
      updateState(await platform.runtimeState());
      token = _token;
      if (!_running || _disposed || expired) return;
      final core = _core;
      final admittedAt = _now - admission.elapsedMilliseconds;
      final parameters = <String, Object?>{
        ...window.parameters,
        'admittedAt': admittedAt,
        'deadline': admittedAt + 5000,
      };
      final sample = await platform.sampleConnections(core, parameters);
      if (_disposed || expired || token != _token || !_running) return;
      window.accept(sample, core, parameters);
      traffic.accept(sample);
      _now = sample['elapsedMs'] as int;
      _sampledAt = _now;
      _failures = 0;
      _error = null;
    } catch (error) {
      if (!_disposed && !expired && token == _token) {
        _error = error.toString();
        _failures++;
        _sampledAt = null;
        window.invalidate();
        traffic.invalidate();
      }
    } finally {
      deadline.cancel();
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
    final value = !_disposed && retained;
    if (_retained == value || _retainFlight != null) return;
    // Serialize retain/release acknowledgments; a stale completion must not
    // overwrite the state of a newer lease, and failures stay visible/retryable.
    final flight = Future<void>.sync(
      () => platform.retainObservation(value, owner: _owner),
    );
    _retainFlight = flight;
    unawaited(() async {
      try {
        await flight;
        _retained = value;
        _retainError = null;
      } catch (failure) {
        // The host may have applied the lease before delivery failed. Its state
        // is unknown until an owner-scoped acknowledgment, including on dispose.
        _retained = null;
        _retainError = failure.toString();
      } finally {
        _retainFlight = null;
        if (value != (!_disposed && retained)) _retain();
      }
    }());
  }

  void dispose() {
    _disposed = true;
    _token++;
    _timer?.cancel();
    _deadline?.cancel();
    _retain();
  }
}
