import 'package:clash_pseudo/src/model/core_snapshot.dart';

CoreSnapshot dnsCore({
  int generation = 1,
  String purpose = 'RUNNING',
  String composition = 'composition-1',
  int networkRevision = 1,
}) => CoreSnapshot(
  processId: 'dns-process-$generation',
  inputId: 'dns-input-$generation',
  networkRevision: networkRevision,
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
    'processId': core.processId,
    'inputId': core.inputId,
    'networkRevision': core.networkRevision,
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
  'dns': <String, dynamic>{'error': code},
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
