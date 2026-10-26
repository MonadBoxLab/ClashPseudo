import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';
import 'package:clash_pseudo/src/features/overrides/provider_form.dart';
import 'package:clash_pseudo/src/features/overrides/proxy_form.dart';
import 'package:clash_pseudo/src/features/overrides/rule_form.dart';
import 'package:clash_pseudo/src/features/overrides/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import 'definition_forms_test.dart' as forms;

void main() {
  for (final language in ['en', 'zh']) {
    testWidgets(
      'only the visible proxy type and bool value have semantics $language',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await forms.openForm(
            tester,
            ProxyFormPage(onSave: (_) async {}),
            locale: Locale(language),
          );
          final type = tester
              .getSemantics(forms.keyed('proxy-select-type'))
              .getSemanticsData()
              .label;
          expect(type, contains('HTTP'));
          for (final hidden in [
            'SOCKS5',
            'SSH',
            'Shadowsocks',
            'WireGuard',
            'reject',
          ]) {
            expect(type, isNot(contains(hidden)));
          }
          final strings = AppLocalizations.of(
            tester.element(find.byType(ProxyFormPage)),
          );
          await tester.ensureVisible(forms.keyed('proxy-choice:http/tls'));
          await tester.pumpAndSettle();
          final choiceData = tester
              .getSemantics(
                find.descendant(
                  of: forms.keyed('proxy-choice:http/tls'),
                  matching: find.byType(InkWell),
                ),
              )
              .getSemanticsData();
          expect(choiceData.flagsCollection.isButton, isTrue);
          expect(choiceData.hasAction(SemanticsAction.tap), isTrue);
          final choice = choiceData.label;
          expect(choice, contains(strings.proxyUnset));
          expect(choice, isNot(contains(strings.proxyTrue)));
          expect(choice, isNot(contains(strings.proxyFalse)));
          expect(
            find.bySemanticsLabel(
              RegExp(RegExp.escape(strings.operationFailed)),
            ),
            findsNothing,
          );
          expect(
            find.bySemanticsLabel(RegExp(RegExp.escape(strings.proxyRequired))),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'proxy inputs expose the label on the actual editing node $language',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await forms.openForm(
            tester,
            ProxyFormPage(onSave: (_) async {}),
            locale: Locale(language),
          );
          final strings = AppLocalizations.of(
            tester.element(find.byType(ProxyFormPage)),
          );
          for (final (id, label) in [
            ('common/name', strings.proxyName),
            ('common/server', strings.proxyServer),
            ('common/port', strings.portLabel('').trim()),
            ('common/password', strings.proxyPassword),
          ]) {
            final input = find.descendant(
              of: forms.keyed('proxy-field:$id'),
              matching: find.byType(TextField),
            );
            await tester.ensureVisible(input);
            await tester.pumpAndSettle();
            final data = tester.getSemantics(input).getSemanticsData();
            expect(data.flagsCollection.isTextField, isTrue, reason: id);
            expect(data.label, label, reason: id);
            expect(data.value, isEmpty, reason: id);
          }
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    for (final enabled in [true, false]) {
      for (final value in <String?>[null, 'file']) {
        testWidgets(
          'definition choice trigger owns its accessible name and value $language/$enabled/$value',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              final label = language == 'en' ? 'Source type' : '来源类型';
              final file = language == 'en' ? 'File' : '文件';
              await forms.openForm(
                tester,
                Scaffold(
                  body: Form(
                    child: DefinitionChoiceField(
                      id: 'source',
                      label: label,
                      enabled: enabled,
                      initialValue: value,
                      options: {'file': file, 'http': 'HTTP'},
                    ),
                  ),
                ),
                locale: Locale(language),
              );
              final trigger = find.descendant(
                of: forms.keyed('definition-menu:source'),
                matching: find.byType(InkWell),
              );
              final node = tester.getSemantics(trigger);
              final data = node.getSemanticsData();
              final strings = AppLocalizations.of(tester.element(trigger));
              expect(data.flagsCollection.isButton, isTrue);
              expect(
                data.flagsCollection.isEnabled,
                enabled ? Tristate.isTrue : Tristate.isFalse,
              );
              expect(data.hasAction(SemanticsAction.tap), enabled);
              expect(data.label, label);
              expect(data.value, value == null ? strings.proxyUnset : file);
              if (enabled) {
                tester
                    .element(trigger)
                    .findRenderObject()!
                    .owner!
                    .semanticsOwner!
                    .performAction(node.id, SemanticsAction.tap);
                await tester.pumpAndSettle();
                expect(
                  find.widgetWithText(MenuItemButton, file),
                  findsOneWidget,
                );
                expect(
                  find.widgetWithText(MenuItemButton, 'HTTP'),
                  findsOneWidget,
                );
                await tester.tap(find.widgetWithText(MenuItemButton, 'HTTP'));
                await tester.pumpAndSettle();
                final selected = tester
                    .getSemantics(trigger)
                    .getSemanticsData();
                expect(selected.label, label);
                expect(selected.value, 'HTTP');
              }
              expect(tester.takeException(), isNull);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }

    final editingForms = <String, Widget>{
      'proxy': ProxyFormPage(
        initialDefinition: const {
          'name': 'controlled',
          'type': 'http',
          'server': '192.0.2.1',
          'port': 18080,
        },
        onSave: (_) async {},
      ),
      'proxy-provider': ProviderFormPage(
        ruleProvider: false,
        initialName: 'controlled',
        initialDefinition: const {'type': 'file', 'path': 'controlled.yaml'},
        onSave: (_, _) async {},
      ),
      'rule-provider': ProviderFormPage(
        ruleProvider: true,
        initialName: 'controlled',
        initialDefinition: const {
          'type': 'file',
          'behavior': 'domain',
          'path': 'controlled.yaml',
        },
        onSave: (_, _) async {},
      ),
      'rule': RuleFormPage(
        initialRule: 'DOMAIN,example.test,DIRECT',
        targets: const ['DIRECT'],
        onSave: (_) async {},
      ),
    };
    for (final entry in editingForms.entries) {
      testWidgets('existing ${entry.key} uses an editing title $language', (
        tester,
      ) async {
        await forms.openForm(tester, entry.value, locale: Locale(language));
        final strings = AppLocalizations.of(
          tester.element(find.byType(AppBar)),
        );
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text(strings.editLocalDefinition),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
    for (final entry in <String, (Widget, String)>{
      'group': (
        StrategyGroupFormPage(
          initialDefinition: const {
            'name': 'controlled',
            'type': 'select',
            'proxies': ['DIRECT'],
          },
          onSave: (_) async {},
        ),
        'group/name',
      ),
      'proxy-provider': (editingForms['proxy-provider']!, 'provider/name'),
      'rule-provider': (editingForms['rule-provider']!, 'provider/name'),
    }.entries) {
      testWidgets(
        'definition name is not a proxy label ${entry.key}/$language',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            await forms.openForm(
              tester,
              entry.value.$1,
              locale: Locale(language),
            );
            final input = forms.keyed('definition-input:${entry.value.$2}');
            await tester.ensureVisible(input);
            await tester.pumpAndSettle();
            final data = tester.getSemantics(input).getSemanticsData();
            expect(data.flagsCollection.isTextField, isTrue);
            expect(data.label, language == 'en' ? 'Name' : '名称');
            expect(data.value, 'controlled');
          } finally {
            semantics.dispose();
          }
        },
      );
    }

    testWidgets('provider replacement hides untriggered validation $language', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await forms.openForm(
          tester,
          ProviderFormPage(
            ruleProvider: false,
            initialName: 'controlled',
            initialDefinition: const {
              'type': 'inline',
              'payload': <Object?>[],
              'override': {
                'proxy-name': [
                  {'pattern': 'controlled', 'target': 'replacement'},
                ],
              },
            },
            onSave: (_, _) async {},
          ),
          locale: Locale(language),
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(ProviderFormPage)),
        );
        final pattern = forms.keyed(
          'definition-input:provider/override/proxy-name/0/pattern',
          offstage: true,
        );
        await forms.expandAncestors(tester, pattern);
        await tester.ensureVisible(pattern);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(pattern).getSemanticsData().value,
          'controlled',
        );
        expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(strings.proxyRequired))),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });

    for (final width in [280.0, 1704.0]) {
      for (final (scaleLabel, scaler) in [
        ('1', TextScaler.noScaling),
        ('2', TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          'failure slots preserve geometry but retire hidden interaction $language/$width/$scaleLabel',
          (tester) async {
            final semantics = tester.ensureSemantics();
            final first = Completer<void>();
            final retry = Completer<void>();
            var calls = 0;
            try {
              await forms.openForm(
                tester,
                ProxyFormPage(
                  initialDefinition: const {
                    'type': 'http',
                    'name': 'controlled',
                    'server': '127.0.0.1',
                    'port': 1080,
                  },
                  onSave: (_) => ++calls == 1 ? first.future : retry.future,
                ),
                locale: Locale(language),
                scaler: scaler,
                size: Size(width, 1136),
              );
              final strings = AppLocalizations.of(
                tester.element(find.byType(ProxyFormPage)),
              );
              final details = forms.keyed('proxy-save-details');
              final save = forms.keyed('proxy-save');
              final header = forms.keyed('proxy-select-type');
              final saveBounds = tester.getRect(save);
              final headerBounds = tester.getRect(header);
              final detailsBounds = tester.getRect(details);
              final icon = find.descendant(
                of: details,
                matching: find.byType(Icon),
              );
              final focus = Focus.of(tester.element(icon));
              final scrollable = find
                  .descendant(
                    of: forms.keyed('proxy-form-scroll'),
                    matching: find.byType(Scrollable),
                  )
                  .first;
              final position = tester
                  .state<ScrollableState>(scrollable)
                  .position;
              final pixels = position.pixels;

              void expectFrame({required bool failed}) {
                expect(tester.getRect(save), saveBounds);
                expect(tester.getRect(header), headerBounds);
                expect(tester.getRect(details), detailsBounds);
                expect(
                  tester.state<ScrollableState>(scrollable).position,
                  same(position),
                );
                expect(position.pixels, pixels);
                // Retained render objects can expose their last, now detached
                // node through a widget finder. Inspect the active tree instead.
                var root = tester.getSemantics(save);
                while (root.parent != null) {
                  root = root.parent!;
                }
                final labels = <String>[];
                void collect(SemanticsNode node) {
                  labels.add(node.getSemanticsData().label);
                  node.visitChildren((child) {
                    collect(child);
                    return true;
                  });
                }

                collect(root);
                expect(
                  labels.any(
                    (label) => label.contains(strings.operationFailed),
                  ),
                  failed,
                );
                expect(
                  details.hitTestable(),
                  failed ? findsOneWidget : findsNothing,
                );
                expect(focus.canRequestFocus, failed);
                if (!failed) {
                  expect(focus.hasFocus, isFalse);
                  expect(
                    labels.any(
                      (label) => label.contains(strings.viewConfigError),
                    ),
                    isFalse,
                  );
                }
                expect(tester.takeException(), isNull);
              }

              expectFrame(failed: false);
              await tester.tapAt(detailsBounds.center);
              await tester.pump();
              expect(find.byType(AlertDialog), findsNothing);
              await tester.tap(save);
              for (final ms in [0, 16, 32, 80]) {
                await tester.pump(Duration(milliseconds: ms));
                expectFrame(failed: false);
              }
              expect(calls, 1);
              first.completeError(
                ProxyFormSaveException(messages.configSavedReconnectIncomplete),
              );
              for (final ms in [0, 16, 32, 80]) {
                await tester.pump(Duration(milliseconds: ms));
                expectFrame(failed: true);
              }
              focus.requestFocus();
              await tester.pump();
              expect(focus.hasFocus, isTrue);
              await tester.tap(save);
              for (final ms in [0, 16, 32, 80]) {
                await tester.pump(Duration(milliseconds: ms));
                expectFrame(failed: false);
              }
              expect(calls, 2);
              retry.complete();
              await tester.pumpAndSettle();
              expect(find.byType(ProxyFormPage), findsNothing);
              expect(tester.takeException(), isNull);
            } finally {
              if (!first.isCompleted) first.complete();
              if (!retry.isCompleted) retry.complete();
              semantics.dispose();
            }
          },
        );
      }
    }
  }
}
