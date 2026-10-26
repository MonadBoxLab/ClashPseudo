import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/app_controller.dart';
import 'traffic_window.dart';
import '../../l10n/messages.dart';

class TrafficController extends ChangeNotifier {
  TrafficController(this.app, {Stopwatch? clock})
    : _clock = clock ?? Stopwatch() {
    _clock.start();
    app.addListener(_changed);
  }

  final AppController app;
  final Stopwatch _clock;
  TrafficSnapshot? _data;
  Object? _observed;
  Timer? _timer;
  Timer? _expiry;
  int _receivedAt = 0;
  int _request = 0;
  int _failures = 0;
  bool _visible = false;
  bool _flight = false;
  bool _disposed = false;
  bool _confirmed = false;
  AppMessage? errorMessage;
  Timer? _memoryTimer;
  Timer? _memoryExpiry;
  bool _memoryFlight = false;
  int? _processRssBytes;
  int? _memoryReceivedAt;
  bool memoryUnavailable = false;

  int? get processRssBytes =>
      active &&
          !memoryUnavailable &&
          _memoryReceivedAt != null &&
          _clock.elapsedMilliseconds - _memoryReceivedAt! <= 5000
      ? _processRssBytes
      : null;

  String? get error => errorMessage?.text;

  bool get available =>
      app.state.running &&
      app.state.core.ready &&
      app.state.core.purpose == 'VPN';
  bool get active => !_disposed && _visible && app.foreground;
  TrafficSnapshot? get data => !available
      ? null
      : _data?.at(
          _data!.elapsedMs + _clock.elapsedMilliseconds - _receivedAt,
          unavailable: !active || !_confirmed || error != null,
        );

  void setVisible(bool value) {
    if (_disposed || value == _visible) return;
    _visible = value;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    final core = app.state.core;
    final key = (
      _visible,
      app.foreground,
      app.state.phase,
      app.state.generation,
      core.generation,
      core.phase,
      core.purpose,
      core.configId,
      core.revision,
      core.composition,
    );
    if (_observed == key) return;
    _observed = key;
    _request++;
    _timer?.cancel();
    _expiry?.cancel();
    _memoryTimer?.cancel();
    _memoryExpiry?.cancel();
    _processRssBytes = null;
    _memoryReceivedAt = null;
    memoryUnavailable = false;
    _confirmed = false;
    _failures = 0;
    errorMessage = null;
    if (!available ||
        _data?.matches(core) != true ||
        _data?.sessionGeneration != app.state.generation) {
      _data = null;
    }
    notifyListeners();
    if (active) unawaited(_readMemory());
    if (active && available) {
      _expire();
      unawaited(_read());
    }
  }

  Future<void> _read() async {
    if (!active || !available || _flight) return;
    _flight = true;
    final request = _request;
    final began = _clock.elapsedMilliseconds;
    bool valid() => active && available && request == _request;
    try {
      final result = await app.platform.traffic().timeout(
        const Duration(seconds: 5),
      );
      if (!valid()) return;
      if (result.phase != 'RUNNING' ||
          result.sessionGeneration != app.state.generation ||
          !result.matches(app.state.core)) {
        throw const FormatException('Traffic session changed');
      }
      _receivedAt = _clock.elapsedMilliseconds;
      // Include the round trip rather than making a delayed reply look new.
      _data = result.at(result.elapsedMs + _receivedAt - began);
      _confirmed = true;
      errorMessage = result.failed ? messages.trafficUpdateFailed : null;
      _failures = 0;
    } catch (_) {
      if (!valid()) return;
      _confirmed = false;
      errorMessage = messages.trafficUpdateFailed;
      _failures++;
    } finally {
      _flight = false;
      if (!_disposed) {
        notifyListeners();
        _expire();
        if (active && available) {
          const backoff = [1, 2, 5, 10, 30];
          final seconds = request != _request
              ? 0
              : _failures == 0
              ? 1
              : backoff[(_failures - 1).clamp(0, 4)];
          _timer = Timer(Duration(seconds: seconds), _read);
        }
      }
    }
  }

  Future<void> _readMemory() async {
    if (!active || _memoryFlight) return;
    _memoryFlight = true;
    final request = _request;
    final began = _clock.elapsedMilliseconds;
    bool valid() => active && request == _request;
    try {
      // Read the process-local snapshot and retain its gate until the bridge Future
      // settles.
      final value = await app.platform.processMemory();
      if (!valid()) return;
      final bytes = value['processRssBytes'];
      final sampledAt = value['sampledAt'];
      final now = DateTime.now().millisecondsSinceEpoch;
      if (value['valid'] != true ||
          bytes is! int ||
          bytes < 0 ||
          sampledAt is! int ||
          sampledAt <= 0 ||
          sampledAt > now ||
          now - sampledAt > 5000 ||
          _clock.elapsedMilliseconds - began > 5000 ||
          value['error'] != null) {
        throw const FormatException('Process memory unavailable');
      }
      _processRssBytes = bytes;
      _memoryReceivedAt = _clock.elapsedMilliseconds - (now - sampledAt);
      memoryUnavailable = false;
      _memoryExpiry?.cancel();
      _memoryExpiry = Timer(
        Duration(milliseconds: (5001 - (now - sampledAt)).clamp(1, 5001)),
        () {
          if (!valid()) return;
          _processRssBytes = null;
          memoryUnavailable = true;
          notifyListeners();
        },
      );
    } catch (_) {
      if (!valid()) return;
      _processRssBytes = null;
      _memoryReceivedAt = null;
      memoryUnavailable = true;
    } finally {
      _memoryFlight = false;
      if (!_disposed) {
        notifyListeners();
        if (active) {
          _memoryTimer = Timer(
            Duration(milliseconds: request == _request ? 1000 : 0),
            _readMemory,
          );
        }
      }
    }
  }

  void _expire() {
    _expiry?.cancel();
    if (!active) return;
    final value = data;
    if (value == null) return;
    final deadlines = <int>[
      if (value.fresh && value.sampledAt != null)
        value.sampledAt! + TrafficWindow.maxIntervalMs + 1,
      if (value.points.isNotEmpty)
        value.points.first.elapsedMs + TrafficWindow.durationMs + 1,
    ];
    if (deadlines.isEmpty) return;
    final next = deadlines.reduce((a, b) => a < b ? a : b);
    _expiry = Timer(
      Duration(
        milliseconds: (next - value.elapsedMs).clamp(
          1,
          TrafficWindow.durationMs + 1,
        ),
      ),
      () {
        if (!active) return;
        notifyListeners();
        _expire();
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _timer?.cancel();
    _expiry?.cancel();
    _memoryTimer?.cancel();
    _memoryExpiry?.cancel();
    _clock.stop();
    app.removeListener(_changed);
    super.dispose();
  }
}
