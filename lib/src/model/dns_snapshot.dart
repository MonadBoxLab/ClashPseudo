import 'dart:convert';

import 'core_snapshot.dart';
import 'application_contract.dart';

const dnsRecordTypes = [
  'A',
  'AAAA',
  'CNAME',
  'MX',
  'TXT',
  'NS',
  'SOA',
  'PTR',
  'SRV',
  'HTTPS',
  'SVCB',
  'CAA',
];

class DnsFailure implements Exception {
  const DnsFailure(this.code, {this.detail});
  final String code;
  final String? detail;

  @override
  String toString() => detail == null ? code : '$code\n$detail';
}

/// Admission checks delegate IDNA, DNS wire limits and PTR conversion to the native
/// resolver's public implementation.
bool validDnsInput(String name, String type) =>
    dnsRecordTypes.contains(type) &&
    name.isNotEmpty &&
    utf8.encode(name).length <= ApplicationContract.dnsNameBytes &&
    utf8.encode(jsonEncode({'name': name, 'type': type})).length <=
        ApplicationContract.dnsRequestBytes;

CoreSnapshot _identity(Map<String, dynamic> value) {
  final core = CoreSnapshot(
    phase: 'READY',
    processId: value['processId'] as String?,
    inputId: value['inputId'] as String?,
    networkRevision:
        value['networkRevision'] as int? ?? value['networkEpoch'] as int? ?? 0,
    generation: value['generation'] is int ? value['generation'] as int : 0,
    configId: value['configId'] is String ? value['configId'] as String : null,
    revision: value['revision'] is int ? value['revision'] as int : null,
    composition: value['composition'] is String
        ? value['composition'] as String
        : null,
    purpose: value['purpose'] is String ? value['purpose'] as String : null,
  );
  if (!core.hasIdentity) throw const DnsFailure('invalidResponse');
  return core;
}

String _text(Object? value) {
  if (value is! String) throw const DnsFailure('invalidResponse');
  return value;
}

int _integer(Object? value, int maximum) {
  if (value is! int || value < 0 || value > maximum) {
    throw const DnsFailure('invalidResponse');
  }
  return value;
}

class DnsRecord {
  const DnsRecord({
    required this.name,
    required this.type,
    required this.recordClass,
    required this.ttl,
    required this.data,
  });
  final String name;
  final String type;
  final String recordClass;
  final int ttl;
  final String data;

  factory DnsRecord.fromMap(Map value) => DnsRecord(
    name: _text(value['name']),
    type: _text(value['type']),
    recordClass: _text(value['class']),
    ttl: _integer(value['ttl'], 0xffffffff),
    data: _text(value['data']),
  );
}

String? _dnsErrorCode(Object? error) {
  if (error == null) return null;
  if (error is String) return error;
  if (error is Map && error['code'] is String) return error['code'] as String;
  return 'queryFailed';
}

class DnsResponse {
  DnsResponse._({
    required this.source,
    required this.networkEpoch,
    required this.name,
    required this.type,
    required this.rcode,
    required this.rcodeName,
    required this.elapsedMs,
    required this.truncated,
    required this.answer,
    required this.authority,
    required this.additional,
    required this.raw,
  });

  final CoreSnapshot source;
  final int networkEpoch;
  final String name;
  final String type;
  final int rcode;
  final String rcodeName;
  final double elapsedMs;
  final bool truncated;
  final List<DnsRecord> answer;
  final List<DnsRecord> authority;
  final List<DnsRecord> additional;

  final Map<String, dynamic> raw;
  String? get errorCode => _dnsErrorCode(
    raw['operationError'] ?? (raw['dns'] as Map)['error'] ?? raw['error'],
  );
  String? get errorDetail => errorCode == null
      ? null
      : const JsonEncoder.withIndent('  ').convert(raw);
  Object? get cancellationError => raw['cancelError'];
  bool get stale =>
      raw['stale'] == true || (raw['dns'] as Map)['stale'] == true;

  factory DnsResponse.fromMap(Map<String, dynamic> value) {
    try {
      // Reject malformed or oversized responses as a whole.
      if (utf8.encode(jsonEncode(value)).length >
          ApplicationContract.dnsResultBytes) {
        throw const DnsFailure('resultTooLarge');
      }
      final source = _identity(value);
      final networkEpoch = _integer(value['networkEpoch'], 0x7fffffffffffffff);
      final data = value['dns'];
      if (data is! Map) {
        throw DnsFailure(
          _dnsErrorCode(value['operationError'] ?? value['error']) ??
              'invalidResponse',
          detail: const JsonEncoder.withIndent('  ').convert(value),
        );
      }
      if (data['error'] != null && data['question'] == null) {
        throw DnsFailure(
          _dnsErrorCode(data['error'])!,
          detail: const JsonEncoder.withIndent('  ').convert(value),
        );
      }
      final question = data['question'];
      final elapsed = data['elapsedMs'];
      if (question is! Map ||
          elapsed is! num ||
          !elapsed.isFinite ||
          elapsed < 0 ||
          data['truncated'] is! bool) {
        throw const DnsFailure('invalidResponse');
      }
      var count = 0;
      List<DnsRecord> records(Object? raw) {
        if (raw is! List) {
          throw const DnsFailure('invalidResponse');
        }
        if ((count += raw.length) > ApplicationContract.dnsResultRecords) {
          throw const DnsFailure('resultTooLarge');
        }
        return List.unmodifiable(
          raw.map((row) {
            if (row is! Map) throw const DnsFailure('invalidResponse');
            return DnsRecord.fromMap(row);
          }),
        );
      }

      return DnsResponse._(
        source: source,
        networkEpoch: networkEpoch,
        name: _text(question['name']),
        type: _text(question['type']),
        rcode: _integer(data['rcode'], 4095),
        rcodeName: _text(data['rcodeName']),
        elapsedMs: elapsed.toDouble(),
        truncated: data['truncated'] as bool,
        answer: records(data['answer']),
        authority: records(data['authority']),
        additional: records(data['additional']),
        raw: Map.unmodifiable(value),
      );
    } on DnsFailure catch (error) {
      if (error.code == 'resultTooLarge') rethrow;
      throw DnsFailure(
        error.code,
        detail: const JsonEncoder.withIndent('  ').convert(value),
      );
    }
  }
}

