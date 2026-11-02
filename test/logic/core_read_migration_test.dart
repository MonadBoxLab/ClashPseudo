import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_diagnostic_fixture.dart';
import '../support/core_runtime_fixture.dart';

const _reads = <String, int>{
  'runtimeConfig': ApplicationContract.coreOperationRuntimeConfig,
  'resources': ApplicationContract.coreOperationResources,
  'nodes': ApplicationContract.coreOperationNodes,
  'rules': ApplicationContract.coreOperationRules,
  'updateResource': ApplicationContract.coreOperationResourceUpdate,
};
const _dns = <String, int>{
  'dnsQuery': ApplicationContract.coreOperationDnsQuery,
  'clearDnsCache': ApplicationContract.coreOperationDnsCacheClear,
  'flushFakeIp': ApplicationContract.coreOperationFakeIpFlush,
};

Map<String, dynamic> _originalRow() => {
  'detail': modeStrategyOriginal,
  'future': {'Authorization': modeStrategyOriginal},
  'boolean': false,
  'absent': null,
};

void _completeRead(
  CoreTestRequest request,
  Map<String, dynamic> row, {
  bool exited = true,
  Map<String, dynamic> terminal = const {},
}) {
  if (const [
    ApplicationContract.coreOperationResources,
    ApplicationContract.coreOperationNodes,
    ApplicationContract.coreOperationRules,
  ].contains(request.operation)) {
    request.metadata({'source': request.source, 'origin': 'inline-source'});
    request.record(row);
    request.terminal({
      'complete': true,
      'recordCount': 1,
      'source': request.source,
      'stale': false,
      'exited': exited,
      ...terminal,
    });
  } else {
    request.complete(row, terminal: {'exited': exited, ...terminal});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoreRuntimeFixture fixture;

  Future<void> create() async {
    fixture = await CoreRuntimeFixture.create(preview: true);
    addTearDown(fixture.dispose);
    await fixture.warmUp();
  }

  Future<Object?> read(
    String method, {
    CoreSnapshot? source,
    String search = '',
  }) => fixture.runtime.read(method, {
    ...fixture.identity(source),
    'owner': 'one',
    'admittedAt': fixture.admittedAt,
    'deadline': fixture.deadline,
    'queryOwner': 'fixture',
    'query': {
      if (method == 'dnsQuery') ...{'name': 'test.test', 'type': 'A'},
      if (method == 'nodes' || method == 'rules') ...{
        'offset': 0,
        'limit': 50,
        'search': search,
        if (method == 'rules') 'kind': 'main',
      },
      if (method == 'updateResource') ...{'kind': 'geo', 'name': 'GeoIP'},
    },
  }, operation: fixture.operation);

  Map<String, dynamic> decoded(Object? result) =>
      Map<String, dynamic>.from(jsonDecode(result as String) as Map);

  void expectIdentity(Map<String, dynamic> value, CoreSnapshot source) {
    for (final item in fixture.identity(source).entries) {
      expect(value[item.key], item.value, reason: item.key);
    }
  }

  Map rowFrom(String method, Map<String, dynamic> value) => switch (method) {
    'runtimeConfig' => value['configuration'] as Map,
    'resources' => (value['resources'] as List).single as Map,
    'nodes' => ((value['page'] as Map)['nodes'] as List).single as Map,
    'rules' => ((value['page'] as Map)['rows'] as List).single as Map,
    _ => value,
  };

  test('CoreReadCallsTest.stoppedLogsReadTheirWindowAndKeepCapturedResultsAfterReplacement', () async {
    fixture = await CoreRuntimeFixture.create(preview: true);
    addTearDown(fixture.dispose);
    fixture.script(ApplicationContract.coreOperationLogs, (request) {
      request.metadata({'source': request.source});
      request.record({'seq': 1, 'level': 'info', 'text': modeStrategyOriginal});
      request.terminal({'complete': true, 'exited': true});
    });
    await fixture.warmUp();
    final source = fixture.core;
    final window = fixture.runtime.logs.source;
    expect(window, isNotNull);
    fixture.replaceCore(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    final captured = decoded(
      await fixture.runtime.read('logs', {
        'query': {'window': window},
      }),
    );
    expectIdentity(captured, source);
    expect(
      (((captured['logs'] as Map)['entries'] as List).single as Map)['text'],
      modeStrategyOriginal,
    );
    expect(fixture.calls(ApplicationContract.coreOperationLogs), hasLength(1));
    fixture.replaceCore(
      processId: 'replacement',
      inputId: 'replacement-input',
      generation: 2,
    );
    await fixture.runtime.restoreExisting();
    final old = FutureProbe(
      fixture.runtime.read('logs', {
        'query': {'window': window},
      }),
    );
    await old.done;
    expect(old.value, isNull);
    expect(old.error, isA<PlatformFailure>());
    expect(fixture.calls(ApplicationContract.coreOperationLogs), hasLength(2));
    expect(
      (((captured['logs'] as Map)['entries'] as List).single as Map)['text'],
      modeStrategyOriginal,
    );
  });

  test(
    'CoreReadCallsTest.queryChecksCapturedCompositionBeforeExecution',
    () async {
      await create();
      final source = fixture.core;
      fixture.script(
        ApplicationContract.coreOperationRuntimeConfig,
        (request) => request.complete({'mode': 'rule'}),
      );
      final first = decoded(await read('runtimeConfig'));
      expectIdentity(first, source);
      expect((first['configuration'] as Map)['mode'], 'rule');
      fixture.replaceCore(
        composition: 'replacement-composition',
        generation: 2,
      );
      final result = FutureProbe(read('runtimeConfig', source: source));
      await result.done;
      expect(result.value, isNull);
      expect(result.error, isA<PlatformFailure>());
      expect(
        fixture.calls(ApplicationContract.coreOperationRuntimeConfig),
        hasLength(1),
      );
    },
  );

  test('CoreReadCallsTest.executingPageDeadlineKeepsItsOriginalReplyAndBusyReportsActualPending', () async {
    await create();
    fixture.script(ApplicationContract.coreOperationRules, (_) {});
    fixture.script(
      ApplicationContract.coreOperationRules,
      (request) =>
          _completeRead(request, {'payload': 'unexpected-second-read'}),
    );
    final source = fixture.core;
    final entered = fixture.next(ApplicationContract.coreOperationRules);
    final first = FutureProbe(read('rules'));
    final request = await entered;
    fixture.expire();
    await fixture.flush();
    expect(first.replies, 0);
    final pending = FutureProbe(read('rules'));
    await fixture.flush();
    expect(pending.settled, isTrue);
    final value = decoded(pending.value);
    expect(value['readPending'], isTrue);
    expectIdentity(value, source);
    expect(value.containsKey('page'), isFalse);
    expect(fixture.calls(ApplicationContract.coreOperationRules), hasLength(1));
    _completeRead(request, {'original': true});
    await first.done;
    expect(first.replies, 1);
    expect(((decoded(first.value)['page'] as Map)['rows'] as List).single, {
      'original': true,
    });
  });

  test('CoreReadCallsTest.slowPagesReturnTheirOriginalCompletionThenRefreshExecutesAgain', () async {
    await create();
    fixture.script(
      ApplicationContract.coreOperationRules,
      (request) => _completeRead(request, {'execution': 1}, exited: false),
    );
    final entered = fixture.next(ApplicationContract.coreOperationRules);
    final first = FutureProbe(read('rules'));
    final request = await entered;
    fixture.expire();
    await fixture.flush();
    expect(first.settled, isFalse);
    request.signalExit();
    await first.done;
    final value = decoded(first.value);
    expectIdentity(value, fixture.core);
    expect(value['stale'] ?? false, isFalse);
    expect(((value['page'] as Map)['rows'] as List).single, {'execution': 1});
    fixture.operationExpired = false;
    fixture.now = fixture.admittedAt;
    fixture.script(
      ApplicationContract.coreOperationRules,
      (request) => _completeRead(request, {'execution': 2}),
    );
    final refreshed = decoded(await read('rules'));
    expect(((refreshed['page'] as Map)['rows'] as List).single, {
      'execution': 2,
    });
    expect(fixture.calls(ApplicationContract.coreOperationRules), hasLength(2));
    expect(first.replies, 1);
  });

  for (final method in ['rules', 'runtimeConfig']) {
    test(
      'CoreReadCallsTest.${method == 'rules' ? 'pageDeadlineBeforeWorkerAdmissionRejectsWithoutEnteringNativeAndAllowsRetry' : 'timedOutQueuedReadDoesNotQueryAndRepliesOnce'}',
      () async {
        await create();
        final entered = Completer<void>();
        final release = Completer<void>();
        fixture.beforePlatformCall = (call) async {
          if (call.method == 'snapshot' && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          return null;
        };
        fixture.script(
          _reads[method]!,
          (request) => _completeRead(request, {'ready': true}),
        );
        final result = FutureProbe(read(method));
        await entered.future;
        fixture.expire();
        release.complete();
        await result.done;
        expect(result.replies, 1);
        expect(result.value, isNull);
        expect(result.error, isNotNull);
        expect(fixture.calls(_reads[method]!), isEmpty);
        fixture.operationExpired = false;
        fixture.now = fixture.admittedAt;
        fixture.script(
          _reads[method]!,
          (request) => _completeRead(request, {'ready': true}),
        );
        expect(rowFrom(method, decoded(await read(method)))['ready'], isTrue);
        expect(fixture.calls(_reads[method]!), hasLength(1));
      },
    );
  }

  test('CoreReadCallsTest.latePagesStayWithTheirOriginalQueryMethodAndIdentityWithoutCachingReplies', () async {
    await create();
    final source = fixture.core;
    final row = {'search': 'original', ..._originalRow()};
    fixture.script(
      ApplicationContract.coreOperationRules,
      (request) => _completeRead(request, row, exited: false),
    );
    final entered = fixture.next(ApplicationContract.coreOperationRules);
    final result = FutureProbe(read('rules', search: 'original'));
    final request = await entered;
    fixture.replaceCore(
      processId: 'replacement',
      inputId: 'replacement-input',
      generation: 2,
    );
    await fixture.flush();
    expect(result.replies, 0);
    request.signalExit();
    await result.done;
    expect(result.error, isNull);
    final value = decoded(result.value);
    expectIdentity(value, source);
    expect(value['stale'], isTrue);
    expect(rowFrom('rules', value), row);
    expect(fixture.calls(ApplicationContract.coreOperationRules), hasLength(1));
    fixture.script(
      ApplicationContract.coreOperationRules,
      (request) => _completeRead(request, {'search': 'current'}),
    );
    final refreshed = decoded(await read('rules', search: 'current'));
    expect(rowFrom('rules', refreshed)['search'], 'current');
    expect(fixture.calls(ApplicationContract.coreOperationRules), hasLength(2));
  });

  test(
    'CoreReadCallsTest.resourcesReplyCarriesTheRowListNotTheCoreEnvelope',
    () async {
      await create();
      fixture.script(
        ApplicationContract.coreOperationResources,
        (request) =>
            _completeRead(request, {'name': 'GeoIP', ..._originalRow()}),
      );
      final value = decoded(await read('resources'));
      expect(value['resources'], isA<List>());
      expect((value['resources'] as List).single, {
        'name': 'GeoIP',
        ..._originalRow(),
      });
    },
  );

  for (final method in _reads.keys) {
    test('独立 native receipt 结束前不复用 $method slot，原错误返回后允许重试', () async {
      await create();
      final failure = nativeFailure('java.io.IOException');
      fixture.script(
        _reads[method]!,
        (request) => _completeRead(request, _originalRow(), exited: false),
      );
      final entered = fixture.next(_reads[method]!);
      final first = FutureProbe(read(method));
      final request = await entered;
      await fixture.flush();
      expect(first.replies, 0);
      fixture.expire();
      final pending = decoded(await read(method));
      expect(pending['readPending'], isTrue);
      expect(pending.containsKey('page'), isFalse);
      expect(fixture.calls(_reads[method]!), hasLength(1));
      expect(first.replies, 0);
      request.signalExit(receipt: {'error': failure});
      await first.done;
      expect(first.value, isNull);
      expectOriginalError(first.error, failure);
      expect(first.replies, 1);
      fixture.operationExpired = false;
      fixture.now = fixture.admittedAt;
      fixture.script(
        _reads[method]!,
        (request) => _completeRead(request, {'ready': true}),
      );
      expect(rowFrom(method, decoded(await read(method)))['ready'], isTrue);
      expect(fixture.calls(_reads[method]!), hasLength(2));
    });
    for (final kind in [
      'java.io.IOException',
      'java.lang.UnsatisfiedLinkError',
    ]) {
      test(
        'CoreReadCallsErrorTest.nativeAndLinkageReadFailuresKeepTheirActualCause $method $kind',
        () async {
          await create();
          final failure = nativeFailure(kind);
          fixture.script(
            _reads[method]!,
            (request) => _completeRead(
              request,
              {},
              terminal: {'complete': false, 'error': failure},
            ),
          );
          final result = FutureProbe(read(method));
          await result.done;
          expect(result.value, isNull);
          expectOriginalError(result.error, failure);
          expect(result.replies, 1);
          expect(fixture.runtime.dns.busy, isFalse);
          expect(fixture.exits, isEmpty);
        },
      );
    }

    test(
      'CoreReadCallsErrorTest.wireReadFailuresKeepAllFieldsInsteadOfOnlyStableCodes $method',
      () async {
        await create();
        final raw = jsonEncode({
          'error': 'future-error',
          'detail': modeStrategyOriginal,
          'future': {'Authorization': modeStrategyOriginal},
        });
        fixture.script(
          _reads[method]!,
          (request) => _completeRead(
            request,
            {},
            terminal: {'complete': false, 'error': raw},
          ),
        );
        final result = FutureProbe(read(method));
        await result.done;
        expect(result.value, isNull);
        expect(errorText(result.error), contains(raw));
        expect(result.replies, 1);
        expect(fixture.runtime.dns.busy, isFalse);
      },
    );

    test(
      'CoreReadCallsErrorTest.contextChangedDuringAReadDoesNotEraseItsActualFailure $method',
      () async {
        await create();
        final source = fixture.core;
        final failure = nativeFailure('java.io.IOException');
        fixture.script(_reads[method]!, (request) {
          fixture.replaceCore(
            processId: 'replacement',
            inputId: 'replacement-input',
            generation: 2,
          );
          _completeRead(
            request,
            {},
            terminal: {'complete': false, 'error': failure},
          );
        });
        final result = FutureProbe(read(method, source: source));
        await result.done;
        expect(result.value, isNull);
        expectOriginalError(result.error, failure);
        expect(fixture.core.processId, 'replacement');
        expect(fixture.exits, isEmpty);
      },
    );

    test(
      'CoreReadCallsErrorTest.executingReadsKeepTheirCompleteCapturedResultAfterDeadlineAndSourceChanges $method',
      () async {
        await create();
        final source = fixture.core;
        final row = _originalRow();
        fixture.script(
          _reads[method]!,
          (request) => _completeRead(request, row, exited: false),
        );
        final entered = fixture.next(_reads[method]!);
        final result = FutureProbe(read(method));
        final request = await entered;
        fixture.expire();
        fixture.replaceCore(
          processId: 'replacement',
          inputId: 'replacement-input',
          generation: 2,
        );
        await fixture.flush();
        expect(result.replies, 0);
        request.signalExit();
        await result.done;
        expect(result.error, isNull);
        expect(result.replies, 1);
        final value = decoded(result.value);
        expectIdentity(value, source);
        expect(value['stale'], isTrue);
        final actual = rowFrom(method, value);
        for (final item in row.entries) {
          expect(actual.containsKey(item.key), isTrue, reason: item.key);
          expect(actual[item.key], item.value, reason: item.key);
        }
        expect(fixture.runtime.dns.busy, isFalse);
        expect(fixture.exits, isEmpty);
      },
    );

    for (final kind in [
      'java.io.IOException',
      'java.lang.UnsatisfiedLinkError',
    ]) {
      test(
        'CoreReadCallsErrorTest.executingReadFailuresKeepTheirCauseAfterTheDeadlineAndStop $method $kind',
        () async {
          await create();
          final failure = nativeFailure(kind);
          fixture.script(
            _reads[method]!,
            (request) => _completeRead(
              request,
              {},
              exited: false,
              terminal: {'complete': false, 'error': failure},
            ),
          );
          final entered = fixture.next(_reads[method]!);
          final result = FutureProbe(read(method));
          final request = await entered;
          fixture.expire();
          fixture.replaceCore(phase: 'EMPTY');
          await fixture.flush();
          expect(result.replies, 0);
          request.signalExit();
          await result.done;
          expect(result.value, isNull);
          expectOriginalError(result.error, failure);
          expect(result.replies, 1);
          expect(fixture.runtime.dns.busy, isFalse);
        },
      );
    }

    test(
      'CoreReadCallsErrorTest.malformedReadWiresKeepThePublicParserErrorAndCompleteOriginalInput $method',
      () async {
        await create();
        fixture.script(_reads[method]!, (request) {
          final collection = const [
            ApplicationContract.coreOperationNodes,
            ApplicationContract.coreOperationRules,
            ApplicationContract.coreOperationResources,
          ].contains(request.operation);
          if (collection) request.metadata({'source': request.source});
          request.bytes(
            collection
                ? ApplicationContract.coreIpcFrameRecord
                : ApplicationContract.coreIpcFrameData,
            Uint8List.fromList(utf8.encode(modeStrategyOriginal)),
          );
          request.terminal({
            'complete': true,
            'exited': false,
            'recordCount': 1,
            'source': request.source,
          });
        });
        final entered = fixture.next(_reads[method]!);
        final result = FutureProbe(read(method));
        final request = await entered;
        await fixture.flush();
        expect(result.settled, isFalse);
        expect(
          request.cancellations,
          ['resources', 'nodes', 'rules'].contains(method) ? 1 : 0,
        );
        request.signalExit();
        await result.done;
        expect(result.value, isNull);
        expect(result.error, isA<FormatException>());
        expect((result.error as FormatException).source, modeStrategyOriginal);
        expect(errorText(result.error), contains(modeStrategyOriginal));
        expect(result.replies, 1);
      },
    );

    for (final kind in [
      'java.util.concurrent.RejectedExecutionException',
      'java.lang.UnsatisfiedLinkError',
    ]) {
      test(
        'CoreReadCallsErrorTest.${kind.endsWith('UnsatisfiedLinkError') ? 'readWorkerRejectionsKeepLinkageErrorsAndReleaseActualReservations' : 'workerRejectionsReplyOnceWithTheirActualCauseAndAllowRetry'} $method',
        () async {
          await create();
          final failure = nativeFailure(kind);
          fixture.beforePlatformCall = (call) {
            if (call.method == ApplicationContract.coreChannelSubmit &&
                (call.arguments as Map)['operation'] == _reads[method]) {
              throw PlatformException(code: 'callFailed', details: failure);
            }
            return null;
          };
          final result = FutureProbe(read(method));
          await result.done;
          expect(result.value, isNull);
          expectOriginalError(result.error, failure);
          expect(result.replies, 1);
          expect(fixture.calls(_reads[method]!), isEmpty);
          expect(fixture.runtime.dns.busy, isFalse);
          fixture.beforePlatformCall = null;
          fixture.script(
            _reads[method]!,
            (request) => _completeRead(request, {'ready': true}),
          );
          expect(rowFrom(method, decoded(await read(method)))['ready'], isTrue);
          expect(fixture.calls(_reads[method]!), hasLength(1));
        },
      );
    }
  }

  for (final method in _dns.keys) {
    for (final kind in [
      'java.io.IOException',
      'java.lang.UnsatisfiedLinkError',
    ]) {
      test(
        'CoreReadCallsErrorTest.nativeAndLinkageReadFailuresKeepTheirActualCause $method $kind',
        () async {
          await create();
          final failure = nativeFailure(kind);
          fixture.script(
            _dns[method]!,
            (request) => request.complete(
              {},
              terminal: {'complete': false, 'error': failure},
            ),
          );
          final result = FutureProbe(read(method));
          await result.done;
          expect(result.error, isNull);
          expect(decoded(result.value)['error'], failure);
          expect(
            decoded(result.value)['operationErrorDetail'],
            failure.toString(),
          );
          expect(result.replies, 1);
          expect(fixture.runtime.dns.busy, isFalse);
          expect(fixture.exits, isEmpty);
        },
      );
      for (final action in ['cancel', 'timeout', 'network', 'stop']) {
        diagnosticTest(
          'CoreReadCallsErrorTest.executingDnsFailuresKeepTheirCauseAfterCancellationTimeoutAndContextChanges $method $kind $action',
          (tester, transport) async {
            await transport.warmUp(tester);
            final source = transport.core;
            final failure = nativeFailure(kind);
            transport.script(
              _dns[method]!,
              (request) => request.complete(
                {},
                terminal: {'complete': false, 'error': failure},
              ),
            );
            final result = FutureProbe(
              transport.read(
                method,
                arguments: {
                  'queryOwner': 'fixture',
                  'query': {'name': 'test.test', 'type': 'A'},
                },
              ),
            );
            await tester.pump();
            final request = transport.calls(_dns[method]!).single;
            final owner = transport.dns.snapshot()['queryOwner'] as String;
            if (action == 'cancel') await transport.dns.cancel(source, owner);
            if (action == 'timeout') {
              await tester.pump(
                const Duration(
                  milliseconds: ApplicationContract.dnsQueryTimeoutMs,
                ),
              );
            }
            if (action == 'network') transport.replaceCore(networkRevision: 9);
            if (action == 'stop') transport.replaceCore(phase: 'EMPTY');
            await tester.pump();
            expect(result.replies, 0);
            expect(transport.dns.busy, isTrue);
            if (action == 'cancel' || action == 'timeout') {
              expect(transport.cancellations, [request]);
            }
            request.signalExit();
            await tester.pump();
            expect(result.error, isNull);
            final value = result.value as Map;
            expect(value['error'], failure);
            expect(value['operationErrorDetail'], failure.toString());
            expect(value['processId'], source.processId);
            expect(value['networkRevision'], source.networkRevision);
            expect(transport.dns.busy, isFalse);
            expect(result.replies, 1);
          },
        );
      }
    }
    test(
      'CoreReadCallsErrorTest.oversizedNativeDnsAndCacheErrorsKeepCompleteDetailsOnTheFailureChannel $method',
      () async {
        await create();
        final detail = 'native error $modeStrategyOriginal\n' * 8192;
        final native = {'error': 'queryFailed', 'detail': detail};
        fixture.script(
          _dns[method]!,
          (request) => request.complete(
            {},
            terminal: {'complete': false, 'error': native},
          ),
        );
        final result = FutureProbe(read(method));
        await result.done;
        expect(result.value, isNull);
        expect(result.error, isA<PlatformFailure>());
        final failure = result.error as PlatformFailure;
        expect(failure.code, ApplicationContract.coreErrorResultTooLarge);
        expect(
          (((failure.details as Map)['result'] as Map)['error']
              as Map)['detail'],
          detail,
        );
        expect(result.replies, 1);
        expect(fixture.runtime.dns.busy, isFalse);
      },
    );
    for (final action in ['cancel', 'timeout', 'network', 'stop']) {
      for (final nativeError in [false, true]) {
        diagnosticTest(
          'CoreReadCallsErrorTest.executingDnsAndCacheCallsKeepActualResultsThroughInterruptionAndSourceChanges $method $action nativeError=$nativeError',
          (tester, transport) async {
            await transport.warmUp(tester);
            final source = transport.core;
            final raw = {
              nativeError ? 'error' : 'status': nativeError
                  ? 'future-error'
                  : 'ok',
              ..._originalRow(),
            };
            transport.script(
              _dns[method]!,
              (request) => request.complete(
                raw,
                terminal: {'stale': action == 'network' || action == 'stop'},
              ),
            );
            final result = FutureProbe(
              transport.read(
                method,
                arguments: {
                  'queryOwner': 'fixture',
                  'query': {'name': 'test.test', 'type': 'A'},
                },
              ),
            );
            await tester.pump();
            final request = transport.calls(_dns[method]!).single;
            if (action == 'cancel') {
              await transport.dns.cancel(
                source,
                transport.dns.snapshot()['queryOwner'] as String,
              );
            }
            if (action == 'timeout') {
              await tester.pump(
                const Duration(
                  milliseconds: ApplicationContract.dnsQueryTimeoutMs,
                ),
              );
            }
            if (action == 'network') transport.replaceCore(networkRevision: 9);
            if (action == 'stop') transport.replaceCore(phase: 'EMPTY');
            await tester.pump();
            expect(result.replies, 0);
            expect(transport.dns.busy, isTrue);
            if (action == 'cancel' || action == 'timeout') {
              expect(transport.cancellations, [request]);
            }
            request.signalExit();
            await tester.pump();
            expect(result.error, isNull);
            final value = result.value as Map;
            expect(value['processId'], source.processId);
            expect(value['generation'], source.generation);
            expect(value['composition'], source.composition);
            expect(value['networkEpoch'], source.networkRevision);
            expect(value[method == 'dnsQuery' ? 'dns' : 'cache'], raw);
            expect(
              value['stale'] ?? false,
              action == 'network' || action == 'stop',
            );
            expect(transport.dns.busy, isFalse);
            expect(result.replies, 1);
          },
        );
      }
    }

    test(
      'CoreReadCallsErrorTest.executingDnsFailuresKeepTheirCauseAfterCancellationTimeoutAndContextChanges $method',
      () async {
        await create();
        final failure = nativeFailure('java.io.IOException');
        fixture.script(
          _dns[method]!,
          (request) => request.complete(
            {},
            terminal: {'complete': false, 'error': failure, 'exited': false},
          ),
        );
        final entered = fixture.next(_dns[method]!);
        final result = FutureProbe(read(method));
        final request = await entered;
        await fixture.runtime.dns.cancel(fixture.core, 'fixture');
        fixture.expire();
        fixture.replaceCore(phase: 'EMPTY');
        await fixture.flush();
        expect(result.replies, 0);
        expect(fixture.runtime.dns.busy, isTrue);
        request.signalExit();
        await result.done;
        final value = decoded(result.value);
        expect(value['error'], failure);
        expect(value['operationErrorDetail'], failure.toString());
        expect(fixture.runtime.dns.busy, isFalse);
        expect(result.replies, 1);
      },
    );

    test(
      'CoreReadCallsErrorTest.rejectedDnsWorkersKeepExceptionAndLinkageCausesAndReleaseOnlyActualReservations $method',
      () async {
        await create();
        for (final kind in [
          'java.util.concurrent.RejectedExecutionException',
          'java.lang.UnsatisfiedLinkError',
        ]) {
          final failure = nativeFailure(kind);
          fixture.beforePlatformCall = (call) {
            if (call.method == ApplicationContract.coreChannelSubmit &&
                (call.arguments as Map)['operation'] == _dns[method]) {
              throw PlatformException(code: 'callFailed', details: failure);
            }
            return null;
          };
          final result = FutureProbe(read(method));
          await result.done;
          expectOriginalError(result.error, failure);
          expect(result.value, isNull);
          expect(fixture.calls(_dns[method]!), isEmpty);
          expect(fixture.runtime.dns.busy, isFalse);
        }
        fixture.beforePlatformCall = null;
        fixture.script(_dns[method]!, (request) => request.complete({}));
        expect(await read(method), isA<String>());
        expect(fixture.runtime.dns.busy, isFalse);
      },
    );

    test(
      'CoreReadCallsErrorTest.malformedDnsAndCacheWiresKeepTheParserErrorAndCompleteOriginalInput $method',
      () async {
        await create();
        fixture.script(_dns[method]!, (request) {
          request.bytes(
            ApplicationContract.coreIpcFrameData,
            Uint8List.fromList(utf8.encode(modeStrategyOriginal)),
          );
          request.terminal({'complete': true, 'exited': false});
        });
        final entered = fixture.next(_dns[method]!);
        final result = FutureProbe(read(method));
        final request = await entered;
        await fixture.flush();
        expect(result.settled, isFalse);
        expect(request.cancellations, 0);
        expect(fixture.runtime.dns.busy, isTrue);
        request.signalExit();
        await result.done;
        expect(result.error, isA<FormatException>());
        expect((result.error as FormatException).source, modeStrategyOriginal);
        expect(result.value, isNull);
        expect(fixture.runtime.dns.busy, isFalse);
      },
    );
  }

  for (final kind in [
    'java.io.IOException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    test(
      'CoreReadCallsErrorTest.cancellationErrorsKeepBothRepliesAndStillAllowTheActualQueryToSucceed $kind',
      () async {
        await create();
        final failure = {
          ...nativeFailure(kind),
          'cause': nativeFailure('java.lang.IllegalStateException'),
          'suppressed': [nativeFailure('java.io.IOException')],
        };
        fixture.onCancel = (_) => {
          'cancelRequested': false,
          'cancelError': failure,
        };
        fixture.script(ApplicationContract.coreOperationDnsQuery, (_) {});
        final entered = fixture.next(ApplicationContract.coreOperationDnsQuery);
        final result = FutureProbe(read('dnsQuery'));
        final request = await entered;
        await fixture.runtime.dns.cancel(fixture.core, 'fixture');
        await fixture.flush();
        expect(result.replies, 0);
        expect(fixture.runtime.dns.busy, isTrue);
        expect(fixture.runtime.dns.snapshot()['cancelError'], failure);
        request.complete({'rcode': 0, 'detail': modeStrategyOriginal});
        await result.done;
        final value = decoded(result.value);
        expect(value['dns'], {'rcode': 0, 'detail': modeStrategyOriginal});
        expect(value['cancelError'], failure);
        expect(fixture.runtime.dns.busy, isFalse);
        expect(result.replies, 1);
      },
    );
  }

  test('CoreReadCallsErrorTest.capturedQueryCanStillBeCancelledAfterItsCoreWasReleased', () async {
    await create();
    final source = fixture.core;
    fixture.script(ApplicationContract.coreOperationDnsQuery, (_) {});
    final entered = fixture.next(ApplicationContract.coreOperationDnsQuery);
    final result = FutureProbe(read('dnsQuery'));
    final request = await entered;
    fixture.replaceCore(phase: 'EMPTY');
    await fixture.runtime.dns.cancel(source, 'wrong-owner');
    expect(request.cancellations, 0);
    await fixture.runtime.dns.cancel(source, 'fixture');
    expect(request.cancellations, 1);
    expect(fixture.runtime.dns.busy, isTrue);
    request.complete(
      {'rcode': 0, 'detail': modeStrategyOriginal},
      terminal: {'stale': true},
    );
    await result.done;
    final value = decoded(result.value);
    expectIdentity(value, source);
    expect(value['stale'], isTrue);
    expect(value['dns'], {'rcode': 0, 'detail': modeStrategyOriginal});
    expect(fixture.runtime.dns.busy, isFalse);
  });

  for (final (exitedBeforeRead, retryFails) in [
    (true, false),
    (false, false),
    (false, true),
  ]) {
    test(
      'CoreCall PREPARE 取消失败后 FD 读取失败保留原错误与 receipt：${exitedBeforeRead
          ? '已确认 exited'
          : retryFails
          ? '再次 cancel 失败后等待 exited'
          : '再次 cancel 成功后等待 exited'}',
      () async {
        await create();
        final cancellation = PlatformException(
          code: 'cancel-rejected',
          message: '取消请求被拒绝',
          details: {
            ...nativeFailure('java.util.concurrent.RejectedExecutionException'),
            'cause': nativeFailure('java.io.IOException'),
            'suppressed': [nativeFailure('java.lang.UnsatisfiedLinkError')],
          },
        );
        final readFailure = PlatformException(
          code: ApplicationContract.coreErrorTransportInterrupted,
          message: 'FD 读取失败',
          details: nativeFailure('java.io.IOException'),
        );
        final receipt = {
          'exited': true,
          'future': {'Authorization': modeStrategyOriginal},
          'values': [false, null],
        };
        final retryCancellation = {
          'accepted': true,
          'exited': false,
          'future': {'Authorization': modeStrategyOriginal},
        };
        final retryFailure = PlatformException(
          code: 'retry-cancel-rejected',
          message: '再次取消请求被拒绝',
          details: nativeFailure('java.lang.UnsatisfiedLinkError'),
        );
        fixture.script(ApplicationContract.coreOperationPrepare, (_) {});
        fixture.onCancel = (request) {
          if (request.cancellations == 1) throw cancellation;
          if (retryFails) throw retryFailure;
          return retryCancellation;
        };
        final call = await fixture.client.submit(
          ApplicationContract.coreOperationPrepare,
          fixture.runtime.identity(fixture.core),
          inputId: fixture.core.inputId,
          owner: 'one',
          arguments: {
            'admittedAt': fixture.admittedAt,
            'deadline': fixture.deadline,
          },
        );
        final request = fixture
            .calls(ApplicationContract.coreOperationPrepare)
            .single;
        await call.requestCancellation();
        expect(request.cancellations, 1);
        expect(call.hasExited, isFalse);
        if (exitedBeforeRead) request.signalExit(receipt: receipt);
        expect(call.hasExited, exitedBeforeRead);
        final result = FutureProbe(
          call.result(maximumBytes: ApplicationContract.coreIpcFrameBytes),
        );
        request.interrupt(readFailure);
        await fixture.flush();
        if (!exitedBeforeRead) {
          expect(request.cancellations, 2);
          expect(result.replies, 0);
          expect(call.hasExited, isFalse);
          request.signalExit(receipt: receipt);
        }
        await result.done;
        expect(result.value, isNull);
        expect(result.error, isA<PlatformFailure>());
        final failure = result.error as PlatformFailure;
        expect(failure.code, readFailure.code);
        expect(failure.details, {
          'error': {
            'code': readFailure.code,
            'message': readFailure.message,
            'details': readFailure.details,
          },
          'cancelError': {
            'code': retryFails ? retryFailure.code : cancellation.code,
            'message': retryFails ? retryFailure.message : cancellation.message,
            'details': retryFails ? retryFailure.details : cancellation.details,
          },
          if (retryFails)
            'previousCancelError': {
              'code': cancellation.code,
              'message': cancellation.message,
              'details': cancellation.details,
            },
          'nativeReceipt': receipt,
          if (!exitedBeforeRead && !retryFails)
            'cancellation': retryCancellation,
        });
        expect(call.receipt, receipt);
        expect(call.hasExited, isTrue);
        expect(request.cancellations, exitedBeforeRead ? 1 : 2);
        expect(result.replies, 1);
        expect(fixture.exits, isEmpty);
      },
    );
  }

  for (final method in _dns.keys) {
    test(
      'CoreReadCallsErrorTest.oversizedDnsChannelResultsHaveAMachineCodeAndCompleteNativeAndAutomaticCancelErrors $method',
      () async {
        await create();
        final nativeDetail = 'native error $modeStrategyOriginal\n' * 8192;
        final native = {
          ...nativeFailure('java.io.IOException'),
          'detail': nativeDetail,
        };
        final cancellation = {
          ...nativeFailure('java.lang.UnsatisfiedLinkError'),
          'cause': {'message': modeStrategyOriginal},
          'suppressed': [
            {'message': modeStrategyOriginal},
          ],
        };
        fixture.onCancel = (_) => {'cancelError': cancellation};
        fixture.script(_dns[method]!, (request) {
          request.data({'error': 'queryFailed', 'detail': nativeDetail});
          request.terminal({
            'complete': false,
            'error': native,
            'exited': false,
          });
        });
        final entered = fixture.next(_dns[method]!);
        final result = FutureProbe(read(method));
        final request = await entered;
        await fixture.flush();
        expect(request.cancellations, 1);
        expect(result.settled, isFalse);
        request.signalExit(
          receipt: {'error': native, 'cancelError': cancellation},
        );
        await result.done;
        expect(result.value, isNull);
        expect(result.error, isA<PlatformFailure>());
        expect(
          (result.error as PlatformFailure).code,
          ApplicationContract.coreErrorResultTooLarge,
        );
        expect(errorText(result.error), contains(native.toString()));
        expect(errorText(result.error), contains(cancellation.toString()));
        expect(fixture.runtime.dns.busy, isFalse);
        expect(result.replies, 1);
      },
    );
  }

  for (final action in ['explicit', 'background', 'timeout']) {
    diagnosticTest(
      'CoreReadCallsErrorTest.oversizedCancellationFeedbackRejectsTheWholeDnsEnvelopeWithoutTruncatingItsCause $action',
      (tester, transport) async {
        await transport.warmUp(tester);
        final source = transport.core;
        final failure = {
          ...nativeFailure('java.io.IOException'),
          'message': '原文🙂' * ApplicationContract.dnsResultBytes,
          'cause': nativeFailure('java.lang.IllegalStateException')
            ..['message'] = 'original cause $modeStrategyOriginal',
          'suppressed': [
            nativeFailure('java.io.IOException')
              ..['message'] = 'original close $modeStrategyOriginal',
          ],
        };
        transport.onCancel = (_) => {'cancelError': failure};
        transport.script(ApplicationContract.coreOperationDnsQuery, (_) {});
        final result = FutureProbe(transport.query(owner: 'fixture'));
        await tester.pump();
        final request = transport
            .calls(ApplicationContract.coreOperationDnsQuery)
            .single;
        if (action == 'explicit') {
          await transport.runtime.read('cancelDnsQuery', {
            ...transport.identity(source),
            'queryOwner': 'fixture',
          });
        } else if (action == 'background') {
          transport.runtime.event({'event': 'uiVisibility', 'visible': false});
        } else {
          await tester.pump(
            const Duration(milliseconds: ApplicationContract.dnsQueryTimeoutMs),
          );
        }
        await tester.pump();
        expect(transport.cancellations, [request]);
        expect(transport.dns.snapshot()['cancelError'], failure);
        expect(transport.dns.busy, isTrue);
        expect(result.replies, 0);
        request.complete({'rcode': 0, 'detail': modeStrategyOriginal});
        await tester.pump();
        expect(result.replies, 0);
        expect(transport.dns.busy, isTrue);
        request.signalExit();
        await tester.pump();
        expect(result.value, isNull);
        expect(result.error, isA<PlatformFailure>());
        final error = result.error as PlatformFailure;
        expect(error.code, ApplicationContract.coreErrorResultTooLarge);
        final retained = ((error.details as Map)['result'] as Map);
        expect(retained['dns'], {'rcode': 0, 'detail': modeStrategyOriginal});
        expect(retained['cancelError'], failure);
        expect(transport.dns.busy, isFalse);
        expect(result.replies, 1);
      },
    );
  }

  diagnosticTest('后台取消在 DNS admission 返回后执行，立即恢复可见也不释放原 slot', (
    tester,
    transport,
  ) async {
    await transport.warmUp(tester);
    final gate = transport.gate();
    final cancellation = nativeFailure('java.lang.UnsatisfiedLinkError');
    transport.onCancel = (_) => {'cancelError': cancellation};
    transport.script(
      ApplicationContract.coreOperationDnsQuery,
      (_) => gate.future,
    );
    final result = FutureProbe(transport.query(owner: 'original-owner'));
    await tester.pump();
    final request = transport
        .calls(ApplicationContract.coreOperationDnsQuery)
        .single;
    transport.runtime.event({'event': 'uiVisibility', 'visible': false});
    transport.runtime.event({'event': 'uiVisibility', 'visible': true});
    await tester.pump();
    expect(transport.cancellations, isEmpty);
    expect(result.replies, 0);
    expect(transport.dns.busy, isTrue);
    final blocked = FutureProbe(transport.query(owner: 'replacement-owner'));
    await tester.pump();
    expect(blocked.error, isNotNull);
    expect(transport.calls(ApplicationContract.coreOperationDnsQuery), [
      request,
    ]);
    gate.complete();
    await tester.pump();
    expect(transport.cancellations, [request]);
    expect(transport.dns.snapshot()['cancelError'], cancellation);
    request.complete({'rcode': 0, 'detail': modeStrategyOriginal});
    await tester.pump();
    expect(result.replies, 0);
    expect(transport.dns.busy, isTrue);
    request.signalExit();
    await tester.pump();
    expect(result.error, isNull);
    expect((result.value as Map)['cancelError'], cancellation);
    expect((result.value as Map)['dns'], {
      'rcode': 0,
      'detail': modeStrategyOriginal,
    });
    expect(result.replies, 1);
    expect(transport.dns.busy, isFalse);
  });

  for (final cancellation in [false, true]) {
    test(
      'DNS structured ${cancellation ? 'cancelError' : 'native error'} 大结果保留完整原文',
      () async {
        await create();
        final failure = {
          ...nativeFailure('java.io.IOException'),
          'message':
              'x' * ApplicationContract.dnsResultBytes + modeStrategyOriginal,
          'cause': nativeFailure('java.lang.IllegalStateException'),
          'suppressed': [nativeFailure('java.io.IOException')],
        };
        fixture.script(
          ApplicationContract.coreOperationDnsQuery,
          (request) => request.complete(
            {'rcode': 0, 'detail': modeStrategyOriginal},
            terminal: {cancellation ? 'cancelError' : 'error': failure},
          ),
        );
        final result = FutureProbe(read('dnsQuery'));
        await result.done;
        expect(result.value, isNull);
        expect(result.error, isA<PlatformFailure>());
        expect(
          (result.error as PlatformFailure).code,
          ApplicationContract.coreErrorResultTooLarge,
        );
        expect(errorText(result.error), contains(failure.toString()));
        expect(errorText(result.error), contains(modeStrategyOriginal));
        expect(fixture.runtime.dns.busy, isFalse);
      },
    );
  }

  test('CoreReadCallsErrorTest.queuedDnsCancellationKeepsItsErrorWithoutEnteringNativeOrFreeingTheSlot', () async {
    await create();
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final failure = nativeFailure('java.io.IOException');
    fixture.script(
      ApplicationContract.coreOperationDnsQuery,
      (_) => gate.future,
    );
    fixture.onCancel = (_) => {'cancelError': failure};
    final entered = fixture.next(ApplicationContract.coreOperationDnsQuery);
    final result = FutureProbe(read('dnsQuery'));
    final request = await entered;
    await fixture.runtime.dns.cancel(fixture.core, 'wrong-owner');
    expect(request.cancellations, 0);
    await fixture.runtime.dns.cancel(fixture.core, 'fixture');
    expect(result.replies, 0);
    expect(fixture.runtime.dns.busy, isTrue);
    expect(request.cancellations, 0);
    gate.complete();
    await fixture.flush();
    expect(request.cancellations, 1);
    expect(fixture.runtime.dns.busy, isTrue);
    request.complete({'error': 'cancelled', 'detail': modeStrategyOriginal});
    await result.done;
    final value = decoded(result.value);
    expect(value['dns'], {
      'error': 'cancelled',
      'detail': modeStrategyOriginal,
    });
    expect(value['cancelError'], failure);
    expect(result.replies, 1);
    expect(fixture.runtime.dns.busy, isFalse);
  });

  for (final kind in [
    'java.io.IOException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    test(
      'CoreReadCallsErrorTest.nativeAndLinkageReadFailuresKeepTheirActualCause logs $kind',
      () async {
        fixture = await CoreRuntimeFixture.create(preview: true);
        addTearDown(fixture.dispose);
        final failure = nativeFailure(kind);
        fixture.script(ApplicationContract.coreOperationLogs, (request) {
          request.metadata({'source': request.source});
          request.terminal({
            'complete': false,
            'error': failure,
            'exited': true,
          });
        });
        await fixture.warmUp();
        expect(fixture.runtime.logError, failure);
        final result = decoded(
          await fixture.runtime.read('logs', {
            'query': {'window': fixture.runtime.logs.source},
          }),
        );
        expect(result['error'], failure);
        expect((result['error'] as Map)['stack'], failure['stack']);
        expect(
          fixture.calls(ApplicationContract.coreOperationLogs),
          hasLength(1),
        );
      },
    );
  }

  test('CoreReadCallsErrorTest.wireReadFailuresKeepAllFieldsInsteadOfOnlyStableCodes logs', () async {
    fixture = await CoreRuntimeFixture.create(preview: true);
    addTearDown(fixture.dispose);
    final raw = jsonEncode({
      'error': 'future-error',
      'detail': modeStrategyOriginal,
      'future': {'Authorization': modeStrategyOriginal},
    });
    fixture.script(ApplicationContract.coreOperationLogs, (request) {
      request.metadata({'source': request.source});
      request.terminal({'complete': false, 'error': raw, 'exited': true});
    });
    await fixture.warmUp();
    final result = decoded(
      await fixture.runtime.read('logs', {
        'query': {'window': fixture.runtime.logs.source},
      }),
    );
    expect(result['error'], raw);
    expect(fixture.runtime.logError, raw);
  });

  for (final kind in [
    'java.io.IOException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    for (final failing in [false, true]) {
      test(
        'CoreReadCallsErrorTest.${failing ? 'executingReadFailuresKeepTheirCauseAfterTheDeadlineAndStop' : 'executingReadsKeepTheirCompleteCapturedResultAfterDeadlineAndSourceChanges'} logs $kind',
        () async {
          fixture = await CoreRuntimeFixture.create(preview: true);
          addTearDown(fixture.dispose);
          final captured = fixture.core;
          final failure = nativeFailure(kind);
          final row = {
            'seq': 1,
            'text': modeStrategyOriginal,
            ..._originalRow(),
          };
          fixture.script(ApplicationContract.coreOperationLogs, (request) {
            request.metadata({'source': request.source});
            if (!failing) request.record(row);
            request.terminal({
              'complete': !failing,
              if (failing) 'error': failure,
              'exited': false,
            });
          });
          await fixture.warmUp();
          final request = fixture
              .calls(ApplicationContract.coreOperationLogs)
              .single;
          final window = fixture.runtime.logs.source;
          fixture.expire();
          fixture.replaceCore(
            processId: 'replacement',
            inputId: 'replacement-input',
            generation: 2,
          );
          final result = decoded(
            await fixture.runtime.read('logs', {
              'query': {'window': window},
            }),
          );
          expectIdentity(result, captured);
          expect(result['stale'], isTrue);
          expect(request.actualExited, isFalse);
          if (failing) {
            expect(result['error'], failure);
            expect((result['error'] as Map)['stack'], failure['stack']);
          } else {
            expect(((result['logs'] as Map)['entries'] as List).single, row);
          }
          request.signalExit();
          await fixture.flush();
          expect(request.actualExited, isTrue);
          final retained = decoded(
            await fixture.runtime.read('logs', {
              'query': {'window': window},
            }),
          );
          expectIdentity(retained, captured);
          expect(retained['logs'], result['logs']);
          expect(retained['error'], result['error']);
        },
      );
    }
  }

  test('CoreReadCallsErrorTest.contextChangedDuringAReadDoesNotEraseItsActualFailure logs', () async {
    fixture = await CoreRuntimeFixture.create(preview: true);
    addTearDown(fixture.dispose);
    final failure = nativeFailure('java.io.IOException');
    fixture.script(ApplicationContract.coreOperationLogs, (request) {
      request.metadata({'source': request.source});
      request.terminal({'complete': false, 'error': failure, 'exited': true});
    });
    await fixture.warmUp();
    final captured = fixture.core;
    fixture.replaceCore(
      processId: 'replacement',
      inputId: 'replacement-input',
      generation: 2,
    );
    final result = decoded(
      await fixture.runtime.read('logs', {
        'query': {'window': fixture.runtime.logs.source},
      }),
    );
    expectIdentity(result, captured);
    expect(result['error'], failure);
    expect(result['stale'], isTrue);
  });

  test('CoreReadCallsErrorTest.malformedReadWiresKeepThePublicParserErrorAndCompleteOriginalInput logs', () async {
    fixture = await CoreRuntimeFixture.create(preview: true);
    addTearDown(fixture.dispose);
    fixture.script(ApplicationContract.coreOperationLogs, (request) {
      request.metadata({'source': request.source});
      request.bytes(
        ApplicationContract.coreIpcFrameRecord,
        Uint8List.fromList(utf8.encode(modeStrategyOriginal)),
      );
      request.terminal({'complete': false, 'exited': false});
    });
    await fixture.warmUp();
    final request = fixture.calls(ApplicationContract.coreOperationLogs).single;
    expect(request.actualExited, isFalse);
    expect(fixture.runtime.logError, isA<FormatException>());
    expect(
      (fixture.runtime.logError as FormatException).source,
      modeStrategyOriginal,
    );
    final result = decoded(
      await fixture.runtime.read('logs', {
        'query': {'window': fixture.runtime.logs.source},
      }),
    );
    expect((result['error'] as Map)['source'], modeStrategyOriginal);
    expect(
      (result['error'] as Map)['message'],
      (fixture.runtime.logError as FormatException).message,
    );
    request.signalExit();
    await fixture.flush();
    expect(request.actualExited, isTrue);
  });

  for (final kind in [
    'java.util.concurrent.RejectedExecutionException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    test(
      'CoreReadCallsErrorTest.${kind.endsWith('UnsatisfiedLinkError') ? 'readWorkerRejectionsKeepLinkageErrorsAndReleaseActualReservations' : 'workerRejectionsReplyOnceWithTheirActualCauseAndAllowRetry'} logs',
      () async {
        fixture = await CoreRuntimeFixture.create(preview: true);
        addTearDown(fixture.dispose);
        final failure = nativeFailure(kind);
        fixture.beforePlatformCall = (call) {
          if (call.method == ApplicationContract.coreChannelSubmit &&
              (call.arguments as Map)['operation'] ==
                  ApplicationContract.coreOperationLogs) {
            throw PlatformException(code: 'callFailed', details: failure);
          }
          return null;
        };
        await fixture.warmUp();
        expectOriginalError(fixture.runtime.logError, failure);
        expect(fixture.calls(ApplicationContract.coreOperationLogs), isEmpty);
        expect(fixture.runtime.dns.busy, isFalse);
        fixture.beforePlatformCall = null;
        await fixture.runtime.restoreExisting();
        await fixture.flush();
        expect(fixture.runtime.logError, isNull);
        expect(
          fixture.calls(ApplicationContract.coreOperationLogs),
          hasLength(1),
        );
      },
    );
  }

  test('CoreReadCallsErrorTest.ruleSourceErrorKeepsEveryNativeFieldAfterItsSourceWasReleased', () async {
    await create();
    final raw = {
      'error': 'sourceUnavailable',
      'detail': modeStrategyOriginal,
      'future': {'Authorization': modeStrategyOriginal},
    };
    fixture.script(ApplicationContract.coreOperationRules, (request) {
      fixture.replaceCore(phase: 'EMPTY');
      request.metadata({'source': request.source});
      request.terminal({
        'complete': false,
        'recordCount': 0,
        'source': request.source,
        'error': raw,
        'stale': true,
        'exited': true,
      });
    });
    final result = FutureProbe(read('rules'));
    await result.done;
    expect(result.value, isNull);
    expect(result.error, isA<FormatException>());
    expect(((result.error as FormatException).source as Map)['error'], raw);
    expect(errorText(result.error), contains(modeStrategyOriginal));
  });

  for (final success in [false, true]) {
    test(
      'CoreReadCallsErrorTest.acceptedUpdateKeepsItsOriginalIdentityAndResultAfterCancellationAndStop success=$success',
      () async {
        await create();
        final source = fixture.core;
        final raw = {
          'update': {
            success ? 'status' : 'error': success ? 'ok' : 'updateFailed',
            ..._originalRow(),
          },
        };
        fixture.script(
          ApplicationContract.coreOperationResourceUpdate,
          (request) =>
              request.complete(raw, terminal: {'exited': false, 'stale': true}),
        );
        final entered = fixture.next(
          ApplicationContract.coreOperationResourceUpdate,
        );
        final result = FutureProbe(read('updateResource'));
        final request = await entered;
        fixture.operation.cancel();
        fixture.replaceCore(phase: 'EMPTY');
        await fixture.flush();
        expect(result.settled, isFalse);
        request.signalExit();
        await result.done;
        expect(result.error, isNull);
        final value = decoded(result.value);
        expectIdentity(value, source);
        expect(value['update'], raw['update']);
        expect(value['stale'], isTrue);
        expect(result.replies, 1);
      },
    );
  }
}
