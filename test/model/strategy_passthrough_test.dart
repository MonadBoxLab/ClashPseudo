import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _original =
    'https://user:pass@fixture.test/?token=原文🙂\n'
    'Authorization: Bearer fixture';
const previewCore = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'PREVIEW',
  configId: 'one',
  revision: 1,
  composition: '["one",1]',
);

Map<String, dynamic> _wire({
  CoreSnapshot source = previewCore,
  bool stale = false,
}) => {
  'generation': source.generation,
  'configId': source.configId,
  'revision': source.revision,
  'composition': source.composition,
  'purpose': source.purpose,
  'mode': 'rule',
  'globalReferenced': false,
  'stale': stale,
  'groups': [
    {
      'name': '出口',
      'type': 'select',
      'hidden': false,
      'now': _original,
      'currentIdentity': 'member-identity',
      'fixed': '',
      'icon': '',
      'members': [
        {
          'name': _original,
          'type': 'Socks5',
          'future': [false, null],
        },
      ],
      'future': {'Authorization': _original},
    },
  ],
  'unrestored': <Object?>[],
  'future': {
    'values': [false, null, _original],
  },
};

void main() {
  group('complete protocol projection', () {
    test(
      'strategy projection retains the complete response and unknown fields',
      () {
        final wire = _wire(stale: true);
        final data = StrategySnapshot.fromMap(wire);
        expect(data.raw, wire);
        expect(data.stale, isTrue);
        expect(data.groups.single.now, _original);
        expect(data.groups.single.members.single.name, _original);
        expect(data.generation, previewCore.generation);
        expect(data.composition, previewCore.composition);
      },
    );
  });
}
