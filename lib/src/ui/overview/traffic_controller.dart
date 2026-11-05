import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/app_controller.dart';
import '../../model/traffic_snapshot.dart';
import '../../model/messages.dart';
import '../locale/message_text.dart';

class TrafficController extends ChangeNotifier {
  TrafficController(this.app, {Stopwatch? clock, this.isCurrent})
    : _clock = clock ?? Stopwatch() {
    _clock.start();
    app.addListener(_changed);
  }

  final AppController app;
  final bool Function()? isCurrent;
  final Stopwatch _clock;
  TrafficSnapshot? _data;
  Object? _observed;
  Object? _source;
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
  final _applicationMemory = _MemorySample();
  final _kernelMemory = _MemorySample();
  Object? _memoryVisibility;
  String? _memoryProcess;

  bool get coreMemoryRunning => _memoryProcess != null;
  int? get appRssBytes =>
      active ? _applicationMemory.bytesAt(_clock.elapsedMilliseconds) : null;
  int? get coreRssBytes =>
      active ? _kernelMemory.bytesAt(_clock.elapsedMilliseconds) : null;
  int? get processRssBytes => appRssBytes;
  bool get memoryUnavailable =>
      _applicationMemory.unavailable ||
      coreMemoryRunning && _kernelMemory.unavailable;
  AppMessage? get appMemoryError => _applicationMemory.error;
  AppMessage? get coreMemoryError => _kernelMemory.error;
  AppMessage? get memoryErrorMessage {
    final failures = [
      appMemoryError,
      if (coreMemoryRunning) coreMemoryError,
    ].whereType<AppMessage>();
    if (failures.isEmpty) return null;
    return const AppMessage('processMemoryUnavailable').withDetail(
      failures.map((message) => message.detail).whereType<String>().join('\n'),
    );
  }

  String? get error => errorMessage?.text;

