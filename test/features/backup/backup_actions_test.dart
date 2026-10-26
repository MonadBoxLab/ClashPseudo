import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/features/backup/backup_actions.dart';
import 'package:clash_pseudo/src/features/backup/backup_data.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_choice.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/logic/preferences_store.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = '12345678-1234-1234-1234-123456789abc';
const _names = ['configurations.json', 'overrides.json', 'preferences.json'];

AppSnapshot _stopped({
  int epoch = 41,
  CoreSnapshot core = const CoreSnapshot(),
}) => AppSnapshot(
  phase: 'STOPPED',
  storageReady: true,
  storageEpoch: epoch,
  core: core,
);

AppSnapshot _running({
  int epoch = 41,
  String id = 'original',
  int revision = 3,
}) => AppSnapshot(
  phase: 'RUNNING',
  generation: 5,
  configId: id,
  revision: revision,
  storageReady: true,
  storageEpoch: epoch,
  mode: TunnelMode.rule,
  core: CoreSnapshot(
    generation: 8,
    phase: 'READY',
    purpose: 'VPN',
    configId: id,
    revision: revision,
    composition: 'actual-composition',
  ),
);

/// Only the fixed native candidate/installation boundary is controlled here.
/// Business actions, all three Stores, text budgets and CoreInput are real.
/// ZIP/CRC/hash/SDK parser admission belongs to native BackupFiles tests.
class _BackupPlatform extends AppBridge {
  _BackupPlatform(this.stores, this.candidate, this.input);

  final Directory stores;
  final Directory candidate;
  final File input;
  AppSnapshot state = _stopped();
  final events = <String>[];
  final stopEntered = Completer<void>();
  final installEntered = Completer<void>();
  final discarded = <String>[];
  final starts = <Map<String, dynamic>>[];
  final registrations = <List<Map<String, Object?>>>[];
  Map<String, String>? defaults;
  String? prepareReplyRequest;
  Map<String, dynamic>? installed;
  Map<String, dynamic> Function(Map<String, dynamic>)? changeDescriptor;
  Future<void> Function()? duringInstall;
  Future<void> Function()? duringStrings;
  Future<void> Function()? duringSchedule;
  Future<void> Function()? duringStart;
  Completer<void>? stopping;
  Completer<void>? installing;
  bool expired = false;
  bool stopReleases = true;
  bool previewReleases = true;
  bool failStrings = false;
  bool failSchedules = false;
  bool failStart = false;
  bool authorizeResult = true;
  bool failInstallTransport = false;
  bool wrongRunningIdentity = false;

  Future<Map<String, dynamic>> descriptor() async {
    final configs = jsonDecode(
      await File('${candidate.path}/configurations.json').readAsString(),
    ) as Map<String, dynamic>;
    final overrides = jsonDecode(
      await File('${candidate.path}/overrides.json').readAsString(),
    ) as Map<String, dynamic>;
    final result = <String, dynamic>{
      'status': 'ready',
      'token': _token,
      'createdAtMillis': 1760000000123,
      'paths': {for (final name in _names) name: '${candidate.path}/$name'},
      'parts': {
        for (final name in _names)
          name: {
            'bytes': await File('${candidate.path}/$name').length(),
            'sha256': 'a' * 64,
          },
      },
      'structure': {
        'nodes': 40,
        'depth': 8,
        'configurations': (configs['entries'] as List).length,
        'overrides': (overrides['entries'] as List).length,
      },
    };
    return changeDescriptor?.call(result) ?? result;
  }

  @override
  Future<void> checkOperation() async {
    if (expired) {
      throw PlatformException(
        code: 'expired',
        details: messages.operationFinished.toMap(),
      );
    }
  }

  @override
  Future<Map<String, dynamic>> backupPrepareExport({
    required String requestId,
    required int createdAtMillis,
    required int expectedEpoch,
    required Map<String, String> defaults,
  }) async {
    events.add('capture');
    this.defaults = defaults;
    await checkOperation();
    if (expectedEpoch != state.storageEpoch) {
      throw PlatformException(
        code: 'storage',
        details: messages.storageContextChanged.toMap(),
      );
    }
    await candidate.create(recursive: true);
    for (final name in _names) {
      final source = File('${stores.path}/$name');
      final target = File('${candidate.path}/$name');
      if (await source.exists()) {
        await source.copy(target.path);
      } else {
        await target.writeAsString(defaults[name]!);
      }
    }
    return {
      ...await descriptor(),
      'requestId': prepareReplyRequest ?? requestId,
    };
  }

