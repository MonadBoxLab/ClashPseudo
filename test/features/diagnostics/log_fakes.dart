import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/platform/app_bridge.dart';

import 'runtime_fakes.dart' show TestApp, core;

class LogBridge extends AppBridge {
  final requests = <Map<String, Object?>>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> logs(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) {
    requests.add(query);
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }
}

CoreSnapshot logSource(
  CoreSnapshot source, {
  bool recent = false,
  String? window,
}) => CoreSnapshot(
  generation: source.generation,
  phase: recent ? 'EMPTY' : 'READY',
  purpose: source.purpose,
  configId: source.configId,
  revision: source.revision,
  composition: source.composition,
  logWindow: window ?? '${source.generation}',
);

TestApp logApp(LogBridge bridge) => TestApp(bridge)
  ..state = AppSnapshot(
    phase: 'RUNNING',
    core: core(1),
    logSource: logSource(core(1)),
  );

Map<String, dynamic> logResponse(
  CoreSnapshot source, {
  List<Map<String, dynamic>> entries = const [],
  int total = 0,
  int dropped = 0,
  int next = 0,
}) => {
  'generation': source.generation,
  'configId': source.configId,
  'revision': source.revision,
  'composition': source.composition,
  'purpose': source.purpose,
  'logs': {
    'window': source.logWindow ?? '${source.generation}',
    'entries': entries,
    'next': next,
    'total': total,
    'dropped': dropped,
  },
};

Map<String, dynamic> entry(int seq, String level, String text) => {
  'seq': seq,
  'level': level,
  'time': '2026-10-18T04:00:00Z',
  'text': text,
};
