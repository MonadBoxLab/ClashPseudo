import '../strategies/strategy_snapshot.dart';

class ConnectionRecord {
  ConnectionRecord.fromMap(Map<String, dynamic> value)
    : id = value['id'] as String,
      start = DateTime.tryParse(value['start'] as String? ?? '')?.toLocal(),
      upload = _count(value['upload']),
      download = _count(value['download']),
      chains = List<String>.unmodifiable(value['chains'] as List? ?? const []),
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
      type = (value['metadata'] as Map?)?['type'] as String? ?? '' {
    if (id.isEmpty) throw const FormatException('Missing connection identity');
  }

  final String id;
  final DateTime? start;
  final int? upload;
  final int? download;
  final List<String> chains;
  final String rule;
  final String rulePayload;
  final String host;
  final String destinationIP;
  final String destinationPort;
  final String sourceIP;
  final String sourcePort;
  final String network;
  final String type;

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

  bool matches(CoreSnapshot core) =>
      core.ready &&
      core.purpose == 'VPN' &&
      generation == core.generation &&
      configId == core.configId &&
      revision == core.revision;
  ConnectionRecord? find(String id) =>
      records.where((record) => record.id == id).firstOrNull;
}
