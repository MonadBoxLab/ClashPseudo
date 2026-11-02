import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/traffic_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _core = CoreSnapshot(
  generation: 3,
  phase: 'READY',
  purpose: 'RUNNING',
  configId: 'main',
  revision: 2,
  composition: 'observed-composition',
);

Map<String, dynamic> _wire({List<Map<String, Object?>>? points}) => {
  'generation': _core.generation,
  'configId': _core.configId,
  'revision': _core.revision,
  'composition': _core.composition,
  'sessionGeneration': 9,
  'phase': 'RUNNING',
  'elapsedMs': 1000,
  'sampledAt': 1000,
  'fresh': true,
  'upload': 25,
  'download': 50,
  'activeCount': 2,
  'sessionUploadBytes': 123,
  'sessionDownloadBytes': 456,
  'points': points ?? [const TrafficPoint(1000, 25, 50).toMap()],
};

void main() {
  test(
    'traffic decoding preserves its observation and complete source identity',
    () {
      final snapshot = TrafficSnapshot.fromMap(_wire());
      expect(snapshot.matches(_core), isTrue);
      expect(snapshot.generation, 3);
      expect(snapshot.sessionGeneration, 9);
      expect(snapshot.upload, 25);
      expect(snapshot.download, 50);
      expect(snapshot.sessionUploadBytes, 123);
      expect(snapshot.sessionDownloadBytes, 456);
      expect(snapshot.points.single.toMap(), {
        'elapsedMs': 1000,
        'upload': 25.0,
        'download': 50.0,
      });
      expect(() => snapshot.points.clear(), throwsUnsupportedError);
      expect(
        snapshot.matches(
          const CoreSnapshot(
            generation: 3,
            phase: 'READY',
            purpose: 'PREVIEW',
            configId: 'main',
            revision: 2,
            composition: 'observed-composition',
          ),
        ),
        isFalse,
      );
    },
  );

  test(
    'freshness has an inclusive boundary and never changes the source sample',
    () {
      final snapshot = TrafficSnapshot.fromMap(_wire());
      final boundary = snapshot.at(1000 + TrafficSnapshot.maxIntervalMs);
      expect(boundary.fresh, isTrue);
      expect(boundary.sessionDownloadBytes, 456);
      final expired = snapshot.at(1001 + TrafficSnapshot.maxIntervalMs);
      expect(expired.fresh, isFalse);
      expect(expired.upload, isNull);
      expect(expired.download, isNull);
      expect(expired.activeCount, isNull);
      expect(expired.sessionUploadBytes, isNull);
      expect(expired.sessionDownloadBytes, isNull);
      expect(snapshot.fresh, isTrue);
      expect(snapshot.upload, 25);
      expect(snapshot.at(1000, unavailable: true).fresh, isFalse);
    },
  );

  test('point budgets and ordering belong to the pure snapshot contract', () {
    final exact = [
      for (var index = 0; index < TrafficSnapshot.maxPoints; index++)
        TrafficPoint(index * 1000, null, index.toDouble()).toMap(),
    ];
    final snapshot = TrafficSnapshot.fromMap(_wire(points: exact));
    expect(snapshot.points, hasLength(TrafficSnapshot.maxPoints));
    expect(
      () => TrafficSnapshot.fromMap(
        _wire(
          points: [...exact, const TrafficPoint(31000, null, null).toMap()],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => TrafficSnapshot.fromMap(_wire(points: [exact.first, exact.first])),
      throwsFormatException,
    );
    final pruned = snapshot.at(31000);
    expect(pruned.points.first.elapsedMs, 1000);
    expect(pruned.points.last.elapsedMs, 30000);
    expect(snapshot.points.first.elapsedMs, 0);
    expect(TrafficSnapshot.durationMs, 30000);
  });
}
