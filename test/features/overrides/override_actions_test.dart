import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_actions.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configs/action_fakes.dart';

class MemoryOverrideStore extends OverrideStore {
  MemoryOverrideStore(super.directory);
  List<OverrideEntry> entries = [];
  bool failSave = false;
  @override
  Future<List<OverrideEntry>> read() async => List.unmodifiable(entries);
  @override
  Future<void> save(List<OverrideEntry> value) async {
    if (failSave) throw const ConfigFailure(AppMessage('overridesSaveFailed'));
    entries = List.of(value);
  }
}

class OverridePlatform extends PlatformFake {
  @override
  Future<void> releasePreview() async => events.add('release-preview');
}

void main() {
  const local = OverrideEntry(
    id: 'local',
    name: 'Local',
    kind: ConfigKind.local,
    revision: 1,
    body: '{}',
    enabled: true,
  );
  const remote = OverrideEntry(
    id: 'remote',
    name: 'Remote',
    kind: ConfigKind.remote,
    source: 'https://example.test/part',
    revision: 1,
    body: 'rules: []',
    enabled: true,
  );
  late Directory directory;
  late MemoryOverrideStore store;
  late DownloadFake download;
  late OverridePlatform platform;
  late OverrideActions actions;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('override-actions-');
    store = MemoryOverrideStore(directory)..entries = [local, remote];
    download = DownloadFake();
    platform = OverridePlatform();
    actions = OverrideActions(
      store,
      download,
      platform,
      runInput: File('${directory.path}/owned.input'),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'unavailable running input preserves VPN and reports saved apply failure',
    () async {
      platform.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'main',
        revision: 1,
      );
      await actions.execute({
        'action': 'saveOverride',
        'id': 'local',
        'revision': 1,
        'body': 'dns: [',
      });
      expect(store.entries.first.body, 'dns: [');
      expect(store.entries.first.revision, 2);
      await actions.execute({
        'action': 'changeOverride',
        'id': 'local',
        'enabled': false,
        'mode': 'replace',
      });
      await actions.execute({
        'action': 'reorderOverrides',
        'ids': ['remote', 'local'],
      });
      await actions.execute({'action': 'deleteOverride', 'id': 'remote'});
      expect(store.entries.single.id, 'local');
      expect(platform.events, isEmpty);
      expect(actions.result['overrideStatus'], 'applyFailed');
      expect(actions.result['success'], isFalse);
    },
  );

  test(
    'enabled composition changes release preview, metadata changes do not',
    () async {
      platform.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(
          generation: 1,
          phase: 'READY',
          purpose: 'PREVIEW',
          configId: 'main',
          revision: 1,
        ),
      );
      await actions.execute({
        'action': 'changeOverride',
        'id': 'local',
        'name': 'Renamed',
      });
      expect(platform.events, isEmpty);
      await actions.execute({
        'action': 'changeOverride',
        'id': 'local',
        'mode': 'replace',
      });
      expect(platform.events, ['release-preview']);
      await actions.execute({
        'action': 'changeOverride',
        'id': 'local',
        'enabled': false,
      });
      expect(platform.events, hasLength(2));
      await actions.execute({
        'action': 'saveOverride',
        'id': 'local',
        'revision': 1,
        'body': 'dns: {}',
      });
      expect(platform.events, hasLength(2));
    },
  );

  test('write failure leaves existing body and preview untouched', () async {
    store.failSave = true;
    await expectLater(
      actions.execute({
        'action': 'saveOverride',
        'id': 'local',
        'revision': 1,
        'body': 'new',
      }),
      throwsA(isA<ConfigFailure>()),
    );
    expect(store.entries.first.body, '{}');
    expect(platform.events, isEmpty);
    expect(actions.result['overrideStatus'], 'notSaved');
  });

  test(
    'stale revision, missing id and incomplete reorder reject without mutation',
    () async {
      for (final command in [
        {'action': 'saveOverride', 'id': 'local', 'revision': 2, 'body': 'new'},
        {
          'action': 'saveOverride',
          'id': 'missing',
          'revision': 1,
          'body': 'new',
        },
        {
          'action': 'saveOverride',
          'id': 'remote',
          'revision': 1,
          'body': 'new',
        },
        {
          'action': 'reorderOverrides',
          'ids': ['local', 'local'],
        },
        {
          'action': 'reorderOverrides',
          'ids': ['local'],
        },
      ]) {
        await expectLater(
          actions.execute(command),
          throwsA(isA<ConfigFailure>()),
        );
      }
      expect(store.entries, [local, remote]);
    },
  );

  test(
    'failed remote update preserves old body, enabled state and running VPN',
    () async {
      platform.state = const AppSnapshot(phase: 'RUNNING');
      download.fail = true;
      await expectLater(
        actions.execute({'action': 'updateOverride', 'id': 'remote'}),
        throwsA(isA<ConfigFailure>()),
      );
      final saved = store.entries.last;
      expect(saved.body, remote.body);
      expect(saved.revision, remote.revision);
      expect(saved.enabled, isTrue);
      expect(saved.errorMessage, messages.downloadFailed);
      expect(platform.events, isEmpty);
      expect(actions.result['overrideStatus'], 'notSaved');
    },
  );

  test(
    'source change failure preserves original source and usable body',
    () async {
      download.fail = true;
      await expectLater(
        actions.execute({
          'action': 'changeOverrideSource',
          'id': 'remote',
          'source': 'https://other.test/part',
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect(store.entries.last.source, remote.source);
      expect(store.entries.last.body, remote.body);
      expect(store.entries.last.revision, remote.revision);
      expect(actions.result['overrideStatus'], 'notSaved');
      expect(platform.events, isEmpty);
    },
  );

  test(
    'HTTP source replacement downloads before publishing normally',
    () async {
      download.pending = Completer<String>();
      final pending = actions.execute({
        'action': 'updateOverride',
        'id': 'remote',
        'source': 'http://example.test/new',
      });
      await download.started.future;
      expect(store.entries, [local, remote]);
      download.pending!.complete('{}');
      await pending;
      expect(download.calls, 1);
      expect(store.entries.last.source, 'http://example.test/new');
      expect(store.entries.last.body, '{}');
    },
  );

  test('source replacement publishes source and original text together after download', () async {
    download.pending = Completer<String>();
    final original = remote.withUpdate(const UpdatePolicy(enabled: true));
    store.entries = [local, original];
    final pending = actions.execute({
      'action': 'changeOverrideSource',
      'id': 'remote',
      'source': 'https://other.test/part',
    });
    await download.started.future;
    expect(store.entries.last.toJson(), original.toJson());
    const body = '\u{feff}dns:\r\n  enable: true\n';
    download.pending!.complete(body);
    await pending;
    final saved = store.entries.last;
    expect(saved.source, 'https://other.test/part');
    expect(saved.body, body);
    expect(saved.revision, 2);
    expect(saved.enabled, isTrue);
    expect(saved.update.enabled, isTrue);
    expect(actions.result['overrideStatus'], 'saved');
    expect(platform.events, isEmpty);
  });

  test('source replacement enforces uniqueness and supports HTTP', () async {
    store.entries = [
      local,
      remote,
      const OverrideEntry(
        id: 'other',
        name: 'Other',
        kind: ConfigKind.remote,
        revision: 1,
        body: '{}',
        source: 'https://other.test/part',
      ),
    ];
    await expectLater(
      actions.execute({
        'action': 'changeOverrideSource',
        'id': 'remote',
        'source': 'https://other.test/part',
      }),
      throwsA(isA<ConfigFailure>()),
    );
    expect(download.calls, 0);
    expect(store.entries[1].source, remote.source);
    await actions.execute({
      'action': 'changeOverrideSource',
      'id': 'remote',
      'source': 'http://plain.test/part',
    });
    expect(download.calls, 1);
    expect(store.entries[1].source, 'http://plain.test/part');
  });

  test(
    'oversized source replacement and failed final save preserve old record',
    () async {
      download.body = 'x' * (16 * 1024 * 1024 + 1);
      await expectLater(
        actions.execute({
          'action': 'changeOverrideSource',
          'id': 'remote',
          'source': 'https://other.test/part',
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect(store.entries.last.toJson(), remote.toJson());
      download.body = '{}';
      store.failSave = true;
      await expectLater(
        actions.execute({
          'action': 'changeOverrideSource',
          'id': 'remote',
          'source': 'https://other.test/part',
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect(store.entries.last.toJson(), remote.toJson());
      expect(actions.result['overrideStatus'], 'notSaved');
      expect(platform.events, isEmpty);
    },
  );

  test(
    'late replacement cannot overwrite another source or duplicate ownership',
    () async {
      download.pending = Completer<String>();
      final pending = actions.execute({
        'action': 'changeOverrideSource',
        'id': 'remote',
        'source': 'https://other.test/part',
      });
      await download.started.future;
      store.entries = [local, remote.changed(source: 'https://new.test/part')];
      download.pending!.complete('new');
      await expectLater(pending, throwsA(isA<ConfigFailure>()));
      expect(store.entries.last.source, 'https://new.test/part');
      expect(store.entries.last.body, remote.body);
      expect(actions.result['overrideStatus'], 'notSaved');
    },
  );

  test(
    'first remote import leaves no placeholder while pending or after failure',
    () async {
      download.pending = Completer<String>();
      final pending = actions.execute({
        'action': 'importOverride',
        'name': 'New',
        'source': 'http://new.test/part',
      });
      await download.started.future;
      expect(store.entries, [local, remote]);
      download.pending!.completeError(ConfigFailure(messages.downloadFailed));
      await expectLater(pending, throwsA(isA<ConfigFailure>()));
      expect(store.entries, [local, remote]);
      expect(platform.events, isEmpty);
    },
  );

  test('same-value policy retries failed registration and body changes do not resync', () async {
    final command = {
      'action': 'setOverrideUpdate',
      'id': remote.id,
      'enabled': true,
      'hours': 12,
    };
    platform.failSchedules = true;
    await expectLater(
      actions.execute(command),
      throwsA(isA<PlatformException>()),
    );
    expect(actions.result['overrideStatus'], 'saved');
    expect(actions.result['scheduleStatus'], 'failed');
    expect(store.entries.last.update.enabled, isTrue);
    platform.failSchedules = false;
    await actions.execute(command);
    expect(platform.schedules, hasLength(2));
    expect(actions.result['scheduleStatus'], 'synced');
    await actions.execute({'action': 'updateOverride', 'id': remote.id});
    await actions.execute({
      'action': 'changeOverride',
      'id': remote.id,
      'name': 'Renamed',
    });
    download.fail = true;
    await expectLater(
      actions.execute({'action': 'updateOverride', 'id': remote.id}),
      throwsA(isA<ConfigFailure>()),
    );
    expect(platform.schedules, hasLength(2));
    expect(platform.events, isEmpty);
  });

  test('new source owner during download rejects late replacement', () async {
    const source = 'https://replacement.test/new';
    download.pending = Completer<String>();
    final pending = actions.execute({
      'action': 'changeOverrideSource',
      'id': remote.id,
      'source': source,
    });
    await download.started.future;
    store.entries = [
      local,
      remote,
      const OverrideEntry(
        id: 'new-owner',
        name: 'New owner',
        kind: ConfigKind.remote,
        source: source,
        revision: 1,
        body: 'other',
      ),
    ];
    download.pending!.complete('late');
    await expectLater(pending, throwsA(isA<ConfigFailure>()));
    expect(store.entries[1].toJson(), remote.toJson());
    expect(store.entries.last.source, source);
    expect(platform.events, isEmpty);
  });

  test('rename does not change content identity or restart', () async {
    platform.state = const AppSnapshot(phase: 'RUNNING');
    await actions.execute({
      'action': 'changeOverride',
      'id': 'remote',
      'name': 'Renamed',
    });
    expect(store.entries.last.name, 'Renamed');
    expect(store.entries.last.revision, remote.revision);
    expect(store.entries.last.body, remote.body);
    expect(platform.events, isEmpty);
  });

  test('late download cannot overwrite a changed source', () async {
    download.pending = Completer<String>();
    final pending = actions.execute({
      'action': 'updateOverride',
      'id': 'remote',
    });
    await download.started.future;
    store.entries = [local, remote.changed(source: 'https://new.test/part')];
    download.pending!.complete('new downloaded body');
    await expectLater(pending, throwsA(isA<ConfigFailure>()));
    expect(store.entries.last.source, 'https://new.test/part');
    expect(store.entries.last.body, remote.body);
    expect(store.entries.last.error, isNull);
  });

  test(
    'new local fragment is enabled but does not start a stopped VPN',
    () async {
      await actions.execute({
        'action': 'saveOverride',
        'name': ' New ',
        'body': '',
      });
      expect(store.entries.last.name, 'New');
      expect(store.entries.last.body, '');
      expect(store.entries.last.enabled, isTrue);
      expect(store.entries.last.revision, 1);
      expect(platform.events, isEmpty);
    },
  );
}
