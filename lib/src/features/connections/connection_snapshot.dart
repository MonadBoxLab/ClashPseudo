import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/core_snapshot.dart';

import '../../l10n/messages.dart';

class ConnectionRecord {
  ConnectionRecord.fromMap(
    Map<String, dynamic> value, {
    Object? ruleMetadata,
  })
    : ruleMetadata = value['ruleSuggestions'] is Map
          ? Map<String, dynamic>.unmodifiable(value['ruleSuggestions'] as Map)
          : ruleMetadata is Map
          ? Map<String, dynamic>.unmodifiable(ruleMetadata)
          : null,
      id = value['id'] as String,
      start = value['startMicros'] is int
          ? DateTime.fromMicrosecondsSinceEpoch(value['startMicros'] as int)
          : DateTime.tryParse(value['start'] as String? ?? '')?.toLocal(),
      upload = _count(value['upload']),
      download = _count(value['download']),
      chains = List<String>.unmodifiable(value['chains'] as List? ?? const []),
      strategyType = _strategyText(value['strategy'], 'type'),
      strategyIcon = _strategyText(value['strategy'], 'icon'),
      rule = value['rule'] as String? ?? '',
      rulePayload = value['rulePayload'] as String? ?? '',
      host = (value['metadata'] as Map?)?['host'] as String? ?? '',
      destinationIP =
          (value['metadata'] as Map?)?['destinationIP'] as String? ?? '',
      destinationPort =
          (value['metadata'] as Map?)?['destinationPort']?.toString() ?? '',
      sourceIP = (value['metadata'] as Map?)?['sourceIP'] as String? ?? '',
      sourcePort = (value['metadata'] as Map?)?['sourcePort']?.toString() ?? '',
      network = (value['metadata'] as Map?)?['network'] as String? ?? '',
      type = (value['metadata'] as Map?)?['type'] as String? ?? '',
      active = value['active'] != false,
      fieldsTruncated = value['fieldsTruncated'] == true,
      observedAt = value['observedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(value['observedAt'] as int)
          : null,
      uploadSpeed = _rate(value['uploadSpeed']),
      downloadSpeed = _rate(value['downloadSpeed']) {
    if (id.isEmpty) throw const FormatException('Missing connection identity');
  }

  final Map<String, dynamic>? ruleMetadata;
  final String id;
  final DateTime? start;
  final int? upload;
  final int? download;
  final List<String> chains;
  final String strategyType;
  final String strategyIcon;

  static String _strategyText(Object? value, String key) =>
      value is Map && value[key] is String ? value[key] as String : '';
  final String rule;
  final String rulePayload;
  final String host;
  final String destinationIP;
  final String destinationPort;
  final String sourceIP;
  final String sourcePort;
  final String network;
  final String type;
  final bool active;
  final bool fieldsTruncated;
  final DateTime? observedAt;
  final double? uploadSpeed;
  final double? downloadSpeed;

  Map<String, Object?> toMap() => {
    if (ruleMetadata != null) 'ruleSuggestions': ruleMetadata,
    'id': id,
    'startMicros': start?.microsecondsSinceEpoch,
    'upload': upload,
    'download': download,
    'chains': chains,
    'strategy': {'type': strategyType, 'icon': strategyIcon},
    'rule': rule,
    'rulePayload': rulePayload,
    'active': active,
    'fieldsTruncated': fieldsTruncated,
    'observedAt': observedAt?.millisecondsSinceEpoch,
    'uploadSpeed': uploadSpeed,
    'downloadSpeed': downloadSpeed,
    'metadata': {
      'host': host,
      'destinationIP': destinationIP,
      'destinationPort': destinationPort,
      'sourceIP': sourceIP,
      'sourcePort': sourcePort,
      'network': network,
      'type': type,
    },
  };

  ConnectionRecord._observed(
    ConnectionRecord source, {
    required this.active,
    required this.observedAt,
    required this.uploadSpeed,
    required this.downloadSpeed,
  }) : ruleMetadata = source.ruleMetadata,
       id = source.id,
       start = source.start,
       upload = source.upload,
       download = source.download,
       chains = source.chains,
       strategyType = source.strategyType,
       strategyIcon = source.strategyIcon,
       rule = source.rule,
       rulePayload = source.rulePayload,
       host = source.host,
       destinationIP = source.destinationIP,
       destinationPort = source.destinationPort,
       sourceIP = source.sourceIP,
       sourcePort = source.sourcePort,
       network = source.network,
       type = source.type,
       fieldsTruncated = source.fieldsTruncated;

  ConnectionRecord observed({
    required bool active,
    DateTime? at,
    double? uploadSpeed,
    double? downloadSpeed,
  }) => ConnectionRecord._observed(
    this,
    active: active,
    observedAt: at ?? observedAt,
    uploadSpeed: _rate(uploadSpeed),
    downloadSpeed: _rate(downloadSpeed),
  );

  static double? _rate(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

  String get target =>
      host.isNotEmpty ? host : endpoint(destinationIP, destinationPort);
  String get path => chains.isEmpty
      ? localizedMessages.pathUnavailable
      : chains.reversed.join(' → ');
  (String, String) get ruleKey => (rule, rulePayload);
  String get ruleLabel => rule.isEmpty
      ? localizedMessages.notProvided
      : [rule, if (rulePayload.isNotEmpty) rulePayload].join(' · ');

  static int? _count(Object? value) =>
      value is int && value >= 0 ? value : null;
  static String endpoint(String address, String port) {
    if (address.isEmpty) return localizedMessages.notProvided;
    final host = address.contains(':') ? '[$address]' : address;
    return port.isEmpty ? host : '$host:$port';
  }
}

typedef ConnectionRuleCandidate = ({String type, String value});

/// 原生完整连接信息提供规则候选，连接结束后随记录保留。
class ConnectionRuleSuggestions {
  ConnectionRuleSuggestions._({
    required this.source,
    required this.connectionId,
    required this.host,
    required List<String> suffixes,
    required this.ipCidr,
    required List<ConnectionRuleCandidate> candidates,
  }) : suffixes = List.unmodifiable(suffixes),
       candidates = List.unmodifiable(candidates);

  final CoreSnapshot source;
  final String connectionId;
  final String? host;
  final List<String> suffixes;
  final String? ipCidr;
  final List<ConnectionRuleCandidate> candidates;

  static bool _domain(String value) =>
      value.isNotEmpty &&
      value.length <= 253 &&
      value
          .split('.')
          .every(
            (label) =>
                label.length <= 63 &&
                RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
          ) &&
      InternetAddress.tryParse(value) == null;

  static ConnectionRuleSuggestions? fromValue(
    Object? raw,
    CoreSnapshot source,
  ) {
    if (raw == null) return null;
    if (raw is! Map ||
        !source.matchesIdentity(source) ||
        source.purpose != 'VPN' ||
        utf8.encode(jsonEncode(raw)).length > 32 * 1024) {
      throw const FormatException('Invalid connection rule source');
    }
    final id = raw['connectionId'];
    final host = raw['host'];
    final suffixes = raw['suffixes'];
    final ipCidr = raw['ipCidr'];
    if (id is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id) ||
        id == '00000000-0000-0000-0000-000000000000' ||
        host != null && (host is! String || !_domain(host)) ||
        suffixes is! List ||
        suffixes.length > 127 ||
        ipCidr != null && ipCidr is! String) {
      throw const FormatException('Invalid connection rule suggestions');
    }
    final domains = <String>[];
    for (final suffix in suffixes) {
      if (suffix is! String ||
          !_domain(suffix) ||
          host is! String ||
          (suffix != host && !host.endsWith('.$suffix')) ||
          domains.contains(suffix) ||
          (domains.isNotEmpty && !domains.last.endsWith('.$suffix'))) {
        throw const FormatException('Invalid suggested domain suffix');
      }
      domains.add(suffix);
    }
    if (domains.isNotEmpty && domains.first != host ||
        host == null && domains.isNotEmpty) {
      throw const FormatException('Invalid suggested suffix boundary');
    }
    final candidates = <ConnectionRuleCandidate>[
      if (host is String) (type: 'DOMAIN', value: host),
      for (final suffix in domains) (type: 'DOMAIN-SUFFIX', value: suffix),
    ];
    if (ipCidr is String) {
      final parts = ipCidr.split('/');
      final address = parts.length == 2 && !parts[0].contains('%')
          ? InternetAddress.tryParse(parts[0])
          : null;
      if (address == null ||
          parts[1] !=
              (address.type == InternetAddressType.IPv4 ? '32' : '128') ||
          address.address == InternetAddress.anyIPv4.address ||
          address.address == InternetAddress.anyIPv6.address) {
        throw const FormatException('Invalid suggested single-address rule');
      }
      candidates.add((
        type: address.type == InternetAddressType.IPv4 ? 'IP-CIDR' : 'IP-CIDR6',
        value: ipCidr,
      ));
    }
    return ConnectionRuleSuggestions._(
      source: source,
      connectionId: id,
      host: host as String?,
      suffixes: domains,
      ipCidr: ipCidr as String?,
      candidates: candidates,
    );
  }

  bool matches(CoreSnapshot core) => core.ready && source.matchesIdentity(core);

  Map<String, Object?> toMap() => {
    'connectionId': connectionId,
    'host': host,
    'suffixes': suffixes,
    'ipCidr': ipCidr,
  };
}

class ConnectionSnapshot {
  ConnectionSnapshot.fromMap(Map<String, dynamic> value)
    : generation = value['generation'] as int,
      configId = value['configId'] as String,
      revision = value['revision'] as int,
      composition = value['composition'] as String?,
      purpose = value['purpose'] as String?,
      ruleSuggestions = ConnectionRuleSuggestions.fromValue(
        value['ruleSuggestions'],
        CoreSnapshot(
          phase: 'READY',
          generation: value['generation'] as int,
          configId: value['configId'] as String,
          revision: value['revision'] as int,
          composition: value['composition'] as String?,
          purpose: value['purpose'] as String?,
        ),
      ),
      phase = value['phase'] as String? ?? 'RUNNING',
      fresh = value['fresh'] != false,
      sampleAgeMs = ConnectionRecord._count(value['sampleAgeMs']),
      failed = value['failed'] == true,
      limited = value['limited'] == true,
      missingDetailId = value['missingDetailId'] as String?,
      sessionGeneration = value['sessionGeneration'] as int? ?? 0,
      observedAt = value['observedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(value['observedAt'] as int)
          : null,
      detail = value['detail'] is Map
          ? ConnectionRecord.fromMap(
              Map<String, dynamic>.from(value['detail'] as Map),
              ruleMetadata: value['ruleSuggestions'],
            )
          : null,
      records = List.unmodifiable(
        (value['connections'] as List)
            .map(
              (row) => ConnectionRecord.fromMap(
                Map<String, dynamic>.from(row as Map),
                ruleMetadata: value['ruleSuggestions'] is Map &&
                        (value['ruleSuggestions'] as Map)['connectionId'] == row['id']
                    ? value['ruleSuggestions']
                    : null,
              ),
            )
            .where((record) => record.type != 'Inner'),
      ) {
    if (records.map((record) => record.id).toSet().length != records.length) {
      throw const FormatException('Duplicate connection identity');
    }
    final suggestions = ruleSuggestions;
    if (suggestions != null) {
      final record =
          find(suggestions.connectionId) ??
          (detail?.id == suggestions.connectionId ? detail : null);
      if (record?.active != true) {
        throw const FormatException('Suggested connection is not current');
      }
    }
  }

  final int generation;
  final String configId;
  final int revision;
  final String? composition;
  final String? purpose;
  final ConnectionRuleSuggestions? ruleSuggestions;
  final List<ConnectionRecord> records;
  final String phase;
  final bool fresh;
  final int? sampleAgeMs;
  final bool failed;
  final bool limited;
  final int sessionGeneration;
  final DateTime? observedAt;
  final ConnectionRecord? detail;
  final String? missingDetailId;

  bool sameIdentity(CoreSnapshot core) =>
      generation == core.generation &&
      configId == core.configId &&
      revision == core.revision;

  bool matches(CoreSnapshot core) =>
      core.ready && core.purpose == 'VPN' && sameIdentity(core);
  ConnectionRecord? find(String id) =>
      records.where((record) => record.id == id).firstOrNull;
}
