import 'dart:io';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overrides/local_custom_actions.dart';
import 'package:clash_pseudo/src/features/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/features/overrides/override_actions.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../configs/action_fakes.dart';

void main() {
  late Directory directory;
  late OverrideStore store;
  late OverrideActions overrides;
  late LocalCustomActions actions;
  const entry = OverrideEntry(
    id: 'custom',
    name: 'Actual saved name',
    kind: ConfigKind.local,
    role: OverrideRole.localCustom,
    revision: 6,
    body: '# preserve\nunknown: true\n',
    enabled: false,
    mode: OverrideMode.replace,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('local-replacement-');
    store = OverrideStore(directory);
    overrides = OverrideActions(
      store,
      DownloadFake(),
      PlatformFake(),
      runInput: File('${directory.path}/run.json'),
    );
    actions = LocalCustomActions(overrides);
  });
  tearDown(() => directory.delete(recursive: true));

  for (final section in LocalYamlSection.values) {
    test(
      '${section.name} replaces one freshly saved draft atomically',
      () async {
        await store.save([entry]);
        Map<String, Object?> draft(String name) => switch (section) {
          LocalYamlSection.proxies => {
            'definition': {'name': name, 'type': 'direct'},
          },
          LocalYamlSection.strategyGroups => {
            'definition': {
              'name': name,
              'type': 'select',
              'proxies': ['DIRECT'],
            },
          },
          LocalYamlSection.proxyProviders || LocalYamlSection.ruleProviders => {
            'definitionName': name,
            'definition': {'type': 'inline', 'payload': <String>[]},
          },
          LocalYamlSection.rules => {'rule': 'DOMAIN,$name,DIRECT'},
        };
        await actions.execute({
          'action': 'saveLocalDefinition',
          'id': entry.id,
          'revision': entry.revision,
          'section': section.name,
          ...draft('old'),
        });
        final saved = (await store.read()).single;
        final target = LocalYamlEdit(saved.body).definitions(section).single;
        await actions.execute({
          'action': 'saveLocalDefinition',
          'id': saved.id,
          'revision': saved.revision,
          'section': section.name,
          ...draft('new'),
          'replacement': {'path': target.path, 'value': target.value},
        });
        final changed = (await store.read()).single;
        expect(changed.id, entry.id);
        expect(changed.revision, saved.revision + 1);
        expect(changed.name, entry.name);
        expect(changed.enabled, isFalse);
        expect(changed.mode, OverrideMode.replace);
        expect(changed.role, OverrideRole.localCustom);
        expect(changed.body, startsWith('# preserve\n'));
        expect(changed.body, endsWith('unknown: true\n'));
        expect(
          LocalYamlEdit(changed.body).definitions(section).single.value,
          section == LocalYamlSection.rules ? 'DOMAIN,new,DIRECT' : 'new',
        );
        expect(overrides.result['savedRevision'], changed.revision);
      },
    );
  }

  test(
    'in-place replacement keeps position, unknown fields and explicit values',
    () async {
      final original = entry.withContent('''# keep
proxy-groups:
  - name: before
    type: fallback
    proxies: [DIRECT]
  # target comment
  - name: target
    type: url-test
    url: https://example.test
    interval: 0
    lazy: false
    empty: ""
    unknown-field:
      nested: 0
  - name: after
    type: select
    proxies: [DIRECT]
''');
      await store.save([original]);
      final editor = LocalYamlEdit(original.body);
      final target = editor.definitionNamed(
        LocalYamlSection.strategyGroups,
        'target',
      )!;
      final value = editor.definitionValue(target);
      await actions.execute({
        'action': 'saveLocalDefinition',
        'id': original.id,
        'revision': original.revision,
        'section': 'strategyGroups',
        'definition': {...value, 'name': 'renamed'},
        'replacement': {
          'path': target.path,
          'value': target.value,
          'inPlace': true,
        },
      });
      final changed = (await store.read()).single;
      expect(changed.body, startsWith('# keep\nproxy-groups:\n'));
      expect(changed.body, contains('# target comment'));
      final parsed = LocalYamlEdit(changed.body);
      expect(
        parsed
            .definitions(LocalYamlSection.strategyGroups)
            .map((definition) => definition.value),
        ['before', 'renamed', 'after'],
      );
      final renamed = parsed.definitionNamed(
        LocalYamlSection.strategyGroups,
        'renamed',
      )!;
      expect(parsed.definitionValue(renamed), {...value, 'name': 'renamed'});
      expect(parsed.definitionValue(renamed)['interval'], 0);
      expect(parsed.definitionValue(renamed)['lazy'], false);
      expect(parsed.definitionValue(renamed)['empty'], '');
      expect(changed.mode, OverrideMode.replace);
      expect(changed.enabled, isFalse);
    },
  );

  for (final section in [
    LocalYamlSection.proxyProviders,
    LocalYamlSection.ruleProviders,
  ]) {
    test(
      'in-place ${section.name} preserves declaration and nested comments',
      () async {
        final original = entry.withContent('''# original
${section.key}:
  before: {type: inline, payload: []}
  # provider comment
  target:
    type: http
    url: 'https://example.test/provider' # keep URL style
    health-check:
      enable: false # explicit false
      interval: 0 # retain zero
      timeout: 5000 # change only this
      unknown: {nested: ''} # retain future field
  after: {type: inline, payload: []}
''');
        await store.save([original]);
        final editor = LocalYamlEdit(original.body);
        final target = editor.definitionNamed(section, 'target')!;
        final value = editor.definitionValue(target);
        const renamed = 'renamed: "name"';
        await actions.execute({
          'action': 'saveLocalDefinition',
          'id': original.id,
          'revision': original.revision,
          'section': section.name,
          'definitionName': renamed,
          'definition': {
            ...value,
            'health-check': {
              ...Map<String, Object?>.from(value['health-check'] as Map),
              'timeout': 6000,
            },
          },
          'replacement': {
            'path': target.path,
            'value': target.value,
            'inPlace': true,
          },
        });
        final saved = (await store.read()).single;
        final changed = LocalYamlEdit(saved.body);
        expect(changed.definitions(section).map((item) => item.value), [
          'before',
          renamed,
          'after',
        ]);
        expect(
          saved.body,
          contains("url: 'https://example.test/provider' # keep URL style"),
        );
        expect(saved.body, contains('enable: false # explicit false'));
        expect(saved.body, contains('interval: 0 # retain zero'));
        expect(
          saved.body,
          contains("unknown: {nested: ''} # retain future field"),
        );
        expect(saved.body, contains('# provider comment'));
        final definition = changed.definitionValue(
          changed.definitionNamed(section, renamed)!,
        );
        expect((definition['health-check'] as Map)['timeout'], 6000);
        expect(saved.enabled, isFalse);
        expect(saved.mode, OverrideMode.replace);
      },
    );
  }

  test(
    'in-place rule replacement keeps duplicate index and neighbor bytes',
    () async {
      final original = entry.withContent('''# original
rules:
  - DOMAIN,same.test,DIRECT # first
  - DOMAIN,same.test,DIRECT # second
  - MATCH,DIRECT # final
''');
      await store.save([original]);
      await actions.execute({
        'action': 'saveLocalDefinition',
        'id': original.id,
        'revision': original.revision,
        'section': 'rules',
        'rule': 'AND,((DOMAIN,a.test),(DST-PORT,443)),REJECT',
        'replacement': {
          'path': ['rules', 1],
          'value': 'DOMAIN,same.test,DIRECT',
          'inPlace': true,
        },
      });
      final saved = (await store.read()).single;
      expect(saved.body, contains('  - DOMAIN,same.test,DIRECT # first'));
      expect(saved.body, contains('  - MATCH,DIRECT # final'));
      expect(loadYaml(saved.body)['rules'], [
        'DOMAIN,same.test,DIRECT',
        'AND,((DOMAIN,a.test),(DST-PORT,443)),REJECT',
        'MATCH,DIRECT',
      ]);
    },
  );

  test(
    'in-place replacement on a stale body leaves the saved text unchanged',
    () async {
      await store.save([entry]);
      await actions.execute({
        'action': 'saveLocalDefinition',
        'id': entry.id,
        'revision': entry.revision,
        'section': 'strategyGroups',
        'definition': {'name': 'old', 'type': 'select'},
      });
      final saved = (await store.read()).single;
      final target = LocalYamlEdit(saved.body)
          .definitionNamed(LocalYamlSection.strategyGroups, 'old')!;
      await actions.execute({
        'action': 'saveLocalDefinition',
        'id': saved.id,
        'revision': saved.revision,
        'section': 'strategyGroups',
        'definition': {'name': 'new', 'type': 'select'},
        'replacement': {
          'path': target.path,
          'value': target.value,
          'inPlace': true,
        },
      });
      expect((await store.read()).single.revision, saved.revision + 1);
      await expectLater(
        actions.execute({
          'action': 'saveLocalDefinition',
          'id': saved.id,
          'revision': saved.revision,
          'section': 'strategyGroups',
          'definition': {'name': 'again', 'type': 'select'},
          'replacement': {'path': target.path, 'value': 'old', 'inPlace': true},
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect(
        LocalYamlEdit((await store.read()).single.body)
            .definitions(LocalYamlSection.strategyGroups)
            .single
            .value,
        'new',
      );
    },
  );

  test(
    'duplicate-name failure does not publish the transient removal',
    () async {
      final original = entry.withContent('''# keep
proxies:
  - {name: first, type: direct}
  - {name: second, type: reject}
''');
      await store.save([original]);
      final before = await File('${directory.path}/overrides.json')
          .readAsBytes();
      final target = LocalYamlEdit(original.body)
          .definitions(LocalYamlSection.proxies)
          .first;
      await expectLater(
        actions.execute({
          'action': 'saveLocalDefinition',
          'id': original.id,
          'revision': original.revision,
          'section': 'proxies',
          'definition': {'name': 'second', 'type': 'direct'},
          'replacement': {'path': target.path, 'value': target.value},
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect(
        await File('${directory.path}/overrides.json').readAsBytes(),
        before,
      );
      expect(overrides.result['overrideStatus'], 'notSaved');
      expect(overrides.result.containsKey('savedRevision'), isFalse);
    },
  );

  test(
    'replacement rule identity is the original path, not equal rule text',
    () async {
      final original = entry.withContent('''rules:
  - DOMAIN,same.test,DIRECT
  - DOMAIN,same.test,DIRECT
  - MATCH,DIRECT
''');
      await store.save([original]);
      await actions.execute({
        'action': 'saveLocalDefinition',
        'id': original.id,
        'revision': original.revision,
        'section': 'rules',
        'rule': 'DOMAIN,new.test,REJECT',
        'replacement': {
          'path': ['rules', 1],
          'value': 'DOMAIN,same.test,DIRECT',
        },
      });
      expect(loadYaml((await store.read()).single.body)['rules'], [
        'DOMAIN,new.test,REJECT',
        'DOMAIN,same.test,DIRECT',
        'MATCH,DIRECT',
      ]);
    },
  );

  test(
    'stale or forged replacement cannot change body or retain old saved result',
    () async {
      await store.save([entry]);
      await actions.execute({
        'action': 'saveLocalDefinition',
        'id': entry.id,
        'revision': entry.revision,
        'section': 'rules',
        'rule': 'MATCH,DIRECT',
      });
      final saved = (await store.read()).single;
      for (final replacement in <Object>[
        {
          'path': ['rules', 1],
          'value': 'MATCH,DIRECT',
        },
        {
          'path': ['rules', 0],
          'value': 'MATCH,REJECT',
        },
        {
          'path': ['proxies', 0],
          'value': 'MATCH,DIRECT',
        },
        {'path': 'rules/0', 'value': 'MATCH,DIRECT'},
        {
          'path': ['rules', 0],
        },
        {
          'path': ['rules', 0],
          'value': 'MATCH,DIRECT',
          'extra': true,
        },
      ]) {
        await expectLater(
          actions.execute({
            'action': 'saveLocalDefinition',
            'id': saved.id,
            'revision': saved.revision,
            'section': 'rules',
            'rule': 'MATCH,REJECT',
            'replacement': replacement,
          }),
          throwsA(isA<ConfigFailure>()),
        );
        expect((await store.read()).single.toJson(), saved.toJson());
        expect(overrides.result['overrideStatus'], 'notSaved');
        expect(overrides.result.containsKey('savedRevision'), isFalse);
      }
      await expectLater(
        actions.execute({
          'action': 'saveLocalDefinition',
          'id': saved.id,
          'revision': entry.revision,
          'section': 'rules',
          'rule': 'MATCH,REJECT',
          'replacement': {
            'path': ['rules', 0],
            'value': 'MATCH,DIRECT',
          },
        }),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await store.read()).single.toJson(), saved.toJson());
    },
  );

  test(
    'replacement cannot turn first-save or ordinary plugin into local role',
    () async {
      for (final target in <OverrideEntry?>[
        null,
        OverrideEntry.fromJson({...entry.toJson(), 'role': null}),
      ]) {
        await store.save([?target]);
        await expectLater(
          actions.execute({
            'action': 'saveLocalDefinition',
            'id': target?.id,
            'revision': target?.revision,
            'name': 'Local',
            'section': 'rules',
            'rule': 'MATCH,DIRECT',
            'replacement': {
              'path': ['rules', 0],
              'value': 'MATCH,REJECT',
            },
          }),
          throwsA(isA<ConfigFailure>()),
        );
        expect((await store.read()).map((entry) => entry.toJson()), [
          if (target != null) target.toJson(),
        ]);
      }
    },
  );
}
