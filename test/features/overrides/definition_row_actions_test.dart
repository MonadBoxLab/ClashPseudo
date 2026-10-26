import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'definition_forms_test.dart' as forms;

void main() {
  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 320.0, 1704.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'row counter changes do not move actions or following content $language/$width/$scale',
          (tester) async {
            final index = ValueNotifier<int>(98);
            addTearDown(index.dispose);
            await forms.openForm(
              tester,
              Scaffold(
                body: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ValueListenableBuilder<int>(
                    valueListenable: index,
                    builder: (context, value, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          key: const ValueKey('actions'),
                          child: DefinitionRowActions(
                            id: 'counter',
                            label: 'Members',
                            index: value,
                            onUp: () {},
                            onDown: () {},
                            onRemove: () {},
                          ),
                        ),
                        const Text(
                          'reading anchor',
                          key: ValueKey('reading-anchor'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              size: Size(width, 1136),
              locale: Locale(language),
              scaler: TextScaler.linear(scale),
            );
            final before = {
              for (final key in [
                'actions',
                'reading-anchor',
                'definition-up:counter',
                'definition-down:counter',
                'definition-remove:counter',
              ])
                key: tester.getRect(forms.keyed(key)),
            };
            for (final next in [99, 999, 4095, 98]) {
              index.value = next;
              for (final ms in [0, 16, 80]) {
                await tester.pump(Duration(milliseconds: ms));
                for (final entry in before.entries) {
                  expect(tester.getRect(forms.keyed(entry.key)), entry.value);
                }
                expect(tester.takeException(), isNull);
              }
            }
          },
        );
      }
    }
  }
}
