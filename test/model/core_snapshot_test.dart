import 'package:clash_pseudo/src/l10n/app_message.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = CoreSnapshot(
  generation: 9,
  phase: 'READY',
  configId: 'main',
  revision: 3,
  composition: 'loaded-composition',
  purpose: 'VPN',
);
const _wire = <String, dynamic>{
  'generation': 9,
  'configId': 'main',
  'revision': 3,
  'composition': 'loaded-composition',
  'purpose': 'VPN',
};

void main() {
  test('typed and wire identity use the complete lease fields', () {
    expect(_source.hasIdentity, isTrue);
    expect(_source.identity, (9, 'main', 3, 'loaded-composition', 'VPN'));
    expect(_source.matchesIdentity(_source), isTrue);
    expect(_source.matchesWireIdentity(_wire), isTrue);
    const recent = CoreSnapshot(
      generation: 9,
      phase: 'EMPTY',
      configId: 'main',
      revision: 3,
      composition: 'loaded-composition',
      purpose: 'VPN',
      logWindow: 'closed-window',
      error: AppMessage('coreContextUnconfirmed'),
    );
    expect(recent.identity, _source.identity);
    expect(_source.matchesIdentity(recent), isTrue);
  });

  for (final change in <Map<String, dynamic>>[
    {'generation': 10},
    {'configId': 'other'},
    {'revision': 4},
    {'composition': 'other-composition'},
    {'purpose': 'PREVIEW'},
  ]) {
    test(
      'changing one lease field invalidates both representations: $change',
      () {
        final wire = {..._wire, ...change};
        final other = CoreSnapshot.fromMap({'phase': 'READY', ...wire});
        expect(other.hasIdentity, isTrue);
        expect(_source.matchesIdentity(other), isFalse);
        expect(_source.matchesWireIdentity(wire), isFalse);
      },
    );
  }

  for (final field in _wire.keys) {
    test('missing wire $field invalidates the response', () {
      expect(
        _source.matchesWireIdentity(Map.of(_wire)..remove(field)),
        isFalse,
      );
    });
  }

  for (final field in ['generation', 'revision']) {
    test('integral floating-point $field is rejected at the wire boundary', () {
      expect(
        _source.matchesWireIdentity({
          ..._wire,
          field: (_wire[field] as int).toDouble(),
        }),
        isFalse,
      );
    });
  }

  for (final invalid in <Map<String, dynamic>>[
    {'generation': 0},
    {'generation': -1},
    {'configId': ''},
    {'configId': null},
    {'revision': 0},
    {'revision': null},
    {'composition': ''},
    {'composition': null},
    {'purpose': 'OTHER'},
    {'purpose': null},
  ]) {
    test('incomplete lease identity has no matching authority: $invalid', () {
      final source = CoreSnapshot.fromMap({
        'phase': 'READY',
        ..._wire,
        ...invalid,
      });
      expect(source.hasIdentity, isFalse);
      expect(source.matchesIdentity(source), isFalse);
      expect(source.matchesWireIdentity(_wire), isFalse);
    });
  }
}
