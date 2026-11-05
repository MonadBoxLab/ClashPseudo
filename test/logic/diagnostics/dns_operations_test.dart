import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/dns_snapshot.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/core_diagnostic_fixture.dart';

Map<String, Object?> _message() => {
  'question': {'name': 'TeSt.test.', 'type': 'TXT', 'futureQuestion': 7},
  'rcode': 0,
  'rcodeName': 'NOERROR',
  'elapsedMs': 1.25,
  'truncated': false,
  'answer': [
    {
      'name': 'TeSt.test.',
      'type': 'TXT',
      'class': 'IN',
      'ttl': 60,
      'data': '"完整消息 原文"',
      'futureRecord': {
        'bytes': [0, 255],
      },
    },
  ],
  'authority': [
    {
      'name': 'test.',
      'type': 'NS',
      'class': 'IN',
      'ttl': 7,
      'data': 'ns.test.',
    },
  ],
  'additional': [
    {
      'name': 'ns.test.',
      'type': 'A',
      'class': 'IN',
      'ttl': 3,
      'data': '192.0.2.7',
    },
  ],
  'futureMessage': {
    'flags': [true, false],
    'value': '未知字段',
  },
};

const _clearResult = {
  'status': 'completed',
  'resolverActive': true,
  'systemResolverActive': false,
};
const _fakeIpResult = {
  'status': 'empty',
  'persistent': false,
  'ipv4': {'active': false, 'outcome': 'inactive'},
  'ipv6': {'active': false, 'outcome': 'inactive'},
};

Matcher _dnsFailure(String code) =>
    isA<DnsFailure>().having((error) => error.code, 'code', code);

