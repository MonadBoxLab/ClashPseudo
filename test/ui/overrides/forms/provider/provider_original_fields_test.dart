import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/save_bar.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shared/definition_forms_test.dart' as forms;

void main() {
  for (final (id, ruleProvider, original, paths)
      in <(String, bool, Map<String, Object?>, List<String>)>[
        (
          'proxy leaf values',
          false,
          {
            'type': 'http',
            'url': 'https://fixture.invalid/provider',
            'path': ['original-path'],
            'interval': '300',
            'size-limit': 1.5,
            'header': {'X-Controlled': 'original-scalar'},
            'health-check': {
              'enable': 'true',
              'url': 7,
              'timeout': ['original-timeout'],
              'expected-status': false,
              'future': 0,
            },
            'override': {
              'tfo': 1,
              'ip-version': ['original-stack'],
              'routing-mark': '64',
              'proxy-name': [
                {'pattern': 1},
              ],
              'override-expr': 'original-expression',
              'future': <String, Object?>{},
            },
            'payload': [
              {'name': 'controlled-node', 'type': 'direct'},
            ],
            'future': [false, 0, ''],
          },
          [
            'path',
            'interval',
            'size-limit',
            'header',
            'health-check/enable',
            'health-check/url',
            'health-check/timeout',
            'health-check/expected-status',
            'override/tfo',
            'override/ip-version',
            'override/routing-mark',
            'override/proxy-name',
            'override/override-expr',
          ],
        ),
        (
          'proxy opaque branches',
          false,
          {
            'type': 'inline',
            'health-check': 'original-health',
            'override': [false, 0],
            'payload': 'original-payload',
          },
          ['health-check', 'override', 'payload'],
        ),
        (
          'rule collection and scalar kinds',
          true,
          {
            'type': 'http',
            'url': 'https://fixture.invalid/rules',
            'behavior': 1,
            'format': false,
            'path-in-bundle': ['original-bundle-path'],
            'payload': {'original': false},
            'header': {'X-Controlled': 'original-scalar'},
          },
          ['behavior', 'format', 'path-in-bundle', 'payload', 'header'],
        ),
        (
          'rule unknown option values',
          true,
          {
            'type': 'inline',
            'behavior': 'future-behavior',
            'format': 'future-format',
            'payload': ['controlled.fixture.test'],
          },
          ['behavior', 'format'],
        ),
      ]) {
    testWidgets(
      '$id preserves originals while unrelated fields remain editable',
      (tester) async {
        String? savedName;
        Map<String, Object?>? saved;
        await forms.openForm(
          tester,
          ProviderFormPage(
            ruleProvider: ruleProvider,
            initialName: 'controlled',
            initialDefinition: original,
            onSave: (name, definition) async {
              savedName = name;
              saved = definition;
            },
          ),
        );
        for (final path in paths) {
          final field = forms.keyed(
            'definition-original:provider/$path',
            offstage: true,
          );
          expect(field, findsOneWidget, reason: path);
          expect(tester.widget(field), isA<DefinitionOriginalField>());
        }
        await forms.text(tester, 'provider/name', 'renamed');
        await forms.tap(tester, forms.keyed('definition-save:provider'));
        expect(savedName, 'renamed');
        expect(saved, original);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'an unknown provider type keeps its original read-only boundary',
    (tester) async {
      var saves = 0;
      await forms.openForm(
        tester,
        ProviderFormPage(
          ruleProvider: true,
          initialName: 'controlled',
          initialDefinition: const {'type': 'future-source'},
          onSave: (_, _) async => saves++,
        ),
      );
      expect(find.byType(DefinitionSaveBar), findsNothing);
      expect(find.text('type'), findsOneWidget);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