  bool get available =>
      app.state.forwarding &&
      app.state.core.ready &&
      app.state.core.purpose == 'RUNNING';
  bool get active =>
      !_disposed && _visible && app.foreground && (isCurrent?.call() ?? true);
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
    final source = (
      app.state.phase,
      app.state.generation,
      core.processId,
      core.inputId,
      core.generation,
      core.phase,
      core.purpose,
      core.configId,
      core.revision,
      core.composition,
    );
    final key = (_visible, app.foreground, source);
    if (_observed == key) return;
    _observed = key;
    _request++;
    _timer?.cancel();
    _expiry?.cancel();
    _confirmed = false;
    _failures = 0;
    if (_source != source) {
      _source = source;
      errorMessage = null;
    }
    if (!available ||
        _data?.matches(core) != true ||
        _data?.sessionGeneration != app.state.generation) {
      _data = null;
    }
    notifyListeners();
    final visibility = (active, app.foreground, _visible);
    if (_memoryVisibility != visibility) {
      _memoryVisibility = visibility;
      _applicationMemory.reset();
      _kernelMemory.reset();
    }
    final process = core.processId;
    final existing =
        process?.isNotEmpty == true &&
        !const [
          'EMPTY',
          'EXITED',
          'disconnected',
          'exited',
          'recoveryRequired',
        ].contains(core.phase);
    final memoryProcess = existing ? process : null;
    if (_memoryProcess != memoryProcess) {
      _memoryProcess = memoryProcess;
      _kernelMemory.reset();
    }
    if (active) {
      if (_applicationMemory.timer?.isActive != true) {
        unawaited(_readMemory(_applicationMemory, core: false));
      }
      if (coreMemoryRunning) unawaited(_readMemory(_kernelMemory, core: true));
    }
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
      // Local freshness expiry never proves the native read has drained.
      // Keep the single-flight slot until the bridge Future really settles.
      final result = await app.platform.traffic();
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
      errorMessage = result.failed
          ? messages.trafficUpdateFailed.withDetail(result.error)
          : null;
      _failures = 0;
    } catch (error) {
      if (!valid()) return;
      _confirmed = false;
      errorMessage = messages.trafficUpdateFailed.withDetail(error);
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

  Future<void> _readMemory(_MemorySample sample, {required bool core}) async {
    if (!active || sample.flight || core && !coreMemoryRunning) return;
    sample.timer?.cancel();
    sample.flight = true;
    final request = sample.request;
    final source = app.state.core;
    final began = _clock.elapsedMilliseconds;
    bool valid() =>
        active &&
        request == sample.request &&
        (!core || source.processId == _memoryProcess);
    // 期限只改变该项显示，不释放仍未退出的请求。
    sample.deadline?.cancel();
    sample.deadline = Timer(const Duration(seconds: 5), () {
      if (!valid()) return;
      sample.fail(const FormatException('内存请求尚未返回'));
      notifyListeners();
    });
    try {
      final value = core
          ? await app.platform.coreMemory(source)
          : await app.platform.appMemory();
      if (!valid()) return;
      if (value['valid'] != true && value['error'] != null) {
        sample.expiry?.cancel();
        sample.fail(value['error'] as Object);
        return;
      }
      final sampledAt = value['sampledAt'];
      final bytes = value['processRssBytes'];
      final now = DateTime.now().millisecondsSinceEpoch;
      if (value['valid'] != true ||
          bytes is! int ||
          bytes < 0 ||
          sampledAt is! int ||
          sampledAt <= 0 ||
          sampledAt > now ||
          now - sampledAt > 5000 ||
          _clock.elapsedMilliseconds - began > 5000 ||
          core && value['processId'] != source.processId) {
        throw FormatException(
          '内存采样无效或已过期: ${{if (value['valid'] is bool) 'valid': value['valid'], if (value['valid'] is! bool) 'validType': value['valid'].runtimeType.toString(), if (bytes is int) 'processRssBytes': bytes, if (bytes is! int) 'processRssBytesType': bytes.runtimeType.toString(), if (sampledAt is int) 'sampledAt': sampledAt, if (sampledAt is! int) 'sampledAtType': sampledAt.runtimeType.toString(), if (core) 'expectedProcessId': source.processId, if (core && value['processId'] is String) 'processId': value['processId']}}',
        );
      }
      sample.bytes = bytes;
      sample.receivedAt = _clock.elapsedMilliseconds - (now - sampledAt);
      sample.unavailable = false;
      sample.error = null;
      sample.expiry?.cancel();
      sample.expiry = Timer(
        Duration(milliseconds: 5001 - (now - sampledAt)),
        () {
          if (!valid()) return;
          sample.fail(const FormatException('内存采样已过期'));
          notifyListeners();
        },
      );
    } catch (error) {
      if (!valid()) return;
      sample.expiry?.cancel();
      sample.fail(error);
    } finally {
      sample.deadline?.cancel();
      sample.flight = false;
      if (!_disposed) {
        notifyListeners();
        if (active && (!core || coreMemoryRunning)) {
          sample.timer = Timer(
            Duration(milliseconds: request == sample.request ? 1000 : 0),
            () => _readMemory(sample, core: core),
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
        value.sampledAt! + TrafficSnapshot.maxIntervalMs + 1,
      if (value.points.isNotEmpty)
        value.points.first.elapsedMs + TrafficSnapshot.durationMs + 1,
    ];
    if (deadlines.isEmpty) return;
    final next = deadlines.reduce((a, b) => a < b ? a : b);
    _expiry = Timer(
      Duration(
        milliseconds: (next - value.elapsedMs).clamp(
          1,
          TrafficSnapshot.durationMs + 1,
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
    _applicationMemory.reset();
    _kernelMemory.reset();
    _clock.stop();
    app.removeListener(_changed);
    super.dispose();
  }
}

class _MemorySample {
  bool flight = false;
  bool unavailable = false;
  int request = 0;
  int? bytes;
  int? receivedAt;
  Timer? timer;
  Timer? expiry;
  Timer? deadline;
  AppMessage? error;

  int? bytesAt(int now) =>
      receivedAt != null && now - receivedAt! <= 5000 ? bytes : null;

  void fail(Object failure) {
    bytes = null;
    receivedAt = null;
    unavailable = true;
    error = const AppMessage('processMemoryUnavailable').withDetail(failure);
  }

  void reset() {
    request++;
    timer?.cancel();
    expiry?.cancel();
    deadline?.cancel();
    bytes = null;
    receivedAt = null;
    unavailable = false;
    error = null;
  }
}
