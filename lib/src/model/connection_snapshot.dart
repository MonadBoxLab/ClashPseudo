import 'dart:convert';

import 'core_snapshot.dart';

class ConnectionRecord {
  ConnectionRecord.fromMap(
    Map<String, dynamic> value, {
    CoreSnapshot source = const CoreSnapshot(),
  }) : this._(
         value['raw'] is Map
             ? Map<String, dynamic>.from(value['raw'] as Map)
             : value,
         value['raw'] is Map ? value['observation'] as Map? ?? const {} : value,
         source,
       );

  ConnectionRecord._(
    Map<String, dynamic> value,
    Map observation,
    CoreSnapshot source,
  ) : raw = _freezeMap(value),
      rawBytes = utf8.encode(jsonEncode(value)).length,
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
      active = observation['active'] != false,
      observedAt = observation['observedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(
              observation['observedAt'] as int,
            )
          : null,
      uploadSpeed = _rate(observation['uploadSpeed']),
      downloadSpeed = _rate(observation['downloadSpeed']) {
    if (id.isEmpty) throw const FormatException('Missing connection identity');
    try {
      final rules = _rules(
        observation['ruleSuggestions'] != null
            ? {...value, 'ruleSuggestions': observation['ruleSuggestions']}
            : value,
        source,
      );
      final failure = observation['ruleError'] as String?;
      ruleMetadata = rules;
      ruleError = failure;
    } catch (failure) {
      ruleMetadata = null;
      final original = observation['ruleError'] as String?;
      final diagnostic = failure.toString();
      // 保留原始错误文本及其中的重复行，仅追加新产生的解析错误。
      ruleError = original == null
          ? diagnostic
          : original == diagnostic || original.endsWith('\n$diagnostic')
          ? original
          : '$original\n$diagnostic';
    }
  }

  static Map<String, dynamic> _freezeMap(Map<String, dynamic> value) =>
      Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries) entry.key: _freeze(entry.value),
      });

  static Object? _freeze(Object? value) => switch (value) {
    Map value => Map.unmodifiable({
      for (final entry in value.entries) entry.key: _freeze(entry.value),
    }),
    List value => List.unmodifiable(value.map(_freeze)),
    _ => value,
  };

  final Map<String, dynamic> raw;
  final int rawBytes;
  late final ConnectionRuleSuggestions? ruleMetadata;
  late final String? ruleError;

  static ConnectionRuleSuggestions? _rules(
    Map<String, dynamic> value,
    CoreSnapshot source,
  ) {
    final rules = ConnectionRuleSuggestions.fromValue(
      value['ruleSuggestions'],
      source,
    );
    if (rules != null && rules.connectionId != value['id']) {
      throw const FormatException('Connection rule identity changed');
    }
    return rules?.candidates.isNotEmpty == true ? rules : null;
  }

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
  final DateTime? observedAt;
  final double? uploadSpeed;
  final double? downloadSpeed;

  Map<String, Object?> toMap() => {
    'raw': raw,
    'observation': {
      'active': active,
      'observedAt': observedAt?.millisecondsSinceEpoch,
      'uploadSpeed': uploadSpeed,
      'downloadSpeed': downloadSpeed,
      if (ruleMetadata != null) 'ruleSuggestions': ruleMetadata!.toMap(),
      if (ruleError != null) 'ruleError': ruleError,
    },
  };

  ConnectionRecord._observed(
    ConnectionRecord source, {
    required this.active,
    required this.observedAt,
    required this.uploadSpeed,
    required this.downloadSpeed,
    ConnectionRuleSuggestions? ruleMetadata,
    String? ruleError,
  }) : raw = source.raw,
       rawBytes = source.rawBytes,
       ruleMetadata = source.ruleMetadata ?? ruleMetadata,
       ruleError = source.ruleError ?? ruleError,
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
       type = source.type;

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

  ConnectionRecord retainingRulesFrom(ConnectionRecord? previous) =>
      ruleMetadata != null ||
          ruleError != null ||
          previous?.id != id ||
          previous?.ruleMetadata == null && previous?.ruleError == null
      ? this
      : ConnectionRecord._observed(
          this,
          active: active,
          observedAt: observedAt,
          uploadSpeed: uploadSpeed,
          downloadSpeed: downloadSpeed,
          ruleMetadata: previous!.ruleMetadata,
          ruleError: previous.ruleError,
        );

  static double? _rate(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.toDouble() : null;

  (String, String) get ruleKey => (rule, rulePayload);

  static int? _count(Object? value) =>
      value is int && value >= 0 ? value : null;
}

typedef ConnectionRuleCandidate = ({String type, String value});