void main() {
  const actualTimeout = {
    'code': 'timeout',
    'message': '原生 DNS 查询到期',
    'cause': {'type': 'TimeoutException', 'message': '原始 timeout cause'},
    'suppressed': [
      {'message': '原始 suppressed'},
    ],
    'future': [false, null],
  };
  for (final nativeTimeout in [false, true]) {
    diagnosticTest(
      nativeTimeout
          ? 'DNS 实际 timeout 保留完整错误与原 owner，返回前拒绝下一查询'
          : 'DNS 超时保留实际调用与原 owner，返回前拒绝下一查询',
      (tester, fixture) async {
        await fixture.warmUp(tester);
        var replies = 0;
        final source = fixture.core;
        final pending = fixture.query().then((value) {
          replies++;
          return value;
        });
        await tester.pump();
        final request = fixture
            .calls(ApplicationContract.coreOperationDnsQuery)
            .single;
        expect(request.id, greaterThan(0));
        expect(request.arguments, {'name': 'test.test', 'type': 'A'});
        await tester.pump(
          const Duration(milliseconds: ApplicationContract.dnsQueryTimeoutMs),
        );
        expect(fixture.cancellations.map((item) => item.id), [request.id]);
        expect(replies, 0);
        expect(fixture.dns.busy, isTrue);
        expect(fixture.dns.snapshot()['queryOwner'], 'owner-one');
        await expectLater(
          fixture.query(name: 'other.test', owner: 'owner-two'),
          throwsA(_dnsFailure('busy')),
        );
        await fixture.dns.cancel(source, 'wrong-owner');
        expect(fixture.cancellations.length, 1);
        expect(fixture.dns.busy, isTrue);
        expect(fixture.dns.snapshot()['error'], 'timeout');
        request.complete(
          {'rcode': 0},
          terminal: {if (nativeTimeout) 'error': actualTimeout},
        );
        await tester.pump();
        expect(replies, 0);
        expect(fixture.dns.busy, isTrue);
        request.signalExit();
        await tester.pump();
        final result = await pending;
        expect((result['dns'] as Map)['rcode'], 0);
        expect((result['dns'] as Map).containsKey('error'), isFalse);
        expect(result['networkEpoch'], 7);
        expect(result['purpose'], 'PREVIEW');
        expect(result['configId'], 'main');
        expect(result['revision'], 1);
        if (nativeTimeout) {
          expect(result['operationError'], 'timeout');
          expect(result['error'], actualTimeout);
          expect(fixture.dns.snapshot()['error'], 'timeout');
        } else {
          expect(result.containsKey('operationError'), isFalse);
          expect(result['error'], isNull);
          expect(fixture.dns.snapshot()['error'], isNull);
        }
        expect(fixture.dns.busy, isFalse);
        expect(replies, 1);
      },
    );
  }

  diagnosticTest('DNS 在受理返回前取消仍保留占用，旧 owner 无权取消', (tester, fixture) async {
    await fixture.warmUp(tester);
    final gate = fixture.gate();
    fixture.script(
      ApplicationContract.coreOperationDnsQuery,
      (_) => gate.future,
    );
    final pending = fixture.query(owner: 'new-page');
    await tester.pump();
    final request = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    await fixture.dns.cancel(fixture.core, 'old-page');
    expect(fixture.cancellations, isEmpty);
    await fixture.dns.cancel(fixture.core, 'new-page');
    expect(fixture.dns.busy, isTrue);
    expect(fixture.dns.snapshot()['cancelRequested'], isTrue);
    expect(request.reads, 0);
    gate.complete();
    await tester.pump();
    expect(fixture.cancellations.map((item) => item.id), [request.id]);
    request.complete({'error': 'cancelled'});
    await tester.pump();
    expect(fixture.dns.busy, isTrue);
    request.signalExit();
    await tester.pump();
    expect((await pending)['dns'], {'error': 'cancelled'});
    expect(fixture.dns.busy, isFalse);
  });

  for (final fakeIp in [false, true]) {
    diagnosticTest('DNS ${fakeIp ? 'fake-IP' : 'cache'} 清理保留原输入、完整身份与结果', (
      tester,
      fixture,
    ) async {
      fixture.replaceCore(networkRevision: 9);
      await fixture.warmUp(tester);
      final operation = fakeIp
          ? ApplicationContract.coreOperationFakeIpFlush
          : ApplicationContract.coreOperationDnsCacheClear;
      final expected = fakeIp ? _fakeIpResult : _clearResult;
      final pending = fixture.read(fakeIp ? 'flushFakeIp' : 'clearDnsCache');
      await tester.pump();
      final request = fixture.calls(operation).single;
      expect(request.arguments, isEmpty);
      expect(request.identity['networkRevision'], 9);
      request.complete(expected);
      request.signalExit();
      await tester.pump();
      final result = await pending;
      for (final item in fixture.identity().entries) {
        expect(result[item.key], item.value, reason: item.key);
      }
      expect(result['networkEpoch'], 9);
      expect(result['cache'], expected);
      final parsed = DnsCacheResult.fromMap(result, fakeIp: fakeIp);
      expect(
        parsed.status,
        fakeIp ? DnsCacheStatus.empty : DnsCacheStatus.completed,
      );
      if (fakeIp) {
        expect(parsed.persistent, isFalse);
        expect(parsed.ipv4, (active: false, outcome: DnsCacheOutcome.inactive));
        expect(parsed.ipv6, (active: false, outcome: DnsCacheOutcome.inactive));
      }
      expect(fixture.calls(operation).length, 1);
      expect(fixture.dns.busy, isFalse);
    });
  }

  diagnosticTest('DNS 网络变化后保留原 networkEpoch、空消息和 stale', (
    tester,
    fixture,
  ) async {
    fixture.replaceCore(networkRevision: 9);
    await fixture.warmUp(tester);
    final source = fixture.core;
    final pending = fixture.query();
    await tester.pump();
    final request = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    fixture.replaceCore(networkRevision: 10);
    request.complete(<String, Object?>{}, terminal: {'stale': true});
    request.signalExit();
    await tester.pump();
    final result = await pending;
    expect(result['stale'], isTrue);
    expect(result['networkEpoch'], 9);
    expect(result['networkRevision'], 9);
    expect(result['generation'], source.generation);
    expect(result['composition'], source.composition);
    expect(result['dns'], isEmpty);
  });

  diagnosticTest('DNS 256 KiB 限制包括不改写的完整身份 envelope', (tester, fixture) async {
    fixture.replaceCore(networkRevision: 2);
    await fixture.warmUp(tester);
    const prefix =
        '{"question":{"name":"test.test.","type":"TXT"},"rcode":0,"rcodeName":"NOERROR","elapsedMs":1,"truncated":false,"answer":[{"name":"test.test.","type":"TXT","class":"IN","ttl":60,"data":"';
    const suffix = '"}],"authority":[],"additional":[]}';
    final body =
        prefix +
        'x' * (256 * 1024 - 64 - prefix.length - suffix.length) +
        suffix;
    expect(utf8.encode(body).length, 256 * 1024 - 64);
    final pending = fixture.query(type: 'TXT');
    final rejected = expectLater(pending, throwsA(anything));
    await tester.pump();
    final request = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    request.complete(jsonDecode(body));
    request.signalExit();
    await tester.pump();
    await rejected;
    expect(fixture.dns.busy, isFalse);
  });

  diagnosticTest('DNS 三操作逐字段验证完整身份与 queryOwner 后才提交', (tester, fixture) async {
    fixture.replaceCore(configId: 'dns-main', revision: 7, networkRevision: 3);
    await fixture.warmUp(tester);
    Map<String, Object?> arguments() => {
      ...fixture.identity(),
      'queryOwner': 'dns-request-one',
      'query': {'name': 'test.test', 'type': 'A'},
    };
    for (final method in ['dnsQuery', 'clearDnsCache', 'flushFakeIp']) {
      for (final field in [
        'generation',
        'composition',
        'configId',
        'revision',
        'purpose',
        'processId',
        'inputId',
        'networkRevision',
      ]) {
        final missing = arguments()..remove(field);
        await expectLater(
          fixture.runtime.read(method, missing),
          throwsA(anything),
        );
        final mismatch = arguments()
          ..[field] =
              ['generation', 'revision', 'networkRevision'].contains(field)
              ? -1
              : 'wrong';
        await expectLater(
          fixture.runtime.read(method, mismatch),
          throwsA(anything),
        );
      }
      for (final field in ['generation', 'revision']) {
        await expectLater(
          fixture.runtime.read(method, arguments()..[field] = 1.5),
          throwsA(anything),
        );
      }
    }
    for (final owner in [null, '', 'x' * 129]) {
      await expectLater(
        fixture.runtime.read('dnsQuery', arguments()..['queryOwner'] = owner),
        throwsA(anything),
      );
    }
    expect(fixture.calls(ApplicationContract.coreOperationDnsQuery), isEmpty);
    expect(
      fixture.calls(ApplicationContract.coreOperationDnsCacheClear),
      isEmpty,
    );
    expect(
      fixture.calls(ApplicationContract.coreOperationFakeIpFlush),
      isEmpty,
    );
    fixture.script(ApplicationContract.coreOperationDnsCacheClear, (request) {
      request.complete(_clearResult);
      request.signalExit();
    });
    final cleared = await fixture.read('clearDnsCache');
    expect(cleared['cache'], _clearResult);
    fixture.script(ApplicationContract.coreOperationDnsQuery, (request) {
      request.complete(<String, Object?>{});
      request.signalExit();
    });
    expect((await fixture.query(owner: 'dns-request-one'))['dns'], isEmpty);
    await fixture.runtime.read('cancelDnsQuery', {
      ...arguments(),
      'generation': fixture.core.generation + 1,
    });
    expect(fixture.cancellations, isEmpty);
    expect(
      fixture.calls(ApplicationContract.coreOperationDnsCacheClear).length,
      1,
    );
    expect(fixture.calls(ApplicationContract.coreOperationDnsQuery).length, 1);
  });

  diagnosticTest('DNS 完整消息与未知字段不因分帧而丢失', (tester, fixture) async {
    await fixture.warmUp(tester);
    final message = {
      ..._message(),
      'futureEnvelope': {'a': 1},
    };
    final pending = fixture.query(name: 'TeSt.test', type: 'TXT');
    await tester.pump();
    final request = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    final bytes = utf8.encode(jsonEncode(message));
    for (var offset = 0; offset < bytes.length; offset += 7) {
      final end = offset + 7 < bytes.length ? offset + 7 : bytes.length;
      request.bytes(
        ApplicationContract.coreIpcFrameData,
        Uint8List.fromList(bytes.sublist(offset, end)),
      );
    }
    request.terminal({'complete': true, 'futureTerminal': '原文'});
    request.signalExit();
    await tester.pump();
    final result = await pending;
    expect(result['dns'], message);
    expect((result['dns'] as Map)['futureEnvelope'], {'a': 1});
    final parsed = DnsResponse.fromMap(result);
    expect(parsed.name, 'TeSt.test.');
    expect(parsed.answer.single.data, '"完整消息 原文"');
    expect(parsed.authority.single.data, 'ns.test.');
    expect(parsed.additional.single.data, '192.0.2.7');
    expect(parsed.source.matchesIdentity(fixture.core), isTrue);
    expect(parsed.errorCode, isNull);
  });

  diagnosticTest('DNS 同时保留完整消息、原 error 与独立 cancelError', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final original = {
      'code': 'callFailed',
      'message': 'DNS 原始错误 https://fixture.test/?token=fixture',
      'cause': {'message': 'cause 原文'},
      'suppressed': [
        {'message': 'suppressed 原文'},
      ],
    };
    final cancellation = {
      'message': 'cancel 原文',
      'cause': {'message': 'cancel cause 原文'},
    };
    final message = _message();
    final pending = fixture.query(type: 'TXT');
    await tester.pump();
    final request = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    request.complete(
      message,
      terminal: {'error': original, 'cancelError': cancellation},
    );
    request.signalExit();
    await tester.pump();
    final result = await pending;
    expect(result['dns'], message);
    expect(result['error'], original);
    expect(result['cancelError'], cancellation);
    final parsed = DnsResponse.fromMap(result);
    expect(parsed.errorCode, 'callFailed');
    expect(parsed.cancellationError, cancellation);
    expect(parsed.errorDetail, contains('cause 原文'));
    expect(parsed.errorDetail, contains('suppressed 原文'));
  });

  diagnosticTest('DNS cancel 失败保留原文，迟到结果退出前仍拒绝新查询', (tester, fixture) async {
    await fixture.warmUp(tester);
    const cancellation = {
      'message': 'cancel 原文',
      'cause': {'message': 'cancel cause 原文'},
      'suppressed': [
        {'message': 'cancel suppressed 原文'},
      ],
    };
    fixture.onCancel = (_) => {'cancelError': cancellation};
    final pending = fixture.query(owner: 'old-page');
    await tester.pump();
    final request = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    await fixture.dns.cancel(fixture.core, 'old-page');
    expect(fixture.dns.snapshot()['cancelError'], cancellation);
    request.complete(_message());
    await tester.pump();
    expect(fixture.dns.busy, isTrue);
    await expectLater(
      fixture.query(owner: 'new-page'),
      throwsA(_dnsFailure('busy')),
    );
    request.signalExit();
    await tester.pump();
    final result = await pending;
    expect(result['dns'], _message());
    expect(result['cancelError'], cancellation);
    expect(fixture.dns.busy, isFalse);
    fixture.script(ApplicationContract.coreOperationDnsQuery, (next) {
      next.complete({'rcode': 0});
      next.signalExit();
    });
    expect((await fixture.query(owner: 'new-page'))['dns'], {'rcode': 0});
    expect(fixture.dns.snapshot()['queryOwner'], 'new-page');
    expect(fixture.dns.snapshot()['cancelError'], isNull);
  });

  diagnosticTest('DNS 身份变化和旧退出事件不能取消或释放新查询', (tester, fixture) async {
    await fixture.warmUp(tester);
    final original = fixture.core;
    final pending = fixture.query(owner: 'page');
    await tester.pump();
    final first = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    fixture.replaceCore(
      inputId: 'replacement-input',
      generation: 2,
      composition: 'replacement',
    );
    await fixture.dns.cancel(fixture.core, 'page');
    expect(fixture.cancellations, isEmpty);
    first.complete({'rcode': 0}, terminal: {'stale': true});
    first.signalExit();
    await tester.pump();
    final old = await pending;
    expect(old['inputId'], original.inputId);
    expect(old['stale'], isTrue);
    final next = fixture.query(owner: 'page');
    await tester.pump();
    final second = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .last;
    await fixture.dns.cancel(original, 'page');
    fixture.emit({
      'processId': first.identity['processId'],
      'requestId': first.id,
      'exited': true,
    });
    await tester.pump();
    expect(fixture.cancellations, isEmpty);
    expect(fixture.dns.busy, isTrue);
    expect(second.id, isNot(first.id));
    second.complete({'rcode': 0});
    second.signalExit();
    await tester.pump();
    expect((await next)['inputId'], 'replacement-input');
  });

  for (final nativeTimeout in [false, true]) {
    diagnosticTest(
      nativeTimeout
          ? 'DNS 原 deadline 从开始受理计时，实际 timeout 不被等待结果覆盖'
          : 'DNS 原 deadline 从开始受理计时，取消和返回不重设预算',
      (tester, fixture) async {
        await fixture.warmUp(tester);
        final gate = fixture.gate();
        fixture.script(
          ApplicationContract.coreOperationDnsQuery,
          (_) => gate.future,
        );
        final pending = fixture.query();
        await tester.pump();
        final request = fixture
            .calls(ApplicationContract.coreOperationDnsQuery)
            .single;
        await tester.pump(
          const Duration(
            milliseconds: ApplicationContract.dnsQueryTimeoutMs - 1,
          ),
        );
        expect(fixture.dns.snapshot()['error'], isNull);
        gate.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        expect(fixture.dns.snapshot()['error'], 'timeout');
        expect(fixture.cancellations.single.id, request.id);
        await tester.pump(
          const Duration(
            milliseconds:
                ApplicationContract.dnsBridgeTimeoutMs -
                ApplicationContract.dnsQueryTimeoutMs,
          ),
        );
        expect(fixture.dns.busy, isTrue);
        expect(fixture.dns.snapshot()['errorDetail'], isNotEmpty);
        request.complete(
          {'rcode': 0},
          terminal: {if (nativeTimeout) 'error': actualTimeout},
        );
        request.signalExit();
        await tester.pump();
        final result = await pending;
        if (nativeTimeout) {
          expect(result['operationError'], 'timeout');
          expect(result['error'], actualTimeout);
          expect(fixture.dns.snapshot()['error'], 'timeout');
        } else {
          expect((result['dns'] as Map)['rcode'], 0);
          expect(result.containsKey('operationError'), isFalse);
          expect(result['error'], isNull);
          expect(fixture.dns.snapshot()['error'], isNull);
        }
        expect(fixture.dns.busy, isFalse);
      },
    );
  }

  for (final method in ['dnsQuery', 'clearDnsCache', 'flushFakeIp']) {
    diagnosticTest('裸 $method FD 非对象正文保留原值并由 UI model 拒绝', (
      tester,
      fixture,
    ) async {
      await fixture.warmUp(tester);
      final pending = method == 'dnsQuery'
          ? fixture.query()
          : fixture.read(method);
      await tester.pump();
      final opcode = switch (method) {
        'dnsQuery' => ApplicationContract.coreOperationDnsQuery,
        'clearDnsCache' => ApplicationContract.coreOperationDnsCacheClear,
        _ => ApplicationContract.coreOperationFakeIpFlush,
      };
      final request = fixture.calls(opcode).single;
      const raw = ['原始正文', false, null];
      request.complete(raw);
      await tester.pump();
      expect(fixture.dns.busy, isTrue);
      request.signalExit();
      await tester.pump();
      final value = await pending;
      expect(value[method == 'dnsQuery' ? 'dns' : 'cache'], raw);
      expect(() {
        if (method == 'dnsQuery') {
          DnsResponse.fromMap(value);
        } else {
          DnsCacheResult.fromMap(value, fakeIp: method == 'flushFakeIp');
        }
      }, throwsA(_dnsFailure('invalidResponse')));
      expect(fixture.dns.busy, isFalse);
    });
  }

  diagnosticTest('DNS 无效输入不提交，传输错误等原调用退出后才释放', (tester, fixture) async {
    await fixture.warmUp(tester);
    for (final input in [
      ('', 'A'),
      ('test.test', 'UNKNOWN'),
      ('x' * (ApplicationContract.dnsNameBytes + 1), 'A'),
    ]) {
      await expectLater(
        fixture.query(name: input.$1, type: input.$2),
        throwsA(_dnsFailure('invalidRequest')),
      );
    }
    expect(fixture.calls(ApplicationContract.coreOperationDnsQuery), isEmpty);
    var completed = false;
    final pending = fixture.query();
    final rejection = expectLater(pending, throwsA(isA<PlatformFailure>()));
    pending.then<void>(
      (_) => completed = true,
      onError: (Object _) => completed = true,
    );
    await tester.pump();
    final request = fixture
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    request.frame(ApplicationContract.coreIpcFrameRecord, {'unexpected': true});
    await tester.pump();
    expect(completed, isFalse);
    expect(fixture.dns.busy, isTrue);
    expect(fixture.cancellations.single.id, request.id);
    request.signalExit();
    await tester.pump();
    await rejection;
    expect(completed, isTrue);
    expect(fixture.dns.busy, isFalse);
  });
}