  @override
  Future<Map<String, dynamic>> backupCandidate(String token) async {
    events.add('candidate');
    if (token != _token) return {'status': 'expired'};
    return descriptor();
  }

  @override
  Future<void> backupDiscard(String token) async {
    events.add('discard');
    discarded.add(token);
  }

  @override
  Future<AppSnapshot> snapshot() async => state;

  @override
  Future<void> stage(AppMessage message) async {}

  @override
  Future<void> stop() async {
    events.add('stop');
    if (!stopEntered.isCompleted) stopEntered.complete();
    final pending = stopping;
    if (pending != null) await pending.future;
    if (stopReleases) state = _stopped(epoch: state.storageEpoch);
  }

  @override
  Future<void> releasePreview() async {
    events.add('releasePreview');
    if (previewReleases) state = _stopped(epoch: state.storageEpoch);
  }

  @override
  Future<Map<String, dynamic>> backupInstall(
    String token, {
    required int expectedEpoch,
  }) async {
    events.add('install');
    if (!installEntered.isCompleted) installEntered.complete();
    final pending = installing;
    if (pending != null) await pending.future;
    if (failInstallTransport) throw const FormatException('private details');
    final response =
        installed ??
        {
          'committed': true,
          'rolledBack': false,
          'ready': true,
          'epoch': expectedEpoch + 1,
        };
    if (response['committed'] == true) {
      await stores.create(recursive: true);
      for (final name in _names) {
        await File('${candidate.path}/$name').copy('${stores.path}/$name');
      }
    }
    state = _stopped(epoch: response['epoch'] as int? ?? expectedEpoch);
    await duringInstall?.call();
    return response;
  }

  @override
  Future<void> refreshStrings() async {
    events.add('strings');
    await duringStrings?.call();
    if (failStrings) throw const FormatException('private language data');
  }

  @override
  Future<void> syncSchedules(List<Map<String, Object?>> targets) async {
    events.add('schedules');
    registrations.add(targets);
    await duringSchedule?.call();
    if (failSchedules) throw const FormatException('private scheduler data');
  }

  @override
  Future<bool> authorize() async {
    events.add('authorize');
    return authorizeResult;
  }

  @override
  Future<void> start({
    required String id,
    required int revision,
    required TunnelMode? mode,
  }) async {
    events.add('start');
    await checkOperation();
    starts.add(jsonDecode(await input.readAsString()) as Map<String, dynamic>);
    await duringStart?.call();
    if (failStart) throw const FormatException('private loader data');
    state = wrongRunningIdentity
        ? _stopped(epoch: state.storageEpoch)
        : _running(epoch: state.storageEpoch, id: id, revision: revision);
  }
}

Future<void> _writeStores(
  Directory directory, {
  bool empty = false,
  bool selected = true,
  String name = 'Restored configuration',
  String id = 'restored',
  String body = '\ufeff# retained\r\nrules: []\r\n',
  AppPreferences preferences = const AppPreferences(
    appearance: AppAppearance.dark,
    brand: BrandColor.jade,
    language: AppLanguage.en,
    reconnectOnRoutingChange: true,
  ),
}) async {
  await ConfigStore(directory).save(
    ConfigCollection(
      entries: empty
          ? []
          : [
              ConfigEntry(
                id: id,
                name: name,
                kind: ConfigKind.remote,
                source: 'https://user:credential@fixture.test/sub?secret=token',
                revision: 9,
                body: body,
                choices: const {
                  'Select': StrategyChoice(
                    type: StrategyType.select,
                    member: 'Stored member',
                  ),
                  'Automatic': StrategyChoice(
                    type: StrategyType.urlTest,
                    member: null,
                  ),
                },
                update: const UpdatePolicy(enabled: true, hours: 6),
              ),
            ],
      selectedId: !empty && selected ? id : null,
      mode: TunnelMode.global,
    ),
  );
  await OverrideStore(directory).save(
    empty
        ? []
        : const [
            OverrideEntry(
              id: 'local-role',
              name: 'Dedicated local',
              kind: ConfigKind.local,
              role: OverrideRole.localCustom,
              revision: 5,
              body: '# intentionally invalid YAML\n:\n[',
              enabled: false,
              mode: OverrideMode.replace,
            ),
            OverrideEntry(
              id: 'remote-part',
              name: 'Remote part',
              kind: ConfigKind.remote,
              source: 'https://fixture.test/part?credential=private',
              revision: 8,
              body: 'rules: ["DOMAIN,fixture.test,DIRECT"]',
              enabled: true,
              proxyName: 'Chosen target',
              addNoResolve: true,
              update: UpdatePolicy(enabled: true, hours: 12),
            ),
          ],
  );
  await PreferencesStore(directory).save(preferences);
}

