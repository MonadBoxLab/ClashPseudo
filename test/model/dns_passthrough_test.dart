import 'dart:convert';

import 'package:clash_pseudo/src/model/dns_snapshot.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/dns_wire_fixtures.dart';

const original =
    'https://user:pass@fixture.test/?token=原文🙂\n'
    'Authorization: Bearer fixture';

void main() {
  group('DNS model passthrough', () {
    test(
      'admitted native resultTooLarge failures retain the complete cause',
      () {
        for (final field in ['dns', 'cache']) {
          final value = dnsEnvelope()
            ..[field] = {
              'error': 'resultTooLarge',
              'detail':
                  '$original\nCaused by: resolver\nSuppressed: close failed',
              'future': [false, 0, null],
            };
          try {
            if (field == 'dns') {
              DnsResponse.fromMap(value);
            } else {
              DnsCacheResult.fromMap(value, fakeIp: true);
            }
            fail('A native failure cannot become an accepted result');
          } on DnsFailure catch (error) {
            expect(error.code, 'resultTooLarge');
            expect(jsonDecode(error.detail!), value);
          }
        }
      },
    );

    test('DNS keeps complete messages, unknown fields and stale metadata', () {
      final value =
          dnsReply(
              answer: [dnsRecord(type: 'TXT', data: original)],
            )
            ..['futureEnvelope'] = {
              'secret': original,
              'boolean': false,
              'nil': null,
            };
      final data = value['dns'] as Map;
      data['message'] = {
        'Id': 0xbeef,
        'Authoritative': true,
        'AuthenticatedData': true,
        'future': [original, false, null],
      };
      (data['answer'] as List).single['futureRecord'] = original;
      for (final envelope in [false, true]) {
        value['stale'] = envelope;
        data['stale'] = !envelope;
        final result = DnsResponse.fromMap(value);
        expect(result.raw, value);
        expect(result.answer.single.data, original);
        expect(result.stale, isTrue);
      }
    });

    test(
      'native and malformed response errors retain their whole original value',
      () {
        final native = dnsError('future-error');
        (native['dns'] as Map)
          ..['detail'] = original
          ..['future'] = {'secret': original, 'boolean': false, 'nil': null};
        final malformed = dnsReply();
        ((malformed['dns'] as Map)['answer'] as List).single['ttl'] = original;
        for (final value in [native, malformed]) {
          try {
            DnsResponse.fromMap(value);
            fail('Invalid response unexpectedly became a successful answer');
          } on DnsFailure catch (error) {
            expect(
              error.code,
              identical(value, native) ? 'future-error' : 'invalidResponse',
            );
            expect(jsonDecode(error.detail!), value);
          }
        }
      },
    );

    test('partial cache results retain original errors and unknown fields', () {
      final value = dnsCacheReply(
        fakeIp: true,
        status: 'partialOrFailed',
        persistent: true,
      );
      (value['cache'] as Map)
        ..['detail'] = original
        ..['stale'] = true
        ..['future'] = [original, false, null];
      final result = DnsCacheResult.fromMap(value, fakeIp: true);
      expect(result.status, DnsCacheStatus.partialOrFailed);
      expect(result.persistent, isTrue);
      expect(result.stale, isTrue);
      expect(result.raw, value);
    });

    test('oversized responses are rejected whole rather than retained in error detail', () {
      for (final fakeIp in [null, false, true]) {
        final value = fakeIp == null
            ? dnsReply()
            : dnsCacheReply(fakeIp: fakeIp);
        value['future'] = 'x' * ApplicationContract.dnsResultBytes;
        expect(
          () => fakeIp == null
              ? DnsResponse.fromMap(value)
              : DnsCacheResult.fromMap(value, fakeIp: fakeIp),
          throwsA(
            isA<DnsFailure>()
                .having((e) => e.code, 'code', 'resultTooLarge')
                .having((e) => e.detail, 'detail', isNull),
          ),
        );
      }
    });
  });
}
