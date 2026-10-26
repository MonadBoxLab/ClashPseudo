import 'dart:convert';

import 'package:clash_pseudo/src/model/definition_provenance.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/provenance_fakes.dart';

void main() {
  test(
    'actual Go wire preserves contribution order and original definition paths',
    () {
      const actualWire = '''{"contributors":[
      {"kind":"plugin","id":"local","revision":3,"name":"Loaded custom","role":"localCustom","path":"/proxies/1"},
      {"kind":"plugin","id":"remote","revision":8,"name":"Loaded remote","path":"/proxies/0"},
      {"kind":"config","id":"main","revision":7,"name":"Loaded main","path":"/proxies/4"}
    ]}''';
      final decoded = jsonDecode(actualWire);
      final value = DefinitionProvenance.fromValue(
        decoded,
        section: 'proxies',
      )!;
      expect(value.contributors.map((item) => item.id), [
        'local',
        'remote',
        'main',
      ]);
      expect(value.plugins.map((item) => item.name), [
        'Loaded custom',
        'Loaded remote',
      ]);
      expect(value.plugins.first.isLocalCustom, isTrue);
      expect(value.plugins.last.isLocalCustom, isFalse);
      expect(value.contributors.map((item) => item.path), [
        '/proxies/1',
        '/proxies/0',
        '/proxies/4',
      ]);
      expect(value.contributors.last.kind, ContributorKind.config);
      expect(jsonDecode(jsonEncode(value)), decoded);
    },
  );

  test(
    'snapshot names do not refer back to mutable wire or saved metadata',
    () {
      final raw = definitionProvenanceWire([
        sourceContributorWire(
          name: 'Actually loaded name',
          role: 'localCustom',
        ),
      ]);
      final value = DefinitionProvenance.fromValue(raw)!;
      (raw['contributors'] as List).single['name'] = 'Latest saved name';
      (raw['contributors'] as List).add(sourceContributorWire(id: 'other'));
      expect(value.plugins.single.name, 'Actually loaded name');
      expect(value.plugins.single.role, 'localCustom');
      expect(value.contributors, hasLength(1));
      expect(
        () => value.contributors.add(value.contributors.single),
        throwsUnsupportedError,
      );
      final serialized = value.toJson();
      (serialized['contributors'] as List).single['name'] =
          'Changed output copy';
      expect(value.plugins.single.name, 'Actually loaded name');
    },
  );

  test('missing/anonymous main origins do not invent a plugin or editable identity', () {
    expect(DefinitionProvenance.fromValue(null), isNull);
    final value = DefinitionProvenance.fromValue({
      'contributors': [
        {'kind': 'config', 'path': '/rules/0'},
      ],
    })!;
    expect(value.plugins, isEmpty);
    expect(value.contributors.single.id, isNull);
    expect(value.contributors.single.revision, isNull);
    expect(value.contributors.single.name, isNull);
    expect(value.contributors.single.isLocalCustom, isFalse);
    expect(value.toJson(), {
      'contributors': [
        {'kind': 'config', 'path': '/rules/0'},
      ],
    });
  });

  test('same display names keep separate IDs and input priority', () {
    final value = DefinitionProvenance.fromValue(
      definitionProvenanceWire([
        sourceContributorWire(id: 'first', name: 'Same name', revision: 2),
        sourceContributorWire(id: 'second', name: 'Same name', revision: 9),
      ]),
    )!;
    expect(value.plugins.map((source) => source.id), ['first', 'second']);
    expect(value.plugins.map((source) => source.revision), [2, 9]);
  });

  for (final path in [
    '/proxies/0',
    '/proxy-groups/12',
    '/proxy-providers/provider~1~0',
    '/proxy-providers/',
    '/rule-providers/规则集',
    '/rules/7',
    '/sub-rules/branch~1~0/0',
  ]) {
    test('accepts original definition/rule pointer $path', () {
      final value = DefinitionProvenance.fromValue(
        definitionProvenanceWire([sourceContributorWire(path: path)]),
      )!;
      expect(value.plugins.single.path, path);
    });
  }

  for (final path in [
    '',
    'proxies/0',
    '/proxies',
    '/proxies/-1',
    '/proxies/01',
    '/proxies/+1',
    '/proxies/0/server',
    '/rules/1.0',
    '/sub-rules//0',
    '/sub-rules/branch/-1',
    '/proxy-providers/name~2',
    '/proxy-providers/name~',
    '/unknown/0',
  ]) {
    test('rejects malformed or leaf pointer $path', () {
      expect(
        () => DefinitionProvenance.fromValue(
          definitionProvenanceWire([sourceContributorWire(path: path)]),
        ),
        throwsFormatException,
      );
    });
  }

  test('response section must match the typed consumer context', () {
    expect(
      () => DefinitionProvenance.fromValue(
        definitionProvenanceWire([sourceContributorWire(path: '/rules/0')]),
        section: 'proxies',
      ),
      throwsFormatException,
    );
  });

  final invalidContributors = <Map<String, dynamic>>[
    {...sourceContributorWire(), 'kind': 'unknown'},
    {...sourceContributorWire(), 'kind': 'configuration'},
    {...sourceContributorWire(), 'id': ''},
    {...sourceContributorWire(), 'id': null},
    {...sourceContributorWire(), 'revision': 0},
    {...sourceContributorWire(), 'revision': -1},
    {...sourceContributorWire(), 'revision': 1.0},
    {...sourceContributorWire(), 'name': null},
    {...sourceContributorWire(), 'name': ''},
    {...sourceContributorWire(), 'name': '  '},
    {...sourceContributorWire(), 'name': 1},
    {...sourceContributorWire(), 'role': 'unknown'},
    {...sourceContributorWire(), 'role': true},
    {...sourceContributorWire(), 'kind': 'config', 'role': 'localCustom'},
    {
      ...sourceContributorWire(),
      'paths': ['/proxies/0/server'],
    },
    {'kind': 'config', 'revision': 1, 'path': '/rules/0'},
    {'kind': 'config', 'id': 'main', 'path': '/rules/0'},
    {'kind': 'config', 'name': 'Invented main', 'path': '/rules/0'},
  ];
  for (var index = 0; index < invalidContributors.length; index++) {
    test(
      'rejects malformed source metadata $index without a fallback identity',
      () {
        expect(
          () => DefinitionProvenance.fromValue(
            definitionProvenanceWire([invalidContributors[index]]),
          ),
          throwsFormatException,
        );
      },
    );
  }

  test('rejects duplicate identities, reordered main, old field tables and non-wire values', () {
    final plugin = sourceContributorWire();
    final main = sourceContributorWire(
      kind: 'config',
      id: 'main',
      name: 'Main',
    );
    for (final raw in <Object?>[
      [],
      '',
      {},
      {'contributors': []},
      {'contributors': null},
      {
        'contributors': ['plugin'],
      },
      {
        'contributors': [
          {1: 'not a string key'},
        ],
      },
      definitionProvenanceWire([plugin, plugin]),
      definitionProvenanceWire([
        plugin,
        {...plugin, 'revision': 4},
      ]),
      definitionProvenanceWire([main, plugin]),
      {
        ...definitionProvenanceWire([plugin]),
        'fields': {},
      },
    ]) {
      expect(() => DefinitionProvenance.fromValue(raw), throwsFormatException);
    }
  });
}
