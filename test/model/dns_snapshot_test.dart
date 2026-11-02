import 'package:clash_pseudo/src/model/dns_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/dns_wire_fixtures.dart';

void main() {
  test(
    'input admission preserves Unicode, SRV and PTR for native normalization',
    () {
      expect(dnsRecordTypes, [
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
      ]);
      expect(validDnsInput('例子.example', 'A'), isTrue);
      expect(validDnsInput('_sip._tcp.controlled.example.', 'SRV'), isTrue);
      expect(validDnsInput('192.0.2.1', 'PTR'), isTrue);
      expect(validDnsInput('2001:db8::1', 'PTR'), isTrue);
      expect(validDnsInput('1.2.0.192.in-addr.arpa.', 'PTR'), isTrue);
      for (final name in [
        r'one\.label.example',
        r'one\046label.example',
        r'controlled.example\path',
      ]) {
        expect(validDnsInput(name, 'TXT'), isTrue, reason: name);
      }
      for (final name in [
        'https://controlled.example',
        'controlled.example:53',
        'controlled.example/path',
        'a@controlled.example',
        ' controlled.example',
        'controlled.example\n',
        'controlled.example\u0000',
        'controlled.example\u0085',
      ]) {
        expect(validDnsInput(name, 'A'), isTrue, reason: name);
      }
      expect(validDnsInput('', 'A'), isFalse);
      expect(validDnsInput('x' * 1024, 'TXT'), isTrue);
      expect(validDnsInput('x' * 1025, 'TXT'), isFalse);
      expect(validDnsInput('例' * 342, 'TXT'), isFalse);
      expect(validDnsInput('controlled.example', 'AXFR'), isFalse);
    },
  );

  test('all twelve records preserve RR data, class and unsigned TTL', () {
    for (final type in dnsRecordTypes) {
      final record = dnsRecord(type: type, data: 'controlled $type RDATA')
        ..['ttl'] = 0xffffffff;
      final result = DnsResponse.fromMap(
        dnsReply(type: type, answer: [record]),
      );
      expect(result.type, type);
      expect(result.answer.single.type, type);
      expect(result.answer.single.recordClass, 'IN');
      expect(result.answer.single.ttl, 0xffffffff);
      expect(result.answer.single.data, 'controlled $type RDATA');
      expect(result.elapsedMs, 1.25);
      expect(result.source.matchesIdentity(dnsCore()), isTrue);
    }
  });

  test('NXDOMAIN, no Answer and TC remain valid protocol results', () {
    final result = DnsResponse.fromMap(
      dnsReply(rcode: 3, truncated: true, answer: []),
    );
    expect(result.rcode, 3);
    expect(result.rcodeName, 'NXDOMAIN');
    expect(result.truncated, isTrue);
    expect(result.answer, isEmpty);
  });

  test('sections share a 512 RR budget, no prefix of oversize response', () {
    final value = dnsReply(answer: List.generate(510, (_) => dnsRecord()));
    final data = value['dns'] as Map;
    data['authority'] = [dnsRecord()];
    data['additional'] = [dnsRecord()];
    expect(DnsResponse.fromMap(value).answer.length, 510);
    data['additional'] = [dnsRecord(), dnsRecord()];
    expect(() => DnsResponse.fromMap(value), throwsA(isA<DnsFailure>()));
    final huge = dnsReply(
      answer: [dnsRecord(type: 'TXT', data: 'x' * (256 * 1024))],
    );
    expect(
      () => DnsResponse.fromMap(huge),
      throwsA(
        isA<DnsFailure>().having((e) => e.code, 'code', 'resultTooLarge'),
      ),
    );
  });

  test('identity and DNS structure reject missing or malformed fields', () {
    for (final field in [
      'generation',
      'composition',
      'configId',
      'revision',
      'purpose',
      'networkEpoch',
    ]) {
      final value = dnsReply()..remove(field);
      expect(
        () => DnsResponse.fromMap(value),
        throwsA(isA<DnsFailure>()),
        reason: field,
      );
    }
    for (final field in [
      'question',
      'rcode',
      'rcodeName',
      'elapsedMs',
      'truncated',
      'answer',
      'authority',
      'additional',
    ]) {
      final value = dnsReply();
      (value['dns'] as Map).remove(field);
      expect(
        () => DnsResponse.fromMap(value),
        throwsA(isA<DnsFailure>()),
        reason: field,
      );
    }
    for (final bad in [-1, '60', null, 0x100000000]) {
      final row = dnsRecord()..['ttl'] = bad;
      expect(
        () => DnsResponse.fromMap(dnsReply(answer: [row])),
        throwsA(isA<DnsFailure>()),
      );
    }
  });

  test('完整 DNS 消息和原始查询错误同时保留', () {
    final value = dnsReply();
    (value['dns'] as Map)['error'] = 'queryFailed';
    (value['dns'] as Map)['errorDetail'] = '原始查询错误';
    value['cancelError'] = '取消未确认';
    final result = DnsResponse.fromMap(value);
    expect(result.answer.single.data, '192.0.2.1');
    expect(result.errorCode, 'queryFailed');
    expect(result.errorDetail, contains('原始查询错误'));
    expect(result.cancellationError, '取消未确认');
    expect(result.raw, value);
  });

  test('stable native errors are not converted into an empty answer', () {
    for (final code in [
      'invalidRequest',
      'busy',
      'unavailable',
      'timeout',
      'cancelled',
      'obsolete',
      'queryFailed',
      'resultTooLarge',
    ]) {
      expect(
        () => DnsResponse.fromMap(dnsError(code)),
        throwsA(isA<DnsFailure>().having((e) => e.code, 'code', code)),
      );
    }
  });

  test(
    'fake-IP results retain mixed family effects and persistent-pool facts',
    () {
      for (final sample in [
        ('cleared', 'unconfirmed', DnsCacheStatus.partialOrFailed),
        ('unconfirmed', 'cleared', DnsCacheStatus.partialOrFailed),
        ('unconfirmed', 'unconfirmed', DnsCacheStatus.partialOrFailed),
        ('cleared', 'cleared', DnsCacheStatus.completed),
      ]) {
        final value = dnsCacheReply(
          fakeIp: true,
          status: sample.$3.name,
          persistent: true,
        );
        final cache = value['cache'] as Map;
        cache['ipv4'] = {'active': true, 'outcome': sample.$1};
        cache['ipv6'] = {'active': true, 'outcome': sample.$2};
        final result = DnsCacheResult.fromMap(value, fakeIp: true);
        expect(result.status, sample.$3);
        expect(result.persistent, isTrue);
        expect(result.ipv4!.active, isTrue);
        expect(result.ipv4!.outcome.name, sample.$1);
        expect(result.ipv6!.active, isTrue);
        expect(result.ipv6!.outcome.name, sample.$2);
      }
    },
  );

  test(
    'independent clear results express empty and partial effects honestly',
    () {
      for (final fakeIp in [false, true]) {
        for (final status in DnsCacheStatus.values) {
          final value = dnsCacheReply(
            fakeIp: fakeIp,
            status: status.name,
            persistent: fakeIp,
          );
          expect(DnsCacheResult.fromMap(value, fakeIp: fakeIp).status, status);
        }
      }
      final falselyEmpty = dnsCacheReply(fakeIp: true, status: 'empty');
      ((falselyEmpty['cache'] as Map)['ipv4'] as Map)['active'] = true;
      expect(
        () => DnsCacheResult.fromMap(falselyEmpty, fakeIp: true),
        throwsA(isA<DnsFailure>()),
      );
      final falselyComplete = dnsCacheReply(fakeIp: true);
      ((falselyComplete['cache'] as Map)['ipv4'] as Map)['outcome'] =
          'unconfirmed';
      expect(
        () => DnsCacheResult.fromMap(falselyComplete, fakeIp: true),
        throwsA(isA<DnsFailure>()),
      );
      final missing = dnsCacheReply()..remove('networkEpoch');
      expect(
        () => DnsCacheResult.fromMap(missing, fakeIp: false),
        throwsA(isA<DnsFailure>()),
      );
    },
  );
}
