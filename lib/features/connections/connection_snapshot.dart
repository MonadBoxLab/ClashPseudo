import '../strategies/strategy_snapshot.dart';

class ConnectionRecord {
  ConnectionRecord.fromMap(Map<String, dynamic> value)
    : id = value['id'] as String,
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
  }) : id = source.id,
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
  String get path => chains.isEmpty ? '路径未提供' : chains.reversed.join(' → ');
  (String, String) get ruleKey => (rule, rulePayload);
  String get ruleLabel => rule.isEmpty
      ? '未提供'
      : [rule, if (rulePayload.isNotEmpty) rulePayload].join(' · ');

  static int? _count(Object? value) =>
      value is int && value >= 0 ? value : null;
  static String endpoint(String address, String port) {
    if (address.isEmpty) return '未提供';
    final host = address.contains(':') ? '[$address]' : address;
    return port.isEmpty ? host : '$host:$port';
  }
}

class ConnectionSnapshot {
  ConnectionSnapshot.fromMap(Map<String, dynamic> value)
    : generation = value['generation'] as int,
      configId = value['configId'] as String,
      revision = value['revision'] as int,
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
            )
          : null,
      records = List.unmodifiable(
        (value['connections'] as List)
            .map(
              (row) => ConnectionRecord.fromMap(
                Map<String, dynamic>.from(row as Map),
              ),
            )
            .where((record) => record.type != 'Inner'),
      ) {
    if (records.map((record) => record.id).toSet().length != records.length) {
      throw const FormatException('Duplicate connection identity');
    }
  }

  final int generation;
  final String configId;
  final int revision;
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
