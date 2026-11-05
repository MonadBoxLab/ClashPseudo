import 'dart:convert';

import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/provenance_fakes.dart';
import '../support/strategy_fakes.dart' show previewCore, vpnCore;

Map<String, dynamic> _wire({
  CoreSnapshot core = previewCore,
  Object? provenance,
  String now = 'A',
}) => {
  'generation': core.generation,
  'configId': core.configId,
  'revision': core.revision,
  'purpose': core.purpose,
  'composition': core.composition,
  'mode': 'rule',
  'globalReferenced': false,
  'unrestored': [],
  'groups': [
    {
      'name': '出口',
      'type': 'select',
      'hidden': false,
      'now': now,
      'currentIdentity': '',
      'fixed': '',
      'icon': '',
      'members': [
        {'name': 'A', 'type': 'Socks5'},
        {'name': 'B', 'type': 'Direct'},
      ],
      'provenance': ?provenance,
    },
  ],
};

Map<String, dynamic> _sources(String first, {String? second}) =>
    definitionProvenanceWire([
      sourceContributorWire(
        id: 'first',
        name: first,
        role: 'localCustom',
        path: '/proxy-groups/1',
      ),
      if (second != null)
        sourceContributorWire(
          id: 'second',
          name: second,
          path: '/proxy-groups/0',
        ),
      sourceContributorWire(
        kind: 'config',
        id: 'one',
        revision: 1,
        name: 'Main without extra label',
        path: '/proxy-groups/2',
      ),
    ]);

void main() {
  for (final (rawType, type) in [
    ('Selector', StrategyType.select),
    ('URLTest', StrategyType.urlTest),
    ('Fallback', StrategyType.fallback),
    ('LoadBalance', StrategyType.loadBalance),
    ('select', StrategyType.select),
    ('url-test', StrategyType.urlTest),
    ('fallback', StrategyType.fallback),
    ('load-balance', StrategyType.loadBalance),
    ('UnknownGroup', null),
  ]) {
    test('runtime 类型 $rawType 保留原值并决定选择能力', () {
      final raw = _wire();
      (raw['groups'] as List).single['type'] = rawType;
      final snapshot = StrategySnapshot.fromMap(raw);
      final group = snapshot.find('出口')!;
      expect(group.rawType, rawType);
      expect(group.type, type);
      expect(group.selectable, type?.selectable ?? false);
      expect(group.automatic, type?.automatic ?? false);
      if (group.selectable) {
        final choice = StrategyChoice(type: group.type!, member: group.now);
        expect(choice.toJson(), {'type': type!.value, 'member': 'A'});
      }
    });
  }

  test('strategy real wire preserves provenance and full query identity', () {
    final raw = _wire(
      provenance: _sources('Z high-priority plugin', second: 'A lower plugin'),
    );
    final value = StrategySnapshot.fromMap(
      jsonDecode(jsonEncode(raw)) as Map<String, dynamic>,
    );
    final group = value.find('出口')!;
    expect(group.provenance!.plugins.map((source) => source.name), [
      'Z high-priority plugin',
      'A lower plugin',
    ]);
    expect(group.provenance!.plugins.map((source) => source.path), [
      '/proxy-groups/1',
      '/proxy-groups/0',
    ]);
    expect(group.provenance!.plugins.first.isLocalCustom, isTrue);
    expect(value.matches(previewCore), isTrue);
    expect(value.matches(vpnCore), isFalse);
    final source =
        ((raw['groups'] as List).single['provenance']['contributors'] as List)
                .first
            as Map;
    source['name'] = 'Latest disk rename';
    expect(group.provenance!.plugins.first.name, 'Z high-priority plugin');
  });

  test(
    'unknown/malformed strategy source cannot become a local-custom identity',
    () {
      for (final raw in [
        {'contributors': []},
        definitionProvenanceWire([
          {...sourceContributorWire(path: '/proxy-groups/0'), 'revision': 0},
        ]),
        definitionProvenanceWire([sourceContributorWire(path: '/proxies/0')]),
        definitionProvenanceWire([
          {
            ...sourceContributorWire(path: '/proxy-groups/0'),
            'kind': 'unknown',
          },
        ]),
      ]) {
        expect(
          () => StrategySnapshot.fromMap(_wire(provenance: raw)),
          throwsFormatException,
        );
      }
      expect(StrategySnapshot.fromMap(_wire()).find('出口')!.provenance, isNull);
    },
  );
}
