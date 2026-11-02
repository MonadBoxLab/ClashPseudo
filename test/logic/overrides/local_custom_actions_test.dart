import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/local_custom_actions.dart';
import 'package:clash_pseudo/src/logic/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/logic/overrides/override_actions.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../../support/config_action_fakes.dart';

void main() {
  late Directory directory;
  late OverrideStore store;
  late OverrideActions overrides;
  late LocalCustomActions actions;
  late PlatformFake platform;
  const ordinary = OverrideEntry(
    id: 'ordinary',
    name: '本地自定义',
    kind: ConfigKind.local,
    revision: 1,
    body: 'rules: [MATCH,DIRECT]\n',
    enabled: true,
  );
  const custom = OverrideEntry(
    id: 'custom',
    name: 'Renamed by user',
    kind: ConfigKind.local,
    role: OverrideRole.localCustom,
    revision: 4,
    body: '# keep\nunknown: value\nrules: [MATCH,DIRECT]\n',
    mode: OverrideMode.replace,
    enabled: false,
  );

  Map<String, dynamic> add({OverrideEntry? entry}) => {
    'action': 'saveLocalDefinition',
    'id': entry?.id,
    'revision': entry?.revision,
    'name': '本地自定义',
    'section': 'proxies',
    'definition': {'name': 'Local node', 'type': 'direct'},
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('local-custom-actions-');
    store = OverrideStore(directory);
    platform = PlatformFake();
    overrides = OverrideActions(
      store,
      DownloadFake(),
      platform,
      runInput: File('${directory.path}/run.json'),
    );
    actions = LocalCustomActions(overrides);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'first GUI save creates one role at the top, not by display name',
    () async {
      await store.save([ordinary]);
      await actions.execute(add());
      final entries = await store.read();
      expect(entries, hasLength(2));
      final created = entries.first;
      expect(created.role, OverrideRole.localCustom);
      expect(created.id, isNot(ordinary.id));
      expect(created.enabled, isTrue);
      expect(created.mode, OverrideMode.prepend);
      expect(created.revision, 1);
      expect(entries.last.toJson(), ordinary.toJson());
      expect(
        (loadYaml(created.body)['proxies'] as YamlList).single['type'],
        'direct',
      );
      expect(overrides.result['targetId'], created.id);
      expect(overrides.result['overrideStatus'], 'saved');
      expect(platform.events, isEmpty);
    },
  );

  test(
    'later GUI save preserves disabled state, mode, name and position',
    () async {
      await store.save([ordinary, custom]);
      await actions.execute(add(entry: custom));
      final entries = await store.read();
      expect(entries.first.id, ordinary.id);
      final changed = entries.last;
      expect(changed.role, custom.role);
      expect(changed.id, custom.id);
      expect(changed.name, custom.name);
      expect(changed.enabled, isFalse);
      expect(changed.mode, OverrideMode.replace);
      expect(changed.revision, 5);
      expect(changed.body, contains(custom.body));
      expect(platform.events, isEmpty);
    },
  );

  test(
    'another first-save form cannot overwrite the newly created role',
    () async {
      await actions.execute(add());
      final before = await File('${directory.path}/overrides.json')
          .readAsBytes();
      await expectLater(actions.execute(add()), throwsA(isA<ConfigFailure>()));
      expect(
        await File('${directory.path}/overrides.json').readAsBytes(),
        before,
      );
    },
  );

  test('a deleted and recreated role rejects the old form identity', () async {
    await store.save([custom]);
    await overrides.execute({'action': 'deleteOverride', 'id': custom.id});
    await actions.execute(add());
    final fresh = (await store.read()).single;
    expect(fresh.id, isNot(custom.id));
    await expectLater(
      actions.execute(add(entry: custom)),
      throwsA(isA<ConfigFailure>()),
    );
    expect((await store.read()).single.toJson(), fresh.toJson());
  });

  test(
    'concurrent text revision rejects a GUI draft without changing text',
    () async {
      final newer = custom.withContent('rules: [MATCH,REJECT]\n');
      await store.save([newer]);
      await expectLater(
        actions.execute(add(entry: custom)),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await store.read()).single.toJson(), newer.toJson());
    },
  );

  test(
    'an ordinary plugin cannot be selected as the GUI write target',
    () async {
      await store.save([ordinary]);
      await expectLater(
        actions.execute(add(entry: ordinary)),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await store.read()).single.toJson(), ordinary.toJson());
    },
  );

  test(
    'deletion targets a direct rule index without removing duplicates',
    () async {
      final existing = custom.withContent(
        'rules:\n  - DOMAIN,example.test,DIRECT\n'
        '  - DOMAIN,example.test,DIRECT\n  - MATCH,DIRECT\n',
      );
      await store.save([existing]);
      final selected = LocalYamlEdit(existing.body)
          .definitions(LocalYamlSection.rules)[1];
      await actions.execute({
        'action': 'deleteLocalDefinition',
        'id': existing.id,
        'revision': existing.revision,
        'section': 'rules',
        'path': selected.path,
        'value': selected.value,
      });
      final saved = (await store.read()).single;
      expect(loadYaml(saved.body)['rules'], [
        'DOMAIN,example.test,DIRECT',
        'MATCH,DIRECT',
      ]);
      expect(saved.enabled, isFalse);
      expect(saved.role, OverrideRole.localCustom);
    },
  );

  test(
    'invalid target path or value cannot remove a nearby definition',
    () async {
      await store.save([custom]);
      for (final path in [
        ['rules', 1],
        ['proxies', 0],
      ]) {
        await expectLater(
          actions.execute({
            'action': 'deleteLocalDefinition',
            'id': custom.id,
            'revision': custom.revision,
            'section': 'rules',
            'path': path,
            'value': 'MATCH,DIRECT',
          }),
          throwsA(isA<ConfigFailure>()),
        );
        expect((await store.read()).single.toJson(), custom.toJson());
      }
    },
  );

  test(
    'bad existing YAML is retained instead of initializing a fresh body',
    () async {
      final broken = custom.withContent('dns: [');
      await store.save([broken]);
      await expectLater(
        actions.execute(add(entry: broken)),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await store.read()).single.toJson(), broken.toJson());
    },
  );

  test(
    'store rejects duplicate roles on save and read without clearing data',
    () async {
      await store.save([custom]);
      final duplicate = OverrideEntry.fromJson({
        ...custom.toJson(),
        'id': 'other-custom',
      });
      await expectLater(store.save([custom, duplicate]), throwsFormatException);
      expect((await store.read()).single.toJson(), custom.toJson());
      final corrupt = jsonEncode({
        'entries': [custom.toJson(), duplicate.toJson()],
      });
      final file = File('${directory.path}/overrides.json');
      await file.writeAsString(corrupt);
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
      expect(await file.readAsString(), corrupt);
    },
  );
}
