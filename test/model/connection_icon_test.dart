import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
