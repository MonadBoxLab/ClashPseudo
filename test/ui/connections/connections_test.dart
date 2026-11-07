import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:flutter/services.dart';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/connections/connection_controller.dart';
import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:clash_pseudo/src/ui/connections/connections_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/connection_fakes.dart';

class _TestClock implements Stopwatch {
  @override
  int elapsedMilliseconds = 0;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ConnectionBridgeFake bridge;
  late ConnectionAppFake app;
  late ConnectionController controller;
  late _TestClock clock;
  late AppTaskNavigatorObserver taskRoutes;
  late bool controllerDisposed;
  setUp(() {
    taskRoutes = AppTaskNavigatorObserver();
    setMessageLanguage(AppLanguage.zh);
    bridge = ConnectionBridgeFake();
    app = ConnectionAppFake(bridge);
    clock = _TestClock();
    controller = ConnectionController(app, clock: clock);
    controllerDisposed = false;
  });
  tearDown(() {
    if (!controllerDisposed) controller.dispose();
    app.dispose();
    setMessageLanguage(AppLanguage.system);
  });

  test('connection icon descriptor survives observation and serialization', () {
    final record = ConnectionRecord.fromMap({
      'id': 'fixture',
      'chains': ['DIRECT', 'entry'],
      'strategy': {'type': 'fallback', 'icon': 'http://fixture.test/icon.svg'},
    });
    final historical = record.observed(active: false);
    final restored = ConnectionRecord.fromMap(historical.toMap());
    expect(restored.strategyType, 'fallback');
    expect(restored.strategyIcon, 'http://fixture.test/icon.svg');
    expect(restored.active, isFalse);
    expect(restored.path, 'entry → DIRECT');
    final other = ConnectionRecord.fromMap({
      'id': 'fixture',
      'strategy': {'type': 'select', 'icon': 'https://other.test/icon.png'},
    });
    expect(other.strategyIcon, isNot(restored.strategyIcon));
    expect(restored.strategyType, 'fallback');
  });

  test('snapshot preserves Inner, unknowns, IPv6 and complete path order', () {
    final data = snapshot([
      row('inner', type: 'Inner'),
      row('unknown', type: 'Future'),
      {'id': 'empty'},
    ]);
    expect(data.records.map((record) => record.id), [
      'inner',
      'unknown',
      'empty',
    ]);
    expect(data.records.first.type, 'Inner');
    expect(data.records[1].type, 'Future');
    expect(data.matches(core), isTrue);
    expect(data.records.first.path, '出口 → node');
    expect(connectionEndpoint('::1', '80'), '[::1]:80');
    expect(data.records.last.upload, isNull);
    expect(data.records.last.start, isNull);
    expect(data.records.last.target, '未提供');
    expect(data.records.last.ruleLabel, '未提供');
    expect(() => snapshot([row('one'), row('one')]), throwsFormatException);
    expect(
      () => ConnectionSnapshot.fromMap({
        'generation': 7,
        'configId': 'one',
        'revision': 1,
      }),
      throwsA(anything),
    );
  });

  testWidgets(
    'old detail reply cannot clear a replacement selection with the same id',
    (tester) async {
      try {
        controller.setVisible(true);
        await tester.pump();
        controller.openDetail(controller.data!.records.single);
        final oldOwner = controller.detailLease;
        final pending = Completer<ConnectionSnapshot>();
        bridge.pending = pending;
        await tester.pump(const Duration(seconds: 1));
        expect(bridge.readOwners.last, oldOwner);
        controller.openDetail(controller.detail!);
        final newOwner = controller.detailLease;
        expect(newOwner, isNot(oldOwner));
        expect(bridge.releasedOwners, [oldOwner]);
        bridge.pending = null;
        pending.complete(snapshot([], releasedDetailId: 'one'));
        await tester.pump();
        expect(controller.detail!.id, 'one');
        expect(controller.detailLease, newOwner);
        controller.closeDetail();
        await tester.pump();
        expect(bridge.releasedOwners, [oldOwner, newOwner]);
      } finally {
        controller.setVisible(false);
        controller.dispose();
        controllerDisposed = true;
        await tester.pump();
      }
    },
  );

  testWidgets(
    'detail release failure remains visible without revoking replacement owner',
    (tester) async {
      try {
        controller.setVisible(true);
        await tester.pump();
        controller.openDetail(controller.data!.records.single);
        final oldOwner = controller.detailLease;
        bridge.releaseFailure = PlatformFailure(
          code: 'controlled-release',
          details: {'detail': 'original release cause; suppressed cleanup'},
        );
        controller.openDetail(controller.detail!);
        final newOwner = controller.detailLease;
        await tester.pump();
        expect(controller.detailLease, newOwner);
        expect(newOwner, isNot(oldOwner));
        expect(bridge.releasedOwners, [oldOwner]);
        expect(controller.errorSource, ConnectionErrorSource.releaseDetail);
        expect(
          controller.error,
          contains('original release cause; suppressed cleanup'),
        );
        bridge.releaseFailure = null;
      } finally {
        controller.setVisible(false);
        controller.dispose();
        controllerDisposed = true;
        await tester.pump();
      }
    },
  );

