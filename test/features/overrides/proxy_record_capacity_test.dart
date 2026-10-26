import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proxy_form_test.dart' as forms;

void main() {
  testWidgets('peer summaries do not mount every original input', (
    tester,
  ) async {
    await forms.openForm(
      tester,
      'wireguard',
      initialDefinition: {
        'name': 'controlled peers',
        'type': 'wireguard',
        'private-key': 'controlled-not-a-real-key',
        'peers': [
          for (var i = 0; i < 128; i++)
            {
              'server': '192.0.2.1',
              'port': 18000 + i,
              'public-key': 'controlled-public-$i',
              'future': {'id': i, 'enabled': false},
            },
        ],
      },
      onSave: (_) async {},
    );
    await forms.openGroup(tester, 'wireguard/peers');
    expect(
      find.byType(TextField, skipOffstage: false).evaluate().length,
      lessThan(100),
    );
    expect(tester.takeException(), isNull);
  });
}
