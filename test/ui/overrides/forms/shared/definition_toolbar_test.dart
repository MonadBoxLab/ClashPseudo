import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form_type_page.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/rule_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/text_scalers.dart';

import 'definition_forms_test.dart' as forms;

void main() {
  final pages = <String, Widget Function()>{
    'proxy': () => ProxyFormPage(onSave: (_) async {}),
    'proxy type': () => const ProxyFormTypePage(selectedType: 'http'),
    'group': () => StrategyGroupFormPage(onSave: (_) async {}),
    'proxy provider': () =>
        ProviderFormPage(ruleProvider: false, onSave: (_, _) async {}),
    'rule provider': () =>
        ProviderFormPage(ruleProvider: true, onSave: (_, _) async {}),
    'rule': () => RuleFormPage(targets: const ['DIRECT'], onSave: (_) async {}),
    'edit proxy': () => ProxyFormPage(
      initialDefinition: const {
        'name': 'controlled',
        'type': 'http',
        'server': '192.0.2.1',
        'port': 18080,
      },
      onSave: (_) async {},
    ),
    'edit group': () => StrategyGroupFormPage(
      initialDefinition: const {
        'name': 'controlled',
        'type': 'select',
        'proxies': ['DIRECT'],
      },
      onSave: (_) async {},
    ),
    'edit proxy provider': () => ProviderFormPage(
      ruleProvider: false,
      initialName: 'controlled',
      initialDefinition: const {'type': 'file', 'path': 'controlled.yaml'},
      onSave: (_, _) async {},
    ),
    'edit rule provider': () => ProviderFormPage(
      ruleProvider: true,
      initialName: 'controlled',
      initialDefinition: const {
        'type': 'file',
        'behavior': 'domain',
        'path': 'controlled.yaml',
      },
      onSave: (_, _) async {},
    ),
    'edit rule': () => RuleFormPage(
      initialRule: 'DOMAIN,example.test,DIRECT',
      targets: const ['DIRECT'],
      onSave: (_) async {},
    ),
  };
  for (final entry in pages.entries) {
    for (final language in ['en', 'zh']) {
      for (final width in [280.0, 1704.0]) {
        for (final (label, scaler) in [
          ('1', TextScaler.noScaling),
          ('2', TextScaler.linear(2)),
          ('nonlinear', const NonlinearTextScaler()),
        ]) {
          testWidgets(
            'form title respects full scaler without clipping ${entry.key}/$language/$width/$label',
            (tester) async {
              await forms.openForm(
                tester,
                entry.value(),
                size: Size(width, 1136),
                locale: Locale(language),
                scaler: scaler,
              );
              final bar = find.byType(AppBar);
              final title = find
                  .descendant(of: bar, matching: find.byType(Text))
                  .first;
              final titleElement = tester.element(title);
              expect(
                MediaQuery.textScalerOf(titleElement).scale(22),
                closeTo(scaler.scale(22), .001),
              );
              final paragraph = tester.renderObject<RenderParagraph>(title);
              expect(paragraph.didExceedMaxLines, isFalse);
              final titleBounds = tester.getRect(title);
              final barBounds = tester.getRect(bar);
              expect(titleBounds.top, greaterThanOrEqualTo(barBounds.top));
              expect(titleBounds.bottom, lessThanOrEqualTo(barBounds.bottom));
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }
}
