import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/core_runtime_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('GeoIP waits 750ms after the original 500ms deadline and retains the original success and slot until actual drain', () async {
    final fixture = await CoreRuntimeFixture.create(preview: true, body: '');
    fixture.replaceCore(configId: 'main', composition: '["main",1]');
    await fixture.writeRecord({'id': 'main', 'body': '', 'mode': 'rule'});
    await fixture.warmUp();
    final source = fixture.core;
    final platform = fixture.bootstrap.runtime.platform;
    fixture.deadline = fixture.admittedAt + 500;
    fixture.operation = platform.forOperation(
      operationId: 'owner',
      admittedAt: fixture.admittedAt,
      deadline: fixture.deadline,
    );
    final clock = Stopwatch()..start();
    fixture.beforePlatformCall = (_) {
      fixture.now = fixture.admittedAt + clock.elapsedMilliseconds;
      return null;
    };
    final exitEntered = Completer<void>();
    final exitRelease = Completer<void>();
    fixture.onExit = (arguments) async {
      expect(arguments['processId'], source.processId);
      fixture.replaceCore(phase: 'RELEASING');
      if (!exitEntered.isCompleted) exitEntered.complete();
      await exitRelease.future;
      fixture.replaceCore(phase: 'EMPTY');
      fixture.emit({
        'processId': source.processId,
        'phase': 'exited',
        'exited': true,
      });
      return {'exited': true};
    };
    fixture.script(ApplicationContract.coreOperationResourceUpdate, (request) {
      expect(request.arguments, {
        'kind': 'geo',
        'name': 'GeoIP',
        'admittedAt': fixture.admittedAt,
        'deadline': fixture.admittedAt + 500,
      });
    });
    final entered = fixture.next(
      ApplicationContract.coreOperationResourceUpdate,
    );
    final pending = FutureProbe(
      fixture.operation.updateResource(source, kind: 'geo', name: 'GeoIP'),
    );
    FutureProbe<Object?>? cleanup;
    try {
      final request = await entered;
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(750));
      expect(pending.settled, isFalse);
      expect(pending.replies, 0);
      expect(request.actualExited, isFalse);
      final occupied = jsonDecode(
        await fixture.runtime.read('updateResource', {
          ...fixture.identity(source),
          'query': {'kind': 'geo', 'name': 'GeoIP'},
        }) as String,
      ) as Map;
      expect(occupied['readPending'], isTrue);
      expect(
        fixture.calls(ApplicationContract.coreOperationResourceUpdate),
        hasLength(1),
      );
      fixture.script(ApplicationContract.coreOperationRuntimeConfig, (read) {
        read.complete('mode: rule\n');
      });
      final diagnostic = await platform.runtimeConfiguration(source);
      expect(diagnostic['configuration'], 'mode: rule\n');
      expect(pending.settled, isFalse);

      cleanup = FutureProbe(fixture.runtime.read('releasePreview', const {}));
      await exitEntered.future;
      expect(fixture.exits, hasLength(1));
      expect(cleanup.settled, isFalse);
      expect(pending.settled, isFalse);
      expect(fixture.core.processId, source.processId);
      expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);

      // The original successful terminal arrives first; do not reply or release the
      // slot before the actual receipt exits.
      request.complete({'status': 'ok'}, terminal: {'exited': false});
      await fixture.flush();
      expect(pending.settled, isFalse);
      expect(request.actualExited, isFalse);
      request.signalExit();
      await pending.done;
      expect(pending.error, isNull);
      expect((pending.value!['update'] as Map)['status'], 'ok');
      expect(pending.value!['stale'], isTrue);
      for (final field in fixture.identity(source).entries) {
        expect(pending.value![field.key], field.value, reason: field.key);
      }
      expect(pending.replies, 1);
      expect(cleanup.settled, isFalse);
      exitRelease.complete();
      await cleanup.done;
      expect(cleanup.error, isNull);
      expect(cleanup.replies, 1);
      expect(fixture.core.phase, 'EMPTY');

      fixture.onExit = null;
      await fixture.writeRecord({
        'id': 'main',
        'body': '',
        'mode': 'rule',
        'inputId': 'replacement-input',
      });
      await fixture.runtime.read('prepareStrategies', {
        'id': 'main',
        'revision': 1,
      });
      expect(fixture.core.phase, 'READY');
      expect(fixture.core.processId, isNot(source.processId));
      expect(fixture.core.inputId, 'replacement-input');
      expect(
        fixture.calls(ApplicationContract.coreOperationResourceUpdate),
        hasLength(1),
      );
      expect(pending.replies, 1);
    } finally {
      if (!exitRelease.isCompleted) exitRelease.complete();
      await fixture.dispose();
      await pending.done;
      if (cleanup != null) await cleanup.done;
      clock.stop();
    }
  });
}
