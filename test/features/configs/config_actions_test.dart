import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/features/configs/config_actions.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/services.dart';
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
    platform = PlatformFake();
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
      platform.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'first',
        revision: 1,
      );
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

  test(
    'accepted update retires the old body before download completes',
    () async {
      await seed();
      download.pending = Completer<String>();
      final operation = actions.execute({
        'action': 'import',
        'source': first.source,
        'replace': true,
      });
      await download.started.future;
      expect((await ConfigStore(directory).read()).selected!.body, isNull);
      download.pending!.complete('replacement');
      await operation;
      expect((await store.read()).selected!.body, 'replacement');
    },
  );

  test(
    'failed current update invalidates old body and stops running VPN',
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
      expect((await store.read()).selected!.body, isNull);
      expect(platform.events, ['stop']);
      expect(platform.state.phase, 'STOPPED');
    },
  );

  for (final entry in [first, second]) {
    test('failed initial update write isolates ${entry.id}', () async {
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
            contains('旧记录未修改'),
          ),
        ),
      );
      expect(download.calls, 0);
      expect((await store.read()).find(entry.id)!.body, entry.body);
      expect(platform.events, entry == first ? ['stop'] : isEmpty);
      expect(platform.state.phase, entry == first ? 'STOPPED' : 'RUNNING');
    });
  }

  test('failed update write does not hide unconfirmed stop', () async {
    await seed(running: true);
    await Directory('${directory.path}/configurations.json.tmp').create();
    platform.failStop = true;
    await expectLater(
      actions.execute({
        'action': 'import',
        'source': first.source,
        'replace': true,
      }),
      throwsA(isA<PlatformException>()),
    );
    expect(platform.state.phase, 'UNKNOWN');
    expect(download.calls, 0);
  });

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
    expect(saved.find(second.id)!.body, isNull);
    expect(platform.events, isEmpty);
  });

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
    expect(platform.events, ['stop', 'authorize', 'start:second']);
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
      expect(platform.events, ['stop', 'authorize', 'start:second']);
      platform.failStart = false;
      await actions.execute({'action': 'start'});
      expect(platform.events, [
        'stop',
        'authorize',
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
      expect(platform.events, ['stop', 'authorize', 'start:second']);
      expect(platform.state.phase, 'STOPPED');
      expect((await store.read()).selectedId, second.id);
      expect(await File('${directory.path}/work/input.yaml').exists(), isFalse);
    },
  );

  test('unconfirmed stop does not select or start target', () async {
    await seed(running: true);
    platform.failStop = true;
    await expectLater(
      actions.execute({'action': 'select', 'id': second.id}),
      throwsA(isA<PlatformException>()),
    );
    expect(platform.events, ['stop']);
    expect((await store.read()).selectedId, first.id);
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
