import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = '00000000-0000-4000-8000-000000000001';
const _otherId = '00000000-0000-4000-8000-000000000002';
const _core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'RUNNING',
  configId: 'one',
  revision: 1,
  composition: 'controlled-composition',
);

Map<String, dynamic> _suggestions({
  String id = _id,
  String? host = 'a.private.github.io',
  String? boundary = 'private.github.io',
  String? ip = '192.0.2.1/32',
}) => {
  'connectionId': id,
  'host': host,
  'suffixBoundary': boundary,
  'ipCidr': ip,
};

Map<String, dynamic> _row({
  String id = _id,
  bool active = true,
  String displayHost = 'display-is-not-authoritative.example',
}) => {
  'id': id,
  'start': '2026-10-19T10:00:00Z',
  'active': active,
  'upload': 12,
  'download': 34,
  'chains': ['DIRECT'],
  'rule': 'Match',
  'metadata': {
    'host': displayHost,
    'destinationIP': '198.18.0.99',
    'destinationPort': '443',
    'sourceIP': '192.0.2.2',
    'sourcePort': '1234',
    'network': 'tcp',
    'type': 'Tun',
  },
};

Map<String, dynamic> _sample({
  CoreSnapshot source = _core,
  Object? suggestions,
  bool active = true,
  String id = _id,
  int session = 1,
  int age = 0,
}) => {
  'generation': source.generation,
  'composition': source.composition,
  'configId': source.configId,
  'revision': source.revision,
  'purpose': source.purpose,
  'phase': 'RUNNING',
  'sessionGeneration': session,
  'fresh': true,
  'sampleAgeMs': age,
  'connections': [
    {..._row(id: id, active: active), 'ruleSuggestions': suggestions},
  ],
};

void main() {
  test('compact boundary expands every suffix and serialization preserves the observed source', () {
    final host = List.filled(127, 'a').join('.');
    expect(host.length, 253);
    final record = ConnectionSnapshot.fromMap(
      _sample(
        suggestions: _suggestions(host: host, boundary: 'a.a', ip: null),
      ),
    ).records.single;
    final rules = record.ruleMetadata!;
    expect(rules.host, host);
    expect(rules.suffixes, hasLength(126));
    expect(rules.suffixes.first, host);
    expect(rules.suffixes[1], host.substring(2));
    expect(rules.suffixes.last, 'a.a');
    expect(rules.candidates, hasLength(127));
    const replacement = CoreSnapshot(
      generation: 8,
      phase: 'READY',
      purpose: 'RUNNING',
      configId: 'one',
      revision: 1,
      composition: 'replacement',
    );
    final restored = ConnectionSnapshot.fromMap({
      ..._sample(source: replacement),
      'connections': [record.observed(active: false).toMap()],
    }).records.single;
    expect(restored.active, isFalse);
    expect(restored.ruleMetadata!.source.identity, _core.identity);
    expect(restored.ruleMetadata!.candidates, rules.candidates);
    expect(restored.ruleMetadata!.matches(replacement), isFalse);
  });

  test('trusted helper controls candidates, never cropped display host or displayed IP', () {
    final result = ConnectionSnapshot.fromMap(
      _sample(suggestions: _suggestions()),
    );
    expect(result.records.single.host, 'display-is-not-authoritative.example');
    expect(result.records.single.destinationIP, '198.18.0.99');
    expect(result.records.single.ruleMetadata!.candidates, [
      (type: 'DOMAIN', value: 'a.private.github.io'),
      (type: 'DOMAIN-SUFFIX', value: 'a.private.github.io'),
      (type: 'DOMAIN-SUFFIX', value: 'private.github.io'),
      (type: 'IP-CIDR', value: '192.0.2.1/32'),
    ]);
    expect(result.records.single.ruleMetadata!.matches(_core), isTrue);
    expect(
      ConnectionSnapshot.fromMap(_sample()).records.single.ruleMetadata,
      isNull,
    );
  });

  test('exact-only internal/public suffix names and IP-only results are not invented', () {
    for (final host in ['localhost', 'co.uk']) {
      final value = ConnectionRuleSuggestions.fromValue(
        _suggestions(host: host, boundary: null, ip: null),
        _core,
      )!;
      expect(value.candidates, [(type: 'DOMAIN', value: host)]);
    }
    for (final ip in [
      '192.0.2.1/32',
      '2001:db8::1/128',
      '2001:0DB8:0000::0001/128',
      '::ffff:192.0.2.1/128',
    ]) {
      final value = ConnectionRuleSuggestions.fromValue(
        _suggestions(host: null, boundary: null, ip: ip),
        _core,
      )!;
      expect(value.host, isNull);
      expect(value.candidates.single.value, ip);
      expect(
        value.candidates.single.type,
        ip.contains(':') ? 'IP-CIDR6' : 'IP-CIDR',
      );
    }
  });

  test('malformed identity, suffix scope and non-single-address IP cannot create candidates', () {
    for (final invalid in [
      _suggestions(id: 'not-a-tracker'),
      _suggestions(host: 'cropped…'),
      _suggestions(host: 'bad.example.'),
      _suggestions(host: 'https://example.test'),
      _suggestions(host: null),
      _suggestions(boundary: 'unrelated.example'),
      _suggestions(boundary: 'cropped…'),
      {
        ..._suggestions(),
        'suffixBoundary': ['private.github.io'],
      },
      _suggestions(ip: '192.0.2.0/24'),
      _suggestions(ip: '::/128'),
      _suggestions(ip: '0.0.0.0/32'),
      _suggestions(ip: 'fe80::1%wlan0/128'),
      _suggestions(ip: '192.000.2.1/32'),
      _suggestions(ip: '192.0.2/32'),
      _suggestions(ip: '256.0.2.1/32'),
      _suggestions(ip: '0:0:0:0:0:0:0:0/128'),
      _suggestions(ip: '2001:db8::1/32'),
      _suggestions(ip: '::ffff:0.0.0.0/32'),
    ]) {
      expect(
        () => ConnectionRuleSuggestions.fromValue(invalid, _core),
        throwsFormatException,
      );
    }
    for (final source in [
      const CoreSnapshot(),
      const CoreSnapshot(
        generation: 7,
        configId: 'one',
        revision: 1,
        purpose: 'RUNNING',
      ),
    ]) {
      expect(
        () => ConnectionRuleSuggestions.fromValue(_suggestions(), source),
        throwsFormatException,
      );
    }
    final mismatched = ConnectionSnapshot.fromMap(
      _sample(suggestions: _suggestions(id: _otherId)),
    ).records.single;
    expect(mismatched.id, _id);
    expect(mismatched.ruleMetadata, isNull);
    expect(mismatched.ruleError, contains('Connection rule identity changed'));
    expect(mismatched.raw['ruleSuggestions'], _suggestions(id: _otherId));
    final inactive = ConnectionSnapshot.fromMap(
      _sample(suggestions: _suggestions(), active: false),
    ).records.single;
    expect(inactive.active, isFalse);
    expect(inactive.ruleMetadata!.matches(_core), isTrue);
  });
}
