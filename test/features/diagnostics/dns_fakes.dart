import 'dart:async';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';

CoreSnapshot dnsCore({
  int generation = 1,
  String purpose = 'VPN',
  String composition = 'composition-1',
}) => CoreSnapshot(
  generation: generation,
  phase: 'READY',
  purpose: purpose,
  configId: 'controlled',
  revision: 1,
  composition: composition,
);

Map<String, dynamic> dnsEnvelope({CoreSnapshot? core, int network = 1}) {
  core ??= dnsCore();
  return {
    'generation': core.generation,
    'purpose': core.purpose,
    'configId': core.configId,
    'revision': core.revision,
    'composition': core.composition,
    'networkEpoch': network,
  };
}

Map<String, dynamic> dnsRecord({
  String type = 'A',
  String data = '192.0.2.1',
}) => {
  'name': 'controlled.example.',
  'type': type,
  'class': 'IN',
  'ttl': 60,
  'data': data,
};

Map<String, dynamic> dnsReply({
  CoreSnapshot? core,
  int network = 1,
  int rcode = 0,
  bool truncated = false,
  String type = 'A',
  List<Map<String, dynamic>>? answer,
}) => {
  ...dnsEnvelope(core: core, network: network),
  'dns': {
    'question': {'name': 'controlled.example.', 'type': type},
    'rcode': rcode,
    'rcodeName': rcode == 3 ? 'NXDOMAIN' : 'NOERROR',
    'elapsedMs': 1.25,
    'truncated': truncated,
    'answer': answer ?? [dnsRecord(type: type)],
    'authority': <Map<String, dynamic>>[],
    'additional': <Map<String, dynamic>>[],
  },
};

Map<String, dynamic> dnsError(
  String code, {
  CoreSnapshot? core,
  int network = 1,
}) => {
  ...dnsEnvelope(core: core, network: network),
  'dns': {'error': code},
};

Map<String, dynamic> dnsCacheReply({
  CoreSnapshot? core,
  int network = 1,
  bool fakeIp = false,
  String status = 'completed',
  bool persistent = false,
}) => {
  ...dnsEnvelope(core: core, network: network),
  'cache': {
    'status': status,
    if (fakeIp) ...{
      'persistent': persistent,
      'ipv4': {
        'active': status != 'empty',
        'outcome': status == 'empty'
            ? 'inactive'
            : status == 'completed'
            ? 'cleared'
            : 'unconfirmed',
      },
      'ipv6': {'active': false, 'outcome': 'inactive'},
    } else ...{
      'resolverActive': status != 'empty',
      'systemResolverActive': false,
    },
  },
};

class DnsTestBridge extends AppBridge {
  final queries =
      <({CoreSnapshot core, String name, String type, String queryOwner})>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  final cancellations = <({CoreSnapshot core, String queryOwner})>[];
  final clears = <bool>[];
  Completer<Map<String, dynamic>>? clearPending;
  Map<String, dynamic>? clearValue;

  @override
  Future<Map<String, dynamic>> dnsQuery(
    CoreSnapshot core, {
    required String name,
    required String type,
    required String queryOwner,
  }) {
    queries.add((core: core, name: name, type: type, queryOwner: queryOwner));
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }

  @override
  Future<void> cancelDnsQuery(
    CoreSnapshot core, {
    required String queryOwner,
  }) async {
    cancellations.add((core: core, queryOwner: queryOwner));
  }

  @override
  Future<Map<String, dynamic>> clearDnsCache(CoreSnapshot core) {
    clears.add(false);
    return clearPending?.future ??
        Future.value(clearValue ?? dnsCacheReply(core: core));
  }

  @override
  Future<Map<String, dynamic>> flushFakeIp(CoreSnapshot core) {
    clears.add(true);
    return clearPending?.future ??
        Future.value(clearValue ?? dnsCacheReply(core: core, fakeIp: true));
  }
}

class DnsTestApp extends AppController {
  DnsTestApp(super.platform) {
    loading = false;
    configsLoaded = true;
    state = AppSnapshot(
      phase: 'RUNNING',
      generation: 1,
      core: dnsCore(),
      networkEpoch: 1,
    );
  }
  final commands = <Map<String, Object?>>[];
  int refreshes = 0;
  Completer<void>? refreshPending;
  void Function()? onRefresh;

  void publish({
    CoreSnapshot? core,
    String phase = 'RUNNING',
    int generation = 1,
    int? network = 1,
    bool dnsBusy = false,
  }) {
    state = AppSnapshot(
      phase: phase,
      generation: generation,
      core: core ?? dnsCore(),
      networkEpoch: network,
      dnsBusy: dnsBusy,
    );
    notifyListeners();
  }

  @override
  Future<void> refresh() async {
    refreshes++;
    if (refreshPending != null) await refreshPending!.future;
    onRefresh?.call();
    notifyListeners();
  }

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(command);
    return 'controlled-operation';
  }
}
