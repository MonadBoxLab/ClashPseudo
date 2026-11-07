import 'dart:async';

import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_runtime_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoreRuntimeFixture fixture;

  Future<void> create({bool preview = false, bool stopped = false}) async {
    fixture = await CoreRuntimeFixture.create(
      preview: preview,
      fallback: TunnelMode.rule,
    );
    addTearDown(fixture.dispose);
    if (stopped) {
      fixture.core = const CoreSnapshot(phase: 'EMPTY');
      fixture.phase = 'STOPPED';
    } else {
      await fixture.warmUp();
    }
  }

  Map<String, Object?> timing([String owner = 'one']) => {
    'owner': owner,
    'admittedAt': fixture.admittedAt,
    'deadline': fixture.deadline,
  };

  void loading(CoreTestRequest request, {bool attached = false}) {
    fixture.core = CoreSnapshot(
      processId: request.processId,
      inputId: request.wire['inputId'] as String,
      generation: (request.wire['identity'] as Map)['generation'] as int,
      networkRevision:
          (request.wire['identity'] as Map)['networkRevision'] as int,
      phase: attached ? 'READY' : 'LOADING',
      purpose: request.arguments['purpose'] as String,
      configId: 'one',
      revision: 1,
      composition: '["one",1]',
    );
    fixture.phase = attached ? 'RUNNING' : 'STARTING';
  }

  Future<Object?> start() => fixture.runtime.read('start', {
    ...timing(),
    'id': 'one',
    'revision': 1,
    'mode': 'rule',
  }, operation: fixture.operation);

  Future<Object?> stop() => fixture.runtime.read('stop', {
    ...timing(),
    'preserveLan': false,
  }, operation: fixture.operation);

  for (final (generation, inputId, reusable) in [
    (0, null, true),
    (1, null, false),
    (0, 'submitted-input', false),
    (1, 'submitted-input', false),
  ]) {
    test(
      'connected core is reused only before loading with generation=$generation inputId=$inputId',
      () async {
        await create(stopped: true);
        fixture.core = CoreSnapshot(
          processId: 'system-created',
          inputId: inputId,
          generation: generation,
          networkRevision: 1,
          phase: 'connected',
        );
        fixture.beforePlatformCall = (call) {
          if (call.method == ApplicationContract.coreChannelHandshake &&
              fixture.core.phase == 'connected') {
            return PlatformCallResult(fixture.coreMap());
          }
          return null;
        };
        await start();
        final request = fixture
            .calls(ApplicationContract.coreOperationPrepare)
            .single;
        expect(request.processId == 'system-created', reusable);
        expect((request.wire['identity'] as Map)['generation'], 1);
        expect(fixture.exits, hasLength(reusable ? 0 : 1));
        if (!reusable) {
          expect(fixture.exits.single['processId'], 'system-created');
        }
        expect(fixture.snapshot.running, isTrue);
      },
    );
  }

  test('NativeCallsErrorTest.unknownStopReturnsTheOriginalOperationAndCleanupErrors', () async {
    await create();
    final operation = {
      'id': 'androidErrorTakeoverStartFailed',
      'detail': modeStrategyOriginal,
    };
    final cleanup = {
      'id': 'androidErrorReleaseUnconfirmed',
      'detail': 'cleanup: $modeStrategyOriginal',
    };
    fixture.core = CoreSnapshot(
      processId: fixture.core.processId,
      inputId: fixture.core.inputId,
      generation: fixture.core.generation,
      networkRevision: fixture.core.networkRevision,
      configId: fixture.core.configId,
      revision: fixture.core.revision,
      composition: fixture.core.composition,
      purpose: 'RUNNING',
      phase: 'UNKNOWN',
      error: AppMessage(
        'androidErrorReleaseUnconfirmed',
        detail: '$operation\n$cleanup',
      ),
    );
    fixture.phase = 'UNKNOWN';
    final actual = {
      'exited': false,
      'error': operation,
      'cleanupError': cleanup,
    };
    fixture.onExit = (_) => actual;
    final result = FutureProbe(stop());
    await result.done;
    expect(result.value, isNull);
    expect(result.error, isA<PlatformFailure>());
    expect(
      (result.error as PlatformFailure).code,
      ApplicationContract.coreErrorCommunicationLost,
    );
    expect((result.error as PlatformFailure).details, actual);
    expect(fixture.core.phase, 'UNKNOWN');
    expect(fixture.snapshot.confirmed, isFalse);
    expect(fixture.exits, hasLength(1));
  });

  for (final kind in [
    'java.lang.SecurityException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    test(
      'NativeCallsErrorTest.rejectedServiceStopRetainsTheActualPlatformException $kind',
      () async {
        await create();
        final before = fixture.core.identity;
        final failure = {
          ...nativeFailure(kind),
          'cause': nativeFailure('java.io.IOException')
            ..['message'] = 'original stop cause',
          'suppressed': [
            nativeFailure('java.io.IOException')
              ..['message'] = 'original stop close failure',
          ],
        };
        fixture.onExit = (_) =>
            throw PlatformException(code: 'native', details: failure);
        final result = FutureProbe(stop());
        await result.done;
        expect(result.value, isNull);
        expectOriginalError(result.error, failure);
        expect(fixture.exits, hasLength(1));
        expect(fixture.core.identity, before);
        expect(fixture.snapshot.running, isTrue);
        expect(result.replies, 1);
      },
    );

    test(
      'NativeCallsErrorTest.permissionCheckErrorsKeepTheirCauseWithoutLeavingAPendingStart $kind',
      () async {
        await create(stopped: true);
        final failure = nativeFailure(kind);
        fixture.beforePlatformCall = (call) {
          if (call.method == 'authorize') {
            throw PlatformException(code: 'permission', details: failure);
          }
          return null;
        };
        final result = FutureProbe(
          fixture.configActions.execute({'action': 'start'}),
        );
        await result.done;
        expect(result.value, isNull);
        expectOriginalError(result.error, failure);
        expect(
          fixture.calls(ApplicationContract.coreOperationPrepare),
          isEmpty,
        );
        expect(fixture.publications, isEmpty);
        expect(fixture.exits, isEmpty);
        expect(fixture.core.generation, 0);
        expect(fixture.core.phase, 'EMPTY');
        expect(fixture.snapshot.phase, 'STOPPED');
        expect(result.replies, 1);
      },
    );

    final previewKind = kind == 'java.lang.SecurityException'
        ? 'java.io.IOException'
        : kind;
    test(
      'NativeCallsErrorTest.previewStopKeepsThrownNativeAndLinkageFailures $previewKind',
      () async {
        await create(preview: true);
        final failure = nativeFailure(previewKind);
        fixture.onExit = (_) {
          fixture.core = CoreSnapshot(
            processId: fixture.core.processId,
            inputId: fixture.core.inputId,
            generation: fixture.core.generation,
            networkRevision: fixture.core.networkRevision,
            configId: fixture.core.configId,
            revision: fixture.core.revision,
            composition: fixture.core.composition,
            purpose: 'PREVIEW',
            phase: 'FAILED',
            error: AppMessage('coreStopFailed', detail: failure.toString()),
          );
          throw PlatformException(code: 'native', details: failure);
        };
        final result = FutureProbe(
          fixture.runtime.read('releasePreview', timing()),
        );
        await result.done;
        expect(result.value, isNull);
        expectOriginalError(result.error, failure);
        expect(fixture.core.phase, 'FAILED');
        expect(fixture.snapshot.core.blocked, isTrue);
        expect(result.replies, 1);
      },
    );
  }

  test('NativeCallsErrorTest.previewStopWaitsForItsWorkerAndRetainsTheNativeFailureOnRetry', () async {
    await create(preview: true);
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final actual = {'exited': false, 'error': modeStrategyOriginal};
    fixture.onExit = (_) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      fixture.replaceCore(phase: 'FAILED');
      return actual;
    };
    final first = FutureProbe(fixture.runtime.read('releasePreview', timing()));
    await entered.future;
    expect(first.replies, 0);
    expect(fixture.core.ready, isTrue);
    release.complete();
    await first.done;
    expect(first.value, isNull);
    expect((first.error as PlatformFailure).details, actual);
    expect(fixture.core.phase, 'FAILED');
    final retry = FutureProbe(
      fixture.runtime.read('releasePreview', timing('retry')),
    );
    await retry.done;
    expect(retry.value, isNull);
    expect(
      (retry.error as PlatformFailure).details,
      (first.error as PlatformFailure).details,
    );
    expect(first.replies, 1);
    expect(retry.replies, 1);
  });

  test('NativeCallsErrorTest.rejectedPreviewWorkerRepliesImmediatelyWithoutClaimingRelease', () async {
    await create(preview: true);
    final before = fixture.core.identity;
    final failure = nativeFailure(
      'java.util.concurrent.RejectedExecutionException',
    );
    fixture.beforePlatformCall = (call) {
      if (call.method == ApplicationContract.coreChannelExit) {
        throw PlatformException(code: 'native', details: failure);
      }
      return null;
    };
    final result = FutureProbe(
      fixture.runtime.read('releasePreview', timing()),
    );
    await result.done;
    expect(result.value, isNull);
    expectOriginalError(result.error, failure);
    expect(result.replies, 1);
    expect(fixture.core.identity, before);
    expect(fixture.core.ready, isTrue);
    expect(fixture.exits, isEmpty);
    fixture.beforePlatformCall = null;
    await fixture.runtime.read('releasePreview', timing());
    expect(fixture.core.phase, 'EMPTY');
    expect(fixture.exits, hasLength(1));
  });

  for (final timeout in [false, true]) {
    test(
      'NativeCallsErrorTest.queuedStartupCancellationAndTimeoutWithdrawTheSdkStart ${timeout ? 'timeout' : 'cancel'}',
      () async {
        await create(stopped: true);
        await fixture.startAppRuntime();
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        fixture.beforePlatformCall = (call) async {
          if (call.method == 'checkOperation' && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          return null;
        };
        final result = FutureProbe(fixture.execute({'action': 'start'}));
        await entered.future;
        if (timeout) {
          fixture.expire();
        } else {
          await fixture.abandon();
        }
        release.complete();
        await result.done;
        expect(result.replies, 1);
        expect(result.value!['success'], isFalse);
        expect(
          fixture.calls(ApplicationContract.coreOperationPrepare),
          isEmpty,
        );
        expect(fixture.publications, isEmpty);
        expect(fixture.exits, isEmpty);
        expect(fixture.core.generation, 0);
        expect(fixture.snapshot.phase, 'STOPPED');
        fixture.operationExpired = false;
        fixture.now = fixture.admittedAt;
        await fixture.runtime.read('stop', {});
        expect(fixture.exits, isEmpty);
      },
    );

    test(
      'NativeCallsErrorTest.startupTimeoutKeepsTheAdmittedBudgetAndOnlyWithdrawsAfterItExpires ${timeout ? 'timeout' : 'cancel'}',
      () async {
        await create(stopped: true);
        final exitDrain = Completer<void>();
        addTearDown(() {
          if (!exitDrain.isCompleted) exitDrain.complete();
        });
        fixture.onCancel = (request) => {
          'accepted': true,
          'cancelled': true,
          'started': true,
          'exited': request.actualExited,
        };
        fixture.onExit = (_) async {
          await exitDrain.future;
          fixture.replaceCore(phase: 'EMPTY');
          fixture.phase = 'STOPPED';
          return {'exited': true};
        };
        fixture.script(ApplicationContract.coreOperationPrepare, (request) {
          loading(request);
          request.complete(
            null,
            terminal: {
              'exited': false,
              'complete': false,
              'error': modeStrategyOriginal,
            },
          );
        });
        final entered = fixture.next(ApplicationContract.coreOperationPrepare);
        final result = FutureProbe(start());
        final request = await entered;
        expect(request.arguments['admittedAt'], fixture.admittedAt);
        expect(request.arguments['deadline'], fixture.deadline);
        fixture.now = fixture.deadline - 1;
        await fixture.flush();
        expect(result.replies, 0);
        expect(fixture.exits, isEmpty);
        if (timeout) {
          fixture.expire();
        } else {
          fixture.operation.cancel();
        }
        await fixture.flush();
        expect(result.replies, 0);
        expect(request.actualExited, isFalse);
        expect(fixture.exits, timeout ? isEmpty : hasLength(1));
        request.signalExit();
        exitDrain.complete();
        await result.done;
        expect(result.replies, 1);
        expect(result.value, isNull);
        expect(errorText(result.error), contains(modeStrategyOriginal));
        expect(fixture.exits, hasLength(1));
        expect(fixture.exits.single['admittedAt'], fixture.admittedAt);
        expect(fixture.exits.single['deadline'], fixture.deadline);
        expect(fixture.snapshot.phase, 'STOPPED');
      },
    );

    for (final cleanupFails in [false, true]) {
      test(
        'NativeCallsErrorTest.executingStartupCancellationAndTimeoutKeepTheActualFailureAndStopDrain ${timeout ? 'timeout' : 'cancel'} cleanup=$cleanupFails',
        () async {
          await create(stopped: true);
          final operation = nativeFailure('java.io.IOException');
          final cleanup = {
            ...nativeFailure('java.io.IOException'),
            'message': 'cleanup: $modeStrategyOriginal',
          };
          final gate = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          fixture.script(ApplicationContract.coreOperationPrepare, (request) {
            loading(request);
            request.complete(
              null,
              terminal: {
                'complete': false,
                'error': operation,
                'exited': false,
              },
            );
          });
          final entered = fixture.next(
            ApplicationContract.coreOperationPrepare,
          );
          final started = FutureProbe(start());
          final request = await entered;
          fixture.onExit = (arguments) async {
            await gate.future;
            fixture.replaceCore(phase: cleanupFails ? 'UNKNOWN' : 'EMPTY');
            fixture.phase = cleanupFails ? 'UNKNOWN' : 'STOPPED';
            return {
              'exited': !cleanupFails,
              'error': operation,
              if (cleanupFails) 'cleanupError': cleanup,
            };
          };
          if (timeout) {
            fixture.expire();
          } else {
            fixture.operation.cancel();
          }
          final stopped = FutureProbe(
            fixture.runtime.read('stop', {
              ...timing('stop'),
              'preserveLan': false,
            }),
          );
          await fixture.flush();
          expect(started.replies, 0);
          expect(stopped.replies, 0);
          request.signalExit(receipt: {'error': operation});
          await fixture.flush();
          expect(started.replies, 0);
          expect(stopped.replies, 0);
          gate.complete();
          await Future.wait([started.done, stopped.done]);
          expect(started.replies, 1);
          expect(stopped.replies, 1);
          expect(errorText(started.error), contains(operation.toString()));
          if (cleanupFails) {
            expect(errorText(started.error), contains(cleanup.toString()));
            expect(errorText(stopped.error), contains(operation.toString()));
            expect(errorText(stopped.error), contains(cleanup.toString()));
            expect(fixture.snapshot.phase, 'UNKNOWN');
          } else {
            expect(stopped.error, isNull);
            expect(fixture.snapshot.phase, 'STOPPED');
          }
        },
      );
    }
  }

  for (final cleanupFails in [false, true]) {
    test(
      'NativeCallsErrorTest.confirmedAttachmentIsNotRewrittenWhenStopFinishesBeforeTheMainCallback cleanup=$cleanupFails',
      () async {
        await create(stopped: true);
        fixture.script(ApplicationContract.coreOperationPrepare, (request) {
          loading(request, attached: true);
          request.complete(fixture.coreMap(), terminal: {'exited': false});
        });
        final entered = fixture.next(ApplicationContract.coreOperationPrepare);
        final started = FutureProbe(start());
        final request = await entered;
        await fixture.flush();
        expect(started.replies, 0);
        final cleanup = nativeFailure('java.io.IOException')
          ..['message'] = 'cleanup: $modeStrategyOriginal';
        fixture.onExit = (_) {
          fixture.replaceCore(phase: 'EMPTY');
          fixture.phase = 'STOPPED';
          if (cleanupFails) {
            throw PlatformException(code: 'native', details: cleanup);
          }
          return {'exited': true};
        };
        final stopped = FutureProbe(stop());
        await stopped.done;
        request.signalExit();
        await started.done;
        expect(started.error, isNull);
        expect(started.replies, 1);
        expect(stopped.value, isNull);
        if (cleanupFails) {
          expectOriginalError(stopped.error, cleanup);
        } else {
          expect(stopped.error, isNull);
        }
        expect(stopped.replies, 1);
        expect(fixture.snapshot.phase, 'STOPPED');
      },
    );
  }

  for (final kind in [
    'java.lang.SecurityException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    for (final startFails in [false, true]) {
      test(
        'NativeCallsErrorTest.rejectedStopDuringStartupRetainsBothActualOutcomes $kind startFails=$startFails',
        () async {
          await create(stopped: true);
          final operation = nativeFailure('java.io.IOException');
          final rejected = nativeFailure(kind);
          fixture.script(ApplicationContract.coreOperationPrepare, (request) {
            loading(request, attached: !startFails);
            request.complete(
              startFails ? null : fixture.coreMap(),
              terminal: {
                'complete': !startFails,
                if (startFails) 'error': operation,
                'exited': false,
              },
            );
          });
          final entered = fixture.next(
            ApplicationContract.coreOperationPrepare,
          );
          final started = FutureProbe(start());
          final request = await entered;
          fixture.onExit = (_) =>
              throw PlatformException(code: 'native', details: rejected);
          final stopped = FutureProbe(stop());
          await stopped.done;
          expect(started.replies, 0);
          expectOriginalError(stopped.error, rejected);
          request.signalExit();
          await started.done;
          expect(started.replies, 1);
          expect(stopped.replies, 1);
          if (startFails) {
            expect(errorText(started.error), contains(operation.toString()));
            expect(errorText(started.error), contains(rejected.toString()));
          } else {
            expect(started.error, isNull);
            expect(fixture.snapshot.running, isTrue);
          }
        },
      );
    }
  }

  for (final timeout in [false, true]) {
    for (final failing in [false, true]) {
      test(
        'NativeCallsErrorTest.previewReleaseCancellationAndTimeoutRetainTheActualWorkerResult ${timeout ? 'timeout' : 'cancel'} failing=$failing',
        () async {
          await create(preview: true);
          final entered = Completer<void>();
          final release = Completer<void>();
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          fixture.onExit = (_) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
            fixture.replaceCore(phase: failing ? 'FAILED' : 'EMPTY');
            fixture.phase = 'STOPPED';
            if (failing) {
              throw PlatformException(
                code: 'native',
                details: nativeFailure('java.io.IOException'),
              );
            }
            return {'exited': true};
          };
          final first = FutureProbe(
            fixture.runtime.read('releasePreview', timing()),
          );
          await entered.future;
          if (timeout) {
            fixture.expire();
          } else {
            fixture.operation.cancel();
          }
          final second = FutureProbe(
            fixture.runtime.read('releasePreview', timing('second')),
          );
          await fixture.flush();
          expect(first.replies, 0);
          expect(second.replies, 0);
          release.complete();
          await Future.wait([first.done, second.done]);
          if (failing) {
            expectOriginalError(
              first.error,
              nativeFailure('java.io.IOException'),
            );
            expectOriginalError(
              second.error,
              nativeFailure('java.io.IOException'),
            );
          } else {
            expect(first.error, isNull);
            expect(second.error, isNull);
          }
          expect(first.replies, 1);
          expect(second.replies, 1);
          expect(fixture.core.phase, failing ? 'FAILED' : 'EMPTY');
        },
      );
    }
  }

  test(
    'NativeCallsErrorTest.anOldQueuedStopDoesNotReleaseTheReplacementPreview',
    () async {
      await create(preview: true);
      final old = fixture.core;
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      fixture.beforePlatformCall = (call) async {
        if (call.method == ApplicationContract.coreChannelExit &&
            !entered.isCompleted) {
          expect((call.arguments as Map)['processId'], old.processId);
          entered.complete();
          await release.future;
          throw PlatformException(
            code: ApplicationContract.coreErrorIdentityMismatch,
            details: {'message': '退出请求属于旧内核进程', 'processId': old.processId},
          );
        }
        return null;
      };
      final result = FutureProbe(
        fixture.runtime.read('releasePreview', timing()),
      );
      await entered.future;
      fixture.replaceCore(
        processId: 'replacement',
        inputId: 'replacement-input',
        generation: 2,
      );
      final replacement = fixture.core.identity;
      release.complete();
      await result.done;
      expect(result.value, isNull);
      expect(result.error, isA<PlatformFailure>());
      expect(
        (result.error as PlatformFailure).code,
        ApplicationContract.coreErrorIdentityMismatch,
      );
      expect(fixture.core.identity, replacement);
      expect(fixture.core.ready, isTrue);
      expect(fixture.exits, isEmpty);
      fixture.beforePlatformCall = null;
      await fixture.runtime.read('releasePreview', timing());
      expect(fixture.exits.single['processId'], 'replacement');
      expect(fixture.core.phase, 'EMPTY');
    },
  );
}
