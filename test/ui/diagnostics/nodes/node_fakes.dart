import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';

import '../configuration/runtime_fakes.dart' show core, response;

class NodeBridge extends AppBridge {
  final queries = <Map<String, Object?>>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> nodes(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) {
    queries.add(query);
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }
}

Map<String, dynamic> page({
  int offset = 0,
  String? token,
  int generation = 1,
}) => {
  ...response(core(generation)),
  'page': {
    'token': token ?? 'a' * 64,
    'total': 51,
    'nextOffset': offset == 0 ? 50 : -1,
    'nodes': [
      for (var i = offset; i < (offset == 0 ? 50 : 51); i++)
        {
          'name': 'node-$i',
          'type': 'Direct',
          'source': 'provider',
          'sourceKind': 'proxyProvider',
          'sourceVersion': 1,
          'builtin': false,
          'udp': true,
          'history': [],
          'extra': <String, Object>{},
        },
    ],
  },
};
