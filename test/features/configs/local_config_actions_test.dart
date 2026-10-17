import 'dart:io';

import 'package:clash_pseudo/features/configs/config_actions.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'action_fakes.dart';

class _LocalPlatform extends PlatformFake {
  bool failRelease = false;

  @override
  Future<void> releasePreview() async {
    events.add('releasePreview');
    if (failRelease) throw StateError('Preview release unconfirmed');
    state = const AppSnapshot(phase: 'STOPPED');
  }
}

void main() {
  late Directory directory;
  late ConfigStore store;
  late _LocalPlatform platform;
  late ConfigActions actions;
  const local = ConfigEntry(
    id: 'local',
    name: 'Local',
    kind: ConfigKind.local,
    revision: 1,
    body: 'old',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-local-actions-');
    store = ConfigStore(directory);
    platform = _LocalPlatform();
    actions = ConfigActions(
      store,
      DownloadFake(),
      platform,
      File('${directory.path}/work/input.yaml'),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> seed({bool running = false}) async {
    await store.save(ConfigCollection(entries: [local], selectedId: local.id));
    if (running) {
      platform.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'local',
        revision: 1,
      );
    }
  }

  Future<String> save([String body = 'new']) => actions.execute({
    'action': 'saveLocal',
    'id': local.id,
    'revision': 1,
    'body': body,
  });

  test(
    'first local save accepts empty text and selects without startup',
    () async {
      await actions.execute({
        'action': 'saveLocal',
        'name': 'Empty',
        'body': '',
      });
      final saved = (await store.read()).selected!;
      expect(saved.kind, ConfigKind.local);
      expect(saved.source, isNull);
      expect(saved.body, '');
      expect(saved.updatedAt, isNotNull);
      expect(platform.events, isEmpty);
      expect(actions.result, {
        'configStatus': 'saved',
        'targetId': saved.id,
        'savedRevision': 1,
      });
    },
  );

  test('failed local write leaves running body untouched', () async {
    await seed(running: true);
    await Directory('${directory.path}/configurations.json.tmp').create();
    await expectLater(save(), throwsA(isA<ConfigFailure>()));
    expect((await store.read()).selected!.body, 'old');
    expect(platform.events, isEmpty);
    expect(actions.result['configStatus'], 'notSaved');
  });

  for (final stopFails in [false, true]) {
    test(
      'saved body survives ${stopFails ? 'stop' : 'start'} failure',
      () async {
        await seed(running: true);
        platform.failStop = stopFails;
        platform.failStart = !stopFails;
        await save();
        final saved = (await store.read()).selected!;
        expect(saved.body, 'new');
        expect(saved.revision, 2);
        expect(actions.result, {
          'configStatus': 'applyFailed',
          'targetId': local.id,
          'savedRevision': 2,
          'success': false,
        });
        expect(
          platform.events,
          stopFails ? ['stop'] : ['stop', 'authorize', 'start:local'],
        );
      },
    );
  }

  test('running save reports applied only after successful startup', () async {
    await seed(running: true);
    await save();
    expect(actions.result['configStatus'], 'applied');
    expect(platform.state.revision, 2);
    expect(platform.events, ['stop', 'authorize', 'start:local']);
  });

  test(
    'rename preserves revision and does not invalidate open editor',
    () async {
      await seed();
      await actions.execute({
        'action': 'renameConfig',
        'id': local.id,
        'name': 'Renamed',
      });
      final renamed = (await store.read()).selected!;
      expect(renamed.revision, 1);
      expect(renamed.updatedAt, isNull);
      await save();
      expect((await store.read()).selected!.name, 'Renamed');
    },
  );

  test(
    'stale revision and deleted target never overwrite or recreate',
    () async {
      await seed();
      await save();
      await expectLater(save('stale'), throwsA(isA<ConfigFailure>()));
      expect((await store.read()).selected!.body, 'new');
      await actions.execute({'action': 'delete', 'id': local.id});
      await expectLater(save(), throwsA(isA<ConfigFailure>()));
      expect((await store.read()).entries, isEmpty);
    },
  );

  for (final failRelease in [false, true]) {
    test(
      'saved local body invalidates its old preview failure=$failRelease',
      () async {
        await seed();
        platform.state = const AppSnapshot(
          phase: 'STOPPED',
          core: CoreSnapshot(
            phase: 'READY',
            purpose: 'PREVIEW',
            generation: 3,
            configId: 'local',
            revision: 1,
          ),
        );
        platform.failRelease = failRelease;
        await save();
        expect((await store.read()).selected!.body, 'new');
        expect(actions.result['savedRevision'], 2);
        expect(
          actions.result['configStatus'],
          failRelease ? 'applyFailed' : 'saved',
        );
        expect(platform.events, ['releasePreview']);
      },
    );
  }

  test(
    'saving local body does not release another configuration preview',
    () async {
      await seed();
      platform.state = const AppSnapshot(
        phase: 'STOPPED',
        core: CoreSnapshot(
          phase: 'READY',
          purpose: 'PREVIEW',
          generation: 3,
          configId: 'other',
          revision: 1,
        ),
      );
      await save();
      expect(actions.result['configStatus'], 'saved');
      expect(platform.events, isEmpty);
    },
  );

  test('actual running identity applies even when selection differs', () async {
    await seed(running: true);
    await store.save(ConfigCollection(entries: [local], selectedId: null));
    await save();
    expect(actions.result['configStatus'], 'applied');
    expect((await store.read()).selectedId, isNull);
  });
}