enum DnsCacheStatus { completed, empty, partialOrFailed }

enum DnsCacheOutcome { cleared, inactive, unconfirmed }

typedef DnsCachePool = ({bool active, DnsCacheOutcome outcome});

DnsCachePool _cachePool(Object? value) {
  if (value is! Map || value['active'] is! bool) {
    throw const DnsFailure('invalidResponse');
  }
  final outcome = switch (value['outcome']) {
    'cleared' => DnsCacheOutcome.cleared,
    'inactive' => DnsCacheOutcome.inactive,
    'unconfirmed' => DnsCacheOutcome.unconfirmed,
    _ => throw const DnsFailure('invalidResponse'),
  };
  final active = value['active'] as bool;
  if (active == (outcome == DnsCacheOutcome.inactive)) {
    throw const DnsFailure('invalidResponse');
  }
  return (active: active, outcome: outcome);
}

class DnsCacheResult {
  const DnsCacheResult._(
    this.source,
    this.networkEpoch,
    this.status, {
    required this.raw,
    this.persistent,
    this.ipv4,
    this.ipv6,
  });
  final CoreSnapshot source;
  final int networkEpoch;
  final DnsCacheStatus status;
  final Map<String, dynamic> raw;
  bool get stale =>
      raw['stale'] == true || (raw['cache'] as Map)['stale'] == true;
  final bool? persistent;
  final DnsCachePool? ipv4;
  final DnsCachePool? ipv6;

  factory DnsCacheResult.fromMap(
    Map<String, dynamic> value, {
    required bool fakeIp,
  }) {
    try {
      if (utf8.encode(jsonEncode(value)).length >
          ApplicationContract.dnsResultBytes) {
        throw const DnsFailure('resultTooLarge');
      }
      final source = _identity(value);
      final networkEpoch = _integer(value['networkEpoch'], 0x7fffffffffffffff);
      final cache = value['cache'];
      if (cache is! Map) throw const DnsFailure('invalidResponse');
      if (cache['error'] is String) {
        throw DnsFailure(
          cache['error'] as String,
          detail: const JsonEncoder.withIndent('  ').convert(value),
        );
      }
      final status = switch (cache['status']) {
        'completed' => DnsCacheStatus.completed,
        'empty' => DnsCacheStatus.empty,
        'partialOrFailed' => DnsCacheStatus.partialOrFailed,
        _ => throw const DnsFailure('invalidResponse'),
      };
      if (fakeIp) {
        final persistent = cache['persistent'];
        if (persistent is! bool) {
          throw const DnsFailure('invalidResponse');
        }
        final ipv4 = _cachePool(cache['ipv4']);
        final ipv6 = _cachePool(cache['ipv6']);
        final active = ipv4.active || ipv6.active;
        final unconfirmed =
            ipv4.outcome == DnsCacheOutcome.unconfirmed ||
            ipv6.outcome == DnsCacheOutcome.unconfirmed;
        final expected = !active
            ? DnsCacheStatus.empty
            : unconfirmed
            ? DnsCacheStatus.partialOrFailed
            : DnsCacheStatus.completed;
        if (status != expected) throw const DnsFailure('invalidResponse');
        return DnsCacheResult._(
          source,
          networkEpoch,
          status,
          raw: Map.unmodifiable(value),
          persistent: persistent,
          ipv4: ipv4,
          ipv6: ipv6,
        );
      } else {
        if (cache['resolverActive'] is! bool ||
            cache['systemResolverActive'] is! bool) {
          throw const DnsFailure('invalidResponse');
        }
        final active =
            cache['resolverActive'] == true ||
            cache['systemResolverActive'] == true;
        if (status == DnsCacheStatus.completed && !active ||
            status == DnsCacheStatus.empty && active) {
          throw const DnsFailure('invalidResponse');
        }
      }
      return DnsCacheResult._(
        source,
        networkEpoch,
        status,
        raw: Map.unmodifiable(value),
      );
    } on DnsFailure catch (error) {
      if (error.code == 'resultTooLarge') rethrow;
      throw DnsFailure(
        error.code,
        detail: const JsonEncoder.withIndent('  ').convert(value),
      );
    }
  }
}
