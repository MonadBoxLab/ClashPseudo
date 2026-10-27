import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
  composition: 'one',
);
Map<String, dynamic> row(
  String id, {
  int download = 10,
  String type = 'Tun',
  String rule = 'Domain',
  String? host,
}) => {
  'id': id,
  'start': '2026-10-15T10:00:00Z',
  'upload': 2,
  'download': download,
  'chains': ['node', '出口'],
  'rule': rule,
  'rulePayload': 'fixture.test',
  'metadata': {
    'host': host ?? '$id.fixture.test',
    'destinationIP': '127.0.0.1',
    'destinationPort': '18880',
    'sourceIP': '::1',
    'sourcePort': '1234',
    'network': 'tcp',
    'type': type,
  },
};
ConnectionSnapshot snapshot(
  List<Map<String, dynamic>> rows, {
  int generation = 7,
  int sessionGeneration = 0,
  Object? sampleAgeMs = 0,
  Map<String, dynamic>? detail,
}) => ConnectionSnapshot.fromMap({
  'generation': generation,
  'configId': 'one',
  'revision': 1,
  'composition': 'one',
  'purpose': 'VPN',
  'sessionGeneration': sessionGeneration,
  'sampleAgeMs': sampleAgeMs,
  'detail': detail,
  'connections': rows,
});

class ConnectionBridgeFake extends AppBridge {
  int reads = 0;
  bool fail = false;
  Completer<ConnectionSnapshot>? pending;
  ConnectionSnapshot data = snapshot([row('one')]);
  @override
  Future<void> releaseConnectionDetail() async {}

  @override
  Future<ConnectionSnapshot> recentConnections({Map<String, Object?>? detail}) {
    reads++;
    if (fail) return Future.error(StateError('unavailable'));
    return pending?.future ?? Future.value(data);
  }
}

class ConnectionAppFake extends AppController {
  ConnectionAppFake(super.platform) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'RUNNING', core: core);
  }
  final commands = <Map<String, Object?>>[];
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    lastCommandAutomatic = automatic;
    commands.add(command);
    return 'close-${commands.length}';
  }

  @override
  Future<void> refresh() async {}
  void changed() => notifyListeners();
}
