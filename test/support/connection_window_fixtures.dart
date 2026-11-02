import 'package:clash_pseudo/src/model/core_snapshot.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'RUNNING',
  configId: 'one',
  revision: 1,
  composition: 'one',
);

Map<String, dynamic> row(String id, {int? upload = 10, int? download = 20}) => {
  'id': id,
  'start': '2026-10-16T10:00:00Z',
  'upload': upload,
  'download': download,
};

Map<String, dynamic> sample(
  List<Map<String, dynamic>> rows,
  int elapsed, {
  Map<String, bool> presence = const {},
  Map<String, dynamic>? detail,
  bool limited = false,
}) => {
  'generation': 7,
  'configId': 'one',
  'revision': 1,
  'composition': 'one',
  'purpose': 'RUNNING',
  'complete': true,
  'connections': rows,
  'presence': presence,
  'elapsedMs': elapsed,
  'observedAt': 1792144800000 + elapsed,
  'detail': detail,
  'limited': limited,
};
