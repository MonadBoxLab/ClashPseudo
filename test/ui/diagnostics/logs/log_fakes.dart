import 'package:clash_pseudo/src/logic/diagnostics/log_window.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

import '../configuration/runtime_fakes.dart' show TestApp, core;

class LogBridge extends AppBridge {
  final requests = <Map<String, Object?>>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  final _windows = <String, LogWindow>{};
  @override
  Future<Map<String, dynamic>> logs(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) {
    requests.add(query);
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future.then((value) {
      final page = value['logs'] as Map;
      final source = page['window'] as String;
      final window = _windows.putIfAbsent(
        source,
        () => LogWindow()..begin(source),
      );
      if (query['clear'] == true) {
        final through = page['cleared'] as int? ?? 0;
        window.clear(
          source,
          through: through > 0 ? through : window.watermark,
          droppedThrough: page['dropped'] as int?,
        );
      }
      for (final row in page['entries'] as List) {
        window.accept(source, Map<String, dynamic>.from(row as Map));
      }
      window.transportDropped(source, page['dropped'] as int? ?? 0);
      return {
        ...value,
        'logs': {
          ...page,
          ...window.snapshot(),
          'total': query['clear'] == true ? window.length : page['total'],
        },
      };
    });
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
  int cleared = 0,
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
    'windowDropped': 0,
    'retainedBytes': 0,
    'cleared': cleared,
  },
};

Map<String, dynamic> entry(int seq, String level, String text) => {
  'seq': seq,
  'level': level,
  'time': '2026-10-18T04:00:00Z',
  'text': text,
};
