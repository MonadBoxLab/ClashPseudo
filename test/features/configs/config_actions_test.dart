import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/features/configs/config_actions.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_fakes.dart';

void main() {
  late Directory directory;
  late ConfigStore store;
  late ConfigActions actions;
  late DownloadFake download;
  late PlatformFake platform;
  const first = ConfigEntry(
    id: 'first',
    name: 'First',
    source: 'https://example.test/one',
    revision: 1,
    body: 'old',
  );
  const second = ConfigEntry(
    id: 'second',
    name: 'Second',
    source: 'https://example.test/two',
    revision: 1,
    body: 'candidate',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-actions-');
    store = ConfigStore(directory);
    download = DownloadFake();
    platform = PlatformFake()
      ..input = File('${directory.path}/work/input.yaml');
    actions = ConfigActions(
      store,
      download,
      platform,
      File('${directory.path}/work/input.yaml'),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> seed({bool running = false}) async {
    await store.save(
      ConfigCollection(entries: [first, second], selectedId: first.id),
    );
    if (running) {
      platform.load(first);
    }
  }

  test('first import saves and selects without parsing or starting', () async {
    download.body = '[invalid yaml';
    await actions.execute({'action': 'import', 'source': first.source});
    final saved = await store.read();
    expect(saved.selected!.body, '[invalid yaml');
    expect(platform.events, isEmpty);
  });

  test(
    'duplicate requires confirmation and never creates another row',
    () async {
      await seed();
      await expectLater(
        actions.execute({'action': 'import', 'source': first.source}),
        throwsA(isA<ConfigFailure>()),
      );
      expect(download.calls, 0);
      await actions.execute({
        'action': 'import',
        'source': first.source,
        'replace': true,
      });
      final saved = await store.read();
      expect(saved.entries.map((e) => e.id), ['first', 'second']);
      expect(saved.selected!.body, download.body);
    },
  );

  test('accepted update preserves old body until download completes', () async {
    await seed();
    download.pending = Completer<String>();
    final operation = actions.execute({
      'action': 'import',
      'source': first.source,
      'replace': true,
    });
    await download.started.future;
    expect((await ConfigStore(directory).read()).selected!.body, first.body);
    download.pending!.complete('replacement');
    await operation;
    expect((await store.read()).selected!.body, 'replacement');
  });

  test(
    'failed current update preserves old saved body and running VPN',
    () async {
      await seed(running: true);
      download.fail = true;
      await expectLater(
        actions.execute({
          'action': 'import',
          'source': first.source,
          'replace': true,
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await store.read()).selected!.toJson(), first.toJson());
      expect(platform.events, isEmpty);
      expect(platform.state.phase, 'RUNNING');
    },
  );

  for (final entry in [first, second]) {
    test('failed publication after download isolates ${entry.id}', () async {
      await seed(running: true);
      await Directory('${directory.path}/configurations.json.tmp').create();
      await expectLater(
        actions.execute({
          'action': 'import',
          'source': entry.source,
          'replace': true,
        }),
        throwsA(
          isA<ConfigFailure>().having(
            (error) => error.message,
            'message',
            messages.configSaveFailed,
          ),
        ),
      );
      expect(download.calls, 1);
      expect((await store.read()).find(entry.id)!.body, entry.body);
      expect(platform.events, isEmpty);
      expect(platform.state.phase, 'RUNNING');
    });
  }

  test(
    'failed update publication never attempts even an unconfirmable stop',
    () async {
      await seed(running: true);
      await Directory('${directory.path}/configurations.json.tmp').create();
      platform.failStop = true;
      await expectLater(
        actions.execute({
          'action': 'import',
          'source': first.source,
          'replace': true,
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect(platform.state.phase, 'RUNNING');
      expect(platform.events, isEmpty);
      expect(download.calls, 1);
    },
  );

  test('failed candidate update does not stop current VPN', () async {
    await seed(running: true);
    download.fail = true;
    await expectLater(
      actions.execute({
        'action': 'import',
        'source': second.source,
        'replace': true,
      }),
      throwsA(isA<ConfigFailure>()),
    );
    final saved = await store.read();
    expect(saved.selected!.body, 'old');
    expect(saved.find(second.id)!.body, second.body);
    expect(platform.events, isEmpty);
  });

  test(
    'source change rejects an existing source without writing or stopping',
    () async {
      await seed(running: true);
      final before = await File('${directory.path}/configurations.json')
          .readAsBytes();
      await expectLater(
        actions.execute({
          'action': 'updateConfig',
          'id': 'first',
          'source': second.source,
        }),
        throwsA(
          isA<ConfigFailure>().having(
            (e) => e.message,
            'existing name',
            messages.sourceUsedBy(second.name),
          ),
        ),
      );
      expect(
        await File('${directory.path}/configurations.json').readAsBytes(),
        before,
      );
      expect(download.calls, 0);
      expect(platform.events, isEmpty);
    },
  );

  test(
    'source change publishes source and body together after download',
    () async {
      await seed();
      download.pending = Completer<String>();
      const source = 'https://replacement.test/config';
      final pending = actions.execute({
        'action': 'updateConfig',
        'id': 'first',
        'source': source,
      });
      await download.started.future;
      final waiting = await store.read();
      expect(waiting.entries.map((entry) => entry.id), ['first', 'second']);
      expect(waiting.selected!.source, first.source);
      expect(waiting.selected!.name, 'First');
      expect(waiting.selected!.body, first.body);
      expect(waiting.selected!.revision, 1);
      expect(waiting.selected!.updatedAt, isNull);
      download.pending!.complete('');
      await pending;
      final saved = await store.read();
      expect(saved.selected!.id, 'first');
      expect(saved.selected!.source, source);
      expect(saved.selected!.body, '');
      expect(saved.selected!.revision, 2);
      expect(saved.selected!.updatedAt, isNotNull);
      expect(platform.events, isEmpty);
    },
  );

  test(
    'failed changed source preserves old saved record and actual running VPN',
    () async {
      await seed(running: true);
      await store.save(
        ConfigCollection(entries: [first, second], selectedId: 'second'),
      );
      download.fail = true;
      const source = 'https://replacement.test/config';
      await expectLater(
        actions.execute({
          'action': 'updateConfig',
          'id': 'first',
          'source': source,
        }),
        throwsA(isA<ConfigFailure>()),
      );
      final saved = await store.read();
      expect(saved.selectedId, 'second');
      expect(saved.find('first')!.toJson(), first.toJson());
      expect(saved.find('second')!.body, 'candidate');
      expect(platform.events, isEmpty);
    },
  );

  test('stopped selection saves without starting', () async {
    await seed();
    await actions.execute({'action': 'select', 'id': second.id});
    expect((await store.read()).selectedId, second.id);
    expect(platform.state.phase, 'STOPPED');
    expect(platform.events, isEmpty);
  });

  test('running selection stops before starting the saved target', () async {
    await seed(running: true);
    await actions.execute({'action': 'select', 'id': second.id});
    expect(platform.events, ['stop', 'start:second']);
    expect((await store.read()).selectedId, second.id);
    expect(platform.state.phase, 'RUNNING');
    expect(platform.state.configId, second.id);
    expect(await File('${directory.path}/work/input.yaml').exists(), isFalse);
  });

  test(
    'failed switch permits explicit startup of a selected valid config',
    () async {
      await seed(running: true);
      platform.failStart = true;
      await expectLater(
        actions.execute({'action': 'select', 'id': second.id}),
        throwsA(isA<PlatformException>()),
      );
      expect(platform.state.phase, 'STOPPED');
      await actions.execute({'action': 'select', 'id': first.id});
      expect(platform.events, ['stop', 'start:second']);
      platform.failStart = false;
      await actions.execute({'action': 'start'});
      expect(platform.events, [
        'stop',
        'start:second',
        'authorize',
        'start:first',
      ]);
      expect((await store.read()).selectedId, first.id);
      expect(platform.state.phase, 'RUNNING');
      expect(platform.state.configId, first.id);
      expect(await File('${directory.path}/work/input.yaml').exists(), isFalse);
    },
  );

  test(
    'failed target startup stays stopped without restoring old selection',
    () async {
      await seed(running: true);
      platform.failStart = true;
      await expectLater(
        actions.execute({'action': 'select', 'id': second.id}),
        throwsA(isA<PlatformException>()),
      );
      expect(platform.events, ['stop', 'start:second']);
      expect(platform.state.phase, 'STOPPED');
      expect((await store.read()).selectedId, second.id);
      expect(await File('${directory.path}/work/input.yaml').exists(), isFalse);
    },
  );

  test('unconfirmed stop retains saved target but never starts it', () async {
    await seed(running: true);
    platform.failStop = true;
    await expectLater(
      actions.execute({'action': 'select', 'id': second.id}),
      throwsA(isA<PlatformException>()),
    );
    expect(platform.events, ['stop']);
    expect((await store.read()).selectedId, second.id);
  });

  test('selection save failure leaves old VPN untouched', () async {
    await seed(running: true);
    await Directory('${directory.path}/configurations.json.tmp').create();
    await expectLater(
      actions.execute({'action': 'select', 'id': second.id}),
      throwsA(isA<ConfigFailure>()),
    );
    expect((await store.read()).selectedId, first.id);
    expect(platform.events, isEmpty);
    expect(platform.state.configId, first.id);
  });

  test(
    'selection input preparation failure leaves old VPN untouched',
    () async {
      await seed(running: true);
      await Directory('${directory.path}/work/input.yaml')
          .create(recursive: true);
      await expectLater(
        actions.execute({'action': 'select', 'id': second.id}),
        throwsA(isA<FileSystemException>()),
      );
      expect((await store.read()).selectedId, second.id);
      expect(platform.events, isEmpty);
      expect(platform.state.configId, first.id);
    },
  );

  test('failed first import and pending first import never create placeholder records', () async {
    download.pending = Completer<String>();
    final pending = actions.execute({
      'action': 'import',
      'source': first.source,
    });
    await download.started.future;
    expect((await store.read()).entries, isEmpty);
    download.pending!.completeError(ConfigFailure(messages.downloadFailed));
    await expectLater(pending, throwsA(isA<ConfigFailure>()));
    expect((await store.read()).entries, isEmpty);
    expect(platform.events, isEmpty);
  });

  test('late response cannot overwrite changed revision or claim a newly owned source', () async {
    await seed(running: true);
    download.pending = Completer<String>();
    final pending = actions.execute({'action': 'updateConfig', 'id': first.id});
    await download.started.future;
    await store.save(
      ConfigCollection(
        entries: [first.withContent('newer'), second],
        selectedId: first.id,
      ),
    );
    download.pending!.complete('late');
    await expectLater(pending, throwsA(isA<ConfigFailure>()));
    expect((await store.read()).selected!.body, 'newer');
    expect(platform.events, isEmpty);
  });

  test(
    'source ownership acquired during download rejects late publication',
    () async {
      await seed(running: true);
      const source = 'https://replacement.test/new';
      download.pending = Completer<String>();
      final pending = actions.execute({
        'action': 'updateConfig',
        'id': first.id,
        'source': source,
      });
      await download.started.future;
      await store.save(
        ConfigCollection(
          entries: [first, second.withSource(source)],
          selectedId: first.id,
        ),
      );
      download.pending!.complete('late');
      await expectLater(pending, throwsA(isA<ConfigFailure>()));
      final saved = await store.read();
      expect(saved.find(first.id)!.toJson(), first.toJson());
      expect(saved.find(second.id)!.source, source);
      expect(platform.events, isEmpty);
    },
  );

  test(
    'same-value schedule policy retries registration without reconnecting',
    () async {
      await seed(running: true);
      final command = {
        'action': 'setConfigUpdate',
        'id': first.id,
        'enabled': true,
        'hours': 12,
      };
      platform.failSchedules = true;
      await expectLater(
        actions.execute(command),
        throwsA(isA<PlatformException>()),
      );
      expect(actions.result['configStatus'], 'saved');
      expect(actions.result['scheduleStatus'], 'failed');
      expect((await store.read()).selected!.update.enabled, isTrue);
      platform.failSchedules = false;
      await actions.execute(command);
      expect(platform.schedules, hasLength(2));
      expect(actions.result['scheduleStatus'], 'synced');
      expect(platform.events, isEmpty);
      download.body = first.body;
      await actions.execute({'action': 'updateConfig', 'id': first.id});
      await actions.execute({
        'action': 'renameConfig',
        'id': first.id,
        'name': 'New name',
      });
      expect(platform.schedules, hasLength(2));
    },
  );

  test('shared stop remains available with unreadable storage and unknown snapshot', () async {
    await File('${directory.path}/configurations.json')
        .writeAsString('{broken');
    platform.state = const AppSnapshot();
    expect(await ConfigActions.stop(platform), messages.tunnelStopped);
    expect(platform.events, ['stop']);
    expect(
      await File('${directory.path}/configurations.json').readAsString(),
      '{broken',
    );
    platform.events.clear();
    platform.state = const AppSnapshot();
    expect(await actions.execute({'action': 'stop'}), messages.tunnelStopped);
    expect(platform.events, ['stop']);
  });

  test('cancelled authorization never starts core', () async {
    await seed();
    platform.grant = false;
    await expectLater(
      actions.execute({'action': 'start'}),
      throwsA(isA<ConfigFailure>()),
    );
    expect(platform.events, ['authorize']);
    expect(platform.state.phase, 'STOPPED');
  });

  test('deleting running current is rejected; stopped deletion selects first remainder', () async {
    await seed(running: true);
    await expectLater(
      actions.execute({'action': 'delete', 'id': first.id}),
      throwsA(isA<ConfigFailure>()),
    );
    platform.state = const AppSnapshot(phase: 'STOPPED');
    await actions.execute({'action': 'delete', 'id': first.id});
    expect((await store.read()).selectedId, second.id);
    await actions.execute({'action': 'delete', 'id': second.id});
    expect((await store.read()).selectedId, isNull);
    expect(platform.events, isEmpty);
  });
}
