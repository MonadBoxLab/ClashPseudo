import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/model/traffic_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'RUNNING',
  configId: 'one',
  revision: 1,
);
TrafficSnapshot data({
  int now = 1000,
  int generation = 7,
  bool failed = false,
  String? error,
}) => TrafficSnapshot.fromMap({
  'generation': generation,
  'configId': 'one',
  'revision': 1,
  'sessionGeneration': 1,
  'phase': 'RUNNING',
  'fresh': true,
  'failed': failed,
  'error': error,
  'elapsedMs': now,
  'sampledAt': now,
  'upload': 0,
  'download': 2048,
  'activeCount': 2000,
  'points': [
    {'elapsedMs': now - 1000, 'upload': 0, 'download': 1024},
    {'elapsedMs': now, 'upload': 0, 'download': 2048},
  ],
});

class TrafficBridge extends AppBridge {
  int reads = 0;
  Completer<TrafficSnapshot>? pending;
  TrafficSnapshot value = data();
  bool fail = false;
  Object failure = StateError('failed');
  @override
  Future<TrafficSnapshot> traffic() {
    reads++;
    if (fail) return Future.error(failure);
    return pending?.future ?? Future.value(value);
  }
}

class TrafficApp extends AppController {
  TrafficApp(super.platform) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'RUNNING', generation: 1, core: core);
  }
  @override
  Future<void> refresh() async {}
  void changed() => notifyListeners();
}
