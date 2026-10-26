import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/src/features/overrides/loon_converter.dart';
import 'package:clash_pseudo/src/features/overrides/override_actions.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/logic/schedule_actions.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../configs/action_fakes.dart';

class _Download extends DownloadFake {
  final sources = <String>[];
  @override
  Future<String> download(String source) {
    sources.add(source);
    return super.download(source);
  }
}

class _ReadHookStore extends OverrideStore {
  _ReadHookStore(super.directory, this.beforeRead);
  final Future<void> Function(int) beforeRead;
  int reads = 0;
  @override
  Future<List<OverrideEntry>> read() async {
    await beforeRead(++reads);
    return super.read();
  }
}

class _Platform extends PlatformFake {
  bool expired = false;
  bool failApplyStage = false;
  @override
  Future<void> checkOperation() async {
    if (expired) throw PlatformException(code: 'expired');
  }

  @override
  Future<void> stage(AppMessage message) async {
    if (failApplyStage && message == messages.stageApplyingOverrideUpdate) {
      throw PlatformException(code: 'controlled-apply-failure');
    }
  }
}

void main() {
  const config = ConfigEntry(
    id: 'main',
    name: 'Main',
    kind: ConfigKind.local,
    revision: 1,
    body: 'rules:\n  - MATCH,DIRECT\n',
  );
  const remote = OverrideEntry(
    id: 'remote',
    name: 'Remote',
    kind: ConfigKind.remote,
    source: 'https://fixture.invalid/not-a-format-extension',
    revision: 1,
    body: 'rules:\n  - DOMAIN,old.test,DIRECT\n',
    enabled: true,
    proxyName: 'Chosen',
    addNoResolve: true,
    update: UpdatePolicy(enabled: true),
  );
  // Self-authored minimal input. Nothing is fetched from these metadata fields.
  const loon =
      '#!name=self-authored\n[Rule]\n'
      'DOMAIN,example.test,PROXY\nIP-CIDR,192.0.2.0/24\n'
      'NOT,((IP-CIDR6,2001:db8::/32)),DIRECT\n'
      'DOMAIN,blocked.test,REJECT-IMG\nFINAL,DIRECT\n'
      '[Script]\nscript=never-executed\n';
  const expectedRules = [
    'DOMAIN,example.test,Chosen',
    'IP-CIDR,192.0.2.0/24,Chosen,no-resolve',
    'NOT,((IP-CIDR6,2001:db8::/32,no-resolve)),DIRECT',
    'DOMAIN,blocked.test,REJECT',
  ];
  late Directory directory;
  late ConfigStore configs;
  late OverrideStore store;
  late _Download download;
  late _Platform platform;
  late OverrideActions actions;
  late ScheduleActions schedules;
  var failSave = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('loon-business-');
    configs = ConfigStore(directory);
    failSave = false;
    store = OverrideStore(
      directory,
      beforeWrite: () async {
        if (failSave) throw ConfigFailure(messages.overridesSaveFailed);
        await platform.checkOperation();
      },
    );
    download = _Download()..body = loon;
    platform = _Platform()..input = File('${directory.path}/run-input.json');
    actions = OverrideActions(
      store,
      download,
      platform,
      runInput: platform.input!,
    );
    schedules = ScheduleActions(
      configs,
      store,
      download,
      platform,
      runInput: platform.input!,
    );
    await configs.save(
      ConfigCollection(
        entries: [config],
        selectedId: 'main',
        mode: TunnelMode.rule,
      ),
    );
    await store.save([remote]);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<AppMessage> perform(String entrypoint) async {
    if (entrypoint == 'periodic') {
      final outcome = await schedules.refresh('override', remote.id);
      expect(outcome['scheduleStatus'], anyOf('saved', 'applied', 'unchanged'));
      return outcome['message'] as AppMessage;
    }
    return actions.execute({
      'action': entrypoint,
      if (entrypoint == 'importOverride') ...{
        'name': 'Imported',
        'source': remote.source,
        'proxyName': remote.proxyName,
        'addNoResolve': remote.addNoResolve,
      } else
        'id': remote.id,
      if (entrypoint == 'changeOverrideSource') ...{
        'source': 'https://other.invalid/changed',
        'proxyName': remote.proxyName,
        'addNoResolve': remote.addNoResolve,
      },
    });
  }

  const entrypoints = [
    'importOverride',
    'updateOverride',
    'changeOverrideSource',
    'periodic',
  ];
  for (final entrypoint in entrypoints) {
    test(
      '$entrypoint downloads and converts through the real business/store path',
      () async {
        if (entrypoint == 'importOverride') await store.save([]);
        final message = await perform(entrypoint);
        final saved = (await store.read()).single;
        expect((loadYaml(saved.body) as YamlMap)['rules'], expectedRules);
        expect(
          saved.body,
          convertLoonOverride(
            loon,
            proxyName: 'Chosen',
            addNoResolve: true,
          ).body,
        );
        expect(saved.proxyName, 'Chosen');
        expect(saved.addNoResolve, isTrue);
        expect(saved.enabled, isTrue);
        expect(
          saved.body,
          contains('# FINAL,DIRECT\n# [Script]\n# script=never-executed\n'),
        );
        expect(message.id, 'loonConvertedResult');
        expect(message.args['rules'], 4);
        expect(message.args['comments'], 6);
        expect(message.args['result'], isA<AppMessage>());
        expect(platform.events, isEmpty);
        expect(download.calls, 1);
        final persisted = jsonDecode(
          await File('${directory.path}/overrides.json').readAsString(),
        ) as Map;
        expect(
          (persisted['entries'] as List).single.keys,
          isNot(contains('raw')),
        );
        expect(
          (persisted['entries'] as List).single.keys,
          isNot(contains('history')),
        );
      },
    );

    test(
      '$entrypoint preserves ordinary YAML bytes and ignores conversion options',
      () async {
        const yaml =
            '﻿# original\r\nrules:\r\n  - DOMAIN,yaml.test,DIRECT\nunknown: false\r';
        download.body = yaml;
        if (entrypoint == 'importOverride') await store.save([]);
        final message = await perform(entrypoint);
        final saved = (await store.read()).single;
        expect(saved.body, yaml);
        expect(utf8.encode(saved.body), utf8.encode(yaml));
        expect(message.id, isNot(startsWith('loon')));
        expect(saved.proxyName, 'Chosen');
        expect(saved.addNoResolve, isTrue);
      },
    );

    test(
      '$entrypoint zero-rule result is inert and explicitly reported',
      () async {
        download.body = '[Rule]\nFINAL,DIRECT\n';
        if (entrypoint == 'importOverride') await store.save([]);
        final message = await perform(entrypoint);
        final saved = (await store.read()).single;
        expect(loadYaml(saved.body), isEmpty);
        expect(saved.body, contains('# FINAL,DIRECT\n{}\n'));
        expect(saved.body, isNot(contains('rules: []')));
        expect(message.id, 'loonNoRulesResult');
        expect(message.args['comments'], 2);
      },
    );

    test('$entrypoint damaged YAML never falls back to Loon', () async {
      download.body = 'rules: [broken\n[Rule]\nDOMAIN,injected.test,DIRECT\n';
      if (entrypoint == 'importOverride') await store.save([]);
      final old = await store.read();
      if (entrypoint == 'periodic') {
        final outcome = await schedules.refresh('override', remote.id);
        expect(outcome['scheduleStatus'], 'failed');
        expect(outcome['message'], messages.overrideContentUnsupported);
      } else {
        await expectLater(
          perform(entrypoint),
          failsConfig('overrideContentUnsupported'),
        );
      }
      final saved = await store.read();
      expect(saved.length, old.length);
      if (saved.isNotEmpty) {
        expect(saved.single.source, old.single.source);
        expect(saved.single.body, old.single.body);
        expect(saved.single.revision, old.single.revision);
        expect(saved.single.proxyName, old.single.proxyName);
        expect(saved.single.addNoResolve, old.single.addNoResolve);
      }
      expect(platform.events, isEmpty);
    });
  }

  test(
    'same URL option edit redownloads and commits options/body atomically',
    () async {
      final old = remote.changed(proxyName: 'Previous', addNoResolve: false);
      await store.save([old]);
      download.pending = Completer<String>();
      final pending = actions.execute({
        'action': 'changeOverrideSource',
        'id': old.id,
        'source': old.source,
        'revision': old.revision,
        'expectedSource': old.source,
        'expectedProxyName': old.proxyName,
        'expectedAddNoResolve': old.addNoResolve,
        'proxyName': 'Chosen',
        'addNoResolve': true,
      });
      await download.started.future;
      expect((await store.read()).single.toJson(), old.toJson());
      download.pending!.complete(loon);
      await pending;
      final saved = (await store.read()).single;
      expect(download.sources, [old.source]);
      expect(saved.proxyName, 'Chosen');
      expect(saved.addNoResolve, isTrue);
      expect(saved.revision, old.revision + 1);
      expect((loadYaml(saved.body) as YamlMap)['rules'], expectedRules);
    },
  );

  test(
    'failed same-URL option edit preserves every old record field and run',
    () async {
      platform.load(config, parts: [remote]);
      download.fail = true;
      await expectLater(
        actions.execute({
          'action': 'changeOverrideSource',
          'id': remote.id,
          'source': remote.source,
          'proxyName': 'Candidate',
          'addNoResolve': false,
        }),
        failsConfig('downloadFailed'),
      );
      expect((await store.read()).single.toJson(), remote.toJson());
      expect(platform.state.running, isTrue);
      expect(platform.loaded['overrides'].single['body'], remote.body);
      expect(platform.events, isEmpty);
    },
  );

  test(
    'ordinary YAML options-only edit keeps revision and actual run unchanged',
    () async {
      const yaml = '# byte-preserved\nrules: ["DOMAIN,yaml.test,DIRECT"]\n';
      final before = remote.withContent(yaml);
      await store.save([before]);
      platform.load(config, parts: [before]);
      download.body = yaml;
      await actions.execute({
        'action': 'changeOverrideSource',
        'id': before.id,
        'source': before.source,
        'proxyName': 'New name',
        'addNoResolve': false,
      });
      final saved = (await store.read()).single;
      expect(saved.proxyName, 'New name');
      expect(saved.addNoResolve, isFalse);
      expect(saved.body, yaml);
      expect(saved.revision, before.revision);
      expect(platform.events, isEmpty);
      expect(download.calls, 1);
    },
  );

  for (final mutate in [
    'source',
    'revision',
    'proxyName',
    'addNoResolve',
    'delete',
  ]) {
    for (final periodic in [false, true]) {
      for (final failure in [false, true]) {
        test(
          '${periodic ? 'periodic' : 'manual'} late ${failure ? 'failure' : 'success'} rejects changed $mutate',
          () async {
            download.pending = Completer<String>();
            final pending = periodic
                ? schedules.refresh('override', remote.id)
                : actions.execute({
                    'action': 'updateOverride',
                    'id': remote.id,
                  });
            await download.started.future;
            final changed = switch (mutate) {
              'source' => remote.changed(
                source: 'https://changed.invalid/part',
              ),
              'revision' => remote.withContent('rules: []'),
              'proxyName' => remote.changed(proxyName: 'Changed'),
              'addNoResolve' => remote.changed(addNoResolve: false),
              _ => null,
            };
            await store.save(changed == null ? [] : [changed]);
            final expected = (await store.read())
                .map((entry) => entry.toJson())
                .toList();
            if (failure) {
              download.pending!.completeError(
                ConfigFailure(messages.downloadFailed),
              );
            } else {
              download.pending!.complete(loon);
            }
            if (periodic) {
              final outcome = await pending as Map<String, Object?>;
              expect(outcome['scheduleStatus'], 'skipped');
              expect(outcome['message'], messages.overrideChangedNotApplied);
            } else {
              await expectLater(
                pending,
                failsConfig('overrideChangedNotApplied'),
              );
            }
            expect(
              (await store.read()).map((entry) => entry.toJson()).toList(),
              expected,
            );
            expect(platform.events, isEmpty);
          },
        );
      }
    }
  }

  for (final field in [
    'revision',
    'expectedSource',
    'expectedProxyName',
    'expectedAddNoResolve',
  ]) {
    test('stale source form $field is rejected before download', () async {
      final command = <String, dynamic>{
        'action': 'changeOverrideSource',
        'id': remote.id,
        'source': remote.source,
        'proxyName': 'Candidate',
        'addNoResolve': false,
        'revision': remote.revision,
        'expectedSource': remote.source,
        'expectedProxyName': remote.proxyName,
        'expectedAddNoResolve': remote.addNoResolve,
      };
      command[field] = switch (field) {
        'revision' => 99,
        'expectedAddNoResolve' => false,
        _ => 'stale',
      };
      await expectLater(
        actions.execute(command),
        failsConfig('overrideChangedNotApplied'),
      );
      expect(download.calls, 0);
      expect((await store.read()).single.toJson(), remote.toJson());
    });
  }

  test(
    'first import conflict created during download is not overwritten',
    () async {
      await store.save([]);
      download.pending = Completer<String>();
      final pending = perform('importOverride');
      await download.started.future;
      final occupied = OverrideEntry.fromJson({
        ...remote.toJson(),
        'id': 'other-owner',
      });
      await store.save([occupied]);
      download.pending!.complete(loon);
      await expectLater(pending, failsConfig('overrideChangedNotApplied'));
      expect((await store.read()).single.toJson(), occupied.toJson());
    },
  );

  for (final periodic in [false, true]) {
    test(
      '${periodic ? 'periodic' : 'manual'} cancellation blocks late success writes',
      () async {
        download.pending = Completer<String>();
        final pending = periodic
            ? schedules.refresh('override', remote.id)
            : actions.execute({'action': 'updateOverride', 'id': remote.id});
        await download.started.future;
        platform.expired = true;
        download.pending!.complete(loon);
        await expectLater(pending, throwsA(isA<PlatformException>()));
        expect((await store.read()).single.toJson(), remote.toJson());
        expect(platform.events, isEmpty);
      },
    );
  }

  test('stop during download saves the result without restarting', () async {
    platform.load(config, parts: [remote]);
    download.pending = Completer<String>();
    final pending = actions.execute({
      'action': 'updateOverride',
      'id': remote.id,
    });
    await download.started.future;
    platform.state = const AppSnapshot(phase: 'STOPPED');
    download.pending!.complete(loon);
    await pending;
    expect(
      (loadYaml((await store.read()).single.body) as YamlMap)['rules'],
      expectedRules,
    );
    expect(platform.events, isEmpty);
  });

  test(
    'converted write failure preserves source/body/options and old run',
    () async {
      platform.load(config, parts: [remote]);
      failSave = true;
      await expectLater(
        actions.execute({
          'action': 'changeOverrideSource',
          'id': remote.id,
          'source': 'https://candidate.invalid/part',
          'proxyName': 'Candidate',
          'addNoResolve': false,
        }),
        failsConfig('overridesSaveFailed'),
      );
      expect((await store.read()).single.toJson(), remote.toJson());
      expect(platform.loaded['overrides'].single['body'], remote.body);
      expect(platform.state.running, isTrue);
      expect(platform.events, isEmpty);
      expect(actions.result['overrideStatus'], 'notSaved');
    },
  );

  test(
    'input and expanded output limits fail without partial publication',
    () async {
      for (final tooLarge in [
        'x' * (maxLoonTextBytes + 1),
        '[Script]\n${String.fromCharCode(0) * (maxLoonTextBytes ~/ 6)}',
      ]) {
        download.body = tooLarge;
        await expectLater(
          actions.execute({
            'action': 'changeOverrideSource',
            'id': remote.id,
            'source': 'https://candidate.invalid/part',
          }),
          failsConfig('textTooLargeSave'),
        );
        expect((await store.read()).single.toJson(), remote.toJson());
      }
      expect(platform.events, isEmpty);
    },
  );

  test('saved application failure is not a failed download and explicit same-body retry applies', () async {
    platform.load(config, parts: [remote]);
    platform.failApplyStage = true;
    final failedMessage = await actions.execute({
      'action': 'updateOverride',
      'id': remote.id,
    });
    final saved = (await store.read()).single;
    expect(saved.revision, 2);
    expect(saved.body, isNot(remote.body));
    expect(actions.result['overrideStatus'], 'applyFailed');
    expect(failedMessage.id, 'loonConvertedResult');
    expect(
      failedMessage.args['result'],
      messages.overrideSavedReconnectIncomplete,
    );
    expect(platform.loaded['overrides'].single['body'], remote.body);
    expect(platform.state.running, isTrue);
    platform.failApplyStage = false;
    await actions.execute({'action': 'updateOverride', 'id': remote.id});
    expect((await store.read()).single.revision, saved.revision);
    expect(actions.result['overrideStatus'], 'applied');
    expect(platform.events, ['stop', 'start:main']);
    expect(platform.loaded['overrides'].single['body'], saved.body);
  });

  test(
    'periodic same converted body never retries an earlier failed application',
    () async {
      final saved = remote.withContent(
        convertLoonOverride(loon, proxyName: 'Chosen', addNoResolve: true).body,
      );
      await store.save([saved]);
      platform.load(config, parts: [remote]);
      final outcome = await schedules.refresh('override', remote.id);
      expect(outcome['scheduleStatus'], 'unchanged');
      expect(
        (outcome['message'] as AppMessage).args['result'],
        messages.overrideUnchanged,
      );
      expect((await store.read()).single.revision, saved.revision);
      expect((await store.read()).single.update.lastResult, 'unchanged');
      expect(platform.events, isEmpty);
      expect(platform.loaded['overrides'].single['body'], remote.body);
    },
  );

  test('periodic unchanged result cannot acknowledge options replaced during diagnostic read', () async {
    final saved = remote.withContent(
      convertLoonOverride(loon, proxyName: 'Chosen', addNoResolve: true).body,
    );
    final replacement = saved.changed(proxyName: 'Replacement');
    await store.save([saved]);
    final hooked = _ReadHookStore(directory, (read) async {
      if (read == 3) await store.save([replacement]);
    });
    final refresh = ScheduleActions(
      configs,
      hooked,
      download,
      platform,
      runInput: platform.input!,
    );
    final outcome = await refresh.refresh('override', remote.id);
    expect(outcome['scheduleStatus'], 'skipped');
    expect(outcome['message'], messages.overrideChangedNotApplied);
    expect((await store.read()).single.toJson(), replacement.toJson());
    expect(platform.events, isEmpty);
  });

  group('local-custom shared save publication', () {
    test(
      'first save is enabled/prepend/top; later saves preserve actual metadata',
      () async {
        await actions.execute({
          'action': 'saveOverride',
          'localCustom': true,
          'name': 'Custom',
          'body': '{}',
        });
        var entries = await store.read();
        var custom = entries.first;
        expect(custom.role, OverrideRole.localCustom);
        expect(custom.enabled, isTrue);
        expect(custom.mode, OverrideMode.prepend);
        expect(entries.last.id, remote.id);
        custom = custom.changed(enabled: false, mode: OverrideMode.replace);
        await store.save([remote, custom]);
        await actions.execute({
          'action': 'saveOverride',
          'localCustom': true,
          'id': custom.id,
          'revision': custom.revision,
          'body': 'rules: []',
        });
        entries = await store.read();
        expect(entries.first.id, remote.id);
        expect(entries.last.id, custom.id);
        expect(entries.last.role, OverrideRole.localCustom);
        expect(entries.last.enabled, isFalse);
        expect(entries.last.mode, OverrideMode.replace);
        await actions.execute({
          'action': 'saveOverride',
          'id': custom.id,
          'revision': entries.last.revision,
          'body': '{}',
        });
        expect((await store.read()).last.role, OverrideRole.localCustom);
      },
    );

    test('role flag cannot repurpose an ordinary item or create another custom item', () async {
      const ordinary = OverrideEntry(
        id: 'local',
        name: 'Local',
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
      );
      await store.save([ordinary]);
      await expectLater(
        actions.execute({
          'action': 'saveOverride',
          'localCustom': true,
          'id': ordinary.id,
          'revision': 1,
          'body': 'rules: []',
        }),
        failsConfig('overrideChangedReopen'),
      );
      expect((await store.read()).single.role, isNull);
      await actions.execute({
        'action': 'saveOverride',
        'localCustom': true,
        'name': 'Custom',
        'body': '{}',
      });
      final original = (await store.read())
          .map((entry) => entry.toJson())
          .toList();
      await expectLater(
        actions.execute({
          'action': 'saveOverride',
          'localCustom': true,
          'name': 'Duplicate',
          'body': '{}',
        }),
        failsConfig('overrideChangedReopen'),
      );
      expect(
        (await store.read()).map((entry) => entry.toJson()).toList(),
        original,
      );
    });
  });
}

Matcher failsConfig(String id) => throwsA(
  isA<ConfigFailure>().having((error) => error.message.id, 'message ID', id),
);
