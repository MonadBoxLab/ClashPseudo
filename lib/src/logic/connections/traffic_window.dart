import '../../model/traffic_snapshot.dart';

int? _count(Object? value) => value is int && value >= 0 ? value : null;
double? _rate(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

class TrafficWindow {
  static const durationMs = TrafficSnapshot.durationMs;
  static const maxIntervalMs = TrafficSnapshot.maxIntervalMs;
  static const maxPoints = TrafficSnapshot.maxPoints;
  final _points = <TrafficPoint>[];
  int? _baselineTime;
  int? _uploadTotal;
  int? _downloadTotal;
  int? _sampledAt;
  int? _activeCount;
  int? _sessionUploadBytes;
  int? _sessionDownloadBytes;
  double? _upload;
  double? _download;

  void clear() {
    _points.clear();
    invalidate();
  }

  void invalidate() {
    _baselineTime = null;
    _uploadTotal = null;
    _downloadTotal = null;
    _sampledAt = null;
    _activeCount = null;
    _sessionUploadBytes = null;
    _sessionDownloadBytes = null;
    _upload = null;
    _download = null;
  }

  void accept(Map<String, dynamic> sample) {
    final now = _count(sample['elapsedMs']);
    if (now == null || (_points.isNotEmpty && now <= _points.last.elapsedMs)) {
      invalidate();
      return;
    }
    final up = _count(sample['uploadTotal']);
    final down = _count(sample['downloadTotal']);
    final dt = _baselineTime == null ? null : now - _baselineTime!;
    double? speed(int? value, int? previous) {
      if (value == null ||
          previous == null ||
          value < previous ||
          dt == null ||
          dt <= 0 ||
          dt > maxIntervalMs) {
        return null;
      }
      return _rate((value - previous) * 1000 / dt);
    }

    _upload = speed(up, _uploadTotal);
    _download = speed(down, _downloadTotal);
    _uploadTotal = up;
    _downloadTotal = down;
    _baselineTime = now;
    _sampledAt = now;
    _activeCount = _count(sample['activeCount']);
    _sessionUploadBytes = _count(sample['sessionUploadBytes']);
    _sessionDownloadBytes = _count(sample['sessionDownloadBytes']);
    _points.add(TrafficPoint(now, _upload, _download));
    _prune(now);
  }

  void _prune(int now) {
    _points.removeWhere((p) => p.elapsedMs < now - durationMs);
    if (_points.length > maxPoints) {
      _points.removeRange(0, _points.length - maxPoints);
    }
  }

  Map<String, Object?> snapshot(int now, {required bool fresh}) {
    _prune(now);
    final valid =
        fresh &&
        _sampledAt != null &&
        now >= _sampledAt! &&
        now - _sampledAt! <= maxIntervalMs;
    return {
      'elapsedMs': now,
      'sampledAt': _sampledAt,
      'fresh': valid,
      'upload': valid ? _upload : null,
      'download': valid ? _download : null,
      'activeCount': valid ? _activeCount : null,
      'sessionUploadBytes': valid ? _sessionUploadBytes : null,
      'sessionDownloadBytes': valid ? _sessionDownloadBytes : null,
      'points': [for (final point in _points) point.toMap()],
    };
  }
}
