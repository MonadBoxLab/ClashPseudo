import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/features/configs/config_actions.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configs/action_fakes.dart';

void main() {
  late Directory directory;
  late ConfigStore store;
  late PlatformFake platform;
  late ConfigActions actions;
  const entry = ConfigEntry(
    id: 'one',
    name: 'one',
    source: 'https://example.test/one',
    revision: 1,
    body: 'mode: direct\nrules:\n  - MATCH,DIRECT\n',
  );
  const other = ConfigEntry(
    id: 'two',
    name: 'two',
    source: 'https://example.test/two',
    revision: 1,
    body: 'mode: direct\nrules:\n  - MATCH,DIRECT\n',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-mode-');
    store = ConfigStore(directory);
    platform = PlatformFake();
    actions = ConfigActions(
      store,
      DownloadFake(),
      platform,
      File('${directory.path}/run.yaml'),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test('stage failure after save reports partial completion without changing native', () async {
    platform.state = const AppSnapshot(phase: 'RUNNING', mode: TunnelMode.rule);
    platform.failModeStage = true;
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'direct'}),
      throwsA(
        isA<ConfigFailure>().having(
          (e) => e.message,
          'saved result',
          contains('已保存'),
        ),
      ),
    );
    expect((await store.read()).mode, TunnelMode.direct);
    expect(platform.events, isEmpty);
    expect(platform.state.mode, TunnelMode.rule);
  });

  test(
    'missing and invalid current mode are rejected without rewriting',
    () async {
      final file = File('${directory.path}/configurations.json');
      final data = {'version': 2, 'entries': <Object>[], 'selectedId': null};
      await file.writeAsString(jsonEncode(data));
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
      expect(await file.readAsString(), jsonEncode(data));
      for (final invalid in [null, 'follow', 0, true]) {
        final body = jsonEncode({...data, 'mode': invalid});
        await file.writeAsString(body);
        await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
        expect(await file.readAsString(), body);
      }
    },
  );

  test('stopped selection without configs persists all three modes without starting', () async {
    for (final mode in TunnelMode.values) {
      await actions.execute({'action': 'setMode', 'mode': mode.name});
      expect((await ConfigStore(directory).read()).mode, mode);
    }
    expect(platform.events, isEmpty);
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'follow'}),
      throwsFormatException,
    );
    expect((await store.read()).mode, TunnelMode.direct);
  });

  test(
    'running save precedes apply; failed apply retains preference not actual',
    () async {
      platform.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 7,
        mode: TunnelMode.rule,
      );
      platform.failMode = true;
      await expectLater(
        actions.execute({'action': 'setMode', 'mode': 'global'}),
        throwsA(
          isA<ConfigFailure>().having(
            (e) => e.message,
            'partial result',
            contains('已保存'),
          ),
        ),
      );
      expect((await store.read()).mode, TunnelMode.global);
      expect(platform.state.mode, TunnelMode.rule);
      expect(platform.events, ['mode:global:7']);
      platform.failMode = false;
      await actions.execute({'action': 'setMode', 'mode': 'global'});
      expect(platform.state.mode, TunnelMode.global);
      final count = platform.events.length;
      await actions.execute({'action': 'setMode', 'mode': 'global'});
      expect(platform.events.length, count);
    },
  );

  test('failed save and unknown phase never change native mode', () async {
    await store.save(ConfigCollection(entries: []));
    await Directory('${directory.path}/configurations.json.tmp').create();
    platform.state = const AppSnapshot(phase: 'RUNNING', mode: TunnelMode.rule);
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'global'}),
      throwsA(isA<ConfigFailure>()),
    );
    expect((await store.read()).mode, TunnelMode.rule);
    platform.state = const AppSnapshot();
    await expectLater(
      actions.execute({'action': 'setMode', 'mode': 'global'}),
      throwsA(isA<ConfigFailure>()),
    );
    expect(platform.events, isEmpty);
  });

  test('start, switch, import, update and delete preserve client mode and original body', () async {
    await store.save(
      ConfigCollection(
        entries: [entry, other],
        selectedId: entry.id,
        mode: TunnelMode.global,
      ),
    );
    await actions.execute({'action': 'start'});
    expect(platform.state.mode, TunnelMode.global);
    expect((await store.read()).selected!.body, entry.body);
    await actions.execute({'action': 'select', 'id': other.id});
    expect(platform.state.mode, TunnelMode.global);
    await actions.execute({
      'action': 'import',
      'source': other.source,
      'replace': true,
    });
    expect(platform.state.mode, TunnelMode.global);
    await actions.execute({
      'action': 'import',
      'source': 'https://example.test/new',
    });
    expect((await store.read()).mode, TunnelMode.global);
    await actions.execute({'action': 'delete', 'id': entry.id});
    expect((await store.read()).mode, TunnelMode.global);
    await actions.execute({'action': 'stop'});
    await actions.execute({'action': 'start'});
    expect(platform.state.mode, TunnelMode.global);
  });

  test('native invalid or missing mode preserves running phase and permits independent recovery', () {
    for (final value in [null, 'unknown', 3]) {
      final state = AppSnapshot.fromMap({'phase': 'RUNNING', 'mode': value});
      expect(state.running, isTrue);
      expect(state.mode, isNull);
      expect(state.modeError, isNotNull);
    }
    final stopped = AppSnapshot.fromMap({'phase': 'STOPPED', 'mode': 'global'});
    expect(stopped.mode, isNull);
    expect(stopped.modeError, isNull);
    expect(
      AppSnapshot.fromMap({'phase': 'RUNNING', 'mode': 'direct'}).mode,
      TunnelMode.direct,
    );
  });
}
