import 'package:clash_pseudo/src/model/core_snapshot.dart';

int? _count(Object? value) => value is int && value >= 0 ? value : null;
double? _rate(Object? value) =>
    value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

class TrafficPoint {
  const TrafficPoint(this.elapsedMs, this.upload, this.download);
  final int elapsedMs;
  final double? upload;
  final double? download;

  Map<String, Object?> toMap() => {
    'elapsedMs': elapsedMs,
    'upload': upload,
    'download': download,
  };
}

class TrafficSnapshot {
  TrafficSnapshot({
    required this.generation,
    required this.configId,
    required this.revision,
    required this.sessionGeneration,
    required this.phase,
    required this.elapsedMs,
    required this.sampledAt,
    required this.fresh,
    required this.failed,
    required this.upload,
    required this.download,
    required this.activeCount,
    this.composition,
    this.sessionUploadBytes,
    this.sessionDownloadBytes,
    required List<TrafficPoint> points,
  }) : points = List.unmodifiable(points);

  final int generation;
  final String configId;
  final int revision;
  final int sessionGeneration;
  final String phase;
  final int elapsedMs;
  final int? sampledAt;
  final bool fresh;
  final bool failed;
  final double? upload;
  final double? download;
  final int? activeCount;
  final String? composition;
  // Use the native VPN lease's pre-activation traffic baseline.
  final int? sessionUploadBytes;
  final int? sessionDownloadBytes;
  final List<TrafficPoint> points;

  bool matches(CoreSnapshot core) =>
      core.ready &&
      core.purpose == 'VPN' &&
      core.generation == generation &&
      core.configId == configId &&
      core.revision == revision &&
      core.composition == composition;

  factory TrafficSnapshot.fromMap(Map<String, dynamic> value) {
    final points = <TrafficPoint>[];
    final raw = value['points'];
    if (raw is List) {
      if (raw.length > TrafficWindow.maxPoints) {
        throw const FormatException('Unbounded traffic window');
      }
      for (final item in raw) {
        if (item is! Map) throw const FormatException('Invalid traffic point');
        final time = _count(item['elapsedMs']);
        if (time == null ||
            (points.isNotEmpty && time <= points.last.elapsedMs)) {
          throw const FormatException('Invalid traffic time');
        }
        points.add(
          TrafficPoint(time, _rate(item['upload']), _rate(item['download'])),
        );
      }
    }
    return TrafficSnapshot(
      generation: value['generation'] as int? ?? 0,
      configId: value['configId'] as String? ?? '',
      revision: value['revision'] as int? ?? 0,
      sessionGeneration: value['sessionGeneration'] as int? ?? 0,
      phase: value['phase'] as String? ?? 'UNKNOWN',
      elapsedMs: _count(value['elapsedMs']) ?? 0,
      sampledAt: _count(value['sampledAt']),
      fresh: value['fresh'] == true,
      failed: value['failed'] == true,
      upload: _rate(value['upload']),
      download: _rate(value['download']),
      activeCount: _count(value['activeCount']),
      composition: value['composition'] as String?,
      sessionUploadBytes: _count(value['sessionUploadBytes']),
      sessionDownloadBytes: _count(value['sessionDownloadBytes']),
      points: points,
    );
  }

  TrafficSnapshot at(int now, {bool unavailable = false}) {
    final valid =
        !unavailable &&
        fresh &&
        !failed &&
        phase == 'RUNNING' &&
        sampledAt != null &&
        now >= sampledAt! &&
        now - sampledAt! <= TrafficWindow.maxIntervalMs;
    return TrafficSnapshot(
      generation: generation,
      configId: configId,
      revision: revision,
      sessionGeneration: sessionGeneration,
      phase: phase,
      elapsedMs: now,
      sampledAt: sampledAt,
      fresh: valid,
      failed: failed,
      upload: valid ? upload : null,
      download: valid ? download : null,
      activeCount: valid ? activeCount : null,
      composition: composition,
      sessionUploadBytes: valid ? sessionUploadBytes : null,
      sessionDownloadBytes: valid ? sessionDownloadBytes : null,
      points: points
          .where(
            (p) =>
                p.elapsedMs >= now - TrafficWindow.durationMs &&
                p.elapsedMs <= now,
          )
          .toList(),
    );
  }
}

class TrafficWindow {
  static const durationMs = 30000;
  static const maxIntervalMs = 5000;
  static const maxPoints = 31;
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