  testWidgets('reads only visible running VPN and stops in background', (
    tester,
  ) async {
    await tester.pump(const Duration(seconds: 10));
    expect(bridge.reads, 0);
    controller.setVisible(true);
    await tester.pump();
    expect(bridge.reads, 1);
    app.changed();
    await tester.pump();
    expect(bridge.reads, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.reads, 2);
    app.setForeground(false);
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.reads, 2);
    app.setForeground(true);
    await tester.pump();
    expect(bridge.reads, 3);
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.reads, 3);
    app.state = const AppSnapshot(
      phase: 'STOPPED',
      core: CoreSnapshot(phase: 'READY', purpose: 'PREVIEW'),
    );
    app.changed();
    controller.setVisible(true);
    await tester.pump();
    expect(bridge.reads, 4);
    expect(controller.data, isNotNull);
    expect(controller.available, isFalse);
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets(
    'inflight read is not duplicated and late result cannot repopulate page',
    (tester) async {
      final pending = Completer<ConnectionSnapshot>();
      bridge.pending = pending;
      controller.setVisible(true);
      controller.setVisible(false);
      controller.setVisible(true);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, 1);
      bridge.pending = null;
      pending.complete(snapshot([row('late')]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.data?.find('late'), isNull);
      expect(controller.data?.find('one'), isNotNull);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'failure is stale not absent; successful missing snapshot retains detail only',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.error, isNotNull);
      expect(controller.data!.records.length, 1);
      bridge.fail = false;
      bridge.data = snapshot([], detail: {...row('one'), 'active': false});
      await tester.pump(const Duration(seconds: 1));
      expect(controller.data!.records, isEmpty);
      expect(controller.detail!.id, 'one');
      expect(controller.detail!.active, isFalse);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'steady reads notify once on completion, not before unchanged data',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      var notifications = 0;
      controller.addListener(() => notifications++);
      bridge.pending = Completer<ConnectionSnapshot>();
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, 0);
      bridge.pending!.complete(snapshot([row('one', download: 30)]));
      await tester.pump();
      expect(notifications, 1);
      expect(controller.data!.records.single.download, 30);
      bridge.pending = null;
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, 2);
      expect(controller.error, isNotNull);
      controller.setVisible(false);
    },
  );

  testWidgets('sample expires during pending query', (tester) async {
    bridge.data = snapshot([row('one')], sampleAgeMs: 3500);
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    expect(controller.canClose, isTrue);
    final beforeRead = controller.data;
    bridge.pending = Completer<ConnectionSnapshot>();
    clock.elapsedMilliseconds = 1000;
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.reads, 2);
    var notifications = 0;
    controller.addListener(() => notifications++);
    clock.elapsedMilliseconds = 1501;
    await tester.pump(const Duration(milliseconds: 501));
    expect(controller.current, isFalse);
    expect(controller.detailActive, isFalse);
    expect(controller.canClose, isFalse);
    expect(controller.current, isFalse);
    expect(controller.error, isNull);
    expect(controller.detail!.active, isTrue);
    expect(controller.data, same(beforeRead));
    expect(notifications, 1);
    controller.setVisible(false);
    bridge.pending!.complete(snapshot([row('late')]));
    await tester.pump();
    expect(controller.data!.find('late'), isNull);
  });

  testWidgets('repeated samples keep their age and include query latency', (
    tester,
  ) async {
    bridge.data = snapshot([row('one')], sampleAgeMs: 3000);
    controller.setVisible(true);
    await tester.pump();
    bridge.pending = Completer<ConnectionSnapshot>();
    clock.elapsedMilliseconds = 1000;
    await tester.pump(const Duration(seconds: 1));
    clock.elapsedMilliseconds = 1500;
    await tester.pump(const Duration(milliseconds: 500));
    bridge.pending!.complete(snapshot([row('one')], sampleAgeMs: 4000));
    await tester.pump();
    expect(controller.current, isTrue);
    bridge.pending = Completer<ConnectionSnapshot>();
    clock.elapsedMilliseconds = 2001;
    await tester.pump(const Duration(milliseconds: 501));
    expect(controller.current, isFalse);
    expect(controller.error, isNull);
    controller.setVisible(false);
  });

  for (final age in <Object?>[null, -1, '0', 5001]) {
    testWidgets('missing, invalid or expired sample age is not fresh ($age)', (
      tester,
    ) async {
      bridge.data = snapshot([row('one')], sampleAgeMs: age);
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      expect(controller.current, isFalse);
      expect(controller.canClose, isFalse);
      expect(controller.error, isNull);
      controller.setVisible(false);
    });
  }

  testWidgets('list and detail follow observations and retain stop state', (
    tester,
  ) async {
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    bridge.data = snapshot([row('one', download: 20)]);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.data!.records.single.download, 20);
    expect(controller.detail!.download, 20);
    expect(controller.data!.records.single.download, 20);
    app.state = const AppSnapshot(phase: 'STOPPED');
    app.changed();
    expect(controller.data, isNotNull);
    expect(controller.canClose, isFalse);
    expect(controller.detail!.download, 20);
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('timeout and replacement cannot confirm old connection data', (
    tester,
  ) async {
    bridge.pending = Completer<ConnectionSnapshot>();
    controller.setVisible(true);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.error, isNotNull);
    expect(app.state.running, isTrue);
    app.state = const AppSnapshot(
      phase: 'RUNNING',
      generation: 1,
      core: CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'RUNNING',
        configId: 'one',
        revision: 1,
      ),
    );
    app.changed();
    final old = bridge.pending!;
    bridge.pending = null;
    old.complete(snapshot([row('old')]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(controller.current, isFalse);
    expect(controller.data, isNull);
    controller.setVisible(false);
  });

  for (final outcome in ['closed', 'absent', 'failed', 'unconfirmed']) {
    testWidgets('single close correlates $outcome during live updates', (
      tester,
    ) async {
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      expect(controller.canClose, isTrue);
      await controller.disconnect();
      await controller.disconnect();
      expect(app.commands.length, 1);
      expect(app.commands.single['connectionId'], 'one');
      expect(app.commands.single['generation'], 7);
      expect(app.commands.single['composition'], core.composition);
      expect(app.commands.single['purpose'], core.purpose);
      expect(controller.closing, isTrue);
      app.state = AppSnapshot(
        phase: 'RUNNING',
        core: core,
        resultId: 'another-operation',
        connectionStatus: outcome,
      );
      app.changed();
      expect(controller.closing, isTrue);
      app.state = AppSnapshot(
        phase: 'RUNNING',
        core: core,
        resultId: 'close-1',
        connectionStatus: outcome,
      );
      app.changed();
      expect(controller.closing, isFalse);
      if (outcome == 'closed') {
        expect(controller.closeResult, 'closed');
        expect(controller.canClose, isFalse);
      } else if (outcome == 'absent') {
        expect(controller.closeResult, 'absent');
        expect(controller.canClose, isFalse);
      } else {
        expect(controller.closeMessage, isNotNull);
        bridge.data = snapshot([], detail: {...row('one'), 'active': false});
        await tester.pump(const Duration(seconds: 1));
        expect(
          controller.closeMessage,
          outcome == 'failed' ? '断开失败' : '断开结果未确认',
        );
      }
      controller.setVisible(false);
      await tester.pump();
    });
  }

  for (final interrupted in ['cancel', 'timeout']) {
    for (final outcome in ['closed', 'absent', 'failed', 'unconfirmed']) {
      testWidgets(
        'queued close $interrupted shows unconfirmed early while retaining owner and actual $outcome receipt replaces the waiting message',
        (tester) async {
          controller.setVisible(true);
          await tester.pump();
          controller.openDetail(controller.data!.records.single);
          await controller.disconnect();
          final operation =
              (interrupted == 'cancel'
                      ? messages.androidErrorOperationInterrupted
                      : messages.androidErrorOperationWaitTimeout)
                  .withDetail({
                    'future': [false, null],
                  });
          AppSnapshot waiting({
            String owner = 'close-1',
            int remaining = 0,
            bool stale = false,
          }) => AppSnapshot(
            phase: 'RUNNING',
            core: core,
            stale: stale,
            writerBusy: true,
            operationId: owner,
            operationAdmittedAt: 100,
            operationDeadline: 120100,
            operationRemainingMs: remaining,
            operation: operation,
          );

          // Remaining budget, an old owner, and a stale snapshot must not produce this
          // early feedback.
          for (final ignored in [
            waiting(remaining: 1),
            waiting(owner: 'old-owner'),
            waiting(stale: true),
          ]) {
            app.state = ignored;
            app.changed();
            expect(controller.closeMessageDescription, isNull);
            expect(controller.closing, isTrue);
          }
          app.state = waiting();
          app.changed();
          expect(
            controller.closeMessageDescription!.id,
            'disconnectUnconfirmedShort',
          );
          expect(
            controller.closeMessageDescription!.detail,
            operation.toMap().toString(),
          );
          expect(controller.closing, isTrue);
          expect(controller.canClose, isFalse);
          expect(controller.detailActive, isTrue);
          expect(app.state.resultId, isNull);
          expect(app.state.operationId, 'close-1');
          expect(app.state.operationAdmittedAt, 100);
          expect(app.state.operationDeadline, 120100);
          await controller.disconnect();
          expect(app.commands, hasLength(1));

          final receipt = messages.disconnectFailedShort.withDetail({
            'code': 'native-failure',
            'cause': {'message': '原始 native cause'},
            'suppressed': [
              {'message': '原始 suppressed'},
            ],
            'future': [false, null],
          });
          app.state = AppSnapshot(
            phase: 'RUNNING',
            core: core,
            operationId: 'close-1',
            operationAdmittedAt: 100,
            operationDeadline: 120100,
            operationRemainingMs: 0,
            operation: operation,
            resultId: 'close-1',
            connectionStatus: outcome,
            resultMessage: receipt,
          );
          app.changed();
          expect(controller.closing, isFalse);
          if (outcome == 'closed' || outcome == 'absent') {
            expect(controller.closeMessageDescription, isNull);
            expect(controller.closeResult, outcome);
            expect(controller.canClose, isFalse);
          } else {
            expect(controller.closeMessageDescription, same(receipt));
            expect(controller.closeMessageDescription!.detail, receipt.detail);
          }
          controller.setVisible(false);
          await tester.pump();
        },
      );
    }
  }

  testWidgets(
    'old close cancellation messages and receipts do not affect the new owner close',
    (tester) async {
      bridge.data = snapshot([row('one'), row('two')]);
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.first);
      await controller.disconnect();
      controller.closeDetail();
      controller.openDetail(controller.data!.records.last);
      await controller.disconnect();
      expect(app.commands, hasLength(2));
      app.state = AppSnapshot(
        phase: 'RUNNING',
        core: core,
        operationId: 'close-1',
        operationRemainingMs: 0,
        operation: messages.androidErrorOperationInterrupted,
        resultId: 'close-1',
        connectionStatus: 'closed',
      );
      app.changed();
      expect(controller.detail!.id, 'two');
      expect(controller.closing, isTrue);
      expect(controller.closeMessageDescription, isNull);
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        core: core,
        resultId: 'close-2',
        connectionStatus: 'absent',
      );
      app.changed();
      expect(controller.closing, isFalse);
      expect(controller.closeResult, 'absent');
      controller.setVisible(false);
      await tester.pump();
    },
  );

  testWidgets(
    'unconfirmed close keeps original cause and suppressed diagnostic for presentation',
    (tester) async {
      try {
        controller.setVisible(true);
        await tester.pump();
        controller.openDetail(controller.data!.records.single);
        await controller.disconnect();
        const message = AppMessage(
          'disconnectUnconfirmedShort',
          detail: 'original close failure\nCaused by: socket cause\nSuppressed: cleanup failure',
        );
        app.state = const AppSnapshot(
          phase: 'RUNNING',
          core: core,
          resultId: 'close-1',
          connectionStatus: 'unconfirmed',
          resultMessage: message,
        );
        app.changed();
        expect(controller.closeMessageDescription, same(message));
        expect(
          controller.closeMessage,
          contains('Suppressed: cleanup failure'),
        );
      } finally {
        controller.setVisible(false);
        controller.dispose();
        controllerDisposed = true;
        await tester.pump();
      }
    },
  );

  testWidgets('late close result cannot attach to another detail', (
    tester,
  ) async {
    bridge.data = snapshot([row('one'), row('two')]);
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.first);
    await controller.disconnect();
    controller.closeDetail();
    controller.openDetail(controller.data!.records.last);
    app.state = const AppSnapshot(
      phase: 'RUNNING',
      core: core,
      resultId: 'close-1',
      connectionStatus: 'closed',
    );
    app.changed();
    expect(controller.detail!.id, 'two');
    expect(controller.detailActive, isTrue);
    expect(controller.closeMessage, isNull);
    controller.setVisible(false);
    await tester.pump();
  });

  testWidgets('missing detail is unknown unless explicitly confirmed absent', (
    tester,
  ) async {
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    bridge.data = snapshot([]);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.detailActive, isFalse);
    expect(controller.canClose, isFalse);
    bridge.data = ConnectionSnapshot.fromMap({
      'generation': 7,
      'configId': 'one',
      'revision': 1,
      'composition': 'one',
      'purpose': 'RUNNING',
      'connections': [],
      'sampleAgeMs': 0,
      'missingDetailId': 'one',
    });
    await tester.pump(const Duration(seconds: 1));
    expect(controller.detail!.active, isFalse);
    controller.setVisible(false);
    await tester.pump();
  });

  testWidgets(
    'window removal releases detail, not an unconfirmed missing sample',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      bridge.data = snapshot([], releasedDetailId: 'another');
      await tester.pump(const Duration(seconds: 1));
      expect(controller.detail!.id, 'one');
      expect(controller.detailActive, isFalse);
      bridge.data = snapshot([], releasedDetailId: 'one');
      await tester.pump(const Duration(seconds: 1));
      expect(controller.detail, isNull);
      expect(controller.ruleSuggestions, isNull);
      controller.setVisible(false);
    },
  );

  testWidgets('clear retires earlier reads and releases only ended detail', (
    tester,
  ) async {
    bridge.data = snapshot([
      row('active'),
      {...row('ended'), 'active': false},
    ]);
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.find('ended')!);
    final pending = Completer<ConnectionSnapshot>();
    bridge.pending = pending;
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.reads, 2);
    await controller.clearInactive();
    expect(bridge.clears, 1);
    expect(bridge.clearedDetail?['id'], 'ended');
    expect(controller.detail, isNull);
    expect(controller.data!.records.single.id, 'active');
    expect(app.commands, isEmpty);
    bridge.pending = null;
    pending.complete(
      snapshot([
        row('late'),
        {...row('ended'), 'active': false},
      ]),
    );
    await tester.pump();
    expect(controller.data!.find('late'), isNull);
    expect(controller.data!.find('ended'), isNull);
    controller.setVisible(false);
  });

  testWidgets('clear failure keeps the window and original failure', (
    tester,
  ) async {
    controller.setVisible(true);
    await tester.pump();
    final before = controller.data;
    final pending = Completer<ConnectionSnapshot>();
    bridge.pending = pending;
    await tester.pump(const Duration(seconds: 1));
    bridge.clearFailure = StateError('clear 原文 ?token=fixture');
    await controller.clearInactive();
    expect(controller.data, same(before));
    expect(controller.error, contains('clear 原文 ?token=fixture'));
    expect(controller.errorSource, ConnectionErrorSource.clearInactive);
    expect(controller.readFailed, isFalse);
    expect(controller.clearing, isFalse);
    controller.setVisible(false);
    pending.complete(snapshot([row('late')]));
    await tester.pump();
  });

  testWidgets('late clear result cannot refill a hidden page', (tester) async {
    controller.setVisible(true);
    await tester.pump();
    final before = controller.data;
    final pending = Completer<ConnectionSnapshot>();
    bridge.clearPending = pending;
    final clearing = controller.clearInactive();
    await tester.pump();
    expect(controller.clearing, isTrue);
    controller.setVisible(false);
    pending.complete(snapshot([row('late')]));
    await clearing;
    expect(controller.data, same(before));
    expect(controller.clearing, isFalse);
  });

  for (final clear in [false, true]) {
    testWidgets(
      'Controller marks ${clear ? 'clearInactive' : 'read'} deadline without treating the end of waiting as recovery',
      (tester) async {
        controller.setVisible(true);
        await tester.pump();
        final revision = controller.readRevision;
        final pending = Completer<ConnectionSnapshot>();
        Future<void>? clearing;
        if (clear) {
          bridge.clearPending = pending;
          clearing = controller.clearInactive();
        } else {
          bridge.pending = pending;
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.pump(const Duration(milliseconds: 4999));
        expect(controller.errorMessage, isNull);
        await tester.pump(const Duration(milliseconds: 1));
        expect(
          controller.errorSource,
          clear
              ? ConnectionErrorSource.clearInactive
              : ConnectionErrorSource.read,
        );
        expect(controller.readRevision, clear ? revision : revision + 1);
        expect(controller.readFailed, !clear);
        final reads = bridge.reads;
        await tester.pump(const Duration(seconds: 10));
        expect(bridge.reads, reads);
        expect(controller.clearing, clear);
        controller.setVisible(false);
        pending.completeError(
          PlatformFailure(
            code: '原始错误',
            details: {
              'cause': '原始 cause',
              'suppressed': ['原始 cleanup'],
              'future': [false, null],
            },
          ),
        );
        if (clearing != null) await clearing;
        await tester.pump();
        expect(controller.errorMessage, isNull);
        expect(controller.readRevision, clear ? revision : revision + 1);
        expect(controller.clearing, isFalse);
      },
    );
  }

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    Locale locale = const Locale('zh'),
    bool taskActivity = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [taskRoutes],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: taskActivity
            ? Builder(
                builder: (context) {
                  final route = ModalRoute.of(context);
                  return AppTaskActivity(
                    active: AppTaskActivity.routeIsActive(route),
                    isActiveNow: () => AppTaskActivity.routeIsActive(route),
                    isActiveWithPopup: (popup) =>
                        AppTaskActivity.routeIsActive(route, ownedPopup: popup),
                    child: ConnectionsPage(app: app),
                  );
                },
              )
            : ConnectionsPage(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openActions(WidgetTester tester, {bool detail = false}) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final button = find.byKey(
      ValueKey(
        detail ? 'connection-detail-actions' : 'connection-list-actions',
      ),
    );
    if (MenuController.maybeOf(tester.element(button))?.isOpen != true) {
      await tester.tap(button);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  Future<void> noticeDetails(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    final action = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byType(TextButton),
    );
    expect(action.hitTestable(), findsOneWidget);
    await tester.tap(action);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  for (final interrupted in ['cancel', 'timeout']) {
    for (final outcome in ['closed', 'absent', 'failed']) {
      testWidgets(
        'details show unconfirmed after $interrupted before actual $outcome updates the UI',
        (tester) async {
          await show(tester);
          await tester.tap(find.text('one.fixture.test'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          await openActions(tester, detail: true);
          await tester.tap(find.byKey(const ValueKey('connection-disconnect')));
          await tester.pump();
          final operation = interrupted == 'cancel'
              ? messages.androidErrorOperationInterrupted
              : messages.androidErrorOperationWaitTimeout;
          app.state = AppSnapshot(
            phase: 'RUNNING',
            core: core,
            writerBusy: true,
            operationId: 'close-1',
            operationAdmittedAt: 100,
            operationDeadline: 120100,
            operationRemainingMs: 0,
            operation: operation,
          );
          app.changed();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(find.text('断开结果未确认'), findsOneWidget);
          await noticeDetails(tester);
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(app.state.resultId, isNull);
          expect(app.state.writerBusy, isTrue);
          expect(app.commands, hasLength(1));
          final menu = find.byKey(const ValueKey('connection-detail-actions'));
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          await tester.tap(find.text('关闭'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(AlertDialog), findsNothing);
          await openActions(tester, detail: true);
          expect(
            tester
                .widget<MenuItemButton>(
                  find.byKey(const ValueKey('connection-disconnect')),
                )
                .onPressed,
            isNull,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(menu.hitTestable(), findsOneWidget);
          expect(app.commands, hasLength(1));

          app.state = AppSnapshot(
            phase: 'RUNNING',
            core: core,
            resultId: 'close-1',
            connectionStatus: outcome,
            resultMessage: outcome == 'failed'
                ? messages.disconnectFailedShort.withDetail('原始 native failure')
                : null,
          );
          app.changed();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('断开结果未确认'), findsNothing);
          if (outcome == 'failed') {
            await tester.pump();
            expect(find.text('断开失败'), findsOneWidget);
            await noticeDetails(tester);
            expect(find.byType(AlertDialog), findsOneWidget);
          } else {
            expect(
              find.text(outcome == 'closed' ? '已断开' : '已不活跃'),
              findsOneWidget,
            );
            expect(find.byType(AlertDialog), findsNothing);
          }
          expect(app.commands, hasLength(1));
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        },
      );
    }
  }

  for (final language in ['zh', 'en']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'healthy connection list reserves no height for hidden error entries $language scale=$scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 900);
          addTearDown(tester.view.reset);
          await show(tester, locale: Locale(language), scale: scale);
          final strings = AppLocalizations.of(
            tester.element(find.byType(ConnectionsPage)),
          );
          final filter = find.ancestor(
            of: find.text(strings.allConnections),
            matching: find.byType(TextButton),
          );
          final list = find.byKey(const ValueKey('connection-reading-list'));
          expect(
            tester.getTopLeft(list).dy - tester.getBottomLeft(filter).dy,
            12,
          );
          expect(
            find.byKey(const ValueKey('connection-list-error')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    for (final withRows in [false, true]) {
      testWidgets(
        'status is separate from filters and preserves copyable original '
        '$language rows=$withRows',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 900);
          addTearDown(tester.view.reset);
          final original =
              'https://fixture.test/?token=原文🙂\n'
                  'Caused by: socket failure\nSuppressed: cleanup failure\n' *
              8;
          bridge.data = ConnectionSnapshot.fromMap({
            'generation': 7,
            'configId': 'one',
            'revision': 1,
            'composition': 'one',
            'purpose': 'RUNNING',
            'sessionGeneration': 0,
            'sampleAgeMs': 0,
            'limited': true,
            'omitted': 3,
            'error': original,
            'connections': [if (withRows) row('one')],
          });
          String? copied;
          var copies = 0;
          final messenger = tester.binding.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(SystemChannels.platform, (
            call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String;
              copies++;
            }
            return null;
          });
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            ),
          );
          await show(
            tester,
            locale: Locale(language),
            scale: 2,
            taskActivity: true,
          );
          final strings = AppLocalizations.of(
            tester.element(find.byType(ConnectionsPage)),
          );
          final notice = find.descendant(
            of: find.byKey(const ValueKey('connection-capacity-notice')),
            matching: find.byType(Text),
          );
          expect(
            tester.widget<Text>(notice).data,
            allOf(
              contains(strings.connectionLimitedNotice),
              contains(strings.connectionOmitted(3)),
              isNot(contains(original)),
            ),
          );
          await Scrollable.ensureVisible(
            tester.element(notice),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          expect(notice.hitTestable(), findsOneWidget);
          await tester.tap(notice);
          await tester.pump();
          expect(find.byType(MenuItemButton), findsNothing);
          expect(find.byType(AlertDialog), findsNothing);
          await tester.tap(find.text(strings.allConnections));
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNWidgets(3));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          expect(
            find.byKey(const ValueKey('connection-list-error-details')),
            findsNothing,
          );
          await tester.pump(const Duration(seconds: 1));
          await tester.pumpAndSettle();
          await noticeDetails(tester);
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(
            find.byKey(const ValueKey('operation-technical-text')),
            findsNothing,
          );
          expect(
            find.textContaining(original, findRichText: true),
            findsNothing,
          );
          final technical = find.byKey(
            const ValueKey('operation-technical-details'),
          );
          await tester.ensureVisible(technical);
          await tester.pumpAndSettle();
          expect(technical.hitTestable(), findsOneWidget);
          await tester.tap(technical);
          await tester.pumpAndSettle();
          final text = find.byKey(const ValueKey('operation-technical-text'));
          expect(tester.widget<SelectableText>(text).data, original);
          final copy = find.byKey(const ValueKey('operation-technical-copy'));
          await tester.ensureVisible(copy);
          await tester.pumpAndSettle();
          expect(copy.hitTestable(), findsOneWidget);
          final cachedCopy = tester.widget<TextButton>(copy).onPressed!;
          await tester.tap(copy);
          await tester.pump();
          expect(copied, original);
          expect(copies, 1);
          Navigator.of(tester.element(text)).pop();
          cachedCopy();
          await tester.pumpAndSettle();
          expect(copies, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final dark in [false, true]) {
    testWidgets(
      'missing fresh samples preserve actual records without status explanations or error entries $dark',
      (tester) async {
        await show(tester, dark: dark);
        await tester.tap(find.text('one.fixture.test'));
        await tester.pumpAndSettle();
        final status = find.byKey(const ValueKey('connection-detail-status'));
        final strings = AppLocalizations.of(tester.element(status));
        final statusRect = tester.getRect(status);
        final routingRect = tester.getRect(find.text(strings.routingResult));
        final details = find.byKey(const ValueKey('connection-detail-error'));
        expect(details, findsNothing);
        bridge.data = snapshot([]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(tester.getRect(status), statusRect);
        expect(tester.getRect(find.text(strings.routingResult)), routingRect);
        expect(details, findsNothing);
        final label = find.descendant(
          of: status,
          matching: find.text(strings.connectionActive),
        );
        expect(label, findsOneWidget);
        expect(
          tester.widget<Text>(label).style!.color,
          ConnectionPalette(dark).active,
        );
        expect(find.byIcon(Icons.pending_outlined), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.descendant(
            of: status,
            matching: find.byIcon(Icons.help_outline_rounded),
          ),
          findsNothing,
        );
        expect(
          find.ancestor(of: status, matching: find.byType(InkWell)),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('connection-detail-status-text')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'read and rule errors retain actual causes in separate SnackBars',
    (tester) async {
      const readError = 'read 原文\nCaused by: transport\nSuppressed: release';
      const ruleError = 'rule 原文\nhttps://fixture.test/?token=fixture🙂';
      bridge.data = ConnectionSnapshot.fromMap({
        'generation': 7,
        'configId': 'one',
        'revision': 1,
        'composition': 'one',
        'purpose': 'RUNNING',
        'sessionGeneration': 0,
        'sampleAgeMs': 0,
        'error': readError,
        'connections': [
          {...row('one'), 'ruleError': ruleError},
        ],
      });
      String? copied;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await show(tester, taskActivity: true);
      await noticeDetails(tester);
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      var text = find.byKey(const ValueKey('operation-technical-text'));
      expect(tester.widget<SelectableText>(text).data, readError);
      Navigator.of(tester.element(text)).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('connection-detail-error')),
        findsNothing,
      );
      expect(find.textContaining(ruleError), findsNothing);
      expect(find.byTooltip(ruleError), findsNothing);
      await noticeDetails(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('operation-technical-text')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      text = find.byKey(const ValueKey('operation-technical-text'));
      expect(tester.widget<SelectableText>(text).data, ruleError);
      final copy = find.byKey(const ValueKey('operation-technical-copy'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, ruleError);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'page clears ended records without disconnecting active trackers',
    (tester) async {
      bridge.data = snapshot([
        row('active'),
        {...row('ended'), 'active': false},
      ]);
      await show(tester);
      expect(find.text('ended.fixture.test'), findsOneWidget);
      await openActions(tester);
      await tester.tap(find.byKey(const ValueKey('connection-clear-inactive')));
      await tester.pumpAndSettle();
      expect(bridge.clears, 1);
      expect(find.text('ended.fixture.test'), findsNothing);
      expect(find.text('active.fixture.test'), findsOneWidget);
      expect(app.commands, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'connection details show business fields and close when the source is released',
    (tester) async {
      final original = {
        ...row('one'),
        'start': '2026-10-16T10:00:00.123456+05:30',
        'chains': List.generate(100, (index) => '原始节点-$index'),
        'futureField': {
          'url': 'https://fixture-user:fixture-password@fixture.test/?token=fixture',
          'nested': ['原文🌐' * 3000, '\u0000'],
        },
        'metadata': {
          ...row('one')['metadata'] as Map,
          'unknown': '完整 metadata',
        },
      };
      bridge.data = snapshot([original]);
      final record = bridge.data.records.single;
      expect(record.chains, hasLength(100));
      expect(record.toMap().containsKey('futureField'), isFalse);
      expect(
        (record.toMap()['metadata'] as Map).containsKey('unknown'),
        isFalse,
      );
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('原始数据'), findsNothing);
      expect(find.byKey(const ValueKey('original-text-copy')), findsNothing);
      bridge.data = snapshot([], releasedDetailId: 'one');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('original-text-copy')), findsNothing);
      expect(
        find.byKey(const ValueKey('connection-detail-scroll')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'read failure preserves record state and content position (dark=$dark)',
      (tester) async {
        bridge.data = snapshot([
          row('one'),
          {...row('inactive'), 'active': false},
        ]);
        await show(tester, dark: dark);
        final target = find.text('one.fixture.test');
        final before = tester.getRect(target);
        final list = find.byKey(const ValueKey('connection-reading-list'));
        final listBefore = tester.getRect(list);
        bridge.fail = true;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.text('待确认'), findsNothing);
        expect(find.text('活跃'), findsOneWidget);
        expect(find.text('已不活跃'), findsOneWidget);
        expect(
          tester.widget<Text>(find.text('活跃')).style!.color,
          ConnectionPalette(dark).active,
        );
        expect(
          find.byKey(const ValueKey('connection-list-error')),
          findsNothing,
        );
        expect(tester.getRect(list), listBefore);
        expect(tester.getRect(target), before);
        bridge.fail = false;
        bridge.data = snapshot([row('new')]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.text('待确认'), findsNothing);
        expect(find.text('new.fixture.test'), findsOneWidget);
        expect(tester.getRect(list), listBefore);
        expect(
          find.byKey(const ValueKey('connection-list-error')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'detail reads continue, disappearing connection stays readable, pop releases polling',
    (tester) async {
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('分流结果'), findsOneWidget);
      final count = bridge.reads;
      bridge.data = snapshot([], detail: {...row('one'), 'active': false});
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, count + 1);
      expect(find.text('已不活跃'), findsOneWidget);
      expect(find.text('one.fixture.test'), findsOneWidget);
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      expect(find.text('暂无连接'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final stopped = bridge.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, stopped);
    },
  );

  for (final (width, scale) in [(390.0, 1.0), (320.0, 2.0)]) {
    testWidgets(
      'live detail field identities survive zh-en-zh and missing values '
      '$width/$scale',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final locale = ValueNotifier(const Locale('zh'));
        addTearDown(locale.dispose);
        final page = ConnectionsPage(app: app);
        await tester.pumpWidget(
          ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (context, value, _) => MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: value,
              theme: AppTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: page,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('one.fixture.test'));
        await tester.pumpAndSettle();
        final scroll = find.byKey(const ValueKey('connection-detail-scroll'));
        final route = ModalRoute.of(tester.element(scroll));
        final fields = find.descendant(
          of: scroll,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KeyedSubtree &&
                widget.key != null &&
                widget.child is Padding,
          ),
        );
        expect(fields, findsNWidgets(3));
        final keys = tester
            .widgetList<KeyedSubtree>(fields)
            .map((widget) => widget.key!)
            .toList();
        final elements = [
          for (final key in keys) tester.element(find.byKey(key)),
        ];
        final values = ['127.0.0.1', '[::1]:1234', 'Tun'];

        void expectFields(Locale value, List<String> expectedValues) {
          final strings = lookupAppLocalizations(value);
          expect(ModalRoute.of(tester.element(scroll)), same(route));
          expect(fields, findsNWidgets(3));
          expect(
            tester.widgetList<KeyedSubtree>(fields).map((widget) => widget.key),
            keys,
          );
          final labels = [
            strings.targetIp,
            strings.sourceAddress,
            strings.inbound,
          ];
          for (var index = 0; index < keys.length; index++) {
            final field = find.byKey(keys[index]);
            expect(tester.element(field), same(elements[index]));
            expect(
              find.descendant(of: field, matching: find.text(labels[index])),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: field,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is SelectableText &&
                      widget.data == expectedValues[index],
                ),
              ),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        }

        expectFields(locale.value, values);
        for (final value in [const Locale('en'), const Locale('zh')]) {
          setMessageLanguage(
            value.languageCode == 'en' ? AppLanguage.en : AppLanguage.zh,
          );
          locale.value = value;
          await tester.pumpAndSettle();
          expectFields(value, values);
        }

        await tester.drag(scroll, const Offset(0, -1500));
        await tester.pumpAndSettle();
        final before = [
          for (final key in keys) tester.getRect(find.byKey(key)),
        ];
        final missing = row('one');
        missing['metadata'] = {
          ...missing['metadata'] as Map<String, dynamic>,
          'destinationIP': '',
          'sourceIP': '',
          'type': '',
        };
        bridge.data = snapshot([missing]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        final strings = lookupAppLocalizations(locale.value);
        expectFields(locale.value, List.filled(3, strings.notProvided));
        expect([
          for (final key in keys) tester.getRect(find.byKey(key)),
        ], before);

        final restored = row('one');
        restored['metadata'] = {
          ...restored['metadata'] as Map<String, dynamic>,
          'destinationIP': '192.0.2.1',
          'sourceIP': '::2',
          'sourcePort': '4321',
          'type': 'HTTP',
        };
        bridge.data = snapshot([restored]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expectFields(locale.value, ['192.0.2.1', '[::2]:4321', 'HTTP']);
        expect([
          for (final key in keys) tester.getRect(find.byKey(key)),
        ], before);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('rule filter survives details and follows new observations', (
    tester,
  ) async {
    bridge.data = snapshot([row('one'), row('two', rule: 'Match')]);
    await show(tester);
    await tester.tap(find.byTooltip('筛选命中规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Domain · fixture.test'));
    await tester.pumpAndSettle();
    expect(find.text('one.fixture.test'), findsOneWidget);
    expect(find.text('two.fixture.test'), findsNothing);
    await tester.tap(find.text('one.fixture.test'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    expect(find.text('two.fixture.test'), findsNothing);
    bridge.data = snapshot([row('new')]);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('one.fixture.test'), findsNothing);
    expect(find.text('new.fixture.test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('insertions and removals preserve a surviving reading anchor', (
    tester,
  ) async {
    bridge.data = snapshot(
      List.generate(30, (i) => row(i.toString().padLeft(2, '0'))),
    );
    await show(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    final anchor = find.text('10.fixture.test');
    final before = tester.getTopLeft(anchor);
    bridge.data = snapshot([
      row('00-new'),
      ...List.generate(
        30,
        (i) => row(i.toString().padLeft(2, '0'), download: 9999),
      ),
    ]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect((tester.getTopLeft(anchor).dy - before.dy).abs(), lessThan(1));
    bridge.data = snapshot(
      List.generate(28, (i) => row((i + 2).toString().padLeft(2, '0'))),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect((tester.getTopLeft(anchor).dy - before.dy).abs(), lessThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unrelated route covering details suspends reads and return resumes',
    (tester) async {
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(find.text('连接详情')));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = bridge.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, before);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(bridge.reads, greaterThan(before));
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      final listReads = bridge.reads;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, listReads + 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'read failure and source replacement preserve disconnect eligibility and error source',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      expect(controller.detailActive, isTrue);
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.error, isNotNull);
      app.setForeground(false);
      expect(controller.current, isFalse);
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 1,
        core: CoreSnapshot(
          generation: 8,
          phase: 'READY',
          purpose: 'RUNNING',
          configId: 'one',
          revision: 1,
        ),
      );
      app.changed();
      expect(controller.canClose, isFalse);
      app.state = const AppSnapshot(phase: 'UNKNOWN');
      app.changed();
      expect(controller.detailActive, isFalse);
      expect(controller.data, isNull);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'empty collection read failure uses SnackBar and error entry without inserting status explanations',
    (tester) async {
      bridge.fail = true;
      await show(tester);
      expect(find.text('刷新失败，正在重试'), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      await openActions(tester);
      expect(
        find.byKey(const ValueKey('connection-list-error-details')),
        findsNothing,
      );
      expect(find.text('数据来源'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'missing fields omit optional rows and do not invent zero traffic',
    (tester) async {
      bridge.data = snapshot([
        {
          'id': 'empty',
          'metadata': {
            'destinationIP': '::1',
            'destinationPort': '853',
            'network': 'tcp',
          },
        },
      ]);
      await show(tester);
      await tester.tap(find.text('[::1]:853'));
      await tester.pumpAndSettle();
      expect(find.text('端口 853'), findsNothing);
      expect(find.text('源地址'), findsNothing);
      expect(find.text('连接信息'), findsNothing);
      expect(find.text('数据来源'), findsNothing);
      expect(find.text('0 B'), findsNothing);
      expect(find.text('—'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'disconnect color follows enabled, pending and closed state $dark',
      (tester) async {
        await show(tester, dark: dark);
        await tester.tap(find.text('one.fixture.test'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        final button = find.byKey(const ValueKey('connection-detail-actions'));
        final before = tester.getRect(button);
        final error = Theme.of(tester.element(button)).colorScheme.error;
        await openActions(tester, detail: true);
        final action = find.byKey(const ValueKey('connection-disconnect'));
        final icon = find.descendant(
          of: action,
          matching: find.byIcon(Icons.link_off_rounded),
        );
        expect(tester.widget<Icon>(icon).color, error);
        await tester.tap(action);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator),
              )
              .color,
          error,
        );
        expect(tester.getRect(button), before);
        await openActions(tester, detail: true);
        expect(tester.widget<MenuItemButton>(action).onPressed, isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        app.state = const AppSnapshot(
          phase: 'RUNNING',
          core: core,
          resultId: 'close-1',
          connectionStatus: 'closed',
        );
        app.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await openActions(tester, detail: true);
        expect(tester.widget<MenuItemButton>(action).onPressed, isNull);
        expect(tester.widget<Icon>(icon).color, isNot(error));
        expect(IconTheme.of(tester.element(icon)).color, isNot(error));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expect(tester.getRect(button), before);
        expect(find.text('已断开'), findsOneWidget);
        expect(app.commands, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('semantic colors distinguish status and traffic, dark=$dark', (
      tester,
    ) async {
      await show(tester, dark: dark);
      final palette = ConnectionPalette(dark);
      expect(
        tester.widget<Text>(find.text('↓ 10 B')).style!.color,
        palette.download,
      );
      expect(
        tester.widget<Text>(find.text('↑ 2 B')).style!.color,
        palette.upload,
      );
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      final detailStatus = find.byKey(
        const ValueKey('connection-detail-status'),
      );
      expect(detailStatus, findsOneWidget);
      final activeStatus = find.descendant(
        of: detailStatus,
        matching: find.text('活跃'),
      );
      expect(activeStatus, findsOneWidget);
      expect(tester.widget<Text>(activeStatus).style!.color, palette.active);
      expect(find.byTooltip('暂停刷新'), findsNothing);
      await openActions(tester, detail: true);
      expect(
        find.byKey(const ValueKey('connection-disconnect')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('暂停刷新'), findsNothing);
      expect(find.byTooltip('继续刷新'), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.text('已暂停刷新'), findsNothing);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停刷新'), findsNothing);
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Text>(activeStatus).style!.color, palette.active);
      expect(find.text('数据来源'), findsNothing);
      final surface =
          (dark ? AppTheme.dark : AppTheme.light).colorScheme.surface;
      for (final color in [
        palette.active,
        palette.warning,
        palette.upload,
        palette.download,
      ]) {
        final a = color.computeLuminance();
        final b = surface.computeLuminance();
        final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'long connection fields remain usable at large text, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = 'very-long-目标🌐-${'segment-' * 12}.fixture.test';
        bridge.data = snapshot([
          {
            ...row('long', host: host),
            'chains': ['very-long-node-${'name-' * 12}', '出口🌐'],
            'rulePayload': 'long-rule-${'segment-' * 12}.fixture.test',
          },
        ]);
        await show(tester, dark: dark, scale: 2);
        expect(tester.takeException(), isNull);
        await tester.tapAt(
          tester.getTopLeft(find.text(host)) + const Offset(12, 12),
        );
        await tester.pumpAndSettle();
        expect(find.text('连接详情'), findsOneWidget);
        await tester.drag(
          find.byKey(const ValueKey('connection-detail-scroll')),
          const Offset(0, -1500),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
