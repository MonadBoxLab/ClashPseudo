import 'package:clash_pseudo/src/l10n/app_localizations.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/rule_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'definition_forms_test.dart' as forms;

void main() {
  for (final kind in [
    'proxy',
    'group',
    'proxy-provider',
    'rule-provider',
    'rule',
  ]) {
    for (final language in ['en', 'zh']) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets(
          'form keeps readable width and live draft $kind/$language/$scale',
          (tester) async {
            var pending = Completer<void>();
            Widget form() => switch (kind) {
              'proxy' => ProxyFormPage(
                initialDefinition: const {
                  'name': 'original',
                  'type': 'http',
                  'server': '127.0.0.1',
                  'port': 8080,
                },
                onSave: (_) => pending.future,
              ),
              'group' => StrategyGroupFormPage(
                initialDefinition: const {'name': 'original', 'type': 'select'},
                onSave: (_) => pending.future,
              ),
              'proxy-provider' || 'rule-provider' => ProviderFormPage(
                ruleProvider: kind == 'rule-provider',
                initialName: 'original',
                initialDefinition: {
                  'type': 'inline',
                  'payload': <String>[],
                  if (kind == 'rule-provider') 'behavior': 'domain',
                },
                onSave: (_, value) => pending.future,
              ),
              _ => RuleFormPage(
                initialRule: 'DOMAIN,example.test,DIRECT',
                targets: const ['DIRECT'],
                onSave: (_) => pending.future,
              ),
            };
            await forms.openForm(
              tester,
              form(),
              size: const Size(1704, 1136),
              locale: Locale(language),
              scaler: TextScaler.linear(scale),
            );
            final input = kind == 'proxy'
                ? find.descendant(
                    of: find.byKey(const ValueKey('proxy-field:common/name')),
                    matching: find.byType(TextField),
                  )
                : find.byKey(
                    ValueKey(
                      'definition-input:${switch (kind) {
                        'group' => 'group/name',
                        'rule' => 'rule/value',
                        _ => 'provider/name',
                      }}',
                    ),
                  );
            await tester.ensureVisible(input);
            await tester.enterText(input, 'retained draft 🌐');
            await tester.pump();
            final controller = tester.widget<TextField>(input).controller!;
            final selection = controller.selection;
            final focus = FocusManager.instance.primaryFocus;
            final content = find.byKey(const ValueKey('definition-content'));
            for (final width in [
              1599.0,
              1600.0,
              1601.0,
              1199.0,
              1200.0,
              1201.0,
              839.0,
              840.0,
              841.0,
              601.0,
              600.0,
              599.0,
              280.0,
              320.0,
              700.0,
              1704.0,
            ]) {
              tester.view.physicalSize = Size(width, 1136);
              for (final ms in [0, 16]) {
                await tester.pump(Duration(milliseconds: ms));
                final bounds = tester.getRect(content);
                expect(
                  bounds.width,
                  math.min(kind == 'rule' ? 840 : 1600 * scale, width),
                );
                expect(bounds.center.dx, closeTo(width / 2, .01));
                expect(
                  tester.widget<TextField>(input).controller,
                  same(controller),
                );
                expect(controller.text, 'retained draft 🌐');
                expect(controller.selection, selection);
                expect(FocusManager.instance.primaryFocus, same(focus));
                expect(tester.takeException(), isNull);
              }
            }
            FocusManager.instance.primaryFocus?.unfocus();
            final save = find.byKey(
              ValueKey(
                kind == 'proxy'
                    ? 'proxy-save'
                    : 'definition-save:${kind == 'group'
                          ? 'group'
                          : kind == 'rule'
                          ? 'rule'
                          : 'provider'}',
              ),
            );
            final targets = [content, find.byType(AppBar), save];
            final before = targets.map(tester.getRect).toList();
            await tester.tap(save);
            for (final ms in [0, 16, 80, 180]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(targets.map(tester.getRect).toList(), before);
              expect(controller.text, 'retained draft 🌐');
              expect(tester.takeException(), isNull);
            }
            pending.completeError(
              ConfigFailure(messages.overrideChangedReopen),
            );
            await tester.pumpAndSettle();
            expect(targets.map(tester.getRect).toList(), before);
            expect(controller.text, 'retained draft 🌐');
            pending = Completer<void>();
            final strings = AppLocalizations.of(tester.element(save));
            await tester.tap(find.widgetWithText(TextButton, strings.retry));
            await tester.pump();
            expect(targets.map(tester.getRect).toList(), before);
            pending.complete();
            await tester.pumpAndSettle();
            expect(content, findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
