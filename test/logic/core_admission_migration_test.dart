import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_runtime_fixture.dart';

const _connectionId = '00000001-0000-4000-8000-000000000000';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CoreRuntimeFixture fixture;
  setUp(() async {
    fixture = await CoreRuntimeFixture.create();
    await fixture.warmUp();
  });
  tearDown(() => fixture.dispose());

  for (final abandon in [false, true]) {
    test(
      'ConnectionsCallsTest.queuedCloseCanExpireOrBeAbandonedButKeepsItsSlotUntilWorkerDrain: queued AppRuntime close returns one error after ${abandon ? 'cancellation' : 'expiry'} and retains writer and slot until actual drain',
      () async {
        fixture.deadline = fixture.admittedAt + 100;
        await fixture.startAppRuntime();
        final command = <String, dynamic>{
          'action': 'closeConnection',
          ...fixture.identity(),
          'connectionId': _connectionId,
        };
        final gate = _ValidationGate(fixture, 3);
        addTearDown(gate.close);
        final validate = fixture.beforePlatformCall!;
        AppMessage? interruption;
        fixture.beforePlatformCall = (call) async {
          await validate(call);
          if (call.method == 'snapshot' && interruption != null) {
            return PlatformCallResult({
              ...fixture.snapshotMap(),
              'writerBusy': true,
              'operationId': 'one',
              'operationAdmittedAt': fixture.admittedAt,
              'operationDeadline': fixture.deadline,
              'operationRemainingMs': 0,
              'operation': interruption.toMap(),
            });
          }
          return null;
        };
        final pending = FutureProbe(fixture.execute({...command}));
        await gate.entered.future;
        expect(pending.settled, isFalse);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );
        interruption = abandon
            ? messages.androidErrorOperationInterrupted
            : messages.androidErrorOperationWaitTimeout;
        if (abandon) {
          await fixture.abandon();
        } else {
          fixture.expire();
        }

        // The original first.await/error must precede validation drain; operation
        // feedback cannot replace the business Reply.
        await pending.done;
        expect(pending.error, isNull);
        expect(pending.value!['success'], isFalse);
        expect(pending.value!['connectionStatus'], 'unconfirmed');
        expect((pending.value!['failure'] as Map)['code'], 'expired');
        expect(pending.replies, 1);
        final feedback = await fixture.bootstrap.runtime.platform.snapshot();
        expect(feedback.operationMessage!.toMap(), interruption.toMap());
        expect(feedback.operationId, 'one');
        expect(feedback.operationAdmittedAt, fixture.admittedAt);
        expect(feedback.operationDeadline, fixture.deadline);
        expect(feedback.operationRemainingMs, 0);
        expect(feedback.writerBusy, isTrue);
        expect(feedback.resultId, isNull);
        expect(pending.settled, isTrue);
        final busy = await fixture.execute({...command});
        expect(busy['success'], isFalse);
        expect((busy['message'] as Map)['id'], 'operationInProgress');
        final slot = jsonDecode(
          await fixture.runtime.read('closeConnection', {
            ...fixture.identity(),
            'connectionId': _connectionId,
          }) as String,
        ) as Map;
        expect(slot['readPending'], isTrue);
        expect(gate.checks, 3);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );
        expect(pending.replies, 1);

        gate.close();
        await fixture.flush();
        expect(pending.error, isNull);
        expect(pending.value!['success'], isFalse);
        expect(pending.value!['connectionStatus'], 'unconfirmed');
        expect((pending.value!['failure'] as Map)['code'], 'expired');
        expect(pending.replies, 1);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );
        _renewOperation(fixture);
        fixture.script(
          ApplicationContract.coreOperationConnectionClose,
          (request) => request.complete({'status': 'absent'}),
        );
        final retry = await fixture.execute({...command});
        expect(retry['success'], isTrue);
        expect(retry['connectionStatus'], 'absent');
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          hasLength(1),
        );
        expect(pending.replies, 1);
        expect(fixture.exits, isEmpty);
      },
    );
  }

  for (final outcome in ['closed', 'absent', 'failed', 'nativeError']) {
    test(
      'AppRuntime close reads actual $outcome after cancellation and the original deadline, retaining writer and slot until FD drain',
      () async {
        await fixture.startAppRuntime();
        final command = <String, dynamic>{
          'action': 'closeConnection',
          ...fixture.identity(),
          'connectionId': _connectionId,
        };
        const nativeError = {
          'code': 'native-close-error',
          'message': '原始 native failure',
          'cause': {'message': '原始 cause', 'stack': '原始 stack'},
          'suppressed': [
            {'message': '原始 suppressed'},
          ],
          'future': [false, null],
        };
        fixture.script(ApplicationContract.coreOperationConnectionClose, (
          request,
        ) {
          expect(request.arguments['admittedAt'], fixture.admittedAt);
          expect(request.arguments['deadline'], fixture.deadline);
          expect(request.arguments['id'], _connectionId);
          request.complete(
            {'status': outcome == 'nativeError' ? 'failed' : outcome},
            terminal: {
              'exited': false,
              if (outcome == 'nativeError') 'error': nativeError,
            },
          );
        });
        final entered = fixture.next(
          ApplicationContract.coreOperationConnectionClose,
        );
        final pending = FutureProbe(fixture.execute({...command}));
        final request = await entered;
        fixture.expire();
        await fixture.abandon();
        await fixture.flush();
        expect(pending.settled, isFalse);
        expect(request.actualExited, isFalse);
        final busy = await fixture.execute({...command});
        expect((busy['message'] as Map)['id'], 'operationInProgress');
        final slot = jsonDecode(
          await fixture.runtime.read('closeConnection', {
            ...fixture.identity(),
            'connectionId': _connectionId,
          }) as String,
        ) as Map;
        expect(slot['readPending'], isTrue);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          hasLength(1),
        );
        request.signalExit();
        await pending.done;
        expect(pending.error, isNull);
        expect(pending.replies, 1);
        final receipt = pending.value!;
        expect(
          receipt['connectionStatus'],
          outcome == 'nativeError' ? 'unconfirmed' : outcome,
        );
        expect(receipt['success'], outcome == 'closed' || outcome == 'absent');
        if (outcome == 'nativeError') {
          final failure = receipt['failure'] as Map;
          expect((failure['details'] as Map)['error'], nativeError);
          expect(failure['dartStack'], isA<String>());
        } else {
          expect(receipt['failure'], isNull);
        }
        _renewOperation(fixture);
        fixture.script(
          ApplicationContract.coreOperationConnectionClose,
          (request) => request.complete({'status': 'absent'}),
        );
        expect(
          (await fixture.execute({...command}))['connectionStatus'],
          'absent',
        );
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          hasLength(2),
        );
        expect(pending.replies, 1);
        expect(fixture.exits, isEmpty);
      },
    );
  }

  for (final abandon in [false, true]) {
    test(
      'queued close does not enter native after ${abandon ? 'owner cancellation' : 'deadline expiry'}, cannot requeue until admission ends, and can then retry',
      () async {
        fixture.deadline = fixture.admittedAt + 100;
        fixture.operation = fixture.bootstrap.runtime.platform.forOperation(
          operationId: 'one',
          admittedAt: fixture.admittedAt,
          deadline: fixture.deadline,
        );
        final captured = fixture.core;
        final gate = _ValidationGate(fixture, 3);
        addTearDown(gate.close);
        final pending = FutureProbe(
          fixture.runtime.read('closeConnection', {
            ...fixture.identity(),
            'connectionId': _connectionId,
          }, operation: fixture.operation),
        );
        await gate.entered.future;
        expect(gate.checks, 3);
        expect(pending.settled, isFalse);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );

        if (abandon) {
          fixture.operation.cancel();
        } else {
          fixture.expire();
        }
        await pending.done;
        expect(pending.value, isNull);
        expect(pending.error, isA<PlatformFailure>());
        expect((pending.error as PlatformFailure).code, 'expired');
        expect(pending.replies, 1);
        final drain = FutureProbe(fixture.operation.operationDrain!);
        final busy = jsonDecode(
          await fixture.runtime.read('closeConnection', {
            ...fixture.identity(),
            'connectionId': _connectionId,
          }) as String,
        ) as Map;
        expect(busy['readPending'], isTrue);
        expect(gate.checks, 3);
        expect(pending.replies, 1);
        expect(drain.settled, isFalse);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );
        expect(fixture.core, same(captured));
        expect(fixture.exits, isEmpty);

        gate.close();
        await drain.done;
        expect(drain.error, isNull);
        expect(pending.value, isNull);
        expect(pending.error, isA<PlatformFailure>());
        expect((pending.error as PlatformFailure).code, 'expired');
        expect(pending.replies, 1);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          isEmpty,
        );
        expect(fixture.core, same(captured));

        _renewOperation(fixture);
        fixture.script(ApplicationContract.coreOperationConnectionClose, (
          request,
        ) {
          expect(request.arguments['id'], _connectionId);
          request.complete({'status': 'absent'});
        });
        final retry = FutureProbe(
          fixture.operation.closeConnection(captured, _connectionId),
        );
        await retry.done;
        expect(retry.error, isNull);
        expect(retry.value, 'absent');
        expect(retry.replies, 1);
        expect(pending.replies, 1);
        expect(
          fixture.calls(ApplicationContract.coreOperationConnectionClose),
          hasLength(1),
        );
        expect(fixture.exits, isEmpty);
      },
    );
  }

  for (final beforeAdmission in [true, false]) {
    test(
      'resource owner cancellation ${beforeAdmission ? 'before admission' : 'before native submission'} skips context replacement and update, then releases the slot',
      () async {
        final captured = fixture.core;
        final gate = _ValidationGate(fixture, beforeAdmission ? 1 : 3);
        addTearDown(gate.close);
        final pending = FutureProbe(
          fixture.runtime.read('updateResource', {
            ...fixture.identity(),
            'query': {'kind': 'geo', 'name': 'GeoIP'},
          }, operation: fixture.operation),
        );
        await gate.entered.future;
        final checksAtCancellation = gate.checks;
        fixture.operation.cancel();
        final busy = jsonDecode(
          await fixture.runtime.read('updateResource', {
            ...fixture.identity(),
            'query': {'kind': 'geo', 'name': 'GeoIP'},
          }) as String,
        ) as Map;
        expect(busy['readPending'], isTrue);
        expect(gate.checks, checksAtCancellation);
        expect(pending.settled, isFalse);
        expect(
          fixture.calls(ApplicationContract.coreOperationResourceUpdate),
          isEmpty,
        );
        expect(fixture.core, same(captured));

        gate.close();
        await pending.done;
        expect(pending.value, isNull);
        expect(pending.error, isA<PlatformFailure>());
        expect((pending.error as PlatformFailure).code, 'expired');
        expect(pending.replies, 1);
        expect(
          fixture.calls(ApplicationContract.coreOperationResourceUpdate),
          isEmpty,
        );
        expect(fixture.core, same(captured));
        expect(fixture.exits, isEmpty);

        _renewOperation(fixture);
        fixture.script(ApplicationContract.coreOperationResourceUpdate, (
          request,
        ) {
          expect(request.arguments['kind'], 'geo');
          expect(request.arguments['name'], 'GeoIP');
          request.complete({'status': 'ok'});
        });
        final retry = await fixture.operation.updateResource(
          captured,
          kind: 'geo',
          name: 'GeoIP',
        );
        expect((retry['update'] as Map)['status'], 'ok');
        expect(
          fixture.calls(ApplicationContract.coreOperationResourceUpdate),
          hasLength(1),
        );
        expect(fixture.core, same(captured));
        expect(pending.replies, 1);
        expect(fixture.exits, isEmpty);
      },
    );
  }

  for (final beforeAdmission in [true, false]) {
    test(
      'AppRuntime resource owner cancellation ${beforeAdmission ? 'before business admission' : 'before actual submission'} retains the writer until admission ends and permits retry after failure',
      () async {
        await fixture.startAppRuntime();
        final captured = fixture.core;
        final command = <String, dynamic>{
          'action': 'updateResource',
          ...fixture.identity(),
          'kind': 'geo',
          'name': 'GeoIP',
        };
        final gate = _ValidationGate(fixture, beforeAdmission ? 1 : 4);
        addTearDown(gate.close);
        final pending = FutureProbe(fixture.execute({...command}));
        await gate.entered.future;
        await fixture.abandon();
        expect(pending.settled, isFalse);
        final busy = await fixture.execute({...command});
        expect(busy['success'], isFalse);
        expect(busy['failure'], isNull);
        expect((busy['message'] as Map)['id'], 'operationInProgress');
        expect(
          fixture.calls(ApplicationContract.coreOperationResourceUpdate),
          isEmpty,
        );
        expect(fixture.core, same(captured));
        gate.close();
        await pending.done;
        expect(pending.error, isNull);
        expect(pending.value!['success'], isFalse);
        expect(pending.value!['failure'], isNotNull);
        expect(pending.value!['resourceStatus'], 'unconfirmed');
        expect(pending.replies, 1);
        expect(
          fixture.calls(ApplicationContract.coreOperationResourceUpdate),
          isEmpty,
        );
        expect(fixture.core, same(captured));

        fixture.script(ApplicationContract.coreOperationResourceUpdate, (
          request,
        ) {
          request.complete({'status': 'ok'});
        });
        final retry = await fixture.execute({...command});
        expect(retry['success'], isTrue);
        expect(retry['resourceStatus'], 'ok');
        expect(
          fixture.calls(ApplicationContract.coreOperationResourceUpdate),
          hasLength(1),
        );
        expect(pending.replies, 1);
        expect(fixture.core, same(captured));
        expect(fixture.exits, isEmpty);
      },
    );
  }

  test('queued resource cannot enter replacement native after a context change and can retry on the new source after admission ends', () async {
    final captured = fixture.core;
    final gate = _ValidationGate(fixture, 1);
    addTearDown(gate.close);
    final pending = FutureProbe(
      fixture.runtime.read('updateResource', {
        ...fixture.identity(),
        'query': {'kind': 'geo', 'name': 'GeoIP'},
      }, operation: fixture.operation),
    );
    await gate.entered.future;
    fixture.replaceCore(phase: 'RELEASING');
    fixture.replaceCore(
      processId: 'replacement',
      inputId: 'replacement-input',
      generation: 1,
      composition: 'replacement',
    );
    final replacement = fixture.core;
    final busy = jsonDecode(
      await fixture.runtime.read('updateResource', {
        ...fixture.identity(),
        'query': {'kind': 'geo', 'name': 'GeoIP'},
      }) as String,
    ) as Map;
    expect(busy['readPending'], isTrue);
    expect(busy['processId'], captured.processId);
    expect(
      fixture.calls(ApplicationContract.coreOperationResourceUpdate),
      isEmpty,
    );
    gate.close();
    await pending.done;
    expect(pending.error, isA<PlatformFailure>());
    expect(
      (pending.error as PlatformFailure).code,
      ApplicationContract.coreErrorIdentityMismatch,
    );
    expect(pending.value, isNull);
    expect(pending.replies, 1);
    expect(
      fixture.calls(ApplicationContract.coreOperationResourceUpdate),
      isEmpty,
    );
    expect(fixture.core, same(replacement));
    fixture.script(ApplicationContract.coreOperationResourceUpdate, (request) {
      expect(
        (request.wire['identity'] as Map)['processId'],
        replacement.processId,
      );
      request.complete({'status': 'ok'});
    });
    final retry = await fixture.operation.updateResource(
      replacement,
      kind: 'geo',
      name: 'GeoIP',
    );
    expect((retry['update'] as Map)['status'], 'ok');
    expect(
      fixture.calls(ApplicationContract.coreOperationResourceUpdate),
      hasLength(1),
    );
    expect(pending.replies, 1);
    expect(fixture.exits, isEmpty);
  });

  test('running resource retains its result after deadline and owner cancellation, holds the update slot until the actual receipt, and allows diagnostic reads', () async {
    final captured = fixture.core;
    fixture.script(ApplicationContract.coreOperationResourceUpdate, (request) {
      request.complete(
        {
          'status': 'ok',
          'future': [false, null],
        },
        terminal: {'exited': false},
      );
    });
    final entered = fixture.next(
      ApplicationContract.coreOperationResourceUpdate,
    );
    final pending = FutureProbe(
      fixture.operation.updateResource(captured, kind: 'geo', name: 'GeoIP'),
    );
    final request = await entered;
    fixture.expire();
    fixture.operation.cancel();
    await fixture.flush();
    expect(pending.settled, isFalse);
    expect(request.actualExited, isFalse);
    final busy = jsonDecode(
      await fixture.runtime.read('updateResource', {
        ...fixture.identity(),
        'query': {'kind': 'geo', 'name': 'GeoIP'},
      }) as String,
    ) as Map;
    expect(busy['readPending'], isTrue);
    expect(
      fixture.calls(ApplicationContract.coreOperationResourceUpdate),
      hasLength(1),
    );

    fixture.script(ApplicationContract.coreOperationRuntimeConfig, (request) {
      request.complete('mode: rule\n');
    });
    final diagnostic = jsonDecode(
      await fixture.runtime.read('runtimeConfig', fixture.identity()) as String,
    ) as Map;
    expect(diagnostic['configuration'], 'mode: rule\n');
    expect(pending.settled, isFalse);
    expect(fixture.core, same(captured));
    fixture.replaceCore(phase: 'RELEASING');
    expect(pending.settled, isFalse);

    request.signalExit(
      receipt: {
        'exited': true,
        'future': [false, null],
      },
    );
    await pending.done;
    expect(pending.error, isNull);
    expect((pending.value!['update'] as Map)['status'], 'ok');
    expect((pending.value!['update'] as Map).containsKey('future'), isFalse);
    expect(pending.value!['generation'], captured.generation);
    expect(pending.value!['composition'], captured.composition);
    expect(pending.value!['stale'], isTrue);
    expect(pending.replies, 1);
    expect(request.actualExited, isTrue);

    _renewOperation(fixture);
    fixture.replaceCore(
      processId: 'process-replacement',
      inputId: 'input-replacement',
      generation: 1,
      composition: 'replacement',
    );
    final replacement = fixture.core;
    fixture.script(ApplicationContract.coreOperationResourceUpdate, (request) {
      request.complete({'status': 'ok'});
    });
    expect(
      (await fixture.operation.updateResource(
        replacement,
        kind: 'geo',
        name: 'GeoIP',
      ))['update'],
      {'status': 'ok'},
    );
    expect(
      fixture.calls(ApplicationContract.coreOperationResourceUpdate),
      hasLength(2),
    );
    expect(pending.replies, 1);
    expect(fixture.exits, isEmpty);
  });
}

void _renewOperation(CoreRuntimeFixture fixture) {
  fixture.operationExpired = false;
  fixture.now = 100;
  fixture.operation = fixture.bootstrap.runtime.platform.forOperation(
    operationId: 'retry',
    admittedAt: 100,
    deadline: 60100,
  );
}

class _ValidationGate {
  _ValidationGate(this.fixture, this.target) {
    fixture.beforePlatformCall = (call) async {
      if (call.method == 'checkOperation' && ++checks == target) {
        entered.complete();
        await _release.future;
      }
      return null;
    };
  }

  final CoreRuntimeFixture fixture;
  final int target;
  final entered = Completer<void>();
  final _release = Completer<void>();
  int checks = 0;

  void close() {
    fixture.beforePlatformCall = null;
    if (!_release.isCompleted) _release.complete();
  }
}
