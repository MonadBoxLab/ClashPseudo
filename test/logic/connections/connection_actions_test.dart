import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';

import '../../support/core_runtime_fixture.dart';

import 'package:clash_pseudo/src/logic/connections/connection_actions.dart';
import 'package:clash_pseudo/src/logic/connections/connection_observer.dart';

import '../../support/connection_window_fixtures.dart' as windows;

import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/model/messages.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'RUNNING',
  configId: 'one',
  revision: 1,
  composition: 'one',
);
const command = <String, dynamic>{
  'action': 'closeConnection',
  'generation': 7,
  'configId': 'one',
  'revision': 1,
  'composition': 'one',
  'purpose': 'RUNNING',
  'connectionId': '00000001-0000-4000-8000-000000000000',
};

class CloseBridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'RUNNING', core: core);
  String result = 'closed';
  int calls = 0;
  Completer<String>? pending;
  Completer<AppSnapshot>? snapshotPending;
  @override
  Future<AppSnapshot> snapshot() =>
      snapshotPending?.future ?? Future.value(state);
  @override
  Future<String> closeConnection(CoreSnapshot target, String id) async {
    calls++;
    // The callback can run while pump drains FakeAsync microtasks. These
    // synchronous assertions must not open a competing WidgetTester guard.
    expectSync(target.generation, core.generation);
    expectSync(target.configId, core.configId);
    expectSync(target.revision, core.revision);
    expectSync(target.composition, core.composition);
    expectSync(target.purpose, core.purpose);
    expectSync(id, command['connectionId']);
    final actual = pending;
    if (actual != null) return await actual.future;
    return result;
  }

  @override
  Future<void> stop({bool preserveLan = true}) async =>
      fail('Single close must not stop the VPN');
  @override
  Future<Map<String, dynamic>> paths() async =>
      fail('Single close must not touch configurations');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CoreRuntime FD 连接入口', () {
    late CoreRuntimeFixture fixture;
    const id = '00000001-0000-4000-8000-000000000000';
    final sample = <String, Object?>{
      'complete': true,
      'connections': <Object?>[],
      'presence': <String, bool>{id: true},
      'limited': false,
      'activeCount': 0,
      'sessionUploadBytes': 100,
      'sessionDownloadBytes': 200,
    };
    setUp(() async {
      fixture = await CoreRuntimeFixture.create();
      await fixture.warmUp();
    });
    tearDown(() => fixture.dispose());

    for (final abandon in [false, true]) {
      test(
        'queued close 原${abandon ? 'abandon' : '100ms deadline'}回调在 worker drain 前仅失败一次，drain 后重试 closed',
        () async {
          final captured = fixture.core;
          fixture.deadline = fixture.admittedAt + 100;
          fixture.operation = fixture.bootstrap.runtime.platform.forOperation(
            operationId: 'owner',
            admittedAt: fixture.admittedAt,
            deadline: fixture.deadline,
          );
          final elapsed = Stopwatch()..start();
          final entered = Completer<void>();
          final release = Completer<void>();
          var checks = 0;
          fixture.beforePlatformCall = (call) async {
            fixture.now = fixture.admittedAt + elapsed.elapsedMilliseconds;
            if (call.method == 'checkOperation' && ++checks == 3) {
              entered.complete();
              await release.future;
              fixture.now = fixture.admittedAt + elapsed.elapsedMilliseconds;
            }
            return null;
          };
          final first = FutureProbe(
            fixture.operation.closeConnection(captured, id),
          );
          try {
            await entered.future.timeout(const Duration(seconds: 2));
            expect(checks, 3);
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              isEmpty,
            );
            if (abandon) fixture.operation.cancel();
            final repliedBeforeDrain = await Future.any([
              first.done.then((_) => true),
              Future<bool>.delayed(const Duration(seconds: 2), () => false),
            ]);
            final earlyReplies = first.replies;
            final earlyError = first.error;
            final busy = FutureProbe(
              fixture.bootstrap.runtime.platform.closeConnection(captured, id),
            );
            await busy.done;
            expect(busy.error, isNotNull);
            expect(checks, 3);
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              isEmpty,
            );
            release.complete();
            await first.done;
            // 调用方已收到错误，重试前另行等待实际 work 结束。
            await fixture.flush();
            expect(first.error, isA<PlatformFailure>());
            expect(first.replies, 1);
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              isEmpty,
            );
            expect(fixture.core, same(captured));
            fixture.beforePlatformCall = null;
            fixture.now = fixture.admittedAt;
            fixture.deadline = fixture.admittedAt + 100;
            fixture.operation = fixture.bootstrap.runtime.platform.forOperation(
              operationId: 'next-owner',
              admittedAt: fixture.admittedAt,
              deadline: fixture.deadline,
            );
            fixture.script(ApplicationContract.coreOperationConnectionClose, (
              request,
            ) {
              expect(request.arguments['id'], id);
              request.complete({'status': 'closed'});
            });
            expect(
              await fixture.operation.closeConnection(captured, id),
              'closed',
            );
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              hasLength(1),
            );
            expect(first.replies, 1);
            expect(fixture.exits, isEmpty);
            expect(fixture.phase, 'RUNNING');
            expect(
              {
                'completed': repliedBeforeDrain,
                'replies': earlyReplies,
                'hasError': earlyError != null,
              },
              {'completed': true, 'replies': 1, 'hasError': true},
              reason: '原 first.await/error 必须发生在 worker drain 前，不能用 snapshot.operationMessage 代替回调',
            );
          } finally {
            fixture.beforePlatformCall = null;
            if (!release.isCompleted) release.complete();
            await first.done;
            elapsed.stop();
          }
        },
      );
    }

    for (final boundary in ['cancelBefore', 'cancelAfter', 'deadline']) {
      test('queued close 最后一次 snapshot 在 $boundary 后返回，不提交 native', () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        var checks = 0;
        var snapshots = 0;
        fixture.beforePlatformCall = (call) async {
          if (call.method == 'checkOperation') checks++;
          if (checks == 3 && call.method == 'snapshot' && ++snapshots == 2) {
            entered.complete();
            await release.future;
          }
          return null;
        };
        final first = FutureProbe(
          fixture.operation.closeConnection(fixture.core, id),
        );
        try {
          await entered.future.timeout(const Duration(seconds: 2));
          if (boundary == 'cancelBefore') fixture.operation.cancel();
          if (boundary == 'deadline') fixture.expire();
          release.complete();
          if (boundary == 'cancelAfter') fixture.operation.cancel();
          await first.done;
          await fixture.flush();
          expect(
            first.error,
            isA<PlatformFailure>().having((e) => e.code, 'code', 'expired'),
          );
          expect(first.replies, 1);
          expect(
            fixture.calls(ApplicationContract.coreOperationConnectionClose),
            isEmpty,
          );
          fixture.beforePlatformCall = null;
          fixture.script(ApplicationContract.coreOperationConnectionClose, (
            request,
          ) {
            request.complete({'status': 'closed'});
          });
          expect(
            await fixture.bootstrap.runtime.platform.closeConnection(
              fixture.core,
              id,
            ),
            'closed',
          );
          expect(
            fixture.calls(ApplicationContract.coreOperationConnectionClose),
            hasLength(1),
          );
          expect(first.replies, 1);
          expect(fixture.exits, isEmpty);
        } finally {
          fixture.beforePlatformCall = null;
          if (!release.isCompleted) release.complete();
          await first.done;
          await fixture.flush();
        }
      });
    }

    test('queued close 取消后收到迟到平台异常，只保留原错误并在 drain 后释放 slot', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var checks = 0;
      fixture.beforePlatformCall = (call) async {
        if (call.method == 'checkOperation' && ++checks == 3) {
          entered.complete();
          await release.future;
          throw PlatformException(
            code: 'late-check-failure',
            details: '迟到平台异常',
          );
        }
        return null;
      };
      final first = FutureProbe(
        fixture.operation.closeConnection(fixture.core, id),
      );
      try {
        await entered.future.timeout(const Duration(seconds: 2));
        fixture.operation.cancel();
        await first.done.timeout(const Duration(seconds: 2));
        final original = first.error;
        expect(
          original,
          isA<PlatformFailure>().having((e) => e.code, 'code', 'expired'),
        );
        final blocked = FutureProbe(
          fixture.bootstrap.runtime.platform.closeConnection(fixture.core, id),
        );
        await blocked.done;
        expect(blocked.error, isNotNull);
        expect(checks, 3);
        release.complete();
        await fixture.flush();
        expect(first.error, same(original));
        expect(first.replies, 1);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );
        fixture.beforePlatformCall = null;
        fixture.script(ApplicationContract.coreOperationConnectionClose, (
          request,
        ) {
          request.complete({'status': 'absent'});
        });
        expect(
          await fixture.bootstrap.runtime.platform.closeConnection(
            fixture.core,
            id,
          ),
          'absent',
        );
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          hasLength(1),
        );
        expect(first.replies, 1);
        expect(fixture.exits, isEmpty);
      } finally {
        fixture.beforePlatformCall = null;
        if (!release.isCompleted) release.complete();
        await first.done;
        await fixture.flush();
      }
    });

    for (final networkOnly in [false, true]) {
      test(
        'queued close 在 gate 期间${networkOnly ? 'networkRevision 变化' : '替换 core'}，不关闭新来源的连接',
        () async {
          final captured = fixture.core;
          final entered = Completer<void>();
          final release = Completer<void>();
          var checks = 0;
          fixture.beforePlatformCall = (call) async {
            if (call.method == 'checkOperation' && ++checks == 3) {
              entered.complete();
              await release.future;
            }
            return null;
          };
          final first = FutureProbe(
            fixture.operation.closeConnection(captured, id),
          );
          try {
            await entered.future.timeout(const Duration(seconds: 2));
            if (networkOnly) {
              fixture.replaceCore(
                networkRevision: captured.networkRevision + 1,
              );
            } else {
              fixture.replaceCore(
                processId: 'replacement',
                inputId: 'replacement-input',
                generation: 2,
              );
            }
            final replacement = fixture.core;
            final blocked = FutureProbe(
              fixture.bootstrap.runtime.platform.closeConnection(
                replacement,
                id,
              ),
            );
            await blocked.done;
            expect(blocked.error, isNotNull);
            expect(checks, 3);
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              isEmpty,
            );
            release.complete();
            await first.done;
            expect(
              first.error,
              isA<PlatformFailure>().having(
                (e) => e.code,
                'code',
                ApplicationContract.coreErrorIdentityMismatch,
              ),
            );
            expect(first.replies, 1);
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              isEmpty,
            );
            expect(fixture.core, same(replacement));
            fixture.beforePlatformCall = null;
            fixture.script(ApplicationContract.coreOperationConnectionClose, (
              request,
            ) {
              expect(request.processId, replacement.processId);
              expect(
                (request.wire['identity'] as Map)['networkRevision'],
                replacement.networkRevision,
              );
              request.complete({'status': 'closed'});
            });
            expect(
              await fixture.bootstrap.runtime.platform.closeConnection(
                replacement,
                id,
              ),
              'closed',
            );
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              hasLength(1),
            );
            expect(first.replies, 1);
            expect(fixture.core, same(replacement));
            expect(fixture.exits, isEmpty);
          } finally {
            fixture.beforePlatformCall = null;
            if (!release.isCompleted) release.complete();
            await first.done;
            await fixture.flush();
          }
        },
      );
    }

    for (final cancelFirst in [false, true]) {
      test(
        'close 已提交但 receipt 尚未返回，取消与完成竞争时${cancelFirst ? '先取消' : '先完成'}均等待实际退出',
        () async {
          final receipt = Completer<void>();
          final entered = fixture.next(
            ApplicationContract.coreOperationConnectionClose,
          );
          fixture.script(ApplicationContract.coreOperationConnectionClose, (
            request,
          ) async {
            await receipt.future;
          });
          final first = FutureProbe(
            fixture.operation.closeConnection(fixture.core, id),
          );
          final request = await entered;
          try {
            if (cancelFirst) fixture.operation.cancel();
            request.complete({'status': 'closed'}, terminal: {'exited': false});
            if (!cancelFirst) fixture.operation.cancel();
            fixture.expire();
            await fixture.flush();
            expect(first.settled, isFalse);
            receipt.complete();
            await fixture.flush();
            expect(first.settled, isFalse);
            final blocked = FutureProbe(
              fixture.bootstrap.runtime.platform.closeConnection(
                fixture.core,
                id,
              ),
            );
            await blocked.done;
            expect(blocked.error, isNotNull);
            expect(
              fixture.calls(ApplicationContract.coreOperationConnectionClose),
              hasLength(1),
            );
            request.signalExit();
            await first.done;
            expect(first.value, 'closed');
            expect(first.error, isNull);
            expect(first.replies, 1);
            expect(fixture.exits, isEmpty);
          } finally {
            if (!receipt.isCompleted) receipt.complete();
            request.signalExit();
            await first.done;
          }
        },
      );
    }

    test(
      '完整 bounded query 与 suggestions 原样传输并附 captured identity 和单调时间',
      () async {
        final query = {
          'limit': 50,
          'previousActiveIds': [id],
          'detailId': id,
        };
        final suggestion = {
          'id': id,
          'rule': 'DOMAIN,fixture.test,DIRECT',
          'future': [false, null, modeStrategyOriginal],
        };
        fixture.script(ApplicationContract.coreOperationConnections, (request) {
          expect(request.arguments, {
            ...query,
            'admittedAt': 100,
            'deadline': 60100,
          });
          request.complete({...sample, 'ruleSuggestions': suggestion});
        });
        final value = await fixture.operation.sampleConnections(
          fixture.core,
          query,
        );
        for (final field in fixture.identity().entries) {
          expect(value[field.key], field.value, reason: field.key);
        }
        expect(value['ruleSuggestions'], suggestion);
        expect(value['phase'], fixture.core.phase);
        expect(value.containsKey('failed'), isFalse);
        expect(value['elapsedMs'], fixture.now);
        expect(value['observedAt'], greaterThan(0));
        expect(value['sessionUploadBytes'], 100);
        expect(value['sessionDownloadBytes'], 200);
        expect(fixture.exits, isEmpty);
      },
    );

    for (final method in ['sampleConnections', 'closeConnection']) {
      test('$method 逐字段拒绝缺失或不匹配的完整身份，尚未提交 native', () async {
        final valid = fixture.identity();
        for (final field in valid.keys) {
          for (final wrong in [
            null,
            field == 'generation' ||
                    field == 'revision' ||
                    field == 'networkRevision'
                ? -1
                : 'wrong',
          ]) {
            await expectLater(
              fixture.runtime.read(method, {
                ...valid,
                field: wrong,
                'connectionId': id,
                'query': {'limit': 50},
              }),
              throwsA(isA<PlatformFailure>()),
            );
          }
        }
        expect(
          fixture.calls(ApplicationContract.coreOperationConnections),
          isEmpty,
        );
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );
        expect(fixture.exits, isEmpty);
      });
    }

    test('read 到期后保持实际 slot，close 使用独立 slot，真实退出后才允许下一次 read', () async {
      fixture.script(ApplicationContract.coreOperationConnections, (request) {
        request.complete(sample, terminal: {'exited': false});
      });
      final entered = fixture.next(
        ApplicationContract.coreOperationConnections,
      );
      final pending = FutureProbe(
        fixture.operation.sampleConnections(fixture.core, {'limit': 50}),
      );
      final request = await entered;
      fixture.expire();
      await fixture.flush();
      expect(pending.settled, isFalse);
      final blocked = jsonDecode(
        await fixture.runtime.read('sampleConnections', fixture.identity())
            as String,
      ) as Map;
      expect(blocked['readPending'], isTrue);
      expect(
        fixture.calls(ApplicationContract.coreOperationConnections),
        hasLength(1),
      );
      fixture.script(
        ApplicationContract.coreOperationConnectionClose,
        (request) => request.complete({'status': 'absent'}),
      );
      final close = jsonDecode(
        await fixture.runtime.read('closeConnection', {
          ...fixture.identity(),
          'connectionId': id,
        }) as String,
      ) as Map;
      expect(close['status'], 'absent');
      expect(pending.settled, isFalse);
      request.signalExit();
      await pending.done;
      expect(pending.replies, 1);
      expect(pending.value!['complete'], isTrue);
      fixture.script(
        ApplicationContract.coreOperationConnections,
        (request) => request.complete(sample),
      );
      final next = jsonDecode(
        await fixture.runtime.read('sampleConnections', fixture.identity())
            as String,
      ) as Map;
      expect(next['complete'], isTrue);
      expect(
        fixture.calls(ApplicationContract.coreOperationConnections),
        hasLength(2),
      );
      expect(fixture.exits, isEmpty);
    });

    for (final queued in [true, false]) {
      testWidgets(
        queued
            ? 'ConnectionsCallsTest.timeoutDoesNotQueueMoreReadsOrStopVpn：排队 readonly 到期后显示失败且不进入 native，实际受理结束前保持 slot'
            : 'ConnectionsCallsTest.inProgressTimeoutRetainsSlotAndDropsLateResult：执行中的 readonly 到期后显示失败，实际 FD drain 前保持 slot 且迟到 sample 不回填窗口',
        (tester) async {
          final gate = Completer<Map<String, dynamic>>();
          Map<String, dynamic> state() => {
            ...fixture.snapshotMap(),
            'elapsedMs': fixture.now,
          };
          var snapshots = 0;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(AppBridge.channel, (call) {
                if (call.method == 'retain') return Future.value();
                if (call.method == 'runtimeState') return Future.value(state());
                if (call.method == 'snapshot' && queued && ++snapshots == 3) {
                  return gate.future;
                }
                return fixture.handlePlatformCall(call);
              });
          final observer = ConnectionObserver(
            fixture.bootstrap.runtime.platform,
          );
          addTearDown(observer.dispose);
          if (!queued) {
            fixture.script(ApplicationContract.coreOperationConnections, (
              request,
            ) {
              request.complete({
                ...sample,
                'connections': [windows.row(id)],
              });
            });
          }
          observer.updateState(state());
          await tester.pump(Duration.zero);
          CoreTestRequest? actual;
          final originalStamps = observer.window.records
              .map((row) => row.observedAt)
              .toList();
          final originalIds = observer.window.records
              .map((row) => row.id)
              .toList();
          if (queued) {
            expect(snapshots, 3);
            expect(
              fixture.calls(ApplicationContract.coreOperationConnections),
              isEmpty,
            );
          } else {
            expect(originalIds, [id]);
            fixture.script(ApplicationContract.coreOperationConnections, (
              request,
            ) {
              final admittedAt = request.arguments['admittedAt'] as int;
              expectSync(admittedAt, inInclusiveRange(100, 1100));
              expectSync(request.arguments['deadline'], admittedAt + 5000);
              expectSync(
                request.arguments['deadline'],
                lessThanOrEqualTo(6100),
              );
              request.complete(
                {
                  ...sample,
                  'connections': [windows.row('late')],
                  'presence': {id: false},
                },
                terminal: {'exited': false},
              );
            });
            fixture.now = 1100;
            await tester.pump(const Duration(seconds: 1));
            actual = fixture
                .calls(ApplicationContract.coreOperationConnections)
                .last;
            expect(actual.actualExited, isFalse);
          }
          fixture.now = queued ? 5100 : 6100;
          await tester.pump(const Duration(seconds: 5));
          final expired = observer.snapshot(state(), null);
          expect(expired.containsKey('phase'), isFalse);
          expect(expired.containsKey('failed'), isFalse);
          expect(expired['fresh'], isFalse);
          expect(expired['sampleAgeMs'], isNull);
          expect(
            expired['error'],
            contains('Connection observation is still in progress'),
          );
          expect(
            observer.window.records.map((row) => row.observedAt),
            originalStamps,
          );
          expect(observer.window.records.map((row) => row.id), originalIds);
          final blocked = jsonDecode(
            await fixture.runtime.read('sampleConnections', fixture.identity())
                as String,
          ) as Map;
          expect(blocked['readPending'], isTrue);
          final count = queued ? 0 : 2;
          expect(
            fixture.calls(ApplicationContract.coreOperationConnections),
            hasLength(count),
          );
          await tester.pump(const Duration(seconds: 10));
          expect(
            fixture.calls(ApplicationContract.coreOperationConnections),
            hasLength(count),
          );
          if (queued) {
            gate.complete(fixture.snapshotMap());
          } else {
            actual!.signalExit();
          }
          await tester.pump();
          final drained = observer.snapshot(state(), null);
          expect(drained['fresh'], isFalse);
          expect(drained['error'], expired['error']);
          expect(
            observer.window.records.map((row) => row.observedAt),
            originalStamps,
          );
          expect(observer.window.records.map((row) => row.id), originalIds);
          expect(
            observer.window.records.any((row) => row.id == 'late'),
            isFalse,
          );
          expect(
            fixture.calls(ApplicationContract.coreOperationConnections),
            hasLength(count),
          );
          fixture.script(ApplicationContract.coreOperationConnections, (
            request,
          ) {
            request.complete({
              ...sample,
              'connections': [windows.row(id)],
              'presence': {id: true},
            });
          });
          fixture.now += 1000;
          await tester.pump(const Duration(seconds: 1));
          final retried = observer.snapshot(state(), null);
          expect(retried['error'], isNull);
          expect(retried['fresh'], isTrue);
          expect(observer.window.records.single.id, id);
          expect(
            fixture.calls(ApplicationContract.coreOperationConnections),
            hasLength(count + 1),
          );
          expect(fixture.exits, isEmpty);
          observer.dispose();
          await tester.pump();
        },
      );
    }

    test('sample 交付前 composition 变化使整个结果失效，不更改 replacement', () async {
      final captured = fixture.core;
      fixture.script(ApplicationContract.coreOperationConnections, (request) {
        fixture.replaceCore(composition: 'replacement');
        request.complete({
          ...sample,
          'ruleSuggestions': {'id': id},
        });
      });
      await expectLater(
        fixture.operation.sampleConnections(captured, {'limit': 50}),
        throwsA(isA<PlatformFailure>()),
      );
      expect(fixture.core.composition, 'replacement');
      expect(fixture.exits, isEmpty);
    });

    for (final status in ['closed', 'absent', 'failed', 'unknown']) {
      test('close 的 $status 在 deadline、取消和来源变化后保留实际结果，等真实退出且只交付一次', () async {
        final captured = fixture.core;
        fixture.script(ApplicationContract.coreOperationConnectionClose, (
          request,
        ) {
          expect(request.arguments['id'], id);
          request.complete(
            {
              'status': status,
              'future': [false, null],
            },
            terminal: {'exited': false},
          );
        });
        final entered = fixture.next(
          ApplicationContract.coreOperationConnectionClose,
        );
        final pending = FutureProbe(
          fixture.runtime.read('closeConnection', {
            ...fixture.identity(),
            'connectionId': id,
          }, operation: fixture.operation),
        );
        final request = await entered;
        fixture.expire();
        fixture.operation.cancel();
        await fixture.flush();
        expect(pending.settled, isFalse);
        final blocked = jsonDecode(
          await fixture.runtime.read('closeConnection', {
            ...fixture.identity(),
            'connectionId': id,
          }) as String,
        ) as Map;
        expect(blocked['readPending'], isTrue);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          hasLength(1),
        );
        fixture.replaceCore(
          processId: 'replacement',
          inputId: 'replacement-input',
          generation: 2,
        );
        request.signalExit();
        await pending.done;
        expect(pending.replies, 1);
        final value = jsonDecode(pending.value as String) as Map;
        expect(value['status'], status);
        expect(value['future'], [false, null]);
        expect(value['processId'], captured.processId);
        expect(value['composition'], captured.composition);
        expect(fixture.core.processId, 'replacement');
        expect(fixture.exits, isEmpty);
      });
    }

    test('close native 错误保留 cause、suppressed 与未知字段，不改成成功，失败后释放 slot', () async {
      final failure = nativeFailure('java.io.IOException');
      fixture.script(ApplicationContract.coreOperationConnectionClose, (
        request,
      ) {
        request.complete(null, terminal: {'complete': false, 'error': failure});
      });
      final pending = FutureProbe(
        fixture.operation.closeConnection(fixture.core, id),
      );
      await pending.done;
      expectOriginalError(pending.error, failure);
      expect(pending.replies, 1);
      fixture.script(
        ApplicationContract.coreOperationConnectionClose,
        (request) => request.complete({'status': 'absent'}),
      );
      expect(
        await fixture.operation.closeConnection(fixture.core, id),
        'absent',
      );
      expect(
        fixture.calls(ApplicationContract.coreOperationConnectionClose),
        hasLength(2),
      );
      expect(fixture.exits, isEmpty);
    });
  });

  for (final status in ['closed', 'absent', 'failed']) {
    test('returns structured $status without interpreting messages', () async {
      final bridge = CloseBridge()..result = status;
      final result = await ConnectionActions(bridge).execute(command);
      expect(result['connectionStatus'], status);
      expect(result['success'], status != 'failed');
      expect(bridge.calls, 1);
    });
  }

  test('stopped, replaced, and preview contexts never close', () async {
    for (final state in [
      const AppSnapshot(phase: 'STOPPED', core: core),
      const AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 8,
          phase: 'READY',
          purpose: 'RUNNING',
          configId: 'one',
          revision: 1,
        ),
      ),
      const AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 7,
          phase: 'READY',
          purpose: 'PREVIEW',
          configId: 'one',
          revision: 1,
        ),
      ),
    ]) {
      final bridge = CloseBridge()..state = state;
      final result = await ConnectionActions(bridge).execute(command);
      expect(result['connectionStatus'], 'unconfirmed');
      expect(bridge.calls, 0);
    }
  });

  test('unrecognized native status is unconfirmed, not success', () async {
    final bridge = CloseBridge()..result = 'maybe';
    final result = await ConnectionActions(bridge).execute(command);
    expect(result['connectionStatus'], 'unconfirmed');
    expect(result['success'], isFalse);
  });

  for (final status in ['closed', 'absent', 'failed']) {
    testWidgets(
      'executing close holds its actual Future after UI deadline and cancellation: $status',
      (tester) async {
        final pending = Completer<String>();
        final bridge = CloseBridge()..pending = pending;
        var settled = false;
        final operation = ConnectionActions(bridge).execute(command)
          ..then((_) => settled = true);
        await tester.pump();
        expect(bridge.calls, 1);
        bridge.cancel();
        bridge.state = const AppSnapshot(phase: 'STOPPED');
        await tester.pump(const Duration(seconds: 121));
        expect(
          settled,
          isFalse,
          reason: settled
              ? ((await operation)['message'] as AppMessage).toMap().toString()
              : null,
        );
        expect(bridge.calls, 1);
        pending.complete(status);
        await tester.pump();
        final result = await operation;
        expect(result['connectionStatus'], status);
        expect(result['success'], status != 'failed');
        expect(bridge.calls, 1);
      },
    );
  }

  testWidgets(
    'late close failure retains the complete native diagnostic after deadline',
    (tester) async {
      final pending = Completer<String>();
      final bridge = CloseBridge()..pending = pending;
      var settled = false;
      final operation = ConnectionActions(bridge).execute(command)
        ..then((_) => settled = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 121));
      expect(
        settled,
        isFalse,
        reason: settled
            ? ((await operation)['message'] as AppMessage).toMap().toString()
            : null,
      );
      const original =
          'close outer\nCaused by: close cause\nSuppressed: close cleanup';
      pending.completeError(
        PlatformException(
          code: 'close-failed',
          details: const AppMessage(
            'disconnectUnconfirmedShort',
            detail: original,
          ).toMap(),
        ),
      );
      await tester.pump();
      final result = await operation;
      expect(result['success'], isFalse);
      expect(result['connectionStatus'], 'unconfirmed');
      expect((result['message'] as AppMessage).detail, contains(original));
      expect(bridge.calls, 1);
    },
  );

  testWidgets('snapshot Future also drains before the action settles', (
    tester,
  ) async {
    final pending = Completer<AppSnapshot>();
    final bridge = CloseBridge()..snapshotPending = pending;
    var settled = false;
    final operation = ConnectionActions(bridge).execute(command)
      ..then((_) => settled = true);
    await tester.pump(const Duration(seconds: 10));
    expect(settled, isFalse);
    expect(bridge.calls, 0);
    pending.complete(const AppSnapshot(phase: 'STOPPED'));
    await tester.pump();
    expect((await operation)['connectionStatus'], 'unconfirmed');
    expect(bridge.calls, 0);
  });

  test(
    'a changed composition or missing captured identity cannot close',
    () async {
      for (final changes in [
        <String, dynamic>{'composition': 'replacement'},
        <String, dynamic>{'composition': null},
        <String, dynamic>{'purpose': 'PREVIEW'},
        <String, dynamic>{'purpose': null},
      ]) {
        final bridge = CloseBridge();
        final result = await ConnectionActions(bridge)
            .execute({...command, ...changes});
        expect(result['connectionStatus'], 'unconfirmed');
        expect(bridge.calls, 0);
      }
    },
  );
}
