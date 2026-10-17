import 'package:clash_pseudo/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('connection icon descriptor survives observation and serialization', () {
    final record = ConnectionRecord.fromMap({
      'id': 'fixture',
      'chains': ['DIRECT', 'entry'],
      'strategy': {'type': 'fallback', 'icon': 'http://fixture.test/icon.svg'},
    });
    final historical = record.observed(active: false);
    final restored = ConnectionRecord.fromMap(historical.toMap());
    expect(restored.strategyType, 'fallback');
    expect(restored.strategyIcon, 'http://fixture.test/icon.svg');
    expect(restored.active, isFalse);
    expect(restored.path, 'entry → DIRECT');
    final other = ConnectionRecord.fromMap({
      'id': 'fixture',
      'strategy': {'type': 'select', 'icon': 'https://other.test/icon.png'},
    });
    expect(other.strategyIcon, isNot(restored.strategyIcon));
    expect(restored.strategyType, 'fallback');
  });

  test(
    'missing and malformed optional icon descriptions use neutral fallback',
    () {
      for (final descriptor in [
        null,
        'invalid',
        12,
        {'type': 12, 'icon': false},
      ]) {
        final record = ConnectionRecord.fromMap({
          'id': 'fixture',
          'strategy': descriptor,
        });
        expect(record.strategyType, isEmpty);
        expect(record.strategyIcon, isEmpty);
      }
    },
  );

  test('current strategy protocol retains exact icon source', () {
    final group = StrategyGroup.fromMap({
      'name': 'entry',
      'type': 'select',
      'icon': 'https://fixture.test/icon?token=test',
      'hidden': false,
      'now': 'DIRECT',
      'fixed': '',
      'members': [],
    });
    expect(group.icon, 'https://fixture.test/icon?token=test');
    expect(group.rawType, 'select');
  });
}
