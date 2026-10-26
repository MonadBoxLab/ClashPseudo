import 'package:flutter_test/flutter_test.dart';

import '../../benchmark/connections.dart' as benchmark;

void main() {
  test(
    'connection benchmark exercises production window operations',
    () => benchmark.runConnectionBenchmark(timing: false),
  );
}
