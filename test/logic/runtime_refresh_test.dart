import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_runtime_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoreRuntimeFixture fixture;
  late Map<String, dynamic> input;
  late Map<String, dynamic> command;

  Future<void> pendingRefresh() async {
    fixture.emit({
      'event': 'networkChanged',
      ...fixture.identity(),
      'nextNetworkRevision': fixture.core.networkRevision + 1,
      'changed': true,
    });
    await fixture.flush();
  }

  setUp(() async {
    fixture = await CoreRuntimeFixture.create();
    final composition = jsonEncode([
      'running',
      3,
      ['part', 7, 'replace'],
    ]);
    fixture.replaceCore(
      configId: 'running',
      revision: 3,
      composition: composition,
      generation: 12,
    );
    fixture.actualMode = 'global';
    input = {
      'inputId': fixture.core.inputId,
      'id': 'running',
      'revision': 3,
      'name': 'Actual main',
      'body': 'mode: rule\nrules: [MATCH,DIRECT]\n',
      'source': null,
      'mode': 'direct',
      'composition': composition,
      'overrides': [
        {
          'id': 'part',
          'revision': 7,
          'name': 'Actual part',
          'role': null,
          'body': 'dns: {enable: false}\n',
          'source': null,
          'mode': 'replace',
        },
      ],
      'choices': {},
      'access': 'except',
      'packages': ['test.controlled.client'],
      'vpnIntent': true,
      'lanIntent': false,
    };
    await fixture.writeRecord(input);
    fixture.beforePlatformCall = (call) {
      if (call.method == 'submit') return const PlatformCallResult(null);
      return null;
    };
    await fixture.startAppRuntime();
    await fixture.runInput.delete();
    for (final name in ['configurations', 'overrides', 'preferences']) {
      await File('${fixture.directory.path}/$name.json')
          .writeAsString('broken');
    }
    command = {
      'action': 'refreshRuntime',
      ...fixture.identity(),
      'sessionGeneration': fixture.snapshot.generation,
    };
    await pendingRefresh();
  });
  tearDown(() => fixture.dispose());

  test('refresh 只使用实际运行记录与 actual mode，不读取损坏的已保存文件', () async {
    final result = await fixture.execute(command);
    expect(result['success'], isTrue);
    expect(fixture.exits, hasLength(1));
    final request = fixture
        .calls(ApplicationContract.coreOperationPrepare)
        .single;
    expect(request.arguments['explicitStart'], isFalse);
    expect(request.arguments['vpnIntent'], isTrue);
    expect(request.arguments['lanIntent'], isFalse);
    final prepared = (await fixture.runtime.inputFor(fixture.core))!;
    for (final field in [
      'id',
      'revision',
      'body',
      'composition',
      'mode',
      'access',
      'packages',
      'overrides',
    ]) {
      expect(prepared[field], input[field], reason: field);
    }
    expect(prepared['routingOverride'], 'global');
    expect(prepared['inputId'], isNot(input['inputId']));
    expect(await fixture.runInput.exists(), isFalse);
    expect(fixture.authorizations, 0);
    for (final name in ['configurations', 'overrides', 'preferences']) {
      expect(
        await File('${fixture.directory.path}/$name.json').readAsString(),
        'broken',
      );
    }
  });

  for (final field in [
    'sessionGeneration',
    'generation',
    'composition',
    'processId',
    'inputId',
    'networkRevision',
  ]) {
    test('refresh 在 Stop 前拒绝缺失或变化的 $field', () async {
      for (final value in [
        null,
        field.contains('Id') || field == 'composition' ? 'other' : 999,
      ]) {
        final result = await fixture.execute({...command, field: value});
        expect(result['success'], isFalse);
        expect(fixture.exits, isEmpty);
        expect(
          fixture.calls(ApplicationContract.coreOperationPrepare),
          isEmpty,
        );
      }
    });
  }

  test('已停止的运行记录不能被迟到 refresh 重新启动', () async {
    fixture.phase = 'STOPPED';
    fixture.vpnIntent = false;
    fixture.replaceCore(phase: 'EMPTY');
    expect((await fixture.execute(command))['success'], isFalse);
    expect(fixture.exits, isEmpty);
    expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
  });

  test('读取实际运行选择期间取消 refresh，等待真实读完且不重启运行记录', () async {
    final entered = fixture.next(ApplicationContract.coreOperationStrategies);
    final gate = Completer<void>();
    fixture.script(ApplicationContract.coreOperationStrategies, (
      request,
    ) async {
      await gate.future;
      request.strategies([fixture.strategyRecord()]);
    });
    final result = FutureProbe(fixture.execute(command));
    await entered;
    await fixture.abandon();
    expect(result.settled, isFalse);
    final concurrent = await fixture.execute({'action': 'stop'});
    expect(concurrent['success'], isFalse);
    expect(fixture.exits, isEmpty);
    gate.complete();
    await result.done;
    expect(result.value!['success'], isFalse);
    expect(result.replies, 1);
    expect(fixture.exits, isEmpty);
    expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
    expect(await fixture.runInput.exists(), isFalse);
  });

  test(
    'captured Stop cancelRefresh 清当前 pending，同 identity 迟到 event 不重新启动',
    () async {
      expect(fixture.runtime.refreshCurrent(command), isTrue);
      fixture.emit({'event': 'cancelRefresh', ...fixture.identity()});
      expect(fixture.runtime.refreshCurrent(command), isFalse);
      await pendingRefresh();
      expect(fixture.runtime.refreshCurrent(command), isFalse);
      expect((await fixture.execute(command))['success'], isTrue);
      expect(fixture.exits, isEmpty);
      expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
    },
  );

  test(
    'stale Stop cancelRefresh 不清当前 pending，普通 restore cancel 不清其他 refresh',
    () async {
      fixture.emit({
        'event': 'cancelRefresh',
        ...fixture.identity(),
        'processId': 'old-process',
      });
      await fixture.invokeRuntime('cancel', 'unrelated-restore-owner');
      expect(fixture.runtime.refreshCurrent(command), isTrue);
      expect((await fixture.execute(command))['success'], isTrue);
      expect(fixture.exits, hasLength(1));
      expect(
        fixture.calls(ApplicationContract.coreOperationPrepare),
        hasLength(1),
      );
    },
  );
}
