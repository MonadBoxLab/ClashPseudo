import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:clash_pseudo/src/ui/overrides/forms/shared/form_interaction.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/form_body.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/save_bar.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/rule_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/text_scalers.dart';

import 'definition_forms_test.dart' as forms;

void main() {
  testWidgets('集中校验只提示首错并保留输入、正文几何和 composing', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final form = GlobalKey<FormState>();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final strings = lookupAppLocalizations(const Locale('en'));
      await forms.openForm(
        tester,
        Scaffold(
          body: DefinitionFormBody(
            form: form,
            controller: scroll,
            children: [
              DefinitionTextField(
                id: 'validation/first',
                label: 'port',
                initialValue: 'x',
                isValid: (_) => false,
                invalidMessage: strings.proxyInvalidPort,
              ),
              const DefinitionTextField(
                id: 'validation/second',
                label: 'name',
                required: true,
              ),
            ],
          ),
        ),
        size: const Size(600, 800),
      );
      final first = forms.keyed('definition-input:validation/first');
      final second = forms.keyed('definition-input:validation/second');
      final firstState = tester.state(first);
      final secondState = tester.state(second);
      final controller = tester.widget<TextField>(first).controller!;
      await tester.showKeyboard(first);
      const value = TextEditingValue(
        text: 'x',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
      final firstBounds = tester.getRect(first);
      final secondBounds = tester.getRect(second);
      final focus = FocusManager.instance.primaryFocus;
      expect(DefinitionFormBody.validate(form), isFalse);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(strings.proxyInvalidPort), findsOneWidget);
      expect(find.text(strings.proxyRequired), findsNothing);
      expect(tester.getRect(first), firstBounds);
      expect(tester.getRect(second), secondBounds);
      expect(tester.state(first), same(firstState));
      expect(tester.state(second), same(secondState));
      expect(controller.value, value);
      expect(FocusManager.instance.primaryFocus, same(focus));
      for (final input in [first, second]) {
        expect(tester.widget<TextField>(input).decoration!.errorText, isNull);
        final validation = tester.widget<DefinitionFieldValidation>(
          find.ancestor(
            of: input,
            matching: find.byType(DefinitionFieldValidation),
          ),
        );
        expect(validation.hasError, isTrue);
        expect(
          tester.getSemantics(input).getSemanticsData().validationResult,
          SemanticsValidationResult.invalid,
        );
      }
      final notice = tester.element(find.byType(SnackBar));
      tester.testTextInput.updateEditingValue(value.copyWith(text: 'xy'));
      await tester.pump();
      expect(tester.element(find.byType(SnackBar)), same(notice));
      expect(tester.getRect(first), firstBounds);
      expect(tester.getRect(second), secondBounds);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  group('save failure presentation and live eligibility', () {
    for (final language in ['en', 'zh']) {
      for (final (scaleName, scaler) in [
        ('1', TextScaler.noScaling),
        ('2', TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets('保存按钮在 compact 切换后保留焦点并拒绝失效回调 $language/$scaleName', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          try {
            var compact = false;
            var saving = false;
            var completed = false;
            var active = true;
            var saves = 0;
            late StateSetter update;
            await forms.openForm(
              tester,
              StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return DefinitionFormInteraction(
                    active: active,
                    isActiveNow: () => active,
                    child: Scaffold(
                      body: Align(
                        alignment: Alignment.bottomCenter,
                        child: DefinitionSaveBar(
                          id: 'live-failure',
                          compact: compact,
                          saving: saving,
                          completed: completed,
                          onSave: () => saves++,
                        ),
                      ),
                    ),
                  );
                },
              ),
              locale: Locale(language),
              scaler: scaler,
              size: const Size(280, 480),
            );
            final save = forms.keyed('definition-save:live-failure');
            final saveState = tester.state(save);
            final label = find.descendant(
              of: save,
              matching: find.byType(Text),
            );
            final focus = Focus.of(tester.element(label));
            focus.requestFocus();
            await tester.pump();
            expect(focus.hasFocus, isTrue);
            for (final next in [false, true, false, true]) {
              update(() => compact = next);
              await tester.pump();
              expect(tester.state(save), same(saveState));
              expect(FocusManager.instance.primaryFocus, same(focus));
              expect(save.hitTestable(), findsOneWidget);
              expect(tester.getRect(save).height, greaterThanOrEqualTo(48));
              expect(
                forms.keyed('definition-details:live-failure'),
                findsNothing,
              );
            }
            final cachedSave = tester.widget<FilledButton>(save).onPressed!;
            final saveBounds = tester.getRect(save);
            final barBounds = tester.getRect(find.byType(DefinitionSaveBar));
            for (final state in [
              (saving: true, completed: false),
              (saving: false, completed: true),
              (saving: false, completed: false),
            ]) {
              update(() {
                saving = state.saving;
                completed = state.completed;
              });
              await tester.pump();
              expect(tester.getRect(save), saveBounds);
              expect(tester.getRect(find.byType(DefinitionSaveBar)), barBounds);
              expect(tester.state(save), same(saveState));
              expect(
                tester.widget<FilledButton>(save).onPressed == null,
                saving || completed,
              );
              cachedSave();
              expect(saves, state.saving || state.completed ? 0 : 1);
            }
            active = false;
            cachedSave();
            expect(saves, 1);
            update(() {});
            await tester.pump();
            await tester.pumpWidget(const SizedBox());
            cachedSave();
            expect(saves, 1);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  });
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
            find.bySemanticsLabel(RegExp(RegExp.escape(strings.saveFailed))),
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
          '保存失败提示不移动正文且旧 action 在重试后失效 $language/$width/$scaleLabel',
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
              final save = forms.keyed('proxy-save');
              final header = forms.keyed('proxy-select-type');
              final saveBounds = tester.getRect(save);
              final headerBounds = tester.getRect(header);
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

              void expectFrame() {
                expect(tester.getRect(save), saveBounds);
                expect(tester.getRect(header), headerBounds);
                expect(
                  tester.state<ScrollableState>(scrollable).position,
                  same(position),
                );
                expect(position.pixels, pixels);
                expect(forms.keyed('proxy-save-details'), findsNothing);
                expect(tester.takeException(), isNull);
              }

              expectFrame();
              await tester.tap(save);
              for (final ms in [0, 16, 32, 80]) {
                await tester.pump(Duration(milliseconds: ms));
                expectFrame();
              }
              expect(calls, 1);
              first.completeError(
                ProxyFormSaveException(messages.configSavedReconnectIncomplete),
              );
              for (final ms in [0, 16, 32, 80]) {
                await tester.pump(Duration(milliseconds: ms));
                expectFrame();
              }
              await tester.pumpAndSettle();
              expect(find.byType(SnackBar), findsOneWidget);
              expect(
                find.text(strings.configSavedReconnectIncomplete),
                findsOneWidget,
              );
              expect(find.byType(AlertDialog), findsNothing);
              final details = find.widgetWithText(
                TextButton,
                strings.errorDetails,
              );
              final cachedDetails = tester
                  .widget<TextButton>(details)
                  .onPressed!;
              await tester.tap(find.widgetWithText(TextButton, strings.retry));
              for (final ms in [0, 16, 32, 80]) {
                await tester.pump(Duration(milliseconds: ms));
                expectFrame();
              }
              cachedDetails();
              await tester.pump();
              expect(find.byType(AlertDialog), findsNothing);
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
