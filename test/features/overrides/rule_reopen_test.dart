import 'package:clash_pseudo/src/features/overrides/rule_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'definition_forms_test.dart' as forms;

void main() {
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