/// 根据原生连接信息生成可添加的规则，连接结束后随连接记录保留。
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
      _addressBytes(value) == null;

  static ConnectionRuleSuggestions? fromValue(
    Object? raw,
    CoreSnapshot source,
  ) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw const FormatException('Invalid connection rule source');
    }
    if (raw['source'] case final Map observedSource) {
      source = CoreSnapshot.fromMap(Map<String, dynamic>.from(observedSource));
    } else if (raw['source'] != null) {
      throw const FormatException('Invalid observed connection rule source');
    }
    if (!source.hasIdentity || source.purpose != 'RUNNING') {
      throw const FormatException('Invalid connection rule source');
    }
    final id = raw['connectionId'];
    final host = raw['host'];
    final boundary = raw['suffixBoundary'];
    final ipCidr = raw['ipCidr'];
    if (id is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(id) ||
        id == '00000000-0000-0000-0000-000000000000' ||
        host != null && (host is! String || !_domain(host)) ||
        boundary != null &&
            (boundary is! String ||
                !_domain(boundary) ||
                host is! String ||
                boundary != host && !host.endsWith('.$boundary')) ||
        ipCidr != null && ipCidr is! String) {
      throw const FormatException('Invalid connection rule suggestions');
    }
    final domains = <String>[];
    if (boundary is String && host is String) {
      var suffix = host;
      while (true) {
        domains.add(suffix);
        if (suffix == boundary) break;
        suffix = suffix.substring(suffix.indexOf('.') + 1);
      }
    }
    final candidates = <ConnectionRuleCandidate>[
      if (host is String) (type: 'DOMAIN', value: host),
      for (final suffix in domains) (type: 'DOMAIN-SUFFIX', value: suffix),
    ];
    if (ipCidr is String) {
      final parts = ipCidr.split('/');
      final address = parts.length == 2 && !parts[0].contains('%')
          ? _addressBytes(parts[0])
          : null;
      if (address == null ||
          parts[1] != (address.length == 4 ? '32' : '128') ||
          address.every((byte) => byte == 0)) {
        throw const FormatException('Invalid suggested single-address rule');
      }
      candidates.add((
        type: address.length == 4 ? 'IP-CIDR' : 'IP-CIDR6',
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
    'suffixBoundary': suffixes.lastOrNull,
    'ipCidr': ipCidr,
    'source': {
      'phase': source.phase,
      'processId': source.processId,
      'inputId': source.inputId,
      'generation': source.generation,
      'configId': source.configId,
      'revision': source.revision,
      'composition': source.composition,
      'purpose': source.purpose,
    },
  };
}

class ConnectionSnapshot {
  factory ConnectionSnapshot.fromMap(Map<String, dynamic> value) =>
      ConnectionSnapshot._(
        value,
        CoreSnapshot(
          phase: 'READY',
          processId: value['processId'] as String?,
          inputId: value['inputId'] as String?,
          networkRevision: value['networkRevision'] as int? ?? 0,
          generation: value['generation'] as int,
          configId: value['configId'] as String,
          revision: value['revision'] as int,
          composition: value['composition'] as String?,
          purpose: value['purpose'] as String?,
        ),
      );

  ConnectionSnapshot._(Map<String, dynamic> value, this.source)
    : fresh = value['fresh'] != false,
      sampleAgeMs = ConnectionRecord._count(value['sampleAgeMs']),
      limited = value['limited'] == true,
      activeCount = ConnectionRecord._count(value['activeCount']),
      omitted = value['omitted'] as int? ?? 0,
      error = value['error'] as String?,
      missingDetailId = value['missingDetailId'] as String?,
      releasedDetailId = value['releasedDetailId'] as String?,
      sessionGeneration = value['sessionGeneration'] as int? ?? 0,
      detail = value['detail'] is Map
          ? ConnectionRecord.fromMap(
              Map<String, dynamic>.from(value['detail'] as Map),
              source: source,
            )
          : null,
      records = List.unmodifiable(
        (value['connections'] as List).map(
          (row) => ConnectionRecord.fromMap(
            Map<String, dynamic>.from(row as Map),
            source: source,
          ),
        ),
      ) {
    if (records.map((record) => record.id).toSet().length != records.length) {
      throw const FormatException('Duplicate connection identity');
    }
  }

  final CoreSnapshot source;
  int get generation => source.generation;
  String get configId => source.configId!;
  int get revision => source.revision!;
  String? get composition => source.composition;
  String? get purpose => source.purpose;
  final List<ConnectionRecord> records;
  final bool fresh;
  final int? sampleAgeMs;
  final bool limited;

  /// 原生接口返回的活跃连接总数。
  final int? activeCount;
  final int omitted;
  final String? error;
  final int sessionGeneration;
  final ConnectionRecord? detail;
  final String? missingDetailId;
  final String? releasedDetailId;

  bool matches(CoreSnapshot core) =>
      core.ready && core.purpose == 'RUNNING' && source.matchesIdentity(core);
  ConnectionRecord? find(String id) =>
      records.where((record) => record.id == id).firstOrNull;
}

// 将通道传入的 IP 地址字面量解析为字节。
List<int>? _addressBytes(String value) {
  if (value.contains('%')) return null;
  try {
    return value.contains(':')
        ? Uri.parseIPv6Address(value)
        : Uri.parseIPv4Address(value);
  } on FormatException {
    return null;
  }
}
