import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/features/overview/traffic_window.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
);
TrafficSnapshot data({int now = 1000, int generation = 7}) =>
    TrafficSnapshot.fromMap({
      'generation': generation,
      'configId': 'one',
      'revision': 1,
      'sessionGeneration': 1,
      'phase': 'RUNNING',
      'fresh': true,
      'failed': false,
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
  @override
  Future<TrafficSnapshot> traffic() {
    reads++;
    if (fail) return Future.error(StateError('failed'));
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
