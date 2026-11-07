import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_runtime_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoreRuntimeFixture fixture;

  Future<void> create({bool lanOnly = false}) async {
    fixture = await CoreRuntimeFixture.create(lanOnly: lanOnly);
    addTearDown(fixture.dispose);
  }

  for (final confirmed in [false, true]) {
    test(
      'restored mode errors clear after actual Stop exit and remain until exit is confirmed confirmed=$confirmed',
      () async {
        await create();
        fixture.beforePlatformCall = (call) {
          if (call.method ==
              ApplicationContract.coreChannelReadRunInputRecord) {
            return PlatformCallResult({
              'saved': false,
              'inputId': fixture.core.inputId,
            });
          }
          return null;
        };
        final failure = nativeFailure('java.io.IOException');
        fixture.script(ApplicationContract.coreOperationMode, (request) {
          request.complete(
            null,
            terminal: {'complete': false, 'error': failure},
          );
        });
        await fixture.warmUp();
        final mode = fixture.modeProjection!;
        final original = mode['error'] as Map;
        expect(mode['processId'], fixture.core.processId);
        expect(original['detail'], contains(failure.toString()));
        final window = fixture.runtime.logs.source;
        expect(window, isNotNull);
        final entered = Completer<void>();
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        fixture.onExit = (_) async {
          entered.complete();
          await release.future;
          if (confirmed) {
            fixture.replaceCore(phase: 'EMPTY');
            fixture.phase = 'STOPPED';
          }
          return {'exited': confirmed, if (!confirmed) 'error': failure};
        };
        final stopped = FutureProbe(
          fixture.runtime.read('stop', const {}, operation: fixture.operation),
        );
        await entered.future;
        expect(stopped.settled, isFalse);
        expect(fixture.modeProjection, mode);
        expect(fixture.snapshot.running, isTrue);
        release.complete();
        await stopped.done;
        if (confirmed) {
          expect(stopped.error, isNull);
          expect(fixture.snapshot.running, isFalse);
          expect(fixture.modeProjection!['actual'], isNull);
          expect(fixture.modeProjection!['error'], isNull);
          expect(fixture.runtime.logError, original);
          final diagnostic = jsonDecode(
            await fixture.runtime.read('logs', {
              'query': {'window': window},
            }) as String,
          ) as Map;
          expect(diagnostic['error'], original);
          expect(
            (diagnostic['error'] as Map)['detail'],
            contains(failure.toString()),
          );
          expect(diagnostic['stale'], isTrue);
        } else {
          expect(stopped.error, isA<PlatformFailure>());
          expectOriginalError(stopped.error, failure);
          expect(fixture.modeProjection, mode);
          expect(fixture.snapshot.running, isTrue);
        }
        expect(
          fixture.calls(ApplicationContract.coreOperationMode),
          hasLength(1),
        );
      },
    );
  }

  test('restored process without runInput clears mode issues on actual exit and keeps the complete error in the original log window', () async {
    await create();
    fixture.beforePlatformCall = (call) {
      if (call.method == ApplicationContract.coreChannelReadRunInputRecord) {
        return PlatformCallResult({
          'saved': false,
          'inputId': fixture.core.inputId,
        });
      }
      return null;
    };
    final failure = nativeFailure('java.lang.UnsatisfiedLinkError');
    fixture.script(ApplicationContract.coreOperationMode, (request) {
      request.complete(null, terminal: {'complete': false, 'error': failure});
    });
    await fixture.warmUp();
    final source = fixture.core;
    final original = fixture.modeProjection!['error'];
    expect(original, isNotNull);
    fixture.replaceCore(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    fixture.emit({
      'processId': source.processId,
      'phase': ApplicationContract.corePhaseExited,
      'exited': true,
    });
    await fixture.flush();
    expect(fixture.modeProjection!['error'], isNull);
    expect(fixture.modeProjection!['actual'], isNull);
    expect(fixture.runtime.logError, original);
    expect(
      (fixture.runtime.logError as Map)['detail'],
      contains(failure.toString()),
    );
    expect((fixture.runtime.projection['logSource'] as Map)['phase'], 'EMPTY');
    expect(
      fixture.runtime.logs.source,
      '${source.processId}/${source.inputId}',
    );
    expect(fixture.snapshot.running, isFalse);
  });

  for (final lateLog in [false, true]) {
    test(
      'Stop retains complete original mode and log errors with log after exit=$lateLog',
      () async {
        await create();
        final modeFailure = nativeFailure('java.io.IOException');
        final logFailure = nativeFailure('java.lang.UnsatisfiedLinkError');
        fixture.script(ApplicationContract.coreOperationMode, (request) {
          request.complete(
            null,
            terminal: {'complete': false, 'error': modeFailure},
          );
        });
        late CoreTestRequest logRequest;
        fixture.script(ApplicationContract.coreOperationLogs, (request) {
          logRequest = request;
          request.metadata({'source': request.source});
        });
        await fixture.warmUp();
        final source = fixture.core;
        final original = fixture.modeProjection!['error'];
        expect(original, isNotNull);
        void completeLogs() => logRequest.terminal({
          'complete': false,
          'exited': true,
          'error': logFailure,
        });
        if (!lateLog) {
          completeLogs();
          await fixture.flush();
          expect(fixture.runtime.logError, logFailure);
        }
        fixture.replaceCore(phase: 'EMPTY');
        fixture.phase = 'STOPPED';
        fixture.emit({
          'processId': source.processId,
          'phase': ApplicationContract.corePhaseExited,
          'exited': true,
        });
        if (lateLog) {
          expect(fixture.runtime.logError, original);
          completeLogs();
        }
        await fixture.flush();
        expect(fixture.modeProjection!['error'], isNull);
        final diagnostic = jsonDecode(
          await fixture.runtime.read('logs', {
            'query': {'window': fixture.runtime.logs.source},
          }) as String,
        ) as Map;
        expect(
          diagnostic['error'],
          lateLog
              ? {'error': logFailure, 'previous': original}
              : {'error': original, 'previous': logFailure},
        );
        expect(diagnostic['stale'], isTrue);
        expect(fixture.snapshot.running, isFalse);
      },
    );
  }

  test(
    'old process exit does not clear replacement mode or log source',
    () async {
      await create();
      await fixture.warmUp();
      final source = fixture.core;
      fixture.replaceCore(
        processId: 'mode-replacement',
        inputId: 'mode-replacement-input',
        generation: 2,
      );
      fixture.actualMode = 'direct';
      await fixture.warmUp();
      final mode = fixture.modeProjection;
      final logSource = fixture.runtime.projection['logSource'];
      expect(mode!['processId'], 'mode-replacement');
      expect(mode['actual'], 'direct');
      fixture.emit({
        'processId': source.processId,
        'phase': ApplicationContract.corePhaseExited,
        'exited': true,
      });
      await fixture.flush();
      expect(fixture.modeProjection, mode);
      expect(fixture.runtime.projection['logSource'], logSource);
      expect(fixture.snapshot.running, isTrue);
    },
  );

  for (final failed in [false, true]) {
    test(
      'late MODE after stop does not restore runtime mode or issues and retains original errors for diagnostics failed=$failed',
      () async {
        await create();
        final failure = nativeFailure('java.io.IOException');
        fixture.script(ApplicationContract.coreOperationMode, (request) {
          request.complete(
            failed ? null : {'mode': 'global'},
            terminal: {
              'exited': false,
              if (failed) ...{'complete': false, 'error': failure},
            },
          );
        });
        final entered = fixture.next(ApplicationContract.coreOperationMode);
        final restored = FutureProbe(fixture.runtime.restoreExisting());
        final request = await entered;
        await fixture.flush();
        expect(restored.settled, isFalse);
        fixture.replaceCore(phase: 'EMPTY');
        fixture.phase = 'STOPPED';
        expect(restored.settled, isFalse);
        expect(request.actualExited, isFalse);
        expect(fixture.modeProjection, isNull);
        request.signalExit();
        await restored.done;
        expect(restored.error, isNull);
        expect(fixture.modeProjection, isNull);
        expect(fixture.calls(ApplicationContract.coreOperationLogs), isEmpty);
        expect(fixture.snapshot.running, isFalse);
        if (failed) expectOriginalError(fixture.runtime.logError, failure);
        expect(request.actualExited, isTrue);
      },
    );
  }

  test('late restoration errors after stop do not create mode issues and remain available for diagnostics', () async {
    await create();
    final failure = nativeFailure('java.lang.UnsatisfiedLinkError');
    fixture.script(ApplicationContract.coreOperationSnapshot, (request) {
      request.complete(
        null,
        terminal: {'complete': false, 'error': failure, 'exited': false},
      );
    });
    final entered = fixture.next(ApplicationContract.coreOperationSnapshot);
    final restored = FutureProbe(fixture.runtime.restoreExisting());
    await entered;
    await fixture.flush();
    expect(restored.settled, isFalse);
    fixture.replaceCore(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    fixture.emit({
      'processId': fixture.core.processId,
      'phase': ApplicationContract.corePhaseExited,
      'exited': true,
    });
    await restored.done;
    expect(fixture.modeProjection, isNull);
    expectOriginalError(fixture.runtime.logError, failure);
    expect(fixture.calls(ApplicationContract.coreOperationMode), isEmpty);
    expect(fixture.calls(ApplicationContract.coreOperationLogs), isEmpty);
  });

  for (final lanOnly in [false, true]) {
    test(
      'mode applies and reads back once while preserving ${lanOnly ? 'LAN-only' : 'VPN'} runtime state',
      () async {
        await create(lanOnly: lanOnly);
        await fixture.warmUp();
        final identity = fixture.core.identity;
        final result = await fixture.configActions.execute({
          'action': 'setMode',
          'mode': 'global',
        });
        await fixture.flush();
        expect(result?.id, 'modeSwitchedResult');
        expect(fixture.nativeModeChanges, 1);
        expect(fixture.changes, 1);
        expect(fixture.modeProjection, {
          ...fixture.runtime.envelope(fixture.core),
          'actual': 'global',
          'fallback': null,
          'error': null,
        });
        expect(fixture.core.identity, identity);
        expect(fixture.snapshot.forwarding, isTrue);
        expect(fixture.snapshot.running, !lanOnly);
        expect(fixture.snapshot.lanRunning, lanOnly);
        expect(fixture.exits, isEmpty);
        expect((await fixture.store.read()).mode, TunnelMode.global);
        expect((await fixture.runtime.inputFor(fixture.core))!['mode'], isNull);
      },
    );
  }

  test(
    'cancelled queued mode operation replies once without changing the core',
    () async {
      await create();
      await fixture.startAppRuntime();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.beforePlatformCall = (call) async {
        if (call.method == 'checkOperation' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return null;
      };
      final result = FutureProbe(
        fixture.execute({'action': 'setMode', 'mode': 'global'}),
      );
      await entered.future;
      await fixture.abandon();
      release.complete();
      await result.done;
      expect(result.replies, 1);
      expect(result.value!['success'], isFalse);
      expect(result.value!['message'], isNotNull);
      expect(fixture.nativeModeChanges, 0);
      expect(fixture.calls(ApplicationContract.coreOperationModeSet), isEmpty);
      expect(fixture.snapshot.running, isTrue);
      expect(fixture.exits, isEmpty);
    },
  );

  test(
    'mode requests from an old generation cannot change the replacement',
    () async {
      await create();
      await fixture.warmUp();
      final original = fixture.identity();
      fixture.replaceCore(
        processId: 'replacement-process',
        inputId: 'replacement-input',
        generation: 2,
      );
      final replacement = fixture.core.identity;
      await expectLater(
        fixture.runtime.read('setMode', {...original, 'mode': 'global'}),
        throwsA(
          isA<PlatformFailure>().having(
            (error) => error.code,
            'code',
            ApplicationContract.coreErrorIdentityMismatch,
          ),
        ),
      );
      expect(fixture.nativeModeChanges, 0);
      expect(fixture.core.identity, replacement);
      expect(fixture.snapshot.running, isTrue);
      expect(fixture.exits, isEmpty);
    },
  );

  test(
    'expired queued mode operations do not execute late or stop VPN',
    () async {
      await create();
      await fixture.startAppRuntime();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.beforePlatformCall = (call) async {
        if (call.method == 'checkOperation' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return null;
      };
      final result = FutureProbe(
        fixture.execute({'action': 'setMode', 'mode': 'global'}),
      );
      await entered.future;
      fixture.expire();
      release.complete();
      await result.done;
      await fixture.flush();
      expect(result.replies, 1);
      expect(result.value!['success'], isFalse);
      expect(fixture.nativeModeChanges, 0);
      expect(fixture.calls(ApplicationContract.coreOperationModeSet), isEmpty);
      expect(fixture.snapshot.running, isTrue);
      expect(fixture.exits, isEmpty);
    },
  );

  for (final timeout in [true, false]) {
    test(
      'running mode ${timeout ? 'expiry' : 'cancellation'} retains actual success and awaits actual exit',
      () async {
        await create();
        await fixture.startAppRuntime();
        fixture.script(ApplicationContract.coreOperationModeSet, (request) {
          fixture.nativeModeChanges++;
          fixture.actualMode = 'global';
          request.complete({'mode': 'global'}, terminal: {'exited': false});
        });
        final entered = fixture.next(ApplicationContract.coreOperationModeSet);
        final result = FutureProbe(
          fixture.execute({'action': 'setMode', 'mode': 'global'}),
        );
        final request = await entered;
        if (timeout) {
          fixture.expire();
        } else {
          await fixture.abandon();
        }
        await fixture.flush();
        expect(result.settled, isFalse);
        expect(result.replies, 0);
        final blocked = await fixture.execute({
          'action': 'setMode',
          'mode': 'direct',
        });
        expect(blocked['success'], isFalse);
        expect((blocked['message'] as Map)['id'], 'operationInProgress');
        request.signalExit();
        await result.done;
        await fixture.flush();
        expect(result.replies, 1);
        expect(result.error, isNull);
        expect(result.value!['success'], isTrue);
        expect((result.value!['message'] as Map)['id'], 'modeSwitchedResult');
        expect(fixture.nativeModeChanges, 1);
        expect(fixture.notifications, hasLength(1));
        expect(
          (fixture.notifications.single['mode'] as Map)['actual'],
          'global',
        );
        expect(fixture.snapshot.running, isTrue);
        expect(fixture.exits, isEmpty);
      },
    );
  }

  test(
    'expired mode read retains RUNNING, the original error, and null fallback',
    () async {
      await create();
      final failure = {
        'code': 'expired',
        'admittedAt': fixture.admittedAt,
        'deadline': fixture.deadline,
        'detail': modeStrategyOriginal,
      };
      fixture.script(ApplicationContract.coreOperationMode, (request) {
        request.complete(null, terminal: {'complete': false, 'error': failure});
      });
      await fixture.runtime.restoreExisting();
      await fixture.flush();
      expect(fixture.modeProjection!['actual'], isNull);
      expect(fixture.modeProjection!['fallback'], isNull);
      expect(
        (fixture.modeProjection!['error'] as Map)['detail'],
        contains(failure.toString()),
      );
      expect(fixture.nativeModeChanges, 0);
      expect(fixture.snapshot.running, isTrue);
      expect(fixture.exits, isEmpty);
    },
  );

  test(
    'mode readback mismatch is not success and preserves saved intent',
    () async {
      await create();
      await fixture.warmUp();
      fixture.script(ApplicationContract.coreOperationModeSet, (request) {
        fixture.nativeModeChanges++;
        request.complete({'mode': 'global'});
      });
      final result = FutureProbe(
        fixture.configActions.execute({'action': 'setMode', 'mode': 'global'}),
      );
      await result.done;
      expect(result.error, isA<ConfigFailure>());
      expect((result.error as ConfigFailure).message.id, 'modeNotConfirmed');
      expect(fixture.actualMode, 'rule');
      expect(fixture.modeProjection!['actual'], 'rule');
      expect((await fixture.store.read()).mode, TunnelMode.global);
      expect(fixture.configActions.result['configStatus'], 'applyFailed');
      expect(fixture.configActions.result['success'], isFalse);
      expect(fixture.exits, isEmpty);
    },
  );

  for (final timeout in [false, true]) {
    test(
      'running mode ${timeout ? 'expiry' : 'cancellation'} retains actual failure and the complete original error',
      () async {
        await create();
        await fixture.startAppRuntime();
        final failure = nativeFailure('java.io.IOException');
        fixture.script(ApplicationContract.coreOperationModeSet, (request) {
          request.complete(
            null,
            terminal: {
              'complete': false,
              'error': failure,
              'exited': false,
              'future': {'Authorization': modeStrategyOriginal},
              'values': [false, null],
            },
          );
        });
        final entered = fixture.next(ApplicationContract.coreOperationModeSet);
        final result = FutureProbe(
          fixture.execute({'action': 'setMode', 'mode': 'global'}),
        );
        final request = await entered;
        if (timeout) {
          fixture.expire();
        } else {
          await fixture.abandon();
        }
        await fixture.flush();
        expect(result.replies, 0);
        final blocked = await fixture.execute({
          'action': 'setMode',
          'mode': 'direct',
        });
        expect((blocked['message'] as Map)['id'], 'operationInProgress');
        request.signalExit(receipt: {'error': failure});
        await result.done;
        await fixture.flush();
        expect(result.replies, 1);
        expect(result.value!['success'], isFalse);
        final detail = (result.value!['message'] as Map)['detail'] as String;
        expect(detail, contains(failure.toString()));
        expect(detail, contains(failure['stack'] as String));
        expect(fixture.notifications, hasLength(1));
        expect(fixture.actualMode, 'rule');
        expect(fixture.snapshot.running, isTrue);
        expect(fixture.exits, isEmpty);
      },
    );
  }

  test('invalid mode and reads after stop do not enter the core', () async {
    await create();
    await fixture.warmUp();
    final before = fixture.requests.length;
    await expectLater(
      fixture.runtime.read('setMode', {
        ...fixture.identity(),
        'mode': 'follow',
      }),
      throwsA(isA<Exception>()),
    );
    expect(fixture.requests, hasLength(before));
    await expectLater(
      fixture.configActions.execute({'action': 'setMode', 'mode': ''}),
      throwsA(isA<FormatException>()),
    );
    fixture.replaceCore(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    await expectLater(
      fixture.runtime.read('setMode', {
        ...fixture.identity(),
        'mode': 'global',
      }),
      throwsA(isA<PlatformFailure>()),
    );
    expect(fixture.requests, hasLength(before));
    expect(fixture.nativeModeChanges, 0);
  });

  for (final kind in [
    'java.io.IOException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    test('MODE retains the complete original $kind error', () async {
      await create();
      final failure = nativeFailure(kind);
      fixture.script(ApplicationContract.coreOperationMode, (request) {
        request.complete(null, terminal: {'complete': false, 'error': failure});
      });
      await fixture.runtime.restoreExisting();
      expect(fixture.modeProjection!['actual'], isNull);
      expect(fixture.modeProjection!['fallback'], isNull);
      expect(
        (fixture.modeProjection!['error'] as Map)['detail'],
        contains(failure.toString()),
      );
      expect(
        (fixture.modeProjection!['error'] as Map)['detail'],
        contains(failure['stack'] as String),
      );
      expect(fixture.snapshot.running, isTrue);
    });

    test('MODE_SET retains the complete original $kind error', () async {
      await create();
      await fixture.warmUp();
      final failure = nativeFailure(kind);
      fixture.script(ApplicationContract.coreOperationModeSet, (request) {
        request.complete(null, terminal: {'complete': false, 'error': failure});
      });
      final result = FutureProbe(
        fixture.runtime.read('setMode', {
          ...fixture.identity(),
          'mode': 'global',
        }),
      );
      await result.done;
      expect(result.value, isNull);
      expect(result.replies, 1);
      expectOriginalError(result.error, failure);
      expect((result.error as PlatformFailure).details['error'], failure);
      expect(fixture.snapshot.running, isTrue);
    });
  }

  test(
    'native rejection and unknown MODE retain their complete original values',
    () async {
      await create();
      await fixture.warmUp();
      final failure = nativeFailure('java.lang.IllegalStateException');
      fixture.script(ApplicationContract.coreOperationModeSet, (request) {
        request.complete(null, terminal: {'complete': false, 'error': failure});
      });
      final result = FutureProbe(
        fixture.runtime.read('setMode', {
          ...fixture.identity(),
          'mode': 'global',
        }),
      );
      await result.done;
      expectOriginalError(result.error, failure);
      expect((result.error as PlatformFailure).details['error'], failure);
      fixture.replaceCore(
        processId: 'unknown-mode-process',
        inputId: 'unknown-input',
      );
      fixture.actualMode = modeStrategyOriginal;
      await fixture.runtime.restoreExisting();
      expect(fixture.modeProjection!['actual'], isNull);
      expect(
        (fixture.modeProjection!['error'] as Map)['detail'],
        contains(modeStrategyOriginal),
      );
      expect(fixture.nativeModeChanges, 0);
    },
  );

  test('source changes cannot erase actual MODE errors', () async {
    await create();
    final failure = nativeFailure('java.io.IOException');
    fixture.script(ApplicationContract.coreOperationMode, (request) {
      fixture.replaceCore(
        processId: 'replacement-process',
        inputId: 'replacement-input',
        generation: 2,
      );
      request.complete(null, terminal: {'complete': false, 'error': failure});
    });
    await fixture.runtime.restoreExisting();
    expectOriginalError(fixture.runtime.logError, failure);
    expect(fixture.modeProjection, isNull);
    expect(fixture.core.processId, 'replacement-process');
    expect(fixture.snapshot.running, isTrue);
  });

  test('source changes retain actual success of the applied mode without overwriting the replacement projection', () async {
    await create();
    await fixture.warmUp();
    final captured = fixture.identity();
    fixture.script(ApplicationContract.coreOperationModeSet, (request) {
      fixture.replaceCore(
        processId: 'replacement-process',
        inputId: 'replacement-input',
        generation: 2,
      );
      fixture.actualMode = 'direct';
      request.complete({'mode': 'global'});
    });
    expect(
      await fixture.runtime.read('setMode', {...captured, 'mode': 'global'}),
      'global',
    );
    await fixture.runtime.restoreExisting();
    expect(fixture.modeProjection!['actual'], 'direct');
    expect(fixture.core.processId, 'replacement-process');
    expect(fixture.snapshot.running, isTrue);
    expect(fixture.exits, isEmpty);
  });

  for (final kind in [
    'java.util.concurrent.RejectedExecutionException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    test('mode worker $kind replies once and releases the request', () async {
      await create();
      await fixture.warmUp();
      final failure = nativeFailure(kind);
      var rejected = false;
      fixture.beforePlatformCall = (call) {
        if (call.method == ApplicationContract.coreChannelSubmit && !rejected) {
          rejected = true;
          throw PlatformException(code: 'worker-rejected', details: failure);
        }
        return null;
      };
      final result = FutureProbe(
        fixture.runtime.read('setMode', {
          ...fixture.identity(),
          'mode': 'global',
        }),
      );
      await result.done;
      expect(result.value, isNull);
      expect(result.replies, 1);
      expect((result.error as PlatformFailure).details, failure);
      expectOriginalError(result.error, failure);
      expect(fixture.nativeModeChanges, 0);
      expect(
        await fixture.runtime.read('setMode', {
          ...fixture.identity(),
          'mode': 'global',
        }),
        'global',
      );
      expect(fixture.nativeModeChanges, 1);
      expect(fixture.snapshot.running, isTrue);
    });
  }

  test('mode transport failure is not process death and retains the execution slot until actual exit', () async {
    await create();
    await fixture.startAppRuntime();
    final failure = nativeFailure('native-call-failure');
    final cancellation = nativeFailure('native-cancel-failure');
    fixture.onCancel = (_) => {'accepted': false, 'error': cancellation};
    fixture.script(ApplicationContract.coreOperationModeSet, (request) {
      request.interrupt(
        PlatformException(
          code: ApplicationContract.coreErrorTransportInterrupted,
          details: {'original': modeStrategyOriginal},
        ),
        receipt: {
          'error': failure,
          'future': [false, null],
        },
      );
    });
    final entered = fixture.next(ApplicationContract.coreOperationModeSet);
    final result = FutureProbe(
      fixture.execute({'action': 'setMode', 'mode': 'global'}),
    );
    final request = await entered;
    fixture.emit({
      'processId': request.processId,
      'phase': 'communicationLost',
    });
    await fixture.flush();
    expect(result.settled, isFalse);
    expect(request.actualExited, isFalse);
    expect(request.cancellations, 1);
    final blocked = await fixture.execute({
      'action': 'setMode',
      'mode': 'direct',
    });
    expect((blocked['message'] as Map)['id'], 'operationInProgress');
    request.signalExit(
      receipt: {'error': failure, 'cancelError': cancellation},
    );
    await result.done;
    expect(result.replies, 1);
    final detail = (result.value!['message'] as Map)['detail'] as String;
    expect(detail, contains(failure.toString()));
    expect(detail, contains(cancellation.toString()));
    expect(detail, contains(ApplicationContract.coreErrorTransportInterrupted));
    expect(fixture.exits, isEmpty);
  });

  test('confirmed process death ends the old mode call and old exit events do not change the new process', () async {
    await create();
    await fixture.startAppRuntime();
    fixture.script(ApplicationContract.coreOperationModeSet, (request) {
      request.complete(null, terminal: {'complete': false, 'exited': false});
    });
    final entered = fixture.next(ApplicationContract.coreOperationModeSet);
    final result = FutureProbe(
      fixture.execute({'action': 'setMode', 'mode': 'global'}),
    );
    final request = await entered;
    await fixture.flush();
    expect(result.settled, isFalse);
    fixture.replaceCore(
      processId: 'replacement-process',
      inputId: 'replacement-input',
      generation: 2,
    );
    final replacement = fixture.core.identity;
    fixture.emit({
      'processId': request.processId,
      'phase': ApplicationContract.corePhaseExited,
      'exited': true,
      'error': modeStrategyOriginal,
    });
    request.actualExited = true;
    await result.done;
    expect(result.replies, 1);
    expect(result.value!['success'], isFalse);
    expect(
      (result.value!['message'] as Map)['detail'],
      contains(ApplicationContract.coreErrorProcessExited),
    );
    expect(
      (result.value!['message'] as Map)['detail'],
      contains(modeStrategyOriginal),
    );
    expect(fixture.core.identity, replacement);
    expect(fixture.snapshot.running, isTrue);
    expect(fixture.exits, isEmpty);
  });
}
