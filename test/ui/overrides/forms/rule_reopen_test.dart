import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/rule_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shared/definition_forms_test.dart' as forms;

void main() {
  group('draft scope and failure reading', () {
    for (final language in ['en', 'zh']) {
      for (final typed in [true, false]) {
        testWidgets(
          'draft stays local and full error is copied only from technical details $language/$typed',
          (tester) async {
            const raw =
                'native failure: unknown-field\nline 2 · 原始值\n{"future":false,"zero":0}\n';
            final failure = typed
                ? ConfigFailure(
                    messages.configSavedReconnectIncomplete.withDetail(raw),
                  )
                : StateError(raw);
            final expectedDetail = typed ? raw : failure.toString();
            String? copied;
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              (call) async {
                if (call.method == 'Clipboard.setData') {
                  copied = (call.arguments as Map)['text'] as String;
                }
                return null;
              },
            );
            addTearDown(
              () => tester.binding.defaultBinaryMessenger
                  .setMockMethodCallHandler(SystemChannels.platform, null),
            );
            var saves = 0;
            Object? saved;
            await forms.openForm(
              tester,
              RuleFormPage(
                initialRule: 'DOMAIN,kept.test,DIRECT',
                targets: const ['DIRECT'],
                onSave: (value) async {
                  saves++;
                  if (saves == 1) throw failure;
                  saved = value;
                },
              ),
              locale: Locale(language),
            );
            final strings = AppLocalizations.of(
              tester.element(find.byType(RuleFormPage)),
            );
            expect(
              find.byKey(const ValueKey('definition-draft-notice:rule')),
              findsNothing,
            );
            expect(saves, 0);
            final input = forms.keyed('definition-input:rule/value');
            final controller = tester.widget<TextField>(input).controller!;
            final before = controller.value;
            await tester.tap(
              find.byKey(const ValueKey('definition-save:rule')),
            );
            await tester.pumpAndSettle();
            expect(saves, 1);
            expect(find.byType(RuleFormPage), findsOneWidget);
            expect(find.byType(SnackBar), findsOneWidget);
            expect(find.text(strings.errorDetails), findsOneWidget);
            expect(find.textContaining('unknown-field'), findsNothing);
            await tester.tap(
              find
                  .descendant(
                    of: find.byType(SnackBar),
                    matching: find.byType(TextButton),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            expect(
              find.text(
                typed
                    ? strings.configSavedReconnectIncomplete
                    : strings.proxySaveFailed,
              ),
              findsOneWidget,
            );
            expect(find.textContaining('unknown-field'), findsNothing);
            expect(copied, isNull);
            await tester.tap(
              find.byKey(const ValueKey('operation-technical-details')),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<SelectableText>(
                    find.byKey(const ValueKey('operation-technical-text')),
                  )
                  .data,
              expectedDetail,
            );
            final copy = find.byKey(const ValueKey('operation-technical-copy'));
            await tester.ensureVisible(copy);
            await tester.pumpAndSettle();
            await tester.tap(copy);
            await tester.pumpAndSettle();
            expect(copied, expectedDetail);
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byType(RuleFormPage), findsOneWidget);
            expect(
              tester.widget<TextField>(input).controller,
              same(controller),
            );
            expect(controller.value, before);
            expect(saves, 1);
            await tester.tap(
              find.byKey(const ValueKey('definition-save:rule')),
            );
            await tester.pumpAndSettle();
            expect(saves, 2);
            expect(saved, 'DOMAIN,kept.test,DIRECT');
            expect(find.byType(RuleFormPage), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  for (final row in forms.fixtures['rules'] as List) {
    final type = row[0] as String;
    final payload = row[1] as String?;
    final initial = [type, ?payload, 'original target'].join(',');
    testWidgets('native $type original survives edit and reopen', (
      tester,
    ) async {
      var current = initial;
      for (final round in [0, 1, 2]) {
        String? saved;
        await forms.openForm(
          tester,
          RuleFormPage(
            initialRule: current,
            targets: const [],
            onSave: (value) async => saved = value,
          ),
        );
        if (round == 1) {
          await forms.text(
            tester,
            type == 'SUB-RULE' ? 'rule/sub-rule' : 'rule/target',
            'changed target',
          );
        }
        await forms.tap(tester, forms.keyed('definition-save:rule'));
        expect(tester.takeException(), isNull);
        expect(find.byType(RuleFormPage), findsNothing);
        expect(
          saved,
          round == 0 ? initial : [type, ?payload, 'changed target'].join(','),
        );
        current = saved!;
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('outer fields keep native comma payloads opaque', () {
    for (final raw in [
      'AND,((DOMAIN,first.test),(OR,((DST-PORT,443),(DST-PORT,8443)))),target',
      'OR,((DOMAIN,a.test),(DOMAIN,b.test)),target',
      'NOT,((DOMAIN,a.test)),target',
      'SUB-RULE,(AND,((DOMAIN,a.test),(DST-PORT,443))),child',
      r'DOMAIN-REGEX,^a,b[0-9]+$,target',
    ]) {
      final fields = ruleFormFields(raw);
      expect([fields.type, fields.value, fields.target].join(','), raw);
    }
    for (final target in ['src', 'no-resolve']) {
      final fields = ruleFormFields('IP-CIDR,192.0.2.0/24,$target');
      expect(fields.target, target);
      expect(fields.src, isFalse);
      expect(fields.noResolve, isFalse);
    }
    for (final raw in [
      'FINAL,target',
      'DOMAIN,first,target,unknown',
      'MATCH,target,unknown',
      'DOMAIN,missing-target',
    ]) {
      expect(() => ruleFormFields(raw), throwsFormatException);
    }
  });

  testWidgets('untouched parameter order and native spaces remain byte exact', (
    tester,
  ) async {
    const original = ' IP-CIDR , 192.0.2.0/24 , target , no-resolve , src ';
    String? saved;
    await forms.openForm(
      tester,
      RuleFormPage(
        initialRule: original,
        targets: const [],
        onSave: (value) async => saved = value,
      ),
    );
    expect(
      tester.widget<CheckboxListTile>(forms.keyed('rule-src')).value,
      isTrue,
    );
    expect(
      tester.widget<CheckboxListTile>(forms.keyed('rule-no-resolve')).value,
      isTrue,
    );
    await forms.tap(tester, forms.keyed('definition-save:rule'));
    expect(saved, original);
    expect(tester.takeException(), isNull);
  });
}
