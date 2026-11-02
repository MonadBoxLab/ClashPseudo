import 'package:clash_pseudo/src/logic/strategies/delay_batches.dart';
import 'package:clash_pseudo/src/model/app_platform.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/strategies/delay_test_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/core_diagnostic_fixture.dart';

const _urlTest = ApplicationContract.coreOperationUrlTest;
const _strategies = ApplicationContract.coreOperationStrategies;

Future<Object?> _outcome(Future<void> work) =>
    work.then<Object?>((_) => null, onError: (Object error) => error);

void _finish(
  CoreDiagnosticRequest request,
  int delay, {
  Map<String, Object?> terminal = const {},
}) {
  request.complete({
    'name': request.arguments['name'],
    'identity': request.arguments['identity'],
    'delay': delay,
  }, terminal: terminal);
  request.signalExit();
}

Map<String, dynamic> _observation(Map<String, dynamic> member) =>
    Map<String, dynamic>.from(member['result'] as Map);

void main() {
  diagnosticTest('Delay snapshot 隔离 pending、running 与 settled 结果', (
    tester,
    fixture,
  ) async {
    fixture.setMembers(['a', 'b', 'c', 'd', 'e']);
    final id = diagnosticBatchId(
      await fixture.start(url: 'https://fixture.test/probe'),
    );
    await tester.pump();
    final first = await fixture.batch(id);
    expect(first['target'], isNotEmpty);
    expect(first['state'], 'running');
    expect(diagnosticRows(first).map((row) => row['status']), [
      'running',
      'running',
      'running',
      'running',
      'pending',
    ]);
    expect(fixture.calls(_urlTest).length, 4);
    _finish(fixture.calls(_urlTest).first, 42);
    await tester.pump();
    final updated = await fixture.batch(id);
    expect(diagnosticRows(updated).first['status'], 'success');
    expect(diagnosticRows(updated).first['delay'], 42);
    expect(diagnosticRows(first).first['status'], 'running');
    expect(diagnosticRows(first).last['status'], 'pending');
    (updated['members'] as List).first['status'] = '修改 snapshot';
    ((updated['members'] as List).first['result'] as Map)['delay'] = 999;
    final unchanged = diagnosticRows(await fixture.batch(id)).first;
    expect(unchanged['status'], 'success');
    expect(unchanged['delay'], 42);
    expect(_observation(unchanged)['delay'], 42);
    for (final request in fixture.calls(_urlTest).skip(1)) {
      _finish(request, 7);
    }
    await tester.pump();
    expect((await fixture.batch(id))['state'], 'done');
  });

  diagnosticTest('Delay running 成员接收终态，重复退出不改写 settled 结果', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    expect(diagnosticRows(await fixture.batch(id)).single['status'], 'running');
    final request = fixture.calls(_urlTest).single;
    await tester.pump(const Duration(seconds: 5));
    _finish(
      request,
      0,
      terminal: {
        'error': {'code': 'timedOut', 'message': 'context deadline exceeded'},
      },
    );
    await tester.pump();
    final settled = await fixture.batch(id);
    expect(settled['state'], 'done');
    expect(diagnosticRows(settled).single['status'], 'timeout');
    request.signalExit(
      receipt: {
        'late': {'delay': 7, 'status': 'success'},
      },
    );
    await tester.pump();
    expect(await fixture.batch(id), settled);
  });

  diagnosticTest('Delay 重叠批次在取消 probe 实际退出前仍被拒绝', (tester, fixture) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    await expectLater(fixture.start(), throwsA(anything));
    var cancelled = false;
    final receipt = _outcome(fixture.delays.cancel(id)).then((error) {
      cancelled = true;
      return error;
    });
    await tester.pump();
    expect(cancelled, isFalse);
    expect(fixture.delays.busy, isTrue);
    await expectLater(fixture.start(), throwsA(anything));
    request.measurement(12);
    await tester.pump();
    expect(cancelled, isFalse);
    request.signalExit();
    await tester.pump();
    expect(await receipt, isNull);
    expect(cancelled, isTrue);
    expect(fixture.delays.busy, isFalse);
    expect(fixture.calls(_urlTest).length, 1);
  });

  diagnosticTest('Delay 已完成结果保留 member identity，同名替换只使来源过期', (
    tester,
    fixture,
  ) async {
    fixture.setMembers(['same']);
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    expect(request.arguments['identity'], 'same-one');
    _finish(request, 12);
    await tester.pump();
    final settled = diagnosticRows(await fixture.batch(id)).single;
    expect(settled['status'], 'success');
    fixture.members = [
      {'name': 'same', 'type': 'Direct', 'identity': 'same-replacement'},
    ];
    final expired = await fixture.batch(id);
    expect(expired['state'], 'expired');
    final member = diagnosticRows(expired).single;
    expect(member['identity'], 'same-one');
    expect(member['status'], 'success');
    expect(member['delay'], 12);
    expect(_observation(member), _observation(settled));
  });

  diagnosticTest('Delay 直接成员按名称去重，不递归启动 subgroup', (tester, fixture) async {
    fixture.members = [
      {'name': 'same', 'type': 'Direct', 'identity': 'same-one'},
      {'name': 'same', 'type': 'Direct', 'identity': 'same-one'},
      {'name': 'subgroup', 'type': 'Selector', 'identity': 'subgroup-one'},
    ];
    final id = diagnosticBatchId(await fixture.start(names: ['same', 'same']));
    await tester.pump();
    expect(fixture.calls(_urlTest).length, 1);
    final request = fixture.calls(_urlTest).single;
    expect(request.arguments['name'], 'same');
    _finish(request, 1);
    await tester.pump();
    expect(diagnosticRows(await fixture.batch(id)).length, 1);
    await fixture.delays.cancel(id);
    final next = diagnosticBatchId(await fixture.start());
    await tester.pump();
    expect(
      fixture.calls(_urlTest).skip(1).map((call) => call.arguments['name']),
      ['same', 'subgroup'],
    );
    for (final call in fixture.calls(_urlTest).skip(1)) {
      _finish(call, 1);
    }
    await tester.pump();
    expect(diagnosticRows(await fixture.batch(next)).length, 2);
  });

  diagnosticTest('Delay 120 秒批次期限将未完成成员标为 timeout，并等待真实退出', (
    tester,
    fixture,
  ) async {
    fixture.setMembers(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']);
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    expect(fixture.calls(_urlTest).length, 4);
    await tester.pump(const Duration(seconds: 119));
    expect(
      diagnosticRows(await fixture.batch(id))
          .skip(4)
          .every((row) => row['status'] == 'pending'),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 1));
    final waiting = await fixture.batch(id);
    expect(fixture.delays.busy, isTrue);
    expect(waiting['exited'], isFalse);
    expect(
      diagnosticRows(waiting).every((row) => row['status'] == 'timeout'),
      isTrue,
    );
    expect(fixture.calls(_urlTest).length, 4);
    for (final request in fixture.calls(_urlTest)) {
      _finish(
        request,
        0,
        terminal: {
          'error': {'code': 'timedOut', 'message': 'context deadline exceeded'},
        },
      );
    }
    await tester.pump();
    final done = await fixture.batch(id);
    expect(done['state'], 'done');
    expect(done['exited'], isTrue);
    expect(
      diagnosticRows(done).every((row) => row['status'] == 'timeout'),
      isTrue,
    );
    expect(fixture.delays.busy, isFalse);
  });

  diagnosticTest('Delay 5 秒成员期限后保留公开调用返回的 nil-error 测量', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    expect(request.arguments['timeoutMs'], 5000);
    await tester.pump(const Duration(milliseconds: 4999));
    expect(fixture.cancellations, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.cancellations.single.id, request.id);
    expect(fixture.delays.busy, isTrue);
    _finish(request, 12);
    await tester.pump();
    final batch = await fixture.batch(id);
    expect(batch['state'], 'done');
    final member = diagnosticRows(batch).single;
    expect(member['status'], 'success');
    expect(member['delay'], 12);
    expect(_observation(member)['status'], 'success');
  });

  for (final state in ['running', 'done', 'late']) {
    for (final replacement in ['version', 'identity']) {
      diagnosticTest('Delay subgroup $state 的 provider $replacement 变化保留原观察', (
        tester,
        fixture,
      ) async {
        fixture.members = [
          {'name': 'subgroup', 'type': 'Selector', 'identity': 'subgroup-one'},
        ];
        final id = diagnosticBatchId(await fixture.start());
        await tester.pump();
        final request = fixture.calls(_urlTest).single;
        if (state == 'done') {
          _finish(request, 17);
          await tester.pump();
        }
        fixture.groupIdentity = 'nested-provider-$replacement-replacement';
        fixture.members = [
          {
            'name': 'subgroup',
            'type': 'Selector',
            'identity': 'subgroup-$replacement-two',
          },
        ];
        if (state == 'late') {
          _finish(request, 17);
          await tester.pump();
        }
        final before = await fixture.batch(id);
        expect(before['state'], 'expired');
        final beforeMember = diagnosticRows(before).single;
        expect(beforeMember['identity'], 'subgroup-one');
        expect(
          beforeMember['status'],
          state == 'running' ? 'expired' : 'success',
        );
        expect(beforeMember['delay'], state == 'running' ? 0 : 17);
        if (state == 'running') {
          expect(beforeMember['result'], isNull);
          _finish(request, 17);
          await tester.pump();
        }
        final after = await fixture.batch(id);
        final afterMember = diagnosticRows(after).single;
        expect(after['state'], 'expired');
        final beforeLifecycle = {...beforeMember}
          ..remove('result')
          ..remove('exited');
        final afterLifecycle = {...afterMember}
          ..remove('result')
          ..remove('exited');
        expect(afterLifecycle, beforeLifecycle);
        expect(_observation(afterMember)['status'], 'success');
        expect(_observation(afterMember)['delay'], 17);
        expect(_observation(afterMember)['error'], anyOf(isNull, isEmpty));
        expect(await fixture.batch(id), after);
        expect(fixture.calls(_urlTest).length, 1);
      });
    }
  }

  diagnosticTest('Delay 完成后取消释放批次，但保留已取得的 settled snapshot', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    _finish(fixture.calls(_urlTest).single, 1);
    await tester.pump();
    final settled = await fixture.batch(id);
    final original = jsonEncode(settled);
    await fixture.delays.cancel(id);
    await expectLater(fixture.batch(id), throwsA(anything));
    expect(jsonEncode(settled), original);
    expect(diagnosticRows(settled).single['status'], 'success');
    expect(diagnosticRows(settled).single['delay'], 1);
    expect(fixture.delays.busy, isFalse);
    expect(fixture.cancellations, isEmpty);
  });

  diagnosticTest('Delay 运行中同名替换先使 lifecycle 过期，迟到结果不恢复操作资格', (
    tester,
    fixture,
  ) async {
    fixture.setMembers(['same']);
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    fixture.members = [
      {'name': 'same', 'type': 'Direct', 'identity': 'same-two'},
    ];
    final retired = await fixture.batch(id);
    expect(retired['state'], 'expired');
    expect(diagnosticRows(retired).single['status'], 'expired');
    expect(diagnosticRows(retired).single['result'], isNull);
    _finish(request, 12);
    await tester.pump();
    final late = await fixture.batch(id);
    final member = diagnosticRows(late).single;
    expect(late['state'], 'expired');
    expect(member['status'], 'expired');
    expect(member['identity'], 'same-one');
    expect(member['delay'], 0);
    expect(_observation(member)['status'], 'success');
    expect(_observation(member)['delay'], 12);
    expect(diagnosticRows(retired).single['result'], isNull);
  });

  diagnosticTest('Delay expired 批次取消回执等待原 probe 退出后清理', (
    tester,
    fixture,
  ) async {
    fixture.setMembers(['same']);
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    fixture.members = [
      {'name': 'same', 'type': 'Direct', 'identity': 'same-two'},
    ];
    expect((await fixture.batch(id))['state'], 'expired');
    var released = false;
    final receipt = _outcome(fixture.delays.cancel(id)).then((error) {
      released = true;
      return error;
    });
    await tester.pump();
    expect(released, isFalse);
    expect(fixture.delays.busy, isTrue);
    _finish(request, 12);
    await tester.pump();
    expect(await receipt, isNull);
    expect(released, isTrue);
    expect(fixture.delays.busy, isFalse);
    await expectLater(fixture.batch(id), throwsA(anything));
  });

  diagnosticTest('Delay 四个未退出占位不因取消或成员 deadline 提前释放', (tester, fixture) async {
    fixture.setMembers(
      List.generate(12, (index) => String.fromCharCode(65 + index)),
    );
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    expect(fixture.calls(_urlTest).length, 4);
    expect(
      fixture.calls(_urlTest).where((call) => !call.actualExited).length,
      4,
    );
    await tester.pump(const Duration(seconds: 5));
    expect(fixture.calls(_urlTest).length, 4);
    var released = false;
    final receipt = _outcome(fixture.delays.cancel(id)).then((error) {
      released = true;
      return error;
    });
    await tester.pump();
    expect(released, isFalse);
    expect(fixture.delays.busy, isTrue);
    for (final request in fixture.calls(_urlTest)) {
      request.measurement(0);
    }
    await tester.pump();
    expect(fixture.calls(_urlTest).length, 4);
    expect(released, isFalse);
    for (final request in fixture.calls(_urlTest)) {
      request.signalExit();
    }
    await tester.pump();
    expect(await receipt, isNull);
    expect(fixture.calls(_urlTest).length, 4);
    expect(
      fixture.calls(_urlTest).where((call) => !call.actualExited),
      isEmpty,
    );
    expect(fixture.delays.busy, isFalse);
  });

  diagnosticTest('Delay 真正的 zero delay 同时保留在成员与实际结果 JSON', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    _finish(fixture.calls(_urlTest).single, 0);
    await tester.pump();
    final member = diagnosticRows(await fixture.batch(id)).single;
    expect(member.containsKey('delay'), isTrue);
    expect(member['delay'], 0);
    expect(member['status'], 'success');
    final actual = _observation(member);
    expect(actual.containsKey('delay'), isTrue);
    expect(actual['delay'], 0);
    expect(actual['status'], 'success');
    final wire = jsonDecode(jsonEncode(member)) as Map;
    expect(wire.containsKey('delay'), isTrue);
    expect(wire['delay'], 0);
  });

  diagnosticTest('Delay 取消保留已 settled 成员，未完成成员独立记录迟到结果', (
    tester,
    fixture,
  ) async {
    fixture.setMembers(['a', 'b']);
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final calls = fixture.calls(_urlTest);
    _finish(calls.first, 12);
    await tester.pump();
    final before = await fixture.batch(id);
    final receipt = _outcome(fixture.delays.cancel(id));
    await tester.pump();
    final cancelling = await fixture.batch(id);
    final rows = diagnosticRows(cancelling);
    expect(rows.first['status'], 'success');
    expect(rows.first['delay'], 12);
    expect(rows.last['status'], 'cancelled');
    expect(rows.last['delay'], 0);
    expect(rows.last['result'], isNull);
    _finish(calls.last, 7);
    await tester.pump();
    expect(await receipt, isNull);
    expect(diagnosticRows(before).first['status'], 'success');
    expect(diagnosticRows(before).last['status'], 'running');
    expect(diagnosticRows(cancelling).last['result'], isNull);
    await expectLater(fixture.batch(id), throwsA(anything));
  });

  const original = '延迟测试失败，详细信息：https://fixture.test/?token=fixture';
  for (final expired in [false, true]) {
    for (final failure in ['success', 'failed', 'timeout']) {
      diagnosticTest(
        'Delay ${expired ? 'expired' : 'cancelled'} 来源保留迟到 $failure 原始观察',
        (tester, fixture) async {
          final id = diagnosticBatchId(await fixture.start());
          await tester.pump();
          final request = fixture.calls(_urlTest).single;
          Future<Object?>? receipt;
          final cancellationGate = fixture.gate();
          final lifecycle = expired ? 'expired' : 'cancelled';
          if (expired) {
            fixture.members = [
              {'name': 'member', 'type': 'Direct', 'identity': 'member-two'},
            ];
          } else {
            fixture.onCancel = (_) async {
              await cancellationGate.future;
              return {'cancelRequested': true};
            };
            receipt = _outcome(fixture.delays.cancel(id));
            await tester.pump();
          }
          final retired = await fixture.batch(id);
          expect(retired['state'], lifecycle);
          expect(diagnosticRows(retired).single['status'], lifecycle);
          expect(diagnosticRows(retired).single['result'], isNull);
          final error = failure == 'success'
              ? null
              : {
                  'code': failure == 'timeout' ? 'timedOut' : 'callFailed',
                  'message': failure == 'timeout'
                      ? '$original\ncontext deadline exceeded'
                      : original,
                };
          _finish(request, 0, terminal: {'error': ?error});
          await tester.pump();
          final settled = await fixture.batch(id);
          final member = diagnosticRows(settled).single;
          expect(settled['state'], lifecycle);
          expect(member['status'], lifecycle);
          expect(member['delay'], 0);
          final actual = _observation(member);
          expect(actual['status'], failure);
          expect(actual['delay'], 0);
          if (failure != 'success') {
            expect(actual['error'].toString(), contains(original));
            if (failure == 'timeout') {
              expect(
                actual['error'].toString(),
                contains('context deadline exceeded'),
              );
            }
          }
          ((settled['members'] as List).single['result'] as Map)['status'] =
              '修改 snapshot';
          expect(
            _observation(
              diagnosticRows(await fixture.batch(id)).single,
            )['status'],
            failure,
          );
          if (expired) {
            receipt = _outcome(fixture.delays.cancel(id));
          } else {
            cancellationGate.complete();
            await tester.pump();
          }
          expect(await receipt, isNull);
          await expectLater(fixture.batch(id), throwsA(anything));
        },
      );
    }
  }

  diagnosticTest('Delay cancel 回执只在原 probe 退出后返回并允许新批次', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    var returned = false;
    final receipt = _outcome(fixture.delays.cancel(id)).then((error) {
      returned = true;
      return error;
    });
    await tester.pump();
    expect(fixture.cancellations.single.id, request.id);
    expect(returned, isFalse);
    await expectLater(fixture.start(), throwsA(anything));
    _finish(
      request,
      0,
      terminal: {
        'error': {'code': 'cancelled', 'message': 'context canceled'},
      },
    );
    await tester.pump();
    expect(await receipt, isNull);
    expect(returned, isTrue);
    await expectLater(fixture.batch(id), throwsA(anything));
    final next = diagnosticBatchId(await fixture.start());
    await tester.pump();
    expect(next, isNot(id));
    _finish(fixture.calls(_urlTest).last, 1);
    await tester.pump();
    expect((await fixture.batch(next))['state'], 'done');
  });

  diagnosticTest('Delay sourceExited 只退休对应进程，实际退出后清理不影响替代来源', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    fixture.delays.sourceExited('unrelated-process');
    expect(fixture.cancellations, isEmpty);
    expect((await fixture.batch(id))['state'], 'running');
    fixture.emit({
      'processId': fixture.core.processId,
      'phase': 'disconnected',
      'exited': false,
    });
    await tester.pump();
    expect(fixture.delays.busy, isTrue);
    fixture.delays.sourceExited(fixture.core.processId!);
    await tester.pump();
    expect(fixture.delays.busy, isTrue);
    final receipt = _outcome(fixture.delays.cancel(id));
    _finish(
      request,
      0,
      terminal: {
        'error': {'code': 'cancelled', 'message': 'context canceled'},
      },
    );
    await tester.pump();
    expect(await receipt, isNull);
    expect(fixture.delays.busy, isFalse);
    fixture.replaceCore(
      processId: 'new-process',
      inputId: 'new-input',
      generation: 2,
    );
    final next = diagnosticBatchId(await fixture.start());
    await tester.pump();
    request.signalExit(receipt: {'late': 42});
    fixture.delays.sourceExited('diagnostic-process');
    await tester.pump();
    expect((await fixture.batch(next))['state'], 'running');
    _finish(fixture.calls(_urlTest).last, 1);
    await tester.pump();
    expect((await fixture.batch(next))['state'], 'done');
  });

  diagnosticTest('Delay batch identity 沿当前成员，释放不改变稳定的策略观察', (
    tester,
    fixture,
  ) async {
    fixture.group = 'choice';
    fixture.groupIdentity = 'a' * 64;
    fixture.current = 'REJECT';
    fixture.currentIdentity = 'b' * 64;
    fixture.members = [
      {'name': 'REJECT', 'type': 'Reject', 'identity': 'b' * 64},
      {'name': 'DIRECT', 'type': 'Direct', 'identity': 'c' * 64},
    ];
    final before = (await fixture.runtime.strategies(fixture.core))
        .find('choice')!;
    expect(before.now, 'REJECT');
    expect(before.currentIdentity.length, 64);
    final id = diagnosticBatchId(await fixture.start(names: ['REJECT']));
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    expect(request.arguments['identity'], before.currentIdentity);
    _finish(request, 0);
    await tester.pump();
    final batch = await fixture.batch(id);
    expect(batch['currentIdentity'], before.sourceIdentity);
    expect(diagnosticRows(batch).single['identity'], before.currentIdentity);
    await fixture.delays.cancel(id);
    final after = (await fixture.runtime.strategies(fixture.core))
        .find('choice')!;
    expect(after.currentIdentity, before.currentIdentity);
    fixture.current = 'DIRECT';
    fixture.currentIdentity = 'c' * 64;
    expect(
      (await fixture.runtime.strategies(fixture.core))
          .find('choice')!
          .currentIdentity,
      isNot(before.currentIdentity),
    );
  });

  for (final replacement in [
    'provider-version',
    'provider-object',
    'same-name-member',
  ]) {
    diagnosticTest('Delay 消费 $replacement 的新 opaque identity 并退休旧观察', (
      tester,
      fixture,
    ) async {
      fixture.groupIdentity = 'a' * 64;
      fixture.members = [
        {'name': 'same', 'type': 'Direct', 'identity': 'b' * 64},
      ];
      final id = diagnosticBatchId(await fixture.start());
      await tester.pump();
      final request = fixture.calls(_urlTest).single;
      expect(request.arguments['identity'], 'b' * 64);
      _finish(request, 12);
      await tester.pump();
      final first = await fixture.batch(id);
      expect(
        (await fixture.batch(id))['currentIdentity'],
        first['currentIdentity'],
      );
      if (replacement != 'same-name-member') fixture.groupIdentity = 'c' * 64;
      fixture.members = [
        {'name': 'same', 'type': 'Direct', 'identity': 'd' * 64},
      ];
      final changed = await fixture.batch(id);
      expect(changed['state'], 'expired');
      expect(diagnosticRows(changed).single['identity'], 'b' * 64);
      expect(diagnosticRows(changed).single['delay'], 12);
      await fixture.delays.cancel(id);
      final next = diagnosticBatchId(await fixture.start());
      await tester.pump();
      expect(fixture.calls(_urlTest).last.arguments['identity'], 'd' * 64);
      _finish(fixture.calls(_urlTest).last, 7);
      await tester.pump();
      expect(
        diagnosticRows(await fixture.batch(next)).single['identity'],
        'd' * 64,
      );
    });
  }

  diagnosticTest('Delay start 等待真实来源读取，期限内只保留一个 waiter 与原结果', (
    tester,
    fixture,
  ) async {
    final gate = fixture.gate();
    fixture.script(_strategies, (request) async {
      await gate.future;
      request.frame(ApplicationContract.coreIpcFrameMetadata, {
        'source': 'held-source',
      });
      request.frame(
        ApplicationContract.coreIpcFrameRecord,
        fixture.strategyRecord(),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': 'held-source',
      });
      request.signalExit();
    });
    var replies = 0;
    final pending = fixture.start().then((value) {
      replies++;
      return value;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(replies, 0);
    await expectLater(fixture.start(), throwsA(anything));
    expect(fixture.calls(_strategies).length, 1);
    expect(fixture.calls(_urlTest), isEmpty);
    gate.complete();
    await tester.pump();
    final id = diagnosticBatchId(await pending);
    expect(replies, 1);
    expect(fixture.cancellations, isEmpty);
    _finish(fixture.calls(_urlTest).single, 1);
    await tester.pump();
    expect((await fixture.batch(id))['state'], 'done');
  });

  diagnosticTest('Delay read 只保留一个真实来源读取，迟到完整结果只返回一次', (tester, fixture) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final gate = fixture.gate();
    fixture.script(_strategies, (request) async {
      await gate.future;
      request.frame(
        ApplicationContract.coreIpcFrameRecord,
        fixture.strategyRecord(),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': 'held-read',
      });
      request.signalExit();
    });
    var replies = 0;
    final beforeReads = fixture.calls(_strategies).length;
    final pending = fixture.batch(id).then((value) {
      replies++;
      return value;
    });
    await tester.pump();
    final duplicate = expectLater(fixture.batch(id), throwsA(anything));
    await tester.pump();
    await duplicate;
    await tester.pump(const Duration(milliseconds: 1100));
    expect(replies, 0);
    expect(fixture.calls(_strategies).length, beforeReads + 1);
    gate.complete();
    await tester.pump();
    expect((await pending)['id'], id);
    expect(replies, 1);
    _finish(fixture.calls(_urlTest).single, 1);
    await tester.pump();
  });

  diagnosticTest('Delay 取消合并 waiter、保留原 cause 与 suppressed 并允许重试', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    final gate = fixture.gate();
    const failure = {
      'message': 'actual release 原文',
      'cause': {'message': 'release cause 原文'},
      'suppressed': [
        {'message': 'release suppressed 原文'},
      ],
    };
    fixture.onCancel = (_) async {
      await gate.future;
      return {'cancelError': failure};
    };
    var receipts = 0;
    final first = _outcome(fixture.delays.cancel(id)).then((error) {
      receipts++;
      return error;
    });
    final second = _outcome(fixture.delays.cancel(id)).then((error) {
      receipts++;
      return error;
    });
    await tester.pump();
    expect(fixture.cancellations.length, 1);
    expect(receipts, 0);
    final cancelling = await fixture.batch(id);
    expect(diagnosticRows(cancelling).single['status'], 'cancelled');
    gate.complete();
    await tester.pump();
    expect(receipts, 0);
    _finish(
      request,
      0,
      terminal: {
        'error': {'code': 'cancelled', 'message': 'context canceled'},
      },
    );
    await tester.pump();
    for (final error in [await first, await second]) {
      expect(error, isNotNull);
      expect(error.toString(), contains('actual release 原文'));
      expect(error.toString(), contains('release cause 原文'));
      expect(error.toString(), contains('release suppressed 原文'));
    }
    expect(receipts, 2);
    fixture.onCancel = (_) => {'cancelRequested': true};
    expect(await _outcome(fixture.delays.cancel(id)), isNull);
    expect(fixture.cancellations.map((item) => item.id), [
      request.id,
      request.id,
    ]);
    await expectLater(fixture.batch(id), throwsA(anything));
    expect(fixture.delays.busy, isFalse);
  });

  diagnosticTest('Delay 取消使排队 read 失效，迟到来源结果不能恢复旧批次', (tester, fixture) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final gate = fixture.gate();
    fixture.script(_strategies, (request) async {
      await gate.future;
      request.frame(
        ApplicationContract.coreIpcFrameRecord,
        fixture.strategyRecord(),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': 'late-read',
      });
      request.signalExit();
    });
    final pending = expectLater(fixture.batch(id), throwsA(anything));
    await tester.pump();
    final cancelled = _outcome(fixture.delays.cancel(id));
    await tester.pump();
    gate.complete();
    _finish(fixture.calls(_urlTest).single, 1);
    await tester.pump();
    await pending;
    expect(await cancelled, isNull);
    await expectLater(fixture.batch(id), throwsA(anything));
  });

  diagnosticTest('Delay 同一批次只允许一个排队 read', (tester, fixture) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final gate = fixture.gate();
    fixture.script(_strategies, (request) async {
      await gate.future;
      request.frame(
        ApplicationContract.coreIpcFrameRecord,
        fixture.strategyRecord(),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': 'one-read',
      });
      request.signalExit();
    });
    final before = fixture.calls(_strategies).length;
    final first = fixture.batch(id);
    await tester.pump();
    await expectLater(fixture.batch(id), throwsA(anything));
    expect(fixture.calls(_strategies).length, before + 1);
    gate.complete();
    await tester.pump();
    expect((await first)['id'], id);
    _finish(fixture.calls(_urlTest).single, 1);
    await tester.pump();
  });

  diagnosticTest('Delay 排队 start 的 120 秒原期限届满后不得启动 probe，且只返回一次', (
    tester,
    fixture,
  ) async {
    final gate = fixture.gate();
    fixture.script(_strategies, (request) async {
      await gate.future;
      request.frame(
        ApplicationContract.coreIpcFrameRecord,
        fixture.strategyRecord(),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': 'expired-start',
      });
      request.signalExit();
    });
    var replies = 0;
    final pending = fixture.start().then<Object?>(
      (value) {
        replies++;
        return value;
      },
      onError: (Object error) {
        replies++;
        return error;
      },
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 120));
    expect(fixture.calls(_urlTest), isEmpty);
    expect(replies, 0);
    gate.complete();
    await tester.pump();
    expect(await pending, isA<Exception>());
    expect(fixture.calls(_urlTest), isEmpty);
    expect(replies, 1);
    expect(fixture.delays.busy, isFalse);
  });

  diagnosticTest('Delay 成员受理等待计入原 5 秒期限，迟到 submit 不获得新预算', (
    tester,
    fixture,
  ) async {
    final gate = fixture.gate();
    fixture.script(_urlTest, (_) => gate.future);
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    await tester.pump(const Duration(milliseconds: 4999));
    expect(fixture.cancellations, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.delays.busy, isTrue);
    gate.complete();
    await tester.pump();
    expect(fixture.cancellations.single.id, request.id);
    _finish(request, 12);
    await tester.pump();
    final row = diagnosticRows(await fixture.batch(id)).single;
    expect(row['status'], 'success');
    expect(row['delay'], 12);
  });

  diagnosticTest('Delay UI abandon 使尚未完成来源读取的 start 失效', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final gate = fixture.gate();
    fixture.script(_strategies, (request) async {
      await gate.future;
      request.frame(
        ApplicationContract.coreIpcFrameRecord,
        fixture.strategyRecord(),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': 'abandoned-start',
      });
      request.signalExit();
    });
    final controller = DelayTestController(
      fixture.platform,
      fixture.core,
      fixture.group,
    );
    try {
      final pending = controller.start();
      await tester.pump();
      expect(controller.batch, isNotNull);
      final id = controller.batch!;
      controller.abandon();
      await tester.pump();
      expect(fixture.calls(_urlTest), isEmpty);
      expect(fixture.delays.busy, isTrue);
      gate.complete();
      await tester.pump();
      await pending;
      expect(fixture.calls(_urlTest), isEmpty);
      expect(controller.running, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.cleanupFailure, isNull);
      await expectLater(fixture.batch(id), throwsA(anything));
    } finally {
      controller.dispose();
    }
  });

  diagnosticTest('Delay UI abandon 清理已受理但尚未交付的 start，保留真实结果', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final reply = fixture.gate();
    final platform = AppBridge().withCore(
      _DelayedCore(fixture.runtime, reply.future),
    );
    final controller = DelayTestController(
      platform,
      fixture.core,
      fixture.group,
    );
    try {
      final pending = controller.start();
      await tester.pump();
      expect(fixture.calls(_urlTest).length, 1);
      final request = fixture.calls(_urlTest).single;
      final id = controller.batch!;
      controller.abandon();
      await tester.pump();
      expect(fixture.cancellations.single.id, request.id);
      expect(controller.running, isFalse);
      expect(fixture.delays.busy, isTrue);
      _finish(request, 12);
      await tester.pump();
      reply.complete();
      await tester.pump();
      await pending;
      expect(controller.running, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.cleanupFailure, isNull);
      expect((controller.lastReply!['start'] as Map)['id'], id);
      await expectLater(fixture.batch(id), throwsA(anything));
    } finally {
      controller.dispose();
    }
  });

  diagnosticTest('Delay 已交付批次 abandon 后拒绝旧页面新 start，恢复时建立新 owner', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final previous = DelayTestController(
      fixture.platform,
      fixture.core,
      fixture.group,
    );
    final resumed = DelayTestController(
      fixture.platform,
      fixture.core,
      fixture.group,
    );
    try {
      await previous.start();
      final oldId = previous.batch!;
      final request = fixture.calls(_urlTest).single;
      previous.abandon();
      await tester.pump();
      await previous.start();
      expect(fixture.calls(_urlTest).length, 1);
      expect(previous.running, isFalse);
      expect(fixture.delays.busy, isTrue);
      _finish(
        request,
        0,
        terminal: {
          'error': {'code': 'cancelled', 'message': 'context canceled'},
        },
      );
      await tester.pump();
      await expectLater(fixture.batch(oldId), throwsA(anything));
      await resumed.start();
      final next = fixture.calls(_urlTest).last;
      expect(next.id, isNot(request.id));
      expect(resumed.running, isTrue);
      request.signalExit();
      await tester.pump();
      expect(resumed.running, isTrue);
      _finish(next, 7);
      await tester.pump();
    } finally {
      previous.dispose();
      resumed.dispose();
      await tester.pump();
    }
  });

  diagnosticTest('Delay UI abandon 后迟到 read 不重新发布旧页面结果', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final controller = DelayTestController(
      fixture.platform,
      fixture.core,
      fixture.group,
    );
    try {
      await controller.start();
      final request = fixture.calls(_urlTest).single;
      final gate = fixture.gate();
      fixture.script(_strategies, (read) async {
        await gate.future;
        read.frame(
          ApplicationContract.coreIpcFrameRecord,
          fixture.strategyRecord(),
        );
        read.terminal({
          'complete': true,
          'recordCount': 1,
          'source': 'old-ui-read',
        });
        read.signalExit();
      });
      await tester.pump(DelayTestController.pollInterval);
      controller.abandon();
      await tester.pump();
      _finish(request, 12);
      gate.complete();
      await tester.pump();
      expect(controller.running, isFalse);
      expect(
        controller.results.values.every((row) => row.identity == 'member-one'),
        isTrue,
      );
      final calls = fixture.calls(_urlTest).length;
      await controller.start();
      expect(fixture.calls(_urlTest).length, calls);
      expect(controller.busy, isFalse);
    } finally {
      controller.dispose();
    }
  });

  diagnosticTest('Delay CoreRuntime 的 async read 返回真实 JSON snapshot', (
    tester,
    fixture,
  ) async {
    final started = await fixture.read(
      'delayStart',
      arguments: {
        'query': {'id': 'f' * 32, 'group': fixture.group},
      },
    );
    final id = diagnosticBatchId(started);
    await tester.pump();
    final reply = await fixture.read('delayRead', arguments: {'batch': id});
    expect((reply['batch'] as Map)['id'], id);
    expect((reply['batch'] as Map)['state'], 'running');
    for (final item in fixture.identity().entries) {
      expect(reply[item.key], item.value, reason: item.key);
    }
    _finish(fixture.calls(_urlTest).single, 0);
    await tester.pump();
    expect(
      (await fixture.read('delayRead', arguments: {'batch': id}))['batch'],
      await fixture.batch(id),
    );
  });

  for (final status in [204, 200, 302]) {
    diagnosticTest('Delay 原始公开测量不因 HTTP $status 被应用改判失败', (
      tester,
      fixture,
    ) async {
      final id = diagnosticBatchId(await fixture.start());
      await tester.pump();
      final request = fixture.calls(_urlTest).single;
      request.complete({
        'name': request.arguments['name'],
        'identity': request.arguments['identity'],
        'delay': 17,
        'publicHistory': {'delay': 17, 'status': status},
      });
      request.signalExit();
      await tester.pump();
      final member = diagnosticRows(await fixture.batch(id)).single;
      expect(member['status'], 'success');
      expect(member['delay'], 17);
      expect(_observation(member)['publicHistory'], {
        'delay': 17,
        'status': status,
      });
    });
  }

  diagnosticTest('Delay 自定义 URL 原样传给单次调用并保留在 batch target', (
    tester,
    fixture,
  ) async {
    const target = 'https://fixture.test/probe?token=fixture';
    final id = diagnosticBatchId(await fixture.start(url: target));
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    expect(request.arguments['url'], target);
    expect((await fixture.batch(id))['target'], target);
    _finish(request, 7);
    await tester.pump();
    expect((await fixture.batch(id))['target'], target);
  });

  diagnosticTest('Delay source identity 变化使旧 batch 过期，不把结果交给新输入', (
    tester,
    fixture,
  ) async {
    final source = fixture.core;
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    fixture.replaceCore(
      inputId: 'replacement-input',
      generation: 2,
      composition: 'replacement',
    );
    final retired = await fixture.delays.read(id);
    expect(retired['inputId'], source.inputId);
    expect(retired['generation'], source.generation);
    expect(retired['composition'], source.composition);
    expect(retired['stale'], isTrue);
    expect((retired['batch'] as Map)['state'], 'expired');
    _finish(request, 12);
    await tester.pump();
    final after = await fixture.delays.read(id);
    expect(after['inputId'], source.inputId);
    expect(after['stale'], isTrue);
    final member = diagnosticRows(
      Map<String, dynamic>.from(after['batch'] as Map),
    ).single;
    expect(member['status'], 'expired');
    expect(_observation(member)['delay'], 12);
  });

  diagnosticTest('uiVisibility hidden→resume 使尚未受理的 Delay start 失效，不启动 probe', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final gate = fixture.gate();
    fixture.script(_strategies, (request) async {
      await gate.future;
      request.frame(ApplicationContract.coreIpcFrameMetadata, {
        'source': 'queued-visibility',
      });
      request.frame(
        ApplicationContract.coreIpcFrameRecord,
        fixture.strategyRecord(),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': 'queued-visibility',
      });
      request.signalExit();
    });
    final pending = _outcome(fixture.start());
    await tester.pump();
    fixture.emit({'event': 'uiVisibility', 'visible': false});
    fixture.emit({'event': 'uiVisibility', 'visible': true});
    expect(fixture.delays.busy, isTrue);
    gate.complete();
    await tester.pump();
    expect(await pending, isNotNull);
    expect(fixture.calls(_urlTest), isEmpty);
    expect(fixture.delays.busy, isFalse);
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    _finish(fixture.calls(_urlTest).single, 7);
    await tester.pump();
    expect((await fixture.batch(id))['state'], 'done');
  });

  diagnosticTest('uiVisibility 在 Delay start 交付前退休已受理批次，resume 不复活原请求', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final reply = fixture.gate();
    final platform = AppBridge().withCore(
      _DelayedCore(fixture.runtime, reply.future),
    );
    final pending = platform.startDelayTest(fixture.core, {
      'id': 'a' * 32,
      'group': fixture.group,
    });
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    fixture.emit({'event': 'uiVisibility', 'visible': false});
    fixture.emit({'event': 'uiVisibility', 'visible': true});
    await tester.pump();
    expect(fixture.cancellations.single.id, request.id);
    expect(fixture.delays.busy, isTrue);
    reply.complete();
    await tester.pump();
    final id = diagnosticBatchId(await pending);
    expect((await fixture.batch(id))['state'], 'expired');
    request.measurement(17);
    await tester.pump();
    expect(fixture.delays.busy, isTrue);
    request.signalExit();
    await tester.pump();
    final retired = await fixture.batch(id);
    expect(retired['state'], 'expired');
    expect(_observation(diagnosticRows(retired).single)['delay'], 17);
    expect(fixture.calls(_urlTest), hasLength(1));
    await fixture.delays.cancel(id);
  });

  diagnosticTest(
    'visibility 在原 group=g、batch=batch 已启动但未交付时保留 stale 成功回调并实际取消',
    (tester, fixture) async {
      fixture.group = 'g';
      await fixture.warmUp(tester);
      var starts = 0;
      var replies = 0;
      var hidden = false;
      late final DelayBatches delays;
      delays = DelayBatches(
        (operation, source, arguments) {
          starts++;
          return fixture.client.submit(
            operation,
            fixture.runtime.identity(source),
            arguments: arguments,
          );
        },
        fixture.runtime.strategies,
        changed: () {
          if (starts == 1 && !hidden) {
            // _pump 已启动原 probe，startBatch 尚未生成返回值。
            hidden = true;
            expectSync(replies, 0);
            delays.setVisible(false);
            delays.setVisible(true);
          }
        },
      );
      delays.setVisible(true);
      final pending = delays
          .startBatch(fixture.core, {'group': 'g', 'id': 'batch'})
          .then((value) {
            replies++;
            return value;
          });
      await tester.pump();
      expect(starts, 1);
      expect(hidden, isTrue);
      final value = await pending;
      expect(value['stale'], isTrue);
      expect(diagnosticBatchId(value), 'batch');
      expect(value['generation'], fixture.core.generation);
      expect(value['composition'], fixture.core.composition);
      expect(replies, 1);
      final request = fixture.calls(_urlTest).single;
      expect(request.arguments['group'], 'g');
      expect(fixture.cancellations.single, same(request));
      expect(delays.busy, isTrue);
      expect(request.actualExited, isFalse);
      request.measurement(17);
      await tester.pump();
      expect(delays.busy, isTrue);
      request.signalExit();
      await tester.pump();
      expect(delays.busy, isFalse);
      expect(starts, 1);
      expect(replies, 1);
      final retired = await delays.read('batch');
      expect(retired['stale'], isTrue);
      expect((retired['batch'] as Map)['state'], 'expired');
      await delays.cancel('batch');
      await expectLater(delays.read('batch'), throwsStateError);
    },
  );

  diagnosticTest('uiVisibility hidden 拒绝新 Delay start，已交付批次仅保留迟到实际观察', (
    tester,
    fixture,
  ) async {
    final id = diagnosticBatchId(await fixture.start());
    await tester.pump();
    final request = fixture.calls(_urlTest).single;
    fixture.emit({'event': 'uiVisibility', 'visible': false});
    await tester.pump();
    await expectLater(fixture.start(), throwsA(anything));
    expect((await fixture.batch(id))['state'], 'expired');
    _finish(request, 19);
    await tester.pump();
    final old = await fixture.batch(id);
    expect(old['state'], 'expired');
    expect(_observation(diagnosticRows(old).single)['delay'], 19);
    fixture.emit({'event': 'uiVisibility', 'visible': true});
    expect((await fixture.batch(id))['state'], 'expired');
    final next = diagnosticBatchId(await fixture.start());
    expect(next, isNot(id));
    await tester.pump();
    _finish(fixture.calls(_urlTest).last, 7);
    await tester.pump();
    expect((await fixture.batch(next))['state'], 'done');
    expect((await fixture.batch(id))['state'], 'expired');
    await fixture.delays.cancel(id);
  });

  diagnosticTest('Delay 不接受未知 batch、成员或空来源，也不启动 probe', (
    tester,
    fixture,
  ) async {
    await expectLater(fixture.batch('missing'), throwsA(anything));
    await expectLater(fixture.start(names: ['missing']), throwsA(anything));
    fixture.replaceCore(phase: 'EMPTY');
    await expectLater(fixture.start(), throwsA(anything));
    expect(fixture.calls(_urlTest), isEmpty);
  });
}

class _DelayedCore implements RuntimeCore {
  _DelayedCore(this.inner, this.reply);
  final RuntimeCore inner;
  final Future<void> reply;
  @override
  Future<Map<String, dynamic>?> inputFor(CoreSnapshot source) =>
      inner.inputFor(source);
  @override
  Future<Object?> read(
    String method,
    Map<String, Object?> arguments, {
    AppPlatform? operation,
  }) async {
    final result = await inner.read(method, arguments, operation: operation);
    if (method == 'delayStart') await reply;
    return result;
  }
}
