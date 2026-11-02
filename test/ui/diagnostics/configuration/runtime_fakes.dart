import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

CoreSnapshot core(
  int generation, {
  String purpose = 'RUNNING',
  AppMessage? error,
}) => CoreSnapshot(
  generation: generation,
  phase: 'READY',
  purpose: purpose,
  configId: 'main',
  revision: 1,
  composition: '["main",1,[$generation]]',
  error: error,
);

Map<String, dynamic> response(CoreSnapshot source) => {
  'generation': source.generation,
  'configId': source.configId,
  'revision': source.revision,
  'composition': source.composition,
  'purpose': source.purpose,
  'configuration': {
    'mode': 'rule',
    'authentication': ['[redacted]'],
    'mixed-port': 0,
  },
};

class TestBridge extends AppBridge {
  final requests = <CoreSnapshot>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> runtimeConfiguration(CoreSnapshot core) {
    requests.add(core);
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }
}

class TestApp extends AppController {
  TestApp(super.platform) {
    loading = false;
    configsLoaded = true;
    state = AppSnapshot(phase: 'RUNNING', core: core(1));
  }
  final commands = <Map<String, Object?>>[];
  void publish(AppSnapshot value) {
    state = value;
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    notifyListeners();
  }

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(command);
    return 'operation';
  }
}
