import 'core_snapshot.dart';

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
  static const durationMs = 30000;
  static const maxIntervalMs = 5000;
  static const maxPoints = 31;

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
    this.error,
    required this.upload,
    required this.download,
    required this.activeCount,
    this.composition,
    this.processId,
    this.inputId,
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
  final String? error;
  final double? upload;
  final double? download;
  final int? activeCount;
  final String? composition;
  final String? processId;
  final String? inputId;
  // Use the native VPN lease's pre-activation traffic baseline.
  final int? sessionUploadBytes;
  final int? sessionDownloadBytes;
  final List<TrafficPoint> points;

  bool matches(CoreSnapshot core) =>
      core.ready &&
      core.purpose == 'RUNNING' &&
      core.processId == processId &&
      core.inputId == inputId &&
      core.generation == generation &&
      core.configId == configId &&
      core.revision == revision &&
      core.composition == composition;

  factory TrafficSnapshot.fromMap(Map<String, dynamic> value) {
    final points = <TrafficPoint>[];
    final raw = value['points'];
    if (raw is List) {
      if (raw.length > TrafficSnapshot.maxPoints) {
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
      error: value['error'] as String?,
      upload: _rate(value['upload']),
      download: _rate(value['download']),
      activeCount: _count(value['activeCount']),
      composition: value['composition'] as String?,
      processId: value['processId'] as String?,
      inputId: value['inputId'] as String?,
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
        now - sampledAt! <= TrafficSnapshot.maxIntervalMs;
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
      error: error,
      upload: valid ? upload : null,
      download: valid ? download : null,
      activeCount: valid ? activeCount : null,
      composition: composition,
      processId: processId,
      inputId: inputId,
      sessionUploadBytes: valid ? sessionUploadBytes : null,
      sessionDownloadBytes: valid ? sessionDownloadBytes : null,
      points: points
          .where(
            (p) =>
                p.elapsedMs >= now - TrafficSnapshot.durationMs &&
                p.elapsedMs <= now,
          )
          .toList(),
    );
  }
}
