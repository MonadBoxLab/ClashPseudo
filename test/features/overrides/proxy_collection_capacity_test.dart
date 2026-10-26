import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proxy_form_test.dart' as forms;

void main() {
  for (final mapping in [false, true]) {
    testWidgets(
      'node ${mapping ? 'mapping' : 'scalar list'} does not mount all original inputs',
      (tester) async {
        await forms.openForm(
          tester,
          mapping ? 'http' : 'ssh',
          initialDefinition: {
            'name': 'controlled collection',
            'type': mapping ? 'http' : 'ssh',
            'server': '192.0.2.1',
            'port': 18080,
            if (mapping)
              'headers': {
                for (var i = 0; i < 128; i++)
                  'X-Controlled-$i': 'controlled-$i',
              }
            else ...{
              'username': 'controlled',
              'host-key': [
                for (var i = 0; i < 128; i++) 'controlled-host-key-$i',
              ],
            },
          },
          onSave: (_) async {},
        );
        expect(
          find.byType(TextField, skipOffstage: false).evaluate().length,
          lessThan(100),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
