import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/logic/running_input.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/core_runtime_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CoreRuntimeFixture fixture;

  Future<void> create({
    bool preview = false,
    bool lanOnly = false,
    TunnelMode? fallback,
    String body = '',
  }) async {
    fixture = await CoreRuntimeFixture.create(
      preview: preview,
      lanOnly: lanOnly,
      fallback: fallback,
      body: body,
    );
    addTearDown(fixture.dispose);
  }

  Map<String, dynamic> readyPreparation(CoreTestRequest request) {
    final captured = request.wire['identity'] as Map;
    fixture.core = CoreSnapshot(
      processId: request.processId,
      inputId: request.wire['inputId'] as String,
      generation: captured['generation'] as int,
      networkRevision: captured['networkRevision'] as int,
      phase: 'READY',
      purpose: 'PREVIEW',
      configId: 'one',
      revision: 1,
      composition: captured['composition'] as String,
    );
    return {
      'prepared': true,
      'attached': false,
      'vpnIntent': false,
      'lanIntent': false,
      'vpnSpec': null,
      'listeners': <Object?>[],
      'platform': {
        'vpn': {'running': false, 'applicationAccess': null},
        'lan': {'running': false},
      },
      'processId': request.processId,
      'inputId': request.wire['inputId'],
      'generation': captured['generation'],
      'networkRevision': captured['networkRevision'],
      'future': {'Authorization': modeStrategyOriginal},
      'values': [false, null],
    };
  }

  for (final lanOnly in [false, true]) {
    test('UTF-8 策略选择保存并应用，保留${lanOnly ? 'LAN-only' : 'VPN'}运行状态', () async {
      await create(lanOnly: lanOnly);
      await fixture.warmUp();
      final identity = fixture.core.identity;
      fixture.script(ApplicationContract.coreOperationStrategySelect, (
        request,
      ) async {
        final saved = (await fixture.store.read()).selected!;
        expect(saved.choices['出口🌐']!.member, '节点🌐');
        expect(saved.revision, 1);
        expect(saved.body, '');
        expect(request.arguments['group'], '出口🌐');
        expect(request.arguments['choice'], {
          'type': 'select',
          'member': '节点🌐',
        });
        fixture.nativeStrategyChanges++;
        fixture.actualMember = '节点🌐';
        request.complete(<String, dynamic>{});
      });
      expect(
        await fixture.strategyActions.execute(fixture.strategyCommand()),
        isNull,
      );
      await fixture.flush();
      expect(fixture.nativeStrategyChanges, 1);
      expect(fixture.changes, 1);
      expect(fixture.exits, isEmpty);
      expect(fixture.core.identity, identity);
      expect(fixture.snapshot.forwarding, isTrue);
      expect(fixture.snapshot.running, !lanOnly);
      expect(fixture.snapshot.lanRunning, lanOnly);
      final retained = await fixture.runtime.inputFor(fixture.core);
      expect(retained!['choices'], isEmpty);
      final actual = await RunningInput.read(
        fixture.operation,
        fixture.snapshot,
      );
      expect(actual!.entry.choices['出口🌐']!.member, '节点🌐');
      expect(actual.vpnIntent, !lanOnly);
      expect(actual.lanIntent, lanOnly);
    });
  }

  test('native 拒绝的策略不进入实际运行选择，保存意图仍保留', () async {
    await create();
    await fixture.warmUp();
    fixture.script(ApplicationContract.coreOperationStrategySelect, (request) {
      request.complete(
        null,
        terminal: {'complete': false, 'error': 'not-confirmed'},
      );
    });
    final result = FutureProbe(
      fixture.strategyActions.execute(fixture.strategyCommand()),
    );
    await result.done;
    expect(result.error, isA<ConfigFailure>());
    expect(errorText(result.error), contains('not-confirmed'));
    expect(fixture.actualMember, 'DIRECT');
    expect((await fixture.runtime.inputFor(fixture.core))!['choices'], isEmpty);
    expect(
      (await fixture.store.read()).selected!.choices['出口🌐']!.member,
      '节点🌐',
    );
    final actual = await RunningInput.read(fixture.operation, fixture.snapshot);
    expect(actual!.entry.choices['出口🌐']!.member, 'DIRECT');
    expect(fixture.exits, isEmpty);
    expect(fixture.snapshot.running, isTrue);
  });

  for (final timeout in [true, false]) {
    test('排队中的策略${timeout ? '到期' : '取消'}不应用且不停止 VPN', () async {
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
      final result = FutureProbe(fixture.execute(fixture.strategyCommand()));
      await entered.future;
      if (timeout) {
        fixture.expire();
      } else {
        await fixture.abandon();
      }
      release.complete();
      await result.done;
      await fixture.flush();
      expect(result.replies, 1);
      expect(result.value!['success'], isFalse);
      expect(result.value!['message'], isNotNull);
      expect(fixture.nativeStrategyChanges, 0);
      expect(
        fixture.calls(ApplicationContract.coreOperationStrategySelect),
        isEmpty,
      );
      expect(fixture.snapshot.running, isTrue);
      expect(fixture.core.ready, isTrue);
      expect(fixture.exits, isEmpty);
    });
  }

  test('执行中的策略到期等待实际成功和 actual exited，只通知一次', () async {
    await create();
    await fixture.startAppRuntime();
    fixture.script(ApplicationContract.coreOperationStrategySelect, (request) {
      fixture.nativeStrategyChanges++;
      fixture.actualMember = '节点🌐';
      request.complete(<String, dynamic>{}, terminal: {'exited': false});
    });
    final entered = fixture.next(
      ApplicationContract.coreOperationStrategySelect,
    );
    final result = FutureProbe(fixture.execute(fixture.strategyCommand()));
    final request = await entered;
    fixture.expire();
    await fixture.flush();
    expect(result.settled, isFalse);
    expect(result.replies, 0);
    final blocked = await fixture.execute({
      'action': 'setMode',
      'mode': 'global',
    });
    expect((blocked['message'] as Map)['id'], 'operationInProgress');
    request.signalExit();
    await result.done;
    await fixture.flush();
    expect(result.replies, 1);
    expect(result.error, isNull);
    expect(result.value!['success'], isTrue);
    expect(result.value!['message'], isNull);
    expect(fixture.nativeStrategyChanges, 1);
    expect(fixture.notifications, hasLength(1));
    expect(fixture.exits, isEmpty);
    expect(fixture.snapshot.running, isTrue);
    expect(fixture.core.ready, isTrue);
  });

  test('PREVIEW 仅复用完整 composition 相同的输入', () async {
    await create(preview: true, fallback: TunnelMode.rule);
    await fixture.warmUp();
    final first = fixture.core;
    await fixture.writeRecord({'inputId': 'same-input', 'mode': 'rule'});
    await fixture.runtime.read('prepareStrategies', {
      'owner': 'same',
      'id': 'one',
      'revision': 1,
      'mode': 'rule',
      'admittedAt': fixture.admittedAt,
      'deadline': fixture.deadline,
    });
    expect(fixture.core.identity, first.identity);
    expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
    expect(fixture.exits, isEmpty);
    const composition = '["one",1,["part",2,"replace"]]';
    await fixture.writeRecord({
      'inputId': 'changed-input',
      'mode': 'rule',
      'composition': composition,
      'overrides': [
        {
          'id': 'part',
          'name': 'part',
          'revision': 2,
          'mode': 'replace',
          'body': '{}',
          'role': null,
          'source': null,
        },
      ],
    });
    await fixture.runtime.read('prepareStrategies', {
      'owner': 'next',
      'id': 'one',
      'revision': 1,
      'mode': 'rule',
      'admittedAt': fixture.admittedAt,
      'deadline': fixture.deadline,
    });
    expect(fixture.core.identity, isNot(first.identity));
    expect(fixture.core.processId, isNot(first.processId));
    expect(fixture.core.composition, composition);
    expect(fixture.core.purpose, 'PREVIEW');
    expect(fixture.core.ready, isTrue);
    expect(fixture.exits, hasLength(1));
    expect(fixture.exits.single['processId'], first.processId);
    expect(
      fixture.calls(ApplicationContract.coreOperationPrepare),
      hasLength(1),
    );
    await fixture.runtime.read('releasePreview', {});
    expect(fixture.core.ready, isFalse);
    expect(fixture.exits, hasLength(2));
  });

  test('排队的旧策略读取不能确认 replacement context', () async {
    await create(preview: true);
    await fixture.warmUp();
    final old = fixture.identity();
    fixture.replaceCore(
      processId: 'replacement-process',
      inputId: 'replacement-input',
      generation: 2,
    );
    final replacement = fixture.core.identity;
    final result = FutureProbe(fixture.runtime.read('strategies', old));
    await result.done;
    expect(result.value, isNull);
    expect(result.error, isA<PlatformFailure>());
    expect(fixture.calls(ApplicationContract.coreOperationStrategies), isEmpty);
    expect(fixture.core.identity, replacement);
    expect(fixture.core.ready, isTrue);
    await fixture.runtime.read('releasePreview', {});
    expect(fixture.core.ready, isFalse);
  });

  for (final producer in [false, true]) {
    test(
      'null fallback 进入 PREPARE 并保留${producer ? '真实 typed cause' : '原 JSON 字符串'}',
      () async {
        await create(body: 'tun: {mtu: 0}');
        fixture.core = const CoreSnapshot(phase: 'EMPTY');
        fixture.phase = 'STOPPED';
        fixture.vpnIntent = false;
        final detail = AppMessage.withArgs('nativeConfigurationUnsupported', {
          'field': 'tun.mtu',
          'reason': const AppMessage('nativeReasonInvalidMtu'),
        });
        final original = jsonEncode(detail.toMap());
        const nativeMessage = 'tun.mtu: invalidMtu';
        final nativeError = {
          'code': ApplicationContract.coreErrorCallFailed,
          'message': producer ? nativeMessage : original,
          if (producer) 'cause': detail.withDetail(nativeMessage).toMap(),
        };
        fixture.script(ApplicationContract.coreOperationPrepare, (
          request,
        ) async {
          expect(request.arguments['mode'], isNull);
          expect(request.arguments['purpose'], 'PREVIEW');
          expect(request.arguments['vpnIntent'], isFalse);
          expect(request.arguments['lanIntent'], isFalse);
          final path = fixture.publications.single['path'] as String;
          final record =
              jsonDecode(await fixture.runInput.readAsString()) as Map;
          expect(path, isNotEmpty);
          expect(record['mode'], isNull);
          expect(record['body'], 'tun: {mtu: 0}');
          expect(record['name'], '策略配置🌐');
          request.complete(
            null,
            terminal: {
              'complete': false,
              'error': nativeError,
              'nativeReceipt': {
                'accepted': true,
                'requestId': request.requestId,
                'exited': true,
                'error': nativeError,
              },
            },
          );
        });
        await fixture.startAppRuntime();
        final result = await fixture.execute({
          'action': 'prepareStrategies',
          'id': 'one',
          'revision': 1,
        });
        expect(result['success'], isFalse);
        final actualMessage = result['message'] as Map;
        if (producer) {
          expect(actualMessage['id'], detail.id);
          expect(actualMessage['args'], detail.toMap()['args']);
          expect(actualMessage['detail'], contains(nativeMessage));
          expect(actualMessage['detail'], contains(nativeError.toString()));
        } else {
          expect(actualMessage['id'], isNot(detail.id));
          expect(actualMessage['detail'], contains(original));
          expect(actualMessage['detail'], contains(nativeError.toString()));
        }
        expect(
          fixture.calls(ApplicationContract.coreOperationPrepare),
          hasLength(1),
        );
        expect(fixture.core.phase, 'EMPTY');
        expect(fixture.snapshot.phase, 'STOPPED');
        expect(fixture.authorizations, 0);
        expect(await fixture.runInput.exists(), isFalse);
      },
    );
  }

  test('空模式不是 null fallback，受理前拒绝且不提交 PREPARE', () async {
    await create(preview: true);
    final result = FutureProbe(
      fixture.runtime.read('prepareStrategies', {
        'owner': 'invalid',
        'id': 'one',
        'revision': 1,
        'mode': '',
        'admittedAt': fixture.admittedAt,
        'deadline': fixture.deadline,
      }),
    );
    await result.done;
    expect(result.value, isNull);
    expect(result.error, isNotNull);
    expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
    expect(fixture.publications, isEmpty);
    expect(fixture.exits, isEmpty);
  });

  test('PREPARE 实际成功在到期后保留结果并清理，沿用原 admittedAt 和 deadline', () async {
    await create(fallback: TunnelMode.rule);
    fixture.core = const CoreSnapshot(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    fixture.vpnIntent = false;
    await fixture.startAppRuntime();
    fixture.script(ApplicationContract.coreOperationPrepare, (request) {
      request.complete(<String, dynamic>{}, terminal: {'exited': false});
    });
    final entered = fixture.next(ApplicationContract.coreOperationPrepare);
    final result = FutureProbe(
      fixture.execute({
        'action': 'prepareStrategies',
        'id': 'one',
        'revision': 1,
      }),
    );
    final request = await entered;
    fixture.expire();
    await fixture.flush();
    expect(result.replies, 0);
    expect(fixture.exits, isEmpty);
    final blocked = await fixture.execute({
      'action': 'setMode',
      'mode': 'direct',
    });
    expect((blocked['message'] as Map)['id'], 'operationInProgress');
    request.signalExit();
    await result.done;
    expect(result.replies, 1);
    expect(result.value!['success'], isTrue);
    expect(result.value!.containsKey('failure'), isFalse);
    final actual = result.value!['actual'] as Map;
    expect(actual['value'], isEmpty);
    expect((actual['terminal'] as Map)['exited'], isFalse);
    expect(result.value!['cleanupError'], isNull);
    expect(fixture.exits, hasLength(1));
    expect(fixture.exits.single['processId'], request.processId);
    expect(fixture.exits.single['admittedAt'], fixture.admittedAt);
    expect(fixture.exits.single['deadline'], fixture.deadline);
    expect(fixture.core.phase, 'EMPTY');
    expect(fixture.snapshot.phase, 'STOPPED');
    expect(await fixture.runInput.exists(), isFalse);
  });

  for (final kind in [
    'java.io.IOException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    test('策略读取保留 $kind 的完整原错误', () async {
      await create(preview: true);
      await fixture.warmUp();
      final source = fixture.core.identity;
      final failure = nativeFailure(kind);
      fixture.script(ApplicationContract.coreOperationStrategies, (request) {
        request.strategies([], terminal: {'complete': false, 'error': failure});
      });
      final result = FutureProbe(
        fixture.runtime.read('strategies', fixture.identity()),
      );
      await result.done;
      expect(result.value, isNull);
      expectOriginalError(result.error, failure);
      expect(result.replies, 1);
      expect(fixture.core.identity, source);
      expect(fixture.core.ready, isTrue);
      await fixture.runtime.read('releasePreview', {});
      expect(fixture.core.ready, isFalse);
    });
  }

  test('策略导出保留实际错误，不把 terminal 的其他字段作为错误', () async {
    await create(preview: true);
    await fixture.warmUp();
    final wire = jsonEncode({
      'error': modeStrategyOriginal,
      'future': {'Authorization': modeStrategyOriginal},
      'values': [false, null],
    });
    fixture.script(ApplicationContract.coreOperationStrategies, (request) {
      request.strategies(
        [],
        terminal: {
          'complete': false,
          'error': wire,
          'future': {'Authorization': modeStrategyOriginal},
          'values': [false, null],
        },
      );
    });
    final result = FutureProbe(
      fixture.runtime.read('strategies', fixture.identity()),
    );
    await result.done;
    expect(result.value, isNull);
    final details = (result.error as PlatformFailure).details as Map;
    expect(details['error'], wire);
    expect(details.containsKey('future'), isFalse);
    expect(details.containsKey('values'), isFalse);
    expect(details['complete'], isFalse);
    await fixture.runtime.read('releasePreview', {});
  });

  test('策略变更保留完整 UTF-8 请求和实际 native 拒绝', () async {
    await create(preview: true);
    await fixture.warmUp();
    final failure = nativeFailure('java.lang.IllegalStateException');
    fixture.script(ApplicationContract.coreOperationStrategySelect, (request) {
      expect(request.arguments['group'], modeStrategyOriginal);
      expect(request.arguments['choice'], {
        'type': 'select',
        'member': modeStrategyOriginal,
      });
      request.complete(null, terminal: {'complete': false, 'error': failure});
    });
    final result = FutureProbe<Object?>(
      fixture.operation
          .setStrategy(
            fixture.core,
            modeStrategyOriginal,
            const StrategyChoice(
              type: StrategyType.select,
              member: modeStrategyOriginal,
            ),
          )
          .then<Object?>((_) => null),
    );
    await result.done;
    await fixture.flush();
    expect(result.value, isNull);
    expectOriginalError(result.error, failure);
    expect((result.error as PlatformFailure).details['error'], failure);
    expect(fixture.changes, 1);
    await fixture.runtime.read('releasePreview', {});
  });

  test('显式释放 PREVIEW 保留实际 stop failure 和 FAILED 状态', () async {
    await create(preview: true);
    await fixture.warmUp();
    const failure = AppMessage('coreStopFailed', detail: modeStrategyOriginal);
    fixture.onExit = (arguments) {
      fixture.core = CoreSnapshot(
        processId: fixture.core.processId,
        inputId: fixture.core.inputId,
        generation: fixture.core.generation,
        networkRevision: fixture.core.networkRevision,
        phase: 'FAILED',
        purpose: 'PREVIEW',
        configId: fixture.core.configId,
        revision: fixture.core.revision,
        composition: fixture.core.composition,
        error: failure,
      );
      throw PlatformException(code: 'stop', details: failure.toMap());
    };
    final result = FutureProbe(fixture.runtime.read('releasePreview', {}));
    await result.done;
    expect(result.value, isNull);
    expect(errorText(result.error), contains(modeStrategyOriginal));
    expect(fixture.snapshot.core.errorMessage, failure);
    expect(fixture.snapshot.core.phase, 'FAILED');
    expect(fixture.snapshot.core.blocked, isTrue);
    expect(fixture.exits, hasLength(1));
  });

  test('context 变化不抹去实际读取的策略错误', () async {
    await create(preview: true);
    await fixture.warmUp();
    final captured = fixture.identity();
    final failure = nativeFailure('java.io.IOException');
    fixture.script(ApplicationContract.coreOperationStrategies, (request) {
      fixture.replaceCore(
        processId: 'replacement-process',
        inputId: 'replacement-input',
        generation: 2,
      );
      request.strategies([], terminal: {'complete': false, 'error': failure});
    });
    final result = FutureProbe(fixture.runtime.read('strategies', captured));
    await result.done;
    expect(result.value, isNull);
    expectOriginalError(result.error, failure);
    expect(fixture.core.processId, 'replacement-process');
    expect(fixture.core.generation, 2);
    expect(fixture.exits, isEmpty);
  });

  test('context 变化保留策略业务字段和 captured identity 并标 stale', () async {
    await create(preview: true);
    await fixture.warmUp();
    final captured = fixture.core;
    final rawGroup = fixture.strategyRecord(
      extra: {
        'future': {'Authorization': modeStrategyOriginal},
        'values': [false, null],
      },
    );
    fixture.script(ApplicationContract.coreOperationStrategies, (request) {
      fixture.replaceCore(
        processId: 'replacement-process',
        inputId: 'replacement-input',
        generation: 2,
      );
      request.strategies(
        [rawGroup],
        metadata: {
          'mode': 'rule',
          'future': {'Authorization': modeStrategyOriginal},
          'values': [false, null],
        },
        terminal: {
          'nativeFuture': {'Authorization': modeStrategyOriginal},
          'nativeValues': [false, null],
        },
      );
    });
    final value = jsonDecode(
      await fixture.runtime.read('strategies', fixture.identity(captured))
          as String,
    ) as Map<String, dynamic>;
    for (final entry in fixture.identity(captured).entries) {
      expect(value[entry.key], entry.value, reason: entry.key);
    }
    expect(value['mode'], 'rule');
    expect(value['globalReferenced'], isFalse);
    expect(value.containsKey('terminal'), isFalse);
    final group = (value['groups'] as List).single as Map;
    expect(group['name'], rawGroup['name']);
    expect(group['type'], rawGroup['type']);
    expect(group['now'], rawGroup['now']);
    expect(group['fixed'], rawGroup['fixed']);
    expect(group['members'], rawGroup['members']);
    expect(group['sourceIdentity'], rawGroup['sourceIdentity']);
    expect(group['currentIdentity'], rawGroup['currentIdentity']);
    expect(jsonEncode(value), isNot(contains(modeStrategyOriginal)));
    expect(value['stale'], isTrue);
    expect(StrategySnapshot.fromMap(value).matches(fixture.core), isFalse);
    expect(fixture.core.processId, 'replacement-process');
    expect(fixture.exits, isEmpty);
  });

  for (final timeout in [false, true]) {
    for (final failing in [false, true]) {
      test(
        '执行中的策略读取${timeout ? '到期' : '取消'}等待实际${failing ? '失败' : '成功'}',
        () async {
          await create(preview: true);
          await fixture.warmUp();
          final captured = fixture.core.identity;
          final failure = nativeFailure('java.io.IOException');
          fixture.script(ApplicationContract.coreOperationStrategies, (
            request,
          ) {
            request.strategies(
              [fixture.strategyRecord()],
              metadata: {'future': modeStrategyOriginal},
              terminal: {
                'complete': !failing,
                'exited': false,
                if (failing) 'error': failure,
              },
            );
          });
          final entered = fixture.next(
            ApplicationContract.coreOperationStrategies,
          );
          final result = FutureProbe(
            fixture.operation.strategies(fixture.core),
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
          request.signalExit();
          await result.done;
          expect(result.replies, 1);
          if (failing) {
            expect(result.value, isNull);
            expectOriginalError(result.error, failure);
          } else {
            expect(result.error, isNull);
            expect(
              result.value!.find(fixture.groupName)!.now,
              fixture.actualMember,
            );
            expect(result.value!.stale, isFalse);
          }
          expect(fixture.core.identity, captured);
          expect(fixture.core.ready, isTrue);
          await fixture.runtime.read('releasePreview', {});
        },
      );
    }
  }

  test('非法策略 JSON 保留 parser 错误且不包含原值，仍等实际退出', () async {
    await create(preview: true);
    await fixture.warmUp();
    fixture.script(ApplicationContract.coreOperationStrategies, (request) {
      request.metadata({'source': request.source, 'globalReferenced': false});
      request.bytes(
        ApplicationContract.coreIpcFrameRecord,
        Uint8List.fromList(utf8.encode(modeStrategyOriginal)),
      );
      request.terminal({
        'complete': true,
        'recordCount': 1,
        'source': request.source,
        'stale': false,
        'exited': false,
      });
    });
    final entered = fixture.next(ApplicationContract.coreOperationStrategies);
    final result = FutureProbe(
      fixture.runtime.read('strategies', fixture.identity()),
    );
    final request = await entered;
    await fixture.flush();
    expect(result.settled, isFalse);
    expect(request.cancellations, 1);
    request.signalExit();
    await result.done;
    expect(result.value, isNull);
    expect(result.error, isA<FormatException>());
    final parseError = result.error as FormatException;
    expect(parseError.source, isNull);
    expect(parseError.message, isNotEmpty);
    expect(errorText(parseError), isNot(contains(modeStrategyOriginal)));
    expect(fixture.core.ready, isTrue);
    await fixture.runtime.read('releasePreview', {});
  });

  for (final failing in [false, true]) {
    test('context 变化不替换实际策略变更${failing ? '失败' : '成功'}结果', () async {
      await create(preview: true);
      await fixture.warmUp();
      final captured = fixture.identity();
      final failure = nativeFailure('java.lang.IllegalStateException');
      fixture.script(ApplicationContract.coreOperationStrategySelect, (
        request,
      ) {
        fixture.replaceCore(
          processId: 'replacement-process',
          inputId: 'replacement-input',
          generation: 2,
        );
        request.complete(
          <String, dynamic>{},
          terminal: {'complete': !failing, if (failing) 'error': failure},
        );
      });
      final result = FutureProbe(
        fixture.runtime.read('setStrategy', {
          ...captured,
          'name': modeStrategyOriginal,
          'choice': {'type': 'select', 'member': modeStrategyOriginal},
        }),
      );
      await result.done;
      expect(result.replies, 1);
      if (failing) {
        expect(result.value, isNull);
        expectOriginalError(result.error, failure);
      } else {
        expect(result.value, isNull);
        expect(result.error, isNull);
      }
      expect(fixture.core.processId, 'replacement-process');
      expect(fixture.core.inputId, 'replacement-input');
      expect(fixture.core.generation, 2);
      expect(fixture.exits, isEmpty);
    });
  }

  for (final timeout in [false, true]) {
    for (final failing in [false, true]) {
      test(
        '执行中的策略变更${timeout ? '到期' : '取消'}等待实际${failing ? '拒绝' : '成功'}',
        () async {
          await create();
          fixture.groupName = modeStrategyOriginal;
          fixture.memberName = modeStrategyOriginal;
          await fixture.startAppRuntime();
          final failure = nativeFailure('java.lang.IllegalStateException');
          fixture.script(ApplicationContract.coreOperationStrategySelect, (
            request,
          ) {
            expect(request.arguments['group'], modeStrategyOriginal);
            expect(
              (request.arguments['choice'] as Map)['member'],
              modeStrategyOriginal,
            );
            fixture.nativeStrategyChanges++;
            if (!failing) fixture.actualMember = modeStrategyOriginal;
            request.complete(
              <String, dynamic>{},
              terminal: {
                'complete': !failing,
                'exited': false,
                if (failing) 'error': failure,
              },
            );
          });
          final entered = fixture.next(
            ApplicationContract.coreOperationStrategySelect,
          );
          final result = FutureProbe(
            fixture.execute(fixture.strategyCommand()),
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
          expect((blocked['message'] as Map)['id'], 'operationInProgress');
          expect(
            (await fixture.store.read())
                .selected!
                .choices[modeStrategyOriginal]!
                .member,
            modeStrategyOriginal,
          );
          request.signalExit();
          await result.done;
          await fixture.flush();
          expect(result.replies, 1);
          expect(fixture.nativeStrategyChanges, 1);
          if (failing) {
            expect(result.value!['success'], isFalse);
            expect(
              (result.value!['message'] as Map)['detail'],
              contains(failure.toString()),
            );
            expect(
              (result.value!['message'] as Map)['detail'],
              contains(failure['stack'] as String),
            );
            expect(fixture.actualMember, 'DIRECT');
          } else {
            expect(result.value!['success'], isTrue);
            expect(result.value!['message'], isNull);
            expect(fixture.actualMember, modeStrategyOriginal);
          }
          expect(fixture.notifications, hasLength(1));
          expect(fixture.snapshot.running, isTrue);
          expect(fixture.exits, isEmpty);
        },
      );
    }
  }

  test('PREPARE 未取消时同一成功结果形成 READY，且不请求 cleanup', () async {
    await create();
    fixture.core = const CoreSnapshot(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    fixture.vpnIntent = false;
    await fixture.startAppRuntime();
    late Map<String, dynamic> value;
    fixture.script(ApplicationContract.coreOperationPrepare, (request) {
      value = readyPreparation(request);
      request.data(value);
    });
    final entered = fixture.next(ApplicationContract.coreOperationPrepare);
    final result = FutureProbe(
      fixture.execute({
        'action': 'prepareStrategies',
        'id': 'one',
        'revision': 1,
      }),
    );
    final request = await entered;
    await fixture.flush();
    expect(fixture.core.ready, isTrue);
    expect(result.settled, isFalse);
    expect(fixture.exits, isEmpty);
    final prepared = fixture.core;
    request.signalExit();
    request.terminal({'complete': true, 'exited': true});
    await result.done;
    expect(result.error, isNull);
    expect(result.value!['success'], isTrue);
    expect(result.value!['failure'], isNull);
    expect(result.replies, 1);
    expect(fixture.core.identity, prepared.identity);
    expect(fixture.core.ready, isTrue);
    expect(request.cancellations, 0);
    expect(fixture.exits, isEmpty);
    expect(request.arguments['admittedAt'], fixture.admittedAt);
    expect(request.arguments['deadline'], fixture.deadline);
  });

  for (final kind in [
    'java.util.concurrent.RejectedExecutionException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    for (final timeout in [false, true]) {
      for (final workFails in [false, true]) {
        test(
          'PREPARE ${timeout ? '到期' : '取消'}清理的 $kind 保留实际工作${workFails ? '失败' : '成功'}',
          () async {
            await create();
            if (timeout) fixture.deadline = fixture.now + 100;
            fixture.core = const CoreSnapshot(phase: 'EMPTY');
            fixture.phase = 'STOPPED';
            fixture.vpnIntent = false;
            await fixture.startAppRuntime();
            final work = nativeFailure(
              'java.io.IOException',
              stack:
                  'java.io.IOException: actual preparation: $modeStrategyOriginal\n',
            );
            late Map<String, dynamic> workValue;
            final cleanup = {
              ...nativeFailure(kind),
              'cause': nativeFailure('java.io.IOException'),
              'suppressed': [nativeFailure('java.lang.IllegalStateException')],
            };
            fixture.onExit = (_) => throw PlatformException(
              code: 'cleanup-rejected',
              details: cleanup,
            );
            final terminal = {
              'complete': !workFails,
              if (workFails) 'error': work,
              'nativeFuture': {'Authorization': modeStrategyOriginal},
              'nativeValues': [false, null],
              'exited': true,
            };
            late void Function() completeWork;
            fixture.script(ApplicationContract.coreOperationPrepare, (request) {
              completeWork = () {
                if (!workFails) workValue = readyPreparation(request);
                request.data(workFails ? null : workValue);
              };
            });
            fixture.onCancel = (request) => {
              'cancelled': true,
              'targetRequestId': request.requestId,
              'started': true,
            };
            final entered = fixture.next(
              ApplicationContract.coreOperationPrepare,
            );
            final result = FutureProbe(
              fixture.execute({
                'action': 'prepareStrategies',
                'id': 'one',
                'revision': 1,
              }),
            );
            final request = await entered;
            await fixture.flush();
            expect(request.arguments['admittedAt'], fixture.admittedAt);
            expect(request.arguments['deadline'], fixture.deadline);
            if (timeout) {
              fixture.expire();
              await Future<void>.delayed(const Duration(milliseconds: 150));
            } else {
              await fixture.abandon();
            }
            await fixture.flush();
            expect(result.replies, 0);
            expect(fixture.exits, hasLength(1));
            completeWork();
            await fixture.flush();
            expect(result.replies, 0);
            expect(fixture.exits, hasLength(1));
            if (!workFails) {
              expect(fixture.core.ready, isTrue);
              expect(fixture.core.processId, request.processId);
              expect(fixture.core.inputId, request.wire['inputId']);
            }
            final receipt = workFails ? {'error': work} : <String, dynamic>{};
            request.signalExit(receipt: receipt);
            request.terminal(terminal);
            await result.done;
            expect(result.replies, 1);
            expect(result.value!['success'], !workFails);
            final details = workFails
                ? (result.value!['failure'] as Map)['details'] as Map
                : result.value!;
            final actualTerminal = {
              'complete': !workFails,
              if (workFails) 'error': work,
              'exited': true,
              'nativeReceipt': receipt,
              'cancellation': {
                'cancelled': true,
                'targetRequestId': request.requestId,
                'started': true,
              },
            };
            if (workFails) {
              expect(
                details.keys,
                unorderedEquals(['error', 'actual', 'cleanupError']),
              );
            } else {
              expect(result.value!['failure'], isNull);
            }
            final actual = details['actual'] as Map;
            expect(
              actual['value'],
              workFails
                  ? null
                  : {
                      for (final key in [
                        'prepared',
                        'attached',
                        'vpnIntent',
                        'lanIntent',
                        'processId',
                        'inputId',
                        'generation',
                        'networkRevision',
                      ])
                        key: workValue[key],
                      'platform': {
                        'vpn': {'running': false},
                        'lan': {'running': false},
                      },
                    },
            );
            expect(actual['terminal'], actualTerminal);
            expect(
              jsonEncode(actual['value']),
              isNot(contains(modeStrategyOriginal)),
            );
            expect(
              (actual['terminal'] as Map).containsKey('nativeFuture'),
              isFalse,
            );
            expect(
              (actual['terminal'] as Map).containsKey('nativeValues'),
              isFalse,
            );
            if (workFails) {
              final actualFailure = details['error'] as Map;
              expect(actualFailure['dartStack'], isA<String>());
              expect(
                actualFailure['code'],
                ApplicationContract.coreErrorCallFailed,
              );
              expect(actualFailure['details'], {
                'complete': false,
                'exited': true,
                'error': work,
                'nativeReceipt': receipt,
              });
            }
            final cleanupFailure = Map<String, dynamic>.from(
              details['cleanupError'] as Map,
            );
            expect(cleanupFailure.remove('dartStack'), isA<String>());
            expect(cleanupFailure, {
              'code': 'cleanup-rejected',
              'details': cleanup,
            });
            expect(fixture.exits, hasLength(1));
            expect(fixture.exits.single['processId'], request.processId);
            expect(fixture.exits.single['admittedAt'], fixture.admittedAt);
            expect(fixture.exits.single['deadline'], fixture.deadline);
          },
        );
      }
    }
  }

  for (final kind in [
    'java.util.concurrent.RejectedExecutionException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    for (final timeout in [false, true]) {
      for (final workFails in [false, true]) {
        test(
          '已受理排队的 PREPARE ${timeout ? '到期' : '取消'}保留 $kind，业务应答先于 drain 且原工作${workFails ? '失败' : '成功'}分支不执行',
          () async {
            await create();
            if (timeout) fixture.deadline = fixture.now + 100;
            fixture.core = const CoreSnapshot(phase: 'EMPTY');
            fixture.phase = 'STOPPED';
            fixture.vpnIntent = false;
            await fixture.startAppRuntime();
            final failure = {
              ...nativeFailure(kind),
              'cause': nativeFailure('java.io.IOException'),
              'suppressed': [nativeFailure('java.lang.IllegalStateException')],
            };
            final cancelledFailure = {
              'code': ApplicationContract.coreErrorCancelled,
              'message': '请求在进入内核前已取消',
            };
            final accepted = Completer<void>();
            var cancelled = false;
            var workCalls = 0;
            late void Function() drain;
            fixture.script(ApplicationContract.coreOperationPrepare, (request) {
              // submit 立即返回 accepted；work 只由下面的 drain 放行。
              drain = () {
                if (cancelled) {
                  request.terminal({
                    'complete': false,
                    'error': cancelledFailure,
                    'exited': false,
                  });
                  request.signalExit(receipt: {'error': cancelledFailure});
                  return;
                }
                workCalls++;
                request.complete(
                  workFails ? null : readyPreparation(request),
                  terminal: {
                    'complete': !workFails,
                    if (workFails)
                      'error': nativeFailure('java.io.IOException'),
                  },
                );
              };
            });
            fixture.beforePlatformCall = (call) {
              if (call.method == ApplicationContract.coreChannelRead &&
                  (call.arguments as Map)['requestId'] ==
                      fixture
                          .calls(ApplicationContract.coreOperationPrepare)
                          .single
                          .requestId &&
                  !accepted.isCompleted) {
                accepted.complete();
              }
              return null;
            };
            fixture.onCancel = (request) {
              expect(
                request.operation,
                ApplicationContract.coreOperationPrepare,
              );
              cancelled = true;
              return {'accepted': true, 'exited': false, 'started': false};
            };
            fixture.onExit = (_) => throw PlatformException(
              code: 'cleanup-rejected',
              details: failure,
            );
            final result = FutureProbe(
              fixture.execute({
                'action': 'prepareStrategies',
                'id': 'one',
                'revision': 1,
              }),
            );
            await accepted.future;
            final request = fixture
                .calls(ApplicationContract.coreOperationPrepare)
                .single;
            expect(request.arguments['admittedAt'], fixture.admittedAt);
            expect(request.arguments['deadline'], fixture.deadline);
            expect(workCalls, 0);
            expect(request.actualExited, isFalse);
            await fixture.invokeRuntime('cancel', 'other');
            expect(request.cancellations, 0);
            if (timeout) {
              fixture.expire();
              await Future<void>.delayed(const Duration(milliseconds: 150));
            } else {
              await fixture.abandon();
            }
            await fixture.flush();
            expect(cancelled, isTrue);
            expect(request.cancellations, 1);
            expect(request.actualExited, isFalse);
            expect(workCalls, 0);
            final repliesBeforeDrain = result.replies;
            expect(repliesBeforeDrain, 1);
            final busy = await fixture.execute({
              'action': 'prepareStrategies',
              'id': 'one',
              'revision': 1,
            });
            expect((busy['message'] as Map)['id'], 'operationInProgress');
            expect(
              fixture.calls(ApplicationContract.coreOperationPrepare),
              hasLength(1),
            );
            final early = result.value;
            final earlyFailure = Map<String, dynamic>.from(
              result.value!['failure'] as Map,
            );
            expect(earlyFailure.remove('dartStack'), isA<String>());
            expect(earlyFailure, {
              'code': 'cleanup-rejected',
              'details': failure,
            });
            expect(fixture.exits, hasLength(1));
            drain();
            await fixture.flush();
            expect(result.replies, 1);
            expect(result.value, same(early));
            expect(result.value!['success'], isFalse);
            expect(workCalls, 0);
            expect(request.actualExited, isTrue);
            expect(fixture.exits, hasLength(1));
            expect(fixture.exits.single['processId'], request.processId);
            expect(fixture.exits.single['admittedAt'], fixture.admittedAt);
            expect(fixture.exits.single['deadline'], fixture.deadline);
            expect(await fixture.runInput.exists(), isFalse);
            expect(repliesBeforeDrain, 1);
            fixture.onExit = null;
            fixture.beforePlatformCall = null;
            fixture.operationExpired = false;
            fixture.admittedAt = fixture.now;
            fixture.deadline = fixture.now + 60000;
            final retry = await fixture.execute({
              'owner': 'retry',
              'action': 'prepareStrategies',
              'id': 'one',
              'revision': 1,
            });
            expect(retry['success'], isTrue);
          },
        );
      }
    }
  }

  for (final kind in [
    'java.util.concurrent.RejectedExecutionException',
    'java.lang.UnsatisfiedLinkError',
  ]) {
    for (final started in <bool?>[null, false, true]) {
      for (final workFails in started == false ? [false] : [false, true]) {
        test(
          'PREPARE 的 CANCEL 原错误保留 $kind，started=$started，工作失败=$workFails',
          () async {
            await create();
            fixture.core = const CoreSnapshot(phase: 'EMPTY');
            fixture.phase = 'STOPPED';
            fixture.vpnIntent = false;
            await fixture.startAppRuntime();
            final original = {
              ...nativeFailure(kind),
              'started': ?started,
              'cause': nativeFailure('java.io.IOException'),
              'suppressed': [nativeFailure('java.lang.IllegalStateException')],
            };
            fixture.onCancel = (_) => throw PlatformException(
              code: 'cancel-failed',
              details: original,
            );
            fixture.onExit = (_) => throw PlatformException(
              code: 'cleanup-rejected',
              details: original,
            );
            late void Function() drain;
            var workCalls = 0;
            fixture.script(ApplicationContract.coreOperationPrepare, (request) {
              drain = () {
                if (started == false) {
                  request.complete(
                    null,
                    terminal: {
                      'complete': false,
                      'error': {'code': ApplicationContract.coreErrorCancelled},
                    },
                  );
                  return;
                }
                workCalls++;
                request.complete(
                  workFails ? null : readyPreparation(request),
                  terminal: {
                    'complete': !workFails,
                    if (workFails)
                      'error': nativeFailure('java.io.IOException'),
                  },
                );
              };
            });
            final entered = fixture.next(
              ApplicationContract.coreOperationPrepare,
            );
            final result = FutureProbe(
              fixture.execute({
                'action': 'prepareStrategies',
                'id': 'one',
                'revision': 1,
              }),
            );
            final request = await entered;
            await fixture.flush();
            await fixture.abandon();
            await fixture.flush();
            expect(result.replies, started == false ? 1 : 0);
            expect(request.actualExited, isFalse);
            expect(workCalls, 0);
            if (started == false) {
              final failure = Map<String, dynamic>.from(
                result.value!['failure'] as Map,
              );
              expect(failure.remove('dartStack'), isA<String>());
              expect(failure, {'code': 'cancel-failed', 'details': original});
            }
            drain();
            await result.done;
            await fixture.flush();
            expect(result.replies, 1);
            expect(request.actualExited, isTrue);
            expect(workCalls, started == false ? 0 : 1);
            expect(fixture.exits, hasLength(1));
            if (started != false) {
              expect(result.value!['success'], !workFails);
              final details = workFails
                  ? (result.value!['failure'] as Map)['details'] as Map
                  : result.value!;
              final actual = details['actual'] as Map;
              final terminal = actual['terminal'] as Map;
              expect(terminal['cancelError'], {
                'code': 'cancel-failed',
                'details': original,
              });
              final cleanup = details['cleanupError'] as Map;
              expect(cleanup['code'], 'cleanup-rejected');
              expect(cleanup['details'], original);
              if (workFails) {
                final error = details['error'] as Map;
                expect(error['code'], ApplicationContract.coreErrorCallFailed);
                expect(
                  (error['details'] as Map)['error'],
                  nativeFailure('java.io.IOException'),
                );
              }
            }
          },
        );
      }
    }
  }

  test('其他 owner 的取消不影响已受理 PREPARE', () async {
    await create();
    fixture.core = const CoreSnapshot(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    fixture.vpnIntent = false;
    await fixture.startAppRuntime();
    fixture.script(ApplicationContract.coreOperationPrepare, (request) {
      request.complete(<String, dynamic>{}, terminal: {'exited': false});
    });
    final entered = fixture.next(ApplicationContract.coreOperationPrepare);
    final result = FutureProbe(
      fixture.execute({
        'action': 'prepareStrategies',
        'id': 'one',
        'revision': 1,
      }),
    );
    final request = await entered;
    await fixture.invokeRuntime('cancel', 'other');
    await fixture.flush();
    expect(request.cancellations, 0);
    expect(result.settled, isFalse);
    expect(fixture.exits, isEmpty);
    final captured = request.wire['identity'] as Map;
    fixture.core = CoreSnapshot(
      processId: request.processId,
      inputId: request.wire['inputId'] as String,
      generation: captured['generation'] as int,
      networkRevision: captured['networkRevision'] as int,
      phase: 'READY',
      purpose: 'PREVIEW',
      configId: 'one',
      revision: 1,
      composition: '["one",1]',
    );
    request.signalExit();
    await result.done;
    expect(result.replies, 1);
    expect(result.value!['success'], isTrue);
    expect(fixture.core.ready, isTrue);
    expect(fixture.core.purpose, 'PREVIEW');
    expect(fixture.exits, isEmpty);
  });

  test('PREPARE owner 取消后拒绝旧 context，延迟 cleanup 不影响 replacement', () async {
    await create();
    fixture.core = const CoreSnapshot(phase: 'EMPTY');
    fixture.phase = 'STOPPED';
    fixture.vpnIntent = false;
    await fixture.startAppRuntime();
    fixture.script(ApplicationContract.coreOperationPrepare, (request) {
      request.data(readyPreparation(request));
    });
    fixture.onCancel = (request) {
      expect(request.wire['owner'], 'one');
      fixture.replaceCore(phase: 'RELEASING');
      return {'cancelled': true, 'targetRequestId': request.requestId};
    };
    final cleanupEntered = Completer<void>();
    final cleanup = Completer<Map<String, dynamic>>();
    fixture.onExit = (_) {
      fixture.replaceCore(phase: 'RELEASING');
      cleanupEntered.complete();
      return cleanup.future;
    };
    final entered = fixture.next(ApplicationContract.coreOperationPrepare);
    final result = FutureProbe(
      fixture.execute({
        'action': 'prepareStrategies',
        'id': 'one',
        'revision': 1,
      }),
    );
    final request = await entered;
    await fixture.flush();
    final old = fixture.core;
    expect(old.ready, isTrue);
    await fixture.invokeRuntime('cancel', 'other');
    expect(request.cancellations, 0);
    expect(fixture.exits, isEmpty);
    await fixture.abandon();
    expect(request.cancellations, 1);
    expect(request.actualExited, isFalse);
    expect(result.replies, 0);
    expect(fixture.exits, isEmpty);
    final afterCancellation = FutureProbe(
      fixture.runtime.read('strategies', fixture.identity(old)),
    );
    await afterCancellation.done;
    request.signalExit();
    request.terminal({'complete': true, 'exited': true});
    await cleanupEntered.future;
    expect(fixture.core.phase, 'RELEASING');
    expect(fixture.core.identity, old.identity);
    expect(result.replies, 0);
    expect(fixture.exits, hasLength(1));
    expect(fixture.exits.single['processId'], old.processId);
    expect(fixture.exits.single['admittedAt'], fixture.admittedAt);
    expect(fixture.exits.single['deadline'], fixture.deadline);

    fixture.emit({
      'processId': old.processId,
      'phase': 'exited',
      'exited': true,
    });
    fixture.replaceCore(
      processId: 'replacement-process',
      inputId: 'replacement-input',
      generation: 1,
      configId: 'replacement',
      revision: 2,
      composition: '["replacement",2]',
    );
    final replacement = fixture.core;
    expect(replacement.generation, old.generation);
    expect(replacement.matchesIdentity(old), isFalse);
    await fixture.writeRecord({});
    await fixture.runtime.restoreExisting();
    final replacementMode = fixture.modeProjection;
    final replacementCalls = fixture.requests
        .where((call) => call.processId == replacement.processId)
        .length;
    cleanup.complete({'exited': true});
    await result.done;
    expect(result.replies, 1);
    expect(result.value!['success'], isTrue);
    expect(result.value!.containsKey('failure'), isFalse);
    expect(result.value!['cleanupError'], isNull);
    final actual = result.value!['actual'] as Map;
    expect((actual['terminal'] as Map)['complete'], isTrue);
    expect(fixture.core.identity, replacement.identity);
    expect(fixture.core.ready, isTrue);
    expect(fixture.modeProjection, replacementMode);
    expect(fixture.exits, hasLength(1));
    expect(
      fixture.requests.where((call) => call.processId == replacement.processId),
      hasLength(replacementCalls),
    );
    final current = jsonDecode(
      await fixture.runtime.read('strategies', fixture.identity(replacement))
          as String,
    ) as Map;
    expect(current['processId'], replacement.processId);
    expect(current['inputId'], replacement.inputId);
    expect(current['generation'], replacement.generation);
    expect(current['composition'], replacement.composition);
    expect(
      afterCancellation.error,
      isA<PlatformFailure>(),
      reason: 'owner 取消已生效、cleanup 尚未执行时，旧 context 必须不可继续使用',
    );
    expect(
      (afterCancellation.error as PlatformFailure).code,
      ApplicationContract.coreErrorIdentityMismatch,
    );
  });

  test('旧 PREVIEW 退出结果晚到不能释放 replacement process', () async {
    await create(preview: true);
    await fixture.warmUp();
    final old = fixture.core;
    final entered = Completer<void>();
    final release = Completer<Map<String, dynamic>>();
    fixture.onExit = (arguments) {
      expect(arguments['processId'], old.processId);
      entered.complete();
      return release.future;
    };
    final result = FutureProbe(
      fixture.runtime.read('releasePreview', {
        'owner': 'fixture',
        'admittedAt': fixture.admittedAt,
        'deadline': fixture.deadline,
      }),
    );
    await entered.future;
    fixture.replaceCore(
      processId: 'replacement-process',
      inputId: 'replacement-input',
      generation: 2,
      configId: 'replacement',
      revision: 2,
      composition: '["replacement",2]',
    );
    final replacement = fixture.core.identity;
    expect(result.settled, isFalse);
    release.complete({'exited': true});
    await result.done;
    fixture.emit({
      'processId': old.processId,
      'phase': 'exited',
      'exited': true,
    });
    expect(result.error, isNull);
    expect(result.replies, 1);
    expect(fixture.core.identity, replacement);
    expect(fixture.core.ready, isTrue);
    expect(fixture.exits, hasLength(1));
    expect(fixture.exits.single['processId'], old.processId);
  });

  test('策略 worker 拒绝立即回复一次，不等 timeout 且不泄漏请求', () async {
    await create(preview: true);
    await fixture.warmUp();
    final failure = nativeFailure(
      'java.util.concurrent.RejectedExecutionException',
    );
    var rejected = false;
    fixture.beforePlatformCall = (call) {
      if (call.method == ApplicationContract.coreChannelSubmit && !rejected) {
        rejected = true;
        throw PlatformException(code: 'worker-rejected', details: failure);
      }
      return null;
    };
    final result = FutureProbe(
      fixture.runtime.read('strategies', fixture.identity()),
    );
    await result.done;
    expect(result.value, isNull);
    expect(result.replies, 1);
    expect((result.error as PlatformFailure).details, failure);
    expectOriginalError(result.error, failure);
    expect(fixture.calls(ApplicationContract.coreOperationStrategies), isEmpty);
    expect(fixture.core.ready, isTrue);
    final value = await fixture.operation.strategies(fixture.core);
    expect(value.matches(fixture.core), isTrue);
    expect(
      fixture.calls(ApplicationContract.coreOperationStrategies),
      hasLength(1),
    );
    await fixture.runtime.read('releasePreview', {});
  });

  test('策略 RECORD 分别遵守 8 MiB，集合总量可以超过 8 MiB', () async {
    await create(preview: true);
    await fixture.warmUp();
    final padding = 'x' * (ApplicationContract.coreIpcFrameBytes ~/ 2);
    final groups = [
      fixture.strategyRecord(extra: {'padding': padding}),
      fixture.strategyRecord(extra: {'name': '第二个组🌐', 'padding': padding}),
    ];
    final sizes = [
      for (final group in groups) utf8.encode(jsonEncode(group)).length,
    ];
    expect(
      sizes.every((size) => size <= ApplicationContract.coreIpcFrameBytes),
      isTrue,
    );
    expect(
      sizes.reduce((left, right) => left + right),
      greaterThan(ApplicationContract.coreIpcFrameBytes),
    );
    fixture.script(ApplicationContract.coreOperationStrategies, (request) {
      request.strategies(groups);
    });
    final value = await fixture.operation.strategies(fixture.core);
    expect(value.groups, hasLength(2));
    expect(value.groups.map((group) => group.name), [
      fixture.groupName,
      '第二个组🌐',
    ]);
  });

  for (final field in [
    'processId',
    'inputId',
    'generation',
    'networkRevision',
    'configId',
    'revision',
    'composition',
    'purpose',
  ]) {
    test('策略读取拒绝不匹配的 $field，尚未受理就不提交 FD 请求', () async {
      await create(preview: true);
      await fixture.warmUp();
      final arguments = fixture.identity();
      arguments[field] = switch (field) {
        'generation' => fixture.core.generation + 1,
        'networkRevision' => fixture.core.networkRevision + 1,
        'revision' => fixture.core.revision! + 1,
        'purpose' => 'RUNNING',
        _ => 'other-$field',
      };
      await expectLater(
        fixture.runtime.read('strategies', arguments),
        throwsA(
          isA<PlatformFailure>().having(
            (error) => error.code,
            'code',
            ApplicationContract.coreErrorIdentityMismatch,
          ),
        ),
      );
      expect(
        fixture.calls(ApplicationContract.coreOperationStrategies),
        isEmpty,
      );
      expect(fixture.core.ready, isTrue);
      expect(fixture.exits, isEmpty);
    });
  }

  for (final terminal in [
    {'recordCount': 2},
    {'source': 'other-source'},
    {'complete': false},
  ]) {
    test('策略流终态 $terminal 不发布完整结果', () async {
      await create(preview: true);
      await fixture.warmUp();
      fixture.script(ApplicationContract.coreOperationStrategies, (request) {
        request.strategies([fixture.strategyRecord()], terminal: terminal);
      });
      final result = FutureProbe(fixture.operation.strategies(fixture.core));
      await result.done;
      expect(result.value, isNull);
      expect(result.error, isNotNull);
      expect(fixture.core.ready, isTrue);
      expect(fixture.exits, isEmpty);
    });
  }

  for (final lanOnly in [false, true]) {
    for (final modeChange in [false, true]) {
      test(
        '${lanOnly ? 'LAN-only' : 'VPN'} ${modeChange ? '模式' : '策略'}完整重连保留原 VPN/LAN 意图',
        () async {
          await create(lanOnly: lanOnly);
          await fixture.warmUp();
          final first = fixture.core.identity;
          await PreferencesStore(fixture.directory)
              .save(const AppPreferences(reconnectOnRoutingChange: true));
          if (modeChange) {
            await fixture.configActions.execute({
              'action': 'setMode',
              'mode': 'global',
            });
            expect(fixture.actualMode, 'global');
          } else {
            expect(
              await fixture.strategyActions.execute(fixture.strategyCommand()),
              isNull,
            );
            expect(fixture.actualMember, '节点🌐');
          }
          final prepared = fixture
              .calls(ApplicationContract.coreOperationPrepare)
              .single;
          expect(prepared.arguments['purpose'], 'RUNNING');
          expect(prepared.arguments['vpnIntent'], !lanOnly);
          expect(prepared.arguments['lanIntent'], lanOnly);
          expect(prepared.arguments['explicitStart'], isFalse);
          expect(fixture.core.identity, isNot(first));
          expect(fixture.snapshot.forwarding, isTrue);
          expect(fixture.snapshot.running, !lanOnly);
          expect(fixture.snapshot.lanRunning, lanOnly);
          expect(fixture.authorizations, 0);
          expect(fixture.exits, hasLength(1));
          expect(fixture.exits.single['admittedAt'], fixture.admittedAt);
          expect(fixture.exits.single['deadline'], fixture.deadline);
          final record = await fixture.runtime.inputFor(fixture.core);
          expect(record!['vpnIntent'], !lanOnly);
          expect(record['lanIntent'], lanOnly);
          expect(record['mode'], modeChange ? 'global' : null);
          expect(record['routingOverride'], modeChange ? 'global' : 'rule');
          expect(await fixture.runInput.exists(), isFalse);
        },
      );
    }
  }
  test('profile 装载后恢复应用 choices，保留 missing group/type/member 三项并清理显式 GLOBAL warning', () async {
    await create();
    Map<String, dynamic> group(
      String name,
      String type,
      String now,
      String fixed,
      List<String> members,
    ) => {
      'name': name,
      'sourceIdentity': '$name-source',
      'currentIdentity': '$name-current',
      'type': type,
      'now': now,
      'fixed': fixed,
      'hidden': false,
      'icon': '',
      'members': [
        for (final member in members)
          {'name': member, 'type': 'Direct', 'identity': '$name/$member'},
      ],
    };
    fixture.strategyGroups = [
      group('manual', 'select', 'DIRECT', '', ['DIRECT', 'provider-node']),
      group('automatic', 'url-test', 'DIRECT', '', ['DIRECT', 'COMPATIBLE']),
      group('fallback', 'fallback', 'DIRECT', 'DIRECT', ['DIRECT']),
      group('wrong-type', 'select', 'DIRECT', '', ['DIRECT']),
      group('missing-member', 'select', 'DIRECT', '', ['DIRECT']),
    ];
    final choices = {
      'manual': {'type': 'select', 'member': 'provider-node'},
      'automatic': {'type': 'url-test', 'member': 'COMPATIBLE'},
      'fallback': {'type': 'fallback', 'member': null},
      'GLOBAL': {'type': 'select', 'member': 'DIRECT'},
      'wrong-type': {'type': 'url-test', 'member': 'DIRECT'},
      'missing-member': {'type': 'select', 'member': 'not-present'},
    };
    await fixture.writeRecord({
      'inputId': 'restored-input',
      'choices': choices,
    });
    await fixture.runtime.read('start', {
      'owner': 'one',
      'id': 'one',
      'revision': 1,
      'admittedAt': fixture.admittedAt,
      'deadline': fixture.deadline,
    });
    final restored = fixture.calls(
      ApplicationContract.coreOperationStrategySelect,
    );
    expect(restored.map((call) => call.arguments['group']), [
      'manual',
      'automatic',
      'fallback',
    ]);
    for (final call in restored) {
      expect(call.arguments['restore'], isTrue);
      expect(call.wire['owner'], 'one');
      expect(call.arguments['admittedAt'], fixture.admittedAt);
      expect(call.arguments['deadline'], fixture.deadline);
    }
    final snapshot = await fixture.runtime.strategies(fixture.core);
    expect(snapshot.find('manual')!.now, 'provider-node');
    expect(snapshot.find('automatic')!.fixed, 'COMPATIBLE');
    expect(snapshot.find('fallback')!.fixed, '');
    expect(snapshot.unrestored.keys.toSet(), {
      'GLOBAL',
      'wrong-type',
      'missing-member',
    });
    fixture.strategyGroups!.add(
      group('GLOBAL', 'select', 'provider-node', '', [
        'DIRECT',
        'provider-node',
      ]),
    );
    await fixture.operation.setStrategy(
      fixture.core,
      'GLOBAL',
      const StrategyChoice(type: StrategyType.select, member: 'DIRECT'),
    );
    final updated = await fixture.runtime.strategies(fixture.core);
    expect(
      updated.unrestored.keys,
      unorderedEquals(['wrong-type', 'missing-member']),
    );
    expect(fixture.nativeCacheWrites, 1);
    final before = restored.length + 1;
    await fixture.writeRecord({
      'inputId': 'next-input',
      'choices': <String, dynamic>{},
    });
    await fixture.runtime.read('start', {
      'owner': 'one',
      'id': 'one',
      'revision': 1,
      'admittedAt': fixture.admittedAt,
      'deadline': fixture.deadline,
    });
    expect(
      fixture.calls(ApplicationContract.coreOperationStrategySelect),
      hasLength(before),
    );
    expect(
      (await fixture.runtime.strategies(fixture.core)).unrestored,
      isEmpty,
    );
  });

  for (final invalid in [
    {
      '': {'type': 'select', 'member': 'DIRECT'},
    },
    {
      'manual': {'type': 'select', 'member': null},
    },
    {
      'manual': {'type': 'load-balance', 'member': 'DIRECT'},
    },
    {
      'manual': {'type': 'invalid', 'member': 'DIRECT'},
    },
    {
      'manual': {'type': 'select', 'member': ''},
    },
  ]) {
    test('无效 saved choices $invalid 不发布输入、不认领新 context', () async {
      await create();
      final original = fixture.core.identity;
      await fixture.writeRecord({
        'inputId': 'invalid-choice-input',
        'choices': invalid,
      });
      await expectLater(
        fixture.runtime.read('start', {
          'owner': 'one',
          'id': 'one',
          'revision': 1,
          'admittedAt': fixture.admittedAt,
          'deadline': fixture.deadline,
        }),
        throwsFormatException,
      );
      expect(fixture.core.identity, original);
      expect(fixture.publications, isEmpty);
      expect(fixture.exits, isEmpty);
      expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
    });
  }

  test('应用 choice 覆盖 profile selected cache，恢复不写 cache，显式选择才写', () async {
    await create();
    fixture.actualMember = 'DIRECT';
    await fixture.writeRecord({
      'inputId': 'application-choice-input',
      'choices': {
        '出口🌐': {'type': 'select', 'member': '节点🌐'},
      },
    });
    await fixture.runtime.read('start', {
      'owner': 'one',
      'id': 'one',
      'revision': 1,
      'admittedAt': fixture.admittedAt,
      'deadline': fixture.deadline,
    });
    expect(fixture.actualMember, '节点🌐');
    expect(fixture.nativeCacheWrites, 0);
    final restore = fixture
        .calls(ApplicationContract.coreOperationStrategySelect)
        .single;
    expect(restore.arguments['restore'], isTrue);
    await fixture.operation.setStrategy(
      fixture.core,
      '出口🌐',
      const StrategyChoice(type: StrategyType.select, member: 'DIRECT'),
    );
    expect(fixture.actualMember, 'DIRECT');
    expect(fixture.nativeCacheWrites, 1);
    expect(
      fixture
          .calls(ApplicationContract.coreOperationStrategySelect)
          .last
          .arguments
          .containsKey('restore'),
      isFalse,
    );
  });

  test(
    'systemRevoked 沿独占 execute 等旧进程真实退出，再按 immutable record 仅恢复 LAN',
    () async {
      await create(lanOnly: true);
      fixture.vpnIntent = true;
      fixture.phase = 'RUNNING';
      await fixture.writeRecord({
        'vpnIntent': true,
        'choices': {
          '出口🌐': {'type': 'select', 'member': '节点🌐'},
        },
      });
      await fixture.startAppRuntime();
      final source = fixture.core;
      final gate = Completer<void>();
      final entered = Completer<void>();
      fixture.onExit = (arguments) async {
        expect(arguments['processId'], source.processId);
        expect(arguments['reason'], 'revoked');
        expect(arguments['admittedAt'], fixture.admittedAt);
        expect(arguments['deadline'], fixture.deadline);
        entered.complete();
        await gate.future;
        fixture.replaceCore(phase: 'EMPTY');
        fixture.phase = 'STOPPED';
        fixture.lanRunning = false;
        return {'exited': true};
      };
      final result = FutureProbe(
        fixture.execute({
          'action': 'systemRevoked',
          ...fixture.identity(source),
        }),
      );
      await entered.future;
      expect(result.settled, isFalse);
      expect(fixture.publications, isEmpty);
      expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
      gate.complete();
      await result.done;
      expect(result.value!['success'], isTrue);
      expect(result.value!['lanRestored'], isTrue);
      final prepare = fixture
          .calls(ApplicationContract.coreOperationPrepare)
          .single;
      expect(prepare.arguments['vpnIntent'], isFalse);
      expect(prepare.arguments['lanIntent'], isTrue);
      expect(prepare.arguments['explicitStart'], isFalse);
      expect(prepare.arguments['admittedAt'], fixture.admittedAt);
      expect(prepare.arguments['deadline'], fixture.deadline);
      expect(fixture.authorizations, 0);
      expect(fixture.exits, hasLength(1));
      expect(fixture.snapshot.lanRunning, isTrue);
      expect(fixture.snapshot.running, isFalse);
      final restored = await fixture.runtime.inputFor(fixture.core);
      expect(restored!['inputId'], isNot(source.inputId));
      expect(restored['choices'], {
        '出口🌐': {'type': 'select', 'member': '节点🌐'},
      });
      expect(restored['vpnIntent'], isFalse);
      expect(restored['lanIntent'], isTrue);
      expect(await fixture.runInput.exists(), isFalse);
    },
  );

  test('systemRevoked stale identity 不退出、不发布输入、不触碰替换进程', () async {
    await create(lanOnly: true);
    await fixture.startAppRuntime();
    final old = fixture.identity();
    fixture.replaceCore(
      processId: 'replacement-process',
      inputId: 'replacement-input',
      generation: 2,
    );
    final replacement = fixture.core.identity;
    final result = await fixture.execute({'action': 'systemRevoked', ...old});
    expect(result['success'], isTrue);
    expect(result['lanRestored'], isFalse);
    expect(fixture.core.identity, replacement);
    expect(fixture.exits, isEmpty);
    expect(fixture.publications, isEmpty);
    expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
  });

  test('systemRevoked 在 exit 等待期间被 Stop 取消后不发布迟到 LAN 输入', () async {
    await create(lanOnly: true);
    await fixture.startAppRuntime();
    final gate = Completer<void>();
    final entered = Completer<void>();
    fixture.onExit = (arguments) async {
      entered.complete();
      await gate.future;
      fixture.replaceCore(phase: 'EMPTY');
      fixture.phase = 'STOPPED';
      return {'exited': true};
    };
    final result = FutureProbe(
      fixture.execute({'action': 'systemRevoked', ...fixture.identity()}),
    );
    await entered.future;
    await fixture.abandon();
    expect(result.settled, isFalse);
    gate.complete();
    await result.done;
    expect(result.value!['success'], isFalse);
    expect((result.value!['failure'] as Map)['code'], 'expired');
    expect(fixture.exits.single['reason'], 'revoked');
    expect(fixture.publications, isEmpty);
    expect(fixture.calls(ApplicationContract.coreOperationPrepare), isEmpty);
    expect(fixture.authorizations, 0);
  });
}
