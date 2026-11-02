import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_actions.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/config_action_fakes.dart';

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
    'repeated source creates a distinct row; replacement names its target',
    () async {
      await seed();
      await actions.execute({'action': 'import', 'source': first.source});
      var saved = await store.read();
      expect(saved.entries, hasLength(3));
      expect(saved.entries.last.id, isNot(first.id));
      expect(saved.entries.last.source, first.source);
      expect(saved.find(first.id)!.toJson(), first.toJson());
      expect(saved.find(second.id)!.toJson(), second.toJson());
      await expectLater(
        actions.execute({
          'action': 'import',
          'id': first.id,
          'source': first.source,
        }),
        throwsA(
          isA<ConfigFailure>().having(
            (failure) => failure.message.id,
            'message',
            'sourceSavedConfirmOverwrite',
          ),
        ),
      );
      expect(download.calls, 1);
      await actions.execute({
        'action': 'import',
        'id': first.id,
        'source': first.source,
        'replace': true,
      });
      saved = await store.read();
      expect(saved.entries, hasLength(3));
      expect(saved.selected!.body, download.body);
      expect(platform.events, isEmpty);
    },
  );

  test('accepted update preserves old body until download completes', () async {
    await seed();
    download.pending = Completer<String>();
    final operation = actions.execute({
      'action': 'import',
      'id': first.id,
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
          'id': first.id,
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
          'id': entry.id,
          'source': entry.source,
          'replace': true,
        }),
        throwsA(
          isA<ConfigFailure>()
              .having(
                (error) => error.message.id,
                'message',
                messages.configSaveFailed.id,
              )
              .having(
                (error) => error.message.detail,
                'original error',
                contains('configurations.json.tmp'),
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
          'id': first.id,
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
        'id': second.id,
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
    'source change may share a URL and changes only the specified record',
    () async {
      await seed(running: true);
      await actions.execute({
        'action': 'updateConfig',
        'id': first.id,
        'source': second.source,
      });
      final saved = await store.read();
      expect(saved.entries.map((entry) => entry.id), [first.id, second.id]);
      expect(saved.find(first.id)!.source, second.source);
      expect(saved.find(first.id)!.body, download.body);
      expect(saved.find(first.id)!.revision, 2);
      expect(saved.find(second.id)!.toJson(), second.toJson());
      expect(download.calls, 1);
      expect(platform.events, ['stop', 'start:first']);
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
        throwsA(isA<PlatformFailure>()),
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
        throwsA(isA<PlatformFailure>()),
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
      throwsA(isA<PlatformFailure>()),
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

  test('late response cannot overwrite the target revision changed during download', () async {
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
    'another ID sharing the source during download does not block the target',
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
      await pending;
      final saved = await store.read();
      expect(saved.entries.map((entry) => entry.id), [first.id, second.id]);
      expect(saved.selectedId, first.id);
      expect(saved.find(first.id)!.source, source);
      expect(saved.find(first.id)!.body, 'late');
      expect(saved.find(first.id)!.revision, first.revision + 1);
      expect(
        saved.find(second.id)!.toJson(),
        second.withSource(source).toJson(),
      );
      expect(platform.events, ['stop', 'start:first']);
      expect(platform.loaded['body'], 'late');
      expect(platform.state.configId, first.id);
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
        throwsA(
          isA<ConfigFailure>()
              .having(
                (failure) => failure.message.id,
                'saved result',
                'settingsSaved',
              )
              .having(
                (failure) => failure.message.detail,
                'original error',
                contains('schedule'),
              ),
        ),
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

  test('deleting the running selection leaves its input running and does not select a replacement', () async {
    await seed(running: true);
    final runningState = platform.state;
    final runningInput = Map<String, Object?>.from(platform.loaded);
    await actions.execute({'action': 'delete', 'id': first.id});
    var saved = await store.read();
    expect(saved.selectedId, isNull);
    expect(saved.entries.map((entry) => entry.toJson()), [second.toJson()]);
    expect(platform.state, same(runningState));
    expect(platform.loaded, runningInput);
    expect(actions.result['configStatus'], 'saved');
    expect(actions.result['scheduleStatus'], 'synced');
    await actions.execute({'action': 'delete', 'id': second.id});
    saved = await store.read();
    expect(saved.entries, isEmpty);
    expect(saved.selectedId, isNull);
    expect(platform.state, same(runningState));
    expect(platform.loaded, runningInput);
    expect(platform.scheduleKinds, ['config', 'config']);
    expect(platform.events, isEmpty);
  });
}
