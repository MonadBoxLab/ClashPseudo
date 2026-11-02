import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_actions.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/logic/overrides/override_actions.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/config_action_fakes.dart';

import 'package:clash_pseudo/src/ui/locale/message_text.dart';

class _RemovalPlatform extends PlatformFake {
  int released = 0;
  String? releaseError;

  @override
  Future<void> releasePreview() async {
    released++;
    if (releaseError case final error?) throw StateError(error);
  }
}

void main() {
  late Directory directory;
  late ConfigStore configs;
  late OverrideStore overrides;
  late _RemovalPlatform platform;
  late DownloadFake downloader;
  late ConfigActions configActions;
  late OverrideActions overrideActions;
  const local = ConfigEntry(
    id: 'local',
    name: 'Local',
    kind: ConfigKind.local,
    revision: 1,
    body: 'old',
  );
  const part = OverrideEntry(
    id: 'part',
    name: 'Part',
    kind: ConfigKind.local,
    revision: 1,
    body: 'rules: []',
    enabled: true,
  );
  const originalError =
      'https://user:password@fixture.test/path?token=完整原文#section\n'
      'Authorization: Bearer 原文🙂';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('independent-actions-');
    configs = ConfigStore(directory);
    overrides = OverrideStore(directory);
    platform = _RemovalPlatform()..input = File('${directory.path}/run.input');
    downloader = DownloadFake();
    configActions = ConfigActions(
      configs,
      downloader,
      platform,
      platform.input!,
    );
    overrideActions = OverrideActions(
      overrides,
      downloader,
      platform,
      runInput: platform.input!,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  for (final failStop in [false, true]) {
    test(
      'progress failure never prevents actual Stop, stopFailure=$failStop',
      () async {
        platform.load(local);
        platform.stoppingStageFailure = StateError(originalError);
        platform.failStop = failStop;
        if (failStop) {
          await expectLater(
            ConfigActions.stop(platform),
            throwsA(
              isA<ConfigFailure>().having(
                (failure) => failure.message.text,
                'all original errors',
                allOf(
                  contains(StateError(originalError).toString()),
                  contains(
                    PlatformFailure(
                      code: 'cleanup',
                      details: messages.androidErrorReleaseUnconfirmed.toMap(),
                    ).toString(),
                  ),
                ),
              ),
            ),
          );
          expect(platform.state.phase, 'UNKNOWN');
        } else {
          final message = await ConfigActions.stop(platform);
          expect(message.id, messages.tunnelStopped.id);
          expect(message.text, contains(originalError));
          expect(platform.state.phase, 'STOPPED');
        }
        expect(platform.events, ['stop']);
      },
    );
  }

  test(
    'removal folds release and schedule failures without losing saved deletion',
    () async {
      await configs.save(
        ConfigCollection(entries: [local], selectedId: local.id),
      );
      platform.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(
          phase: 'READY',
          purpose: 'PREVIEW',
          configId: 'local',
          revision: 1,
          generation: 1,
        ),
      );
      platform.releaseError = originalError;
      platform.failSchedules = true;
      final message = await configActions.execute({
        'action': 'delete',
        'id': local.id,
      });
      expect((await configs.read()).entries, isEmpty);
      expect((await configs.read()).selectedId, isNull);
      expect(configActions.result['configStatus'], 'applyFailed');
      expect(configActions.result['scheduleStatus'], 'failed');
      expect(configActions.result['success'], isFalse);
      expect(message!.id, messages.configDeleted.id);
      expect(message.text, contains(originalError));
      expect(message.text, contains('PlatformFailure({code: schedule'));
      expect(platform.released, 1);
      expect(platform.scheduleKinds, ['config']);
      expect(platform.events, isEmpty);
    },
  );

  for (final throwsSnapshot in [false, true]) {
    void failSnapshot() {
      platform.state = const AppSnapshot(
        error: AppMessage('operationFailed', detail: originalError),
      );
      if (throwsSnapshot) platform.snapshotError = originalError;
    }

    test(
      'local config rename, save and delete survive unrelated files and snapshot throw=$throwsSnapshot',
      () async {
        await configs.save(
          ConfigCollection(entries: [local], selectedId: local.id),
        );
        final unrelated = [
          File('${directory.path}/overrides.json'),
          File('${directory.path}/preferences.json'),
        ];
        for (final file in unrelated) {
          await file.writeAsString('{broken');
        }
        failSnapshot();
        const name = '  原名 🌐\t';
        await configActions.execute({
          'action': 'renameConfig',
          'id': local.id,
          'name': name,
        });
        expect(platform.snapshotReads, 0);
        expect((await configs.read()).selected!.name, name);
        expect((await configs.read()).selected!.revision, local.revision);
        const body = '﻿# 原文🙂\r\nrules: []\n';
        final savedMessage = await configActions.execute({
          'action': 'saveLocal',
          'id': local.id,
          'revision': local.revision,
          'body': body,
        });
        final saved = (await configs.read()).selected!;
        expect(saved.name, name);
        expect(saved.body, body);
        expect(saved.revision, local.revision + 1);
        expect(configActions.result['configStatus'], 'applyFailed');
        expect(configActions.result['targetId'], local.id);
        expect(configActions.result['savedRevision'], saved.revision);
        expect(configActions.result['success'], isFalse);
        expect(savedMessage!.id, messages.configSavedApplyReleasePending.id);
        expect(savedMessage.detail, contains(originalError));
        if (throwsSnapshot) {
          expect(savedMessage.detail, StateError(originalError).toString());
        }
        final deletedMessage = await configActions.execute({
          'action': 'delete',
          'id': local.id,
        });
        expect((await configs.read()).entries, isEmpty);
        expect((await configs.read()).selectedId, isNull);
        expect(deletedMessage!.id, messages.configDeleted.id);
        expect(deletedMessage.detail, contains(originalError));
        expect(configActions.result['configStatus'], 'applyFailed');
        expect(configActions.result['scheduleStatus'], 'synced');
        expect(platform.scheduleKinds, ['config']);
        expect(platform.schedules, [<Map<String, Object?>>[]]);
        expect(platform.events, isEmpty);
        expect(platform.loaded, isEmpty);
        for (final file in unrelated) {
          expect(await file.readAsString(), '{broken');
        }
      },
    );

    test(
      'local override rename and save survive unreadable config and snapshot throw=$throwsSnapshot',
      () async {
        await overrides.save([part]);
        final configFile = File('${directory.path}/configurations.json');
        await configFile.writeAsString('{broken');
        failSnapshot();
        const name = '  插件 🌐\t';
        await overrideActions.execute({
          'action': 'changeOverride',
          'id': part.id,
          'name': name,
        });
        expect(platform.snapshotReads, 0);
        expect((await overrides.read()).single.name, name);
        const body = '# 原文🙂\r\nrules: []\n';
        final message = await overrideActions.execute({
          'action': 'saveOverride',
          'id': part.id,
          'revision': part.revision,
          'body': body,
        });
        final saved = (await overrides.read()).single;
        expect(saved.name, name);
        expect(saved.body, body);
        expect(saved.revision, part.revision + 1);
        expect(overrideActions.result['overrideStatus'], 'applyFailed');
        expect(overrideActions.result['savedRevision'], saved.revision);
        expect(overrideActions.result['success'], isFalse);
        expect(message.id, messages.overrideSavedReconnectIncomplete.id);
        expect(message.detail, contains(originalError));
        if (throwsSnapshot) {
          expect(message.detail, StateError(originalError).toString());
        }
        expect(await configFile.readAsString(), '{broken');
        expect(platform.events, isEmpty);
      },
    );
  }

  for (final kind in ['config', 'override']) {
    test('$kind schedule policy does not read the other file or native state', () async {
      final broken = File(
        '${directory.path}/${kind == 'config' ? 'overrides' : 'configurations'}.json',
      );
      await broken.writeAsString('{broken');
      await File('${directory.path}/preferences.json').writeAsString('{broken');
      platform.snapshotError = originalError;
      if (kind == 'config') {
        final remote = ConfigEntry(
          id: local.id,
          name: local.name,
          source: 'https://fixture.test/config',
          revision: 1,
          body: local.body,
        );
        await configs.save(
          ConfigCollection(entries: [remote], selectedId: remote.id),
        );
        await configActions.execute({
          'action': 'setConfigUpdate',
          'id': remote.id,
          'enabled': true,
          'hours': 12,
        });
        expect((await configs.read()).selected!.update.enabled, isTrue);
        expect((await configs.read()).selected!.update.hours, 12);
        expect(configActions.result['configStatus'], 'saved');
        expect(configActions.result['scheduleStatus'], 'synced');
      } else {
        final remote = OverrideEntry(
          id: part.id,
          name: part.name,
          kind: ConfigKind.remote,
          source: 'https://fixture.test/part',
          revision: 1,
          body: part.body,
          enabled: true,
        );
        await overrides.save([remote]);
        await overrideActions.execute({
          'action': 'setOverrideUpdate',
          'id': remote.id,
          'enabled': true,
          'hours': 12,
        });
        expect((await overrides.read()).single.update.enabled, isTrue);
        expect((await overrides.read()).single.update.hours, 12);
        expect(overrideActions.result['overrideStatus'], 'saved');
        expect(overrideActions.result['scheduleStatus'], 'synced');
      }
      expect(platform.scheduleKinds, [kind]);
      expect(platform.schedules.single, [
        {
          'kind': kind,
          'id': kind == 'config' ? local.id : part.id,
          'hours': 12,
        },
      ]);
      expect(platform.snapshotReads, 0);
      expect(platform.events, isEmpty);
      expect(await broken.readAsString(), '{broken');
      expect(
        await File('${directory.path}/preferences.json').readAsString(),
        '{broken',
      );
    });
  }

  for (final snapshotFails in [false, true]) {
    test(
      'application access saves with unreadable config and override snapshot failure=$snapshotFails',
      () async {
        for (final name in ['configurations', 'overrides']) {
          await File('${directory.path}/$name.json').writeAsString('{broken');
        }
        const before = AppPreferences(
          language: AppLanguage.en,
          brand: BrandColor.jade,
        );
        final preferences = PreferencesStore(directory);
        await preferences.save(before);
        if (snapshotFails) platform.snapshotError = originalError;
        final operation = configActions.execute({
          'action': 'setApplicationAccess',
          'access': 'only',
          'packages': ['fixture.second', 'fixture.first'],
        });
        if (snapshotFails) {
          await expectLater(
            operation,
            throwsA(
              isA<ConfigFailure>()
                  .having(
                    (failure) => failure.message.id,
                    'saved result',
                    'accessSavedReconnectFailed',
                  )
                  .having(
                    (failure) => failure.message.detail,
                    'original error',
                    StateError(originalError).toString(),
                  ),
            ),
          );
          expect(configActions.result['success'], isFalse);
        } else {
          expect((await operation)!.id, messages.accessSavedNextConnection.id);
        }
        expect(
          (await preferences.read()).toJson(),
          before.withAccess(ApplicationAccess.only, [
            'fixture.second',
            'fixture.first',
          ]).toJson(),
        );
        expect(platform.events, isEmpty);
        for (final name in ['configurations', 'overrides']) {
          expect(
            await File('${directory.path}/$name.json').readAsString(),
            '{broken',
          );
        }
      },
    );
  }

  for (final kind in ['configurations', 'overrides']) {
    for (final oversized in [false, true]) {
      test(
        'clear $kind does not parse damaged or oversized old files, oversized=$oversized',
        () async {
          final target = File('${directory.path}/$kind.json');
          if (oversized) {
            final file = await target.open(mode: FileMode.write);
            await file.truncate(
              ApplicationContract.backupConfigurationsJsonBytes + 1,
            );
            await file.close();
          } else {
            await target.writeAsString('{broken');
          }
          final other = File(
            '${directory.path}/${kind == 'configurations' ? 'overrides' : 'configurations'}.json',
          );
          final preferences = File('${directory.path}/preferences.json');
          await other.writeAsString('{unrelated broken 原文');
          await preferences.writeAsString('{unrelated settings 原文');
          platform.snapshotError = originalError;
          final message = kind == 'configurations'
              ? (await configActions.execute({
                  'action': 'clearConfigurations',
                }))!
              : await overrideActions.execute({'action': 'clearOverrides'});
          final result = kind == 'configurations'
              ? configActions.result
              : overrideActions.result;
          expect(
            message.id,
            kind == 'configurations'
                ? 'configurationsCleared'
                : 'overridesCleared',
          );
          expect(message.detail, StateError(originalError).toString());
          expect(
            result[kind == 'configurations'
                ? 'configStatus'
                : 'overrideStatus'],
            'applyFailed',
          );
          expect(result['success'], isFalse);
          expect(result['scheduleStatus'], 'synced');
          expect(platform.scheduleKinds, [
            kind == 'configurations' ? 'config' : 'override',
          ]);
          expect(platform.schedules.single, isEmpty);
          expect(await other.readAsString(), '{unrelated broken 原文');
          expect(await preferences.readAsString(), '{unrelated settings 原文');
          if (kind == 'configurations') {
            final after = await configs.read();
            expect(after.entries, isEmpty);
            expect(after.selectedId, isNull);
            expect(after.mode, isNull);
          } else {
            expect(await overrides.read(), isEmpty);
          }
          expect(platform.events, isEmpty);
          expect(platform.released, 0);
        },
      );
    }
  }

  test('clearing saved configurations does not stop or replace the immutable running input', () async {
    await configs.save(
      ConfigCollection(entries: [local], selectedId: local.id),
    );
    platform.load(local, parts: [part]);
    final running = platform.loaded;
    await configActions.execute({'action': 'clearConfigurations'});
    expect((await configs.read()).entries, isEmpty);
    expect(platform.state.running, isTrue);
    expect(platform.loaded, same(running));
    expect(platform.events, isEmpty);
    expect(configActions.result['configStatus'], 'saved');
    expect(platform.scheduleKinds, ['config']);
  });

  for (final configurations in [true, false]) {
    test(
      'clear collection invalidates its preview even when the old file cannot be read, configurations=$configurations',
      () async {
        platform.state = const AppSnapshot(
          phase: 'STOPPED',
          core: CoreSnapshot(
            phase: 'READY',
            purpose: 'PREVIEW',
            configId: 'old',
            revision: 1,
            generation: 1,
          ),
        );
        await File(
          '${directory.path}/${configurations ? 'configurations' : 'overrides'}.json',
        ).writeAsString('{broken');
        if (configurations) {
          await configActions.execute({'action': 'clearConfigurations'});
          expect(configActions.result['configStatus'], 'saved');
        } else {
          await overrideActions.execute({'action': 'clearOverrides'});
          expect(overrideActions.result['overrideStatus'], 'saved');
        }
        expect(platform.released, 1);
        expect(platform.events, isEmpty);
      },
    );
  }

  test('clearing all plugins applies the explicit empty composition to the original running configuration', () async {
    await configs.save(
      ConfigCollection(entries: [local], selectedId: local.id),
    );
    await overrides.save([part]);
    platform.load(local, parts: [part]);
    await overrideActions.execute({'action': 'clearOverrides'});
    expect(await overrides.read(), isEmpty);
    expect(platform.loaded['id'], local.id);
    expect(platform.loaded['body'], local.body);
    expect(platform.loaded['overrides'], isEmpty);
    expect(platform.state.running, isTrue);
    expect(overrideActions.result['overrideStatus'], 'applied');
    expect(platform.scheduleKinds, ['override']);
    expect(platform.schedules.single, isEmpty);
  });

  test(
    'clear collection keeps saved result when schedule reconciliation fails',
    () async {
      await configs.save(
        ConfigCollection(entries: [local], selectedId: local.id),
      );
      platform.failSchedules = true;
      final message = await configActions.execute({
        'action': 'clearConfigurations',
      });
      expect((await configs.read()).entries, isEmpty);
      expect(configActions.result['configStatus'], 'saved');
      expect(configActions.result['scheduleStatus'], 'failed');
      expect(configActions.result['success'], isFalse);
      expect(message!.id, 'configurationsCleared');
      expect(message.detail, contains('PlatformFailure({code: schedule'));
    },
  );

  test(
    'imports retain original names and source spelling for distinct identities',
    () async {
      const source =
          'HTTPS://User:Password@Example.TEST:443/a%2fb?token=%2f原文#fragment';
      const name = '  名称 🌐\t';
      await configActions.execute({
        'action': 'import',
        'source': source,
        'name': name,
      });
      await configActions.execute({
        'action': 'import',
        'source': source,
        'name': name,
      });
      final savedConfigs = (await configs.read()).entries;
      expect(savedConfigs, hasLength(2));
      expect(savedConfigs.map((entry) => entry.id).toSet(), hasLength(2));
      expect(savedConfigs.map((entry) => entry.source), [source, source]);
      expect(savedConfigs.map((entry) => entry.name), [name, name]);
      downloader.body = 'rules: []';
      await overrideActions.execute({
        'action': 'importOverride',
        'source': source,
        'name': name,
      });
      await overrideActions.execute({
        'action': 'importOverride',
        'source': source,
        'name': name,
      });
      final savedParts = await overrides.read();
      expect(savedParts, hasLength(2));
      expect(savedParts.map((entry) => entry.id).toSet(), hasLength(2));
      expect(savedParts.map((entry) => entry.source), [source, source]);
      expect(savedParts.map((entry) => entry.name), [name, name]);
      expect(platform.events, isEmpty);
    },
  );
}