Map<String, dynamic> _details(Map<String, Object?> result) =>
    Map<String, dynamic>.from(result['backupResult'] as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory stores;
  late Directory candidate;
  late File input;
  late _BackupPlatform platform;
  late BackupActions actions;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-actions-');
    stores = Directory('${root.path}/stores');
    candidate = Directory('${root.path}/candidate');
    input = File('${root.path}/run-input.json');
    platform = _BackupPlatform(stores, candidate, input);
    actions = BackupActions(stores, platform, input);
    await _writeStores(candidate);
  });
  tearDown(() async => root.delete(recursive: true));

  for (final action in ['prepareBackup', 'inspectBackup', 'restoreBackup']) {
    for (final part in ['config', 'override']) {
      for (final revision in [
        maxConfigRevision,
        maxConfigRevision + 1,
        4294967297,
      ]) {
        test(
          '$action validates $part revision=$revision before side effects',
          () async {
            final source = action == 'prepareBackup' ? stores : candidate;
            if (action == 'prepareBackup') await _writeStores(stores);
            final name = part == 'config'
                ? 'configurations.json'
                : 'overrides.json';
            final file = File('${source.path}/$name');
            final data =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
            final entry =
                (data['entries'] as List).last as Map<String, dynamic>;
            entry['revision'] = revision;
            await file.writeAsString(jsonEncode(data));
            final original = {
              for (final name in _names)
                name: await File('${source.path}/$name').readAsBytes(),
            };
            platform.state = _running();
            final result = await actions.execute({
              'action': action,
              'requestId': 'revision-boundary',
              'createdAtMillis': 1,
              'token': _token,
              'storageEpoch': 41,
            });
            final valid = revision == maxConfigRevision;
            expect(result['success'], valid);
            if (!valid) {
              expect((result['message'] as AppMessage).id, 'backupInvalid');
              expect(platform.events, isNot(contains('stop')));
              expect(platform.events, isNot(contains('install')));
              if (action != 'prepareBackup') {
                expect(await stores.exists(), isFalse);
              }
              for (final name in _names) {
                expect(
                  await File('${source.path}/$name').readAsBytes(),
                  original[name],
                );
              }
            }
          },
        );
      }
    }
  }

  test(
    'empty body is a saved value rather than a missing backup part',
    () async {
      await _writeStores(candidate, body: '');
      final result = await actions.execute({
        'action': 'restoreBackup',
        'token': _token,
        'storageEpoch': 41,
      });
      expect(result['success'], isTrue);
      expect((await ConfigStore(stores).read()).selected!.body, '');
    },
  );

  for (final over in [false, true]) {
    test(
      'individual body keeps its full 16 MiB UTF-8 budget including BOM; over=$over',
      () async {
        final body =
            String.fromCharCode(0xfeff) +
            'x' * (16 * 1024 * 1024 - 3 + (over ? 1 : 0));
        final file = File('${candidate.path}/configurations.json');
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        ((data['entries'] as List).single as Map)['body'] = body;
        await file.writeAsString(jsonEncode(data));
        if (over) platform.state = _running();
        final result = await actions.execute({
          'action': 'restoreBackup',
          'token': _token,
          'storageEpoch': 41,
        });
        expect(result['success'], !over);
        if (over) {
          expect(platform.events, ['candidate']);
          expect(await stores.exists(), isFalse);
        } else {
          final saved = (await ConfigStore(stores).read()).selected!.body;
          expect(saved == body, isTrue);
          expect(utf8.encode(saved), hasLength(16 * 1024 * 1024));
        }
      },
    );
  }

  test('committed cleanup warning remains visible without undoing independent followups', () async {
    platform.state = _running();
    platform.installed = {
      'committed': true,
      'rolledBack': false,
      'ready': true,
      'epoch': 42,
      'errorCode': 'committedCleanupFailed',
    };
    final result = await actions.execute({
      'action': 'restoreBackup',
      'token': _token,
      'storageEpoch': 41,
    });
    expect(result['success'], isFalse);
    expect((result['message'] as AppMessage).id, 'storageSyncWarning');
    expect(_details(result)['committed'], isTrue);
    expect(_details(result)['errorCode'], 'committedCleanupFailed');
    expect(_details(result)['settingsStatus'], 'done');
    expect(_details(result)['scheduleStatus'], 'done');
    expect(_details(result)['connectionStatus'], 'restored');
  });

  test(
    'retired preparation request is not promoted as the current snapshot',
    () async {
      platform.prepareReplyRequest = 'retired-request';
      final result = await actions.execute({
        'action': 'prepareBackup',
        'requestId': 'current-request',
        'createdAtMillis': 1760000000123,
        'storageEpoch': 41,
      });
      expect(result['success'], isFalse);
      expect(platform.discarded, [_token]);
      expect(await stores.exists(), isFalse);
    },
  );

  Future<Map<String, Object?>> restore([Map<String, dynamic>? extra]) =>
      actions.execute({
        'action': 'restoreBackup',
        'token': _token,
        'storageEpoch': 41,
        ...?extra,
      });

  test(
    'inspection fully validates three Stores, not the old damaged data',
    () async {
      await stores.create();
      for (final name in _names) {
        await File('${stores.path}/$name').writeAsString('damaged old $name');
      }
      final result = await actions.execute({
        'action': 'inspectBackup',
        'token': _token,
      });
      expect(result['success'], isTrue);
      final value = BackupCandidate.fromMap(_details(result));
      expect(value.summary.configurations, 1);
      expect(value.summary.overrides, 2);
      expect(value.summary.hasSelection, isTrue);
      expect(value.summary.selectedName, 'Restored configuration');
      expect(platform.events, ['candidate']);
      expect(jsonEncode(_details(result)), isNot(contains('credential')));
      expect(jsonEncode(_details(result)), isNot(contains(candidate.path)));
      expect(jsonEncode(_details(result)), isNot(contains('selectedId')));
      for (final name in _names) {
        expect(
          await File('${stores.path}/$name').readAsString(),
          'damaged old $name',
        );
      }
    },
  );

  test('empty stores prepare default complete parts without changing business files', () async {
    final result = await actions.execute({
      'action': 'prepareBackup',
      'requestId': 'prepare-fixture',
      'createdAtMillis': 1760000000123,
      'storageEpoch': 41,
    });
    expect(result['success'], isTrue);
    final value = BackupCandidate.fromMap(_details(result));
    expect(value.summary.configurations, 0);
    expect(value.summary.overrides, 0);
    expect(value.summary.hasSelection, isFalse);
    expect(await stores.exists(), isFalse);
    expect(platform.defaults!.keys, unorderedEquals(_names));
    expect((await ConfigStore(candidate).read()).mode, isNull);
    expect(
      (await PreferencesStore(candidate).read()).toJson(),
      const AppPreferences().toJson(),
    );
    expect(platform.discarded, isEmpty);
  });

  test('export validates captured semantics and preserves exact existing JSON bytes', () async {
    await _writeStores(stores);
    final file = File('${stores.path}/configurations.json');
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    data['unknownUntouched'] = {'raw': 'credential must remain in the archive'};
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(data)}\n',
    );
    final originals = {
      for (final name in _names)
        name: await File('${stores.path}/$name').readAsBytes(),
    };
    final result = await actions.execute({
      'action': 'prepareBackup',
      'requestId': 'prepare-fixture',
      'createdAtMillis': 1760000000123,
      'storageEpoch': 41,
    });
    expect(result['success'], isTrue);
    expect(_details(result)['status'], 'prepared');
    for (final name in _names) {
      expect(
        await File('${candidate.path}/$name').readAsBytes(),
        originals[name],
      );
      expect(await File('${stores.path}/$name').readAsBytes(), originals[name]);
    }
    expect(platform.events, ['capture']);
  });

  test('bad captured export is never published and is discarded', () async {
    await _writeStores(stores);
    final file = File('${stores.path}/configurations.json');
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    data['selectedId'] = 'missing';
    await file.writeAsString(jsonEncode(data));
    final original = await file.readAsBytes();
    final result = await actions.execute({
      'action': 'prepareBackup',
      'requestId': 'prepare-fixture',
      'createdAtMillis': 1760000000123,
      'storageEpoch': 41,
    });
    expect(result['success'], isFalse);
    expect((result['message'] as AppMessage).id, 'backupInvalid');
    expect(platform.discarded, [_token]);
    expect(await file.readAsBytes(), original);
    expect(platform.events, ['capture', 'discard']);
  });

  for (final problem in [
    'selected-missing',
    'duplicate-config-id',
    'duplicate-config-source',
    'missing-body',
    'null-body',
    'bad-choice',
    'bad-config-name',
    'bad-override-name',
    'duplicate-local-role',
    'bad-conversion-option',
    'bad-preferences',
  ]) {
    test(
      'full semantics reject $problem before Stop or installation',
      () async {
        final configs = File('${candidate.path}/configurations.json');
        final overrides = File('${candidate.path}/overrides.json');
        final preferences = File('${candidate.path}/preferences.json');
        final c =
            jsonDecode(await configs.readAsString()) as Map<String, dynamic>;
        final o =
            jsonDecode(await overrides.readAsString()) as Map<String, dynamic>;
        final p = jsonDecode(
          await preferences.readAsString(),
        ) as Map<String, dynamic>;
        final entries = c['entries'] as List;
        switch (problem) {
          case 'selected-missing':
            c['selectedId'] = 'not-present';
          case 'duplicate-config-id':
            entries.add({
              ...entries.first as Map,
              'source': 'https://other.test/config',
            });
          case 'duplicate-config-source':
            entries.add({...entries.first as Map, 'id': 'another'});
          case 'missing-body':
            (entries.first as Map).remove('body');
          case 'null-body':
            (entries.first as Map)['body'] = null;
          case 'bad-choice':
            (entries.first as Map)['choices'] = {
              'Group': {'type': 'select', 'member': null},
            };
          case 'bad-config-name':
            (entries.first as Map)['name'] = '🌐' * 21;
          case 'bad-override-name':
            ((o['entries'] as List).last as Map)['name'] = '中' * 27;
          case 'duplicate-local-role':
            (o['entries'] as List).add({
              ...((o['entries'] as List).first as Map),
              'id': 'duplicate-role',
            });
          case 'bad-conversion-option':
            ((o['entries'] as List).last as Map)['addNoResolve'] = null;
          case 'bad-preferences':
            p['access'] = 'only';
            p['packages'] = [];
        }
        await configs.writeAsString(jsonEncode(c));
        await overrides.writeAsString(jsonEncode(o));
        await preferences.writeAsString(jsonEncode(p));
        platform.state = _running();
        final result = await restore();
        expect(result['success'], isFalse);
        expect(_details(result)['committed'], isFalse);
        expect(platform.events, ['candidate']);
        expect(platform.state.running, isTrue);
        expect(await stores.exists(), isFalse);
      },
    );
  }

  test(
    'empty collections replace, never merge or retain the old selection',
    () async {
      await _writeStores(stores);
      await _writeStores(candidate, empty: true);
      final result = await restore();
      expect(result['success'], isTrue);
      expect(_details(result)['committed'], isTrue);
      expect((await ConfigStore(stores).read()).entries, isEmpty);
      expect((await ConfigStore(stores).read()).selectedId, isNull);
      expect(await OverrideStore(stores).read(), isEmpty);
      expect(platform.registrations.single, isEmpty);
      expect(platform.events, ['candidate', 'install', 'strings', 'schedules']);
      expect(platform.starts, isEmpty);
    },
  );

  test('restore replaces damaged old stores and preserves all candidate bytes and settings', () async {
    await stores.create();
    for (final name in _names) {
      await File('${stores.path}/$name').writeAsString('broken');
    }
    final result = await restore();
    expect(result['success'], isTrue);
    for (final name in _names) {
      expect(
        await File('${stores.path}/$name').readAsBytes(),
        await File('${candidate.path}/$name').readAsBytes(),
      );
    }
    final collection = await ConfigStore(stores).read();
    expect(collection.mode, TunnelMode.global);
    expect(collection.selected!.body, '\ufeff# retained\r\nrules: []\r\n');
    expect(collection.selected!.source, contains('credential'));
    expect(collection.selected!.choices['Automatic']!.member, isNull);
    final parts = await OverrideStore(stores).read();
    expect(parts.first.role, OverrideRole.localCustom);
    expect(parts.first.enabled, isFalse);
    expect(parts.first.mode, OverrideMode.replace);
    expect(parts.last.proxyName, 'Chosen target');
    expect(parts.last.addNoResolve, isTrue);
    expect(parts.last.update.hours, 12);
    expect(
      (await PreferencesStore(stores).read()).reconnectOnRoutingChange,
      isTrue,
    );
    expect(_details(result)['connectionStatus'], 'notStarted');
  });

  test('unavailable saved packages and invalid YAML do not invalidate a stopped restore', () async {
    await _writeStores(
      candidate,
      body: ':\n[ invalid YAML',
      preferences: const AppPreferences(
        access: ApplicationAccess.only,
        packages: ['not.installed.fixture'],
      ),
    );
    final result = await restore();
    expect(result['success'], isTrue);
    expect(
      (await ConfigStore(stores).read()).selected!.body,
      ':\n[ invalid YAML',
    );
    expect((await PreferencesStore(stores).read()).packages, [
      'not.installed.fixture',
    ]);
    expect(platform.starts, isEmpty);
  });

  test(
    'a running restore waits for true Stop release before installation',
    () async {
      platform.state = _running();
      platform.stopping = Completer<void>();
      final pending = restore();
      await platform.stopEntered.future;
      expect(platform.events, ['candidate', 'stop']);
      expect(await stores.exists(), isFalse);
      platform.stopping!.complete();
      final result = await pending;
      expect(result['success'], isTrue);
      expect(platform.events, [
        'candidate',
        'stop',
        'install',
        'strings',
        'schedules',
        'authorize',
        'start',
      ]);
      expect(_details(result)['connectionStatus'], 'restored');
      expect(
        platform.starts.single['body'],
        '\ufeff# retained\r\nrules: []\r\n',
      );
      expect(platform.state.configId, 'restored');
      expect(platform.state.revision, 9);
      expect(await input.exists(), isFalse);
    },
  );

  test(
    'preview must really release and never requests a VPN restart',
    () async {
      platform.state = _stopped(
        core: const CoreSnapshot(phase: 'READY', purpose: 'PREVIEW'),
      );
      final result = await restore();
      expect(result['success'], isTrue);
      expect(platform.events, [
        'candidate',
        'releasePreview',
        'install',
        'strings',
        'schedules',
      ]);
      expect(_details(result)['previewReleased'], isTrue);
      expect(_details(result)['connectionStatus'], 'notStarted');
    },
  );

  for (final preview in [false, true]) {
    test('unconfirmed old release refuses install; preview=$preview', () async {
      platform.state = preview
          ? _stopped(
              core: const CoreSnapshot(phase: 'READY', purpose: 'PREVIEW'),
            )
          : _running();
      platform.stopReleases = false;
      platform.previewReleases = false;
      final result = await restore();
      expect(result['success'], isFalse);
      expect(platform.events, isNot(contains('install')));
      expect(_details(result)['committed'], isFalse);
      expect(platform.discarded, isEmpty);
      expect(await stores.exists(), isFalse);
    });
  }

  for (final phase in ['STARTING', 'STOPPING', 'UNKNOWN']) {
    test(
      '$phase admission keeps the same candidate without stopping',
      () async {
        platform.state = AppSnapshot(
          phase: phase,
          storageReady: true,
          storageEpoch: 41,
        );
        final result = await restore();
        expect(result['success'], isFalse);
        expect(platform.events, ['candidate']);
        expect(platform.discarded, isEmpty);
        expect(await candidate.exists(), isTrue);
      },
    );
  }

  test(
    'same-ID/revision new epoch refuses the old confirmation scope',
    () async {
      platform.state = _running(epoch: 42);
      final result = await restore();
      expect(result['success'], isFalse);
      expect((result['message'] as AppMessage).id, 'storageContextChanged');
      expect(platform.events, ['candidate']);
      expect(platform.discarded, isEmpty);
    },
  );

  test(
    'Stop after commit preserves saved fact and prevents every restart call',
    () async {
      platform.state = _running();
      platform.duringInstall = () async => platform.expired = true;
      final result = await restore();
      final detail = _details(result);
      expect(detail['committed'], isTrue);
      expect(detail['status'], 'restored');
      expect(detail['epoch'], 42);
      expect(detail['connectionStatus'], 'cancelled');
      expect(detail['settingsStatus'], 'cancelled');
      expect(detail['scheduleStatus'], 'cancelled');
      expect((await ConfigStore(stores).read()).selectedId, 'restored');
      expect(platform.events, ['candidate', 'stop', 'install']);
      expect(platform.starts, isEmpty);
    },
  );

  test(
    'Stop between independent followups never drops commit or starts',
    () async {
      platform.state = _running();
      platform.duringStrings = () async => platform.expired = true;
      final result = await restore();
      final detail = _details(result);
      expect(detail['committed'], isTrue);
      expect(detail['settingsStatus'], 'done');
      expect(detail['scheduleStatus'], 'cancelled');
      expect(detail['connectionStatus'], 'cancelled');
      expect(platform.events, ['candidate', 'stop', 'install', 'strings']);
    },
  );

  test(
    'cancellation while install is pending waits for its actual commit result',
    () async {
      platform.state = _running();
      platform.installing = Completer<void>();
      var finished = false;
      final pending = restore().then((value) {
        finished = true;
        return value;
      });
      await platform.installEntered.future;
      expect(platform.events, ['candidate', 'stop', 'install']);
      platform.expired = true;
      await pumpEventQueue();
      expect(finished, isFalse);
      expect(platform.discarded, isEmpty);
      platform.installing!.complete();
      final result = await pending;
      expect(_details(result)['committed'], isTrue);
      expect(_details(result)['connectionStatus'], 'cancelled');
      expect((await ConfigStore(stores).read()).selectedId, 'restored');
    },
  );

  for (final failure in [
    'strings',
    'schedules',
    'start',
    'authorization',
    'identity',
  ]) {
    test(
      '$failure partial failure preserves restore and independent outcomes',
      () async {
        platform.state = _running();
        platform.failStrings = failure == 'strings';
        platform.failSchedules = failure == 'schedules';
        platform.failStart = failure == 'start';
        platform.authorizeResult = failure != 'authorization';
        platform.wrongRunningIdentity = failure == 'identity';
        final result = await restore();
        final detail = _details(result);
        expect(result['success'], isFalse);
        expect(detail['committed'], isTrue);
        expect(detail['status'], 'restored');
        expect(
          detail['settingsStatus'],
          failure == 'strings' ? 'failed' : 'done',
        );
        expect(
          detail['scheduleStatus'],
          failure == 'schedules' ? 'failed' : 'done',
        );
        expect(
          detail['connectionStatus'],
          const ['strings', 'schedules'].contains(failure)
              ? 'restored'
              : 'failed',
        );
        expect((await ConfigStore(stores).read()).selectedId, 'restored');
        expect(await input.exists(), isFalse);
      },
    );
  }

  test('no restored selection reports saved but cannot guess a fallback connection', () async {
    await _writeStores(candidate, selected: false);
    platform.state = _running();
    final result = await restore();
    expect(_details(result)['committed'], isTrue);
    expect(_details(result)['connectionStatus'], 'failed');
    final message = result['message'] as AppMessage;
    expect(message.id, 'backupRestoredWithIssue');
    expect((message.args['issue'] as AppMessage).id, 'backupConnectionFailed');
    expect(platform.starts, isEmpty);
    expect((await ConfigStore(stores).read()).selectedId, isNull);
  });

  test('rollback after stopping reports both unchanged data and stopped connection', () async {
    await _writeStores(stores, id: 'old-saved', name: 'Old saved');
    platform.state = _running();
    platform.installed = {
      'committed': false,
      'rolledBack': true,
      'ready': true,
      'epoch': 42,
    };
    final result = await restore();
    expect(_details(result)['committed'], isFalse);
    expect(_details(result)['rolledBack'], isTrue);
    expect(_details(result)['connectionStatus'], 'stopped');
    expect(platform.events, ['candidate', 'stop', 'install']);
    expect((await ConfigStore(stores).read()).selectedId, 'old-saved');
  });

  test(
    'lost install reply is unknown, never an assertion that no data changed',
    () async {
      platform.state = _running();
      platform.failInstallTransport = true;
      final result = await restore();
      expect(_details(result)['committed'], isNull);
      expect(_details(result)['status'], 'unconfirmed');
      expect(_details(result)['connectionStatus'], 'stopped');
      expect(platform.events, ['candidate', 'stop', 'install']);
    },
  );

  test(
    'known commit with closed storage cannot refresh, register or restart',
    () async {
      platform.state = _running();
      platform.installed = {
        'committed': true,
        'rolledBack': false,
        'ready': false,
        'epoch': 42,
        'errorCode': 'storageRecoveryFailed',
      };
      final result = await restore();
      expect(_details(result)['committed'], isTrue);
      expect(_details(result)['ready'], isFalse);
      expect(_details(result)['status'], 'restored');
      expect(result['success'], isFalse);
      expect(platform.events, ['candidate', 'stop', 'install']);
    },
  );

  for (final problem in [
    'path',
    'token',
    'missing-part',
    'nodes',
    'depth',
    'entries',
    'bytes',
    'count-disagreement',
  ]) {
    test('private descriptor $problem cannot bypass fixed admission', () async {
      platform.changeDescriptor = (value) {
        switch (problem) {
          case 'path':
            (value['paths'] as Map)['overrides.json'] =
                '${root.path}/unrelated.json';
          case 'token':
            value['token'] = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
          case 'missing-part':
            (value['paths'] as Map).remove('preferences.json');
          case 'nodes':
            (value['structure'] as Map)['nodes'] = 200001;
          case 'depth':
            (value['structure'] as Map)['depth'] = 33;
          case 'entries':
            (value['structure'] as Map)['configurations'] = 4097;
          case 'bytes':
            ((value['parts'] as Map)['preferences.json'] as Map)['bytes'] =
                1024 * 1024 + 1;
          case 'count-disagreement':
            (value['structure'] as Map)['configurations'] = 0;
        }
        return value;
      };
      final result = await restore({
        'paths': {'configurations.json': '/not/consumed'},
      });
      expect(result['success'], isFalse);
      expect(platform.events, ['candidate']);
      expect(await stores.exists(), isFalse);
    });
  }

  test(
    'forged tokens and arbitrary UI paths never reach candidate lookup',
    () async {
      final result = await restore({'token': '${candidate.path}/../outside'});
      expect(result['success'], isFalse);
      expect(platform.events, isEmpty);
    },
  );

  test('bounded names are displayed completely while opaque IDs remain in raw data', () async {
    final name = '长名称🌐' * 6;
    final id = 'opaque-id-' * 5000;
    await _writeStores(candidate, name: name, id: id);
    final result = await restore();
    expect(result['success'], isTrue);
    final detail = _details(result);
    final summary = BackupSummary.fromMap(
      Map<String, dynamic>.from(detail['summary'] as Map),
    );
    expect(summary.hasSelection, isTrue);
    expect(summary.selectedName, name);
    expect(
      utf8.encode(summary.selectedName!).length,
      lessThanOrEqualTo(maxBackupSummaryNameBytes),
    );
    expect(utf8.encode(jsonEncode(detail)).length, lessThan(2048));
    expect((await ConfigStore(stores).read()).selectedId, id);
    expect((await ConfigStore(stores).read()).selected!.name, name);
  });

  test(
    'full entry boundary is admitted and one extra is not silently omitted',
    () async {
      final file = File('${candidate.path}/configurations.json');
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final first = (data['entries'] as List).first as Map;
      data['selectedId'] = null;
      data['entries'] = [
        for (var index = 0; index < 4096; index++)
          {
            ...first,
            'id': 'entry-$index',
            'source': 'https://fixture.test/$index',
          },
      ];
      await file.writeAsString(jsonEncode(data));
      final accepted = await actions.execute({
        'action': 'inspectBackup',
        'token': _token,
      });
      expect(accepted['success'], isTrue);
      expect(
        BackupCandidate.fromMap(_details(accepted)).summary.configurations,
        4096,
      );
      (data['entries'] as List).add({
        ...first,
        'id': 'one-more',
        'source': 'https://fixture.test/extra',
      });
      await file.writeAsString(jsonEncode(data));
      final refused = await actions.execute({
        'action': 'inspectBackup',
        'token': _token,
      });
      expect(refused['success'], isFalse);
      expect((resultMessage(refused)).id, 'backupTooLarge');
      expect((await ConfigStore(candidate).read()).entries, hasLength(4097));
    },
  );
}

AppMessage resultMessage(Map<String, Object?> result) =>
    result['message'] as AppMessage;
