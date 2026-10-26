import 'package:clash_pseudo/src/features/overrides/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import 'definition_forms_test.dart' as forms;

void main() {
  for (final (label, fields) in <(String, Map<String, Object?>)>[
    ('missing type', {}),
    ('null type', {'type': null}),
    ('numeric type', {'type': 7}),
    ('unknown type', {'type': 'future-group'}),
    ('container name', {'type': 'select', 'name': <String>[]}),
    (
      'non-string members',
      {
        'type': 'select',
        'proxies': [false],
      },
    ),
    ('map providers', {'type': 'select', 'use': <String, Object?>{}}),
    ('non-boolean option', {'type': 'select', 'lazy': 'false'}),
    (
      'non-integer option',
      {
        'type': 'select',
        'interval': [0],
      },
    ),
    ('container text option', {'type': 'select', 'icon': <String, Object?>{}}),
  ]) {
    testWidgets(
      'unrepresentable group original is readable without rewriting: $label',
      (tester) async {
        var saves = 0;
        final original = <String, Object?>{
          'name': 'preserved-group',
          ...fields,
          'future': {'retained': false},
        };
        Map<String, Object?>? saved;
        await forms.openForm(
          tester,
          StrategyGroupFormPage(
            initialDefinition: original,
            onSave: (definition) async {
              saves++;
              saved = definition;
            },
          ),
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(StrategyGroupFormPage)),
        );
        final field = fields.keys.lastOrNull ?? 'type';
        if (field == 'type' || field == 'name') {
          expect(find.text(strings.localYamlUnsupportedEdit), findsOneWidget);
          expect(find.text(field), findsOneWidget);
          expect(forms.keyed('definition-save:group'), findsNothing);
          expect(find.byType(TextField), findsNothing);
          expect(saves, 0);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(saves, 0);
        } else {
          final originalField = forms.keyed(
            'definition-original:group/$field',
            offstage: true,
          );
          await forms.expandAncestors(tester, originalField);
          expect(originalField, findsOneWidget);
          expect(
            find.descendant(
              of: originalField,
              matching: find.byType(TextField),
            ),
            findsNothing,
          );
          expect(find.text(strings.localYamlUnsupportedField), findsOneWidget);
          expect(find.text('group/$field'), findsOneWidget);
          await forms.tap(tester, forms.keyed('definition-save:group'));
          expect(saved, original);
          expect(saves, 1);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 1704.0]) {
      for (final (label, scaler) in [
        ('1', TextScaler.noScaling),
        ('2', TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          'unsupported group remains readable $language/$width/$label',
          (tester) async {
            var saves = 0;
            await forms.openForm(
              tester,
              StrategyGroupFormPage(
                initialDefinition: const {
                  'name': 'original',
                  'type': 'select',
                  'proxies': [false],
                  'interval': 'not-an-integer',
                },
                onSave: (_) async => saves++,
              ),
              size: Size(width, 1136),
              locale: Locale(language),
              scaler: scaler,
            );
            await forms.expandAncestors(
              tester,
              forms.keyed('definition-original:group/interval', offstage: true),
            );
            final maximum = switch (label) {
              '1' => 1600.0,
              '2' => 3200.0,
              _ => 2720.0,
            };
            final content = forms.keyed('definition-content');
            final scrollable = find
                .descendant(of: content, matching: find.byType(Scrollable))
                .first;
            final position = tester.state<ScrollableState>(scrollable).position;
            for (final nextWidth in [width, 280.0, 1704.0, width]) {
              tester.view.physicalSize = Size(nextWidth, 1136);
              for (final ms in [0, 16]) {
                await tester.pump(Duration(milliseconds: ms));
                final bounds = tester.getRect(content);
                expect(bounds.width, nextWidth.clamp(0, maximum));
                expect(bounds.center.dx, closeTo(nextWidth / 2, .01));
                expect(
                  tester.state<ScrollableState>(scrollable).position,
                  same(position),
                );
                expect(find.text('group/proxies'), findsOneWidget);
                expect(find.text('group/interval'), findsOneWidget);
                expect(find.byType(SelectableText), findsNWidgets(4));
                expect(forms.keyed('definition-save:group'), findsOneWidget);
                expect(saves, 0);
                expect(tester.takeException(), isNull);
              }
            }
          },
        );
      }
    }
  }

  for (final type in ['select', 'url-test', 'fallback', 'load-balance']) {
    testWidgets(
      'group shape admission keeps unknown fields and literal values $type',
      (tester) async {
        Map<String, Object?>? saved;
        final original = <String, Object?>{
          'name': 'original-group',
          'type': type,
          if (type != 'select') 'default-selected': 7,
          if (type != 'url-test') 'tolerance': <String>[],
          if (type != 'load-balance') ...{
            'strategy': false,
            'hash-key': <String, Object?>{},
          },
          'proxies': <String>[],
          'use': null,
          'lazy': false,
          'interval': 0,
          'icon': '',
          'future': {
            'retained': [false, 0, '', null],
          },
        };
        await forms.openForm(
          tester,
          StrategyGroupFormPage(
            initialDefinition: original,
            onSave: (definition) async => saved = definition,
          ),
        );
        await forms.tap(tester, forms.keyed('definition-save:group'));
        expect(saved, original);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
