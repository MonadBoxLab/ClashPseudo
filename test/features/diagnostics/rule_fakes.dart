import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/platform/app_bridge.dart';

import 'runtime_fakes.dart' show core, response;

class RuleBridge extends AppBridge {
  final queries = <Map<String, Object?>>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> rules(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) {
    queries.add(query);
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }
}

Map<String, dynamic> rulePage({
  String kind = 'main',
  String name = '',
  int offset = 0,
  int generation = 1,
  String token = '',
  String origin = 'compiled-rules',
  int total = 51,
  Map<String, Object?>? extra,
}) => {
  ...response(core(generation)),
  'page': {
    'token': token.isEmpty ? 'c' * 64 : token,
    'sourceToken': 'e' * 64,
    'total': total,
    'nextOffset': offset == 0 && total > 50 ? 50 : -1,
    'origin': origin,
    'scopes': [
      {'kind': 'main', 'name': '', 'count': total},
      {'kind': 'sub', 'name': 'branch', 'count': 1},
      {'kind': 'provider', 'name': 'set', 'count': 2, 'behavior': 'Classical'},
    ],
    'rows': [
      for (
        var i = offset;
        i < (offset == 0 ? (total > 50 ? 50 : total) : total);
        i++
      )
        {
          'index': i + 1,
          'type': i == 0 ? 'RuleSet' : 'Match',
          'payload': i == 0 ? 'set' : '',
          'target': 'DIRECT',
          'providers': i == 0 ? ['set'] : [],
        },
    ],
    ...?extra,
  },
};
