import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';
import 'package:clash_pseudo/src/features/overrides/definition_form_body.dart';
import 'package:clash_pseudo/src/features/overrides/provider_form.dart';
import 'package:clash_pseudo/src/features/overrides/proxy_form.dart';
import 'package:clash_pseudo/src/features/overrides/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'definition_forms_test.dart' as forms;
import 'proxy_form_test.dart' as proxies;

Widget page(String kind, VoidCallback saved, {bool invalid = false}) =>
    switch (kind) {
      'proxy' => ProxyFormPage(
        initialDefinition: {
          'type': 'http',
          'name': 'controlled',
          'server': 'node.fixture.test',
          'port': 443,
          if (invalid) 'routing-mark': 'invalid',
        },
        onSave: (_) async => saved(),
      ),
      'group' => StrategyGroupFormPage(
        initialDefinition: {
          'name': 'controlled',
          'type': 'select',
          'proxies': ['DIRECT'],
          if (invalid) 'timeout': -1,
        },
        onSave: (_) async => saved(),
      ),
      _ => ProviderFormPage(
        ruleProvider: kind == 'rule-provider',
        initialName: 'controlled',
        initialDefinition: {
          'type': 'http',
          'url': 'https://fixture.invalid/provider',
          if (kind == 'rule-provider') 'behavior': 'domain',
          if (invalid) 'health-check': {'timeout': -1},
        },
        onSave: (_, _) async => saved(),
      ),
    };

Finder nameField(String kind) => kind == 'proxy'
    ? find.descendant(
        of: proxies.keyed('proxy-field:common/name'),
        matching: find.byType(TextField),
      )
    : forms.keyed(
        'definition-input:${kind == 'group' ? 'group' : 'provider'}/name',
      );

void main() {
  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'save bar retains focus and state geometry $language/$scale',
        (tester) async {
          var compact = false;
          var saving = false;
          var failed = false;
          var saves = 0;
          late StateSetter update;
          await forms.openForm(
            tester,
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: DefinitionSaveBar(
                      id: 'controlled',
                      compact: compact,
                      saving: saving,
                      failed: failed,
                      onSave: () => saves++,
                      onDetails: () {},
                    ),
                  ),
                );
              },
            ),
            size: const Size(280, 480),
            locale: Locale(language),
            scaler: TextScaler.linear(scale),
          );
          final save = forms.keyed('definition-save:controlled');
          final button = tester.state(save);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focus = FocusManager.instance.primaryFocus;
          expect(
            focus?.context?.findAncestorWidgetOfExactType<FilledButton>(),
            isNotNull,
          );
          for (final next in [true, false, true]) {
            update(() => compact = next);
            await tester.pumpAndSettle();
            expect(tester.state(save), same(button));
            expect(FocusManager.instance.primaryFocus, same(focus));
            expect(save.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          for (final next in [false, true]) {
            update(() => compact = next);
            await tester.pumpAndSettle();
            final bounds = tester.getRect(save);
            final bar = tester.getRect(find.byType(DefinitionSaveBar));
            for (final state in [
              (true, false),
              (false, true),
              (false, false),
            ]) {
              update(() {
                saving = state.$1;
                failed = state.$2;
              });
              await tester.pump();
              expect(tester.getRect(save), bounds);
              expect(tester.getRect(find.byType(DefinitionSaveBar)), bar);
              expect(tester.state(save), same(button));
              expect(
                tester.widget<FilledButton>(save).onPressed == null,
                saving,
              );
              expect(
                forms.keyed('definition-details:controlled').hitTestable(),
                failed ? findsOneWidget : findsNothing,
              );
              expect(tester.takeException(), isNull);
            }
            await tester.tap(save);
            await tester.pump();
          }
          expect(saves, 2);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final kind in ['proxy', 'group', 'proxy-provider', 'rule-provider']) {
    for (final language in ['en', 'zh']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '$kind chapters retain the form and editing value through both axes $language/$scale',
          (tester) async {
            var saves = 0;
            await forms.openForm(
              tester,
              page(kind, () => saves++),
              size: const Size(2000, 900),
              locale: Locale(language),
              scaler: TextScaler.linear(scale),
            );
            final basic = forms.keyed('definition-chapter:basic');
            final secondary = forms.keyed(
              'definition-chapter:${switch (kind) {
                'proxy-provider' => 'advanced',
                'rule-provider' => 'source',
                _ => 'protocol',
              }}',
            );
            expect(
              tester.getRect(basic).right,
              lessThan(tester.getRect(secondary).left),
            );
            expect(
              tester.getTopLeft(basic).dy,
              tester.getTopLeft(secondary).dy,
            );
            final form = tester.state<FormState>(find.byType(Form).first);
            final body = tester.state(find.byType(DefinitionFormBody));
            addTearDown(tester.view.resetViewInsets);
            final field = nameField(kind);
            await tester.enterText(field, 'retained draft');
            final input = tester.widget<TextField>(field).controller!;
            input.value = input.value.copyWith(
              selection: const TextSelection(baseOffset: 1, extentOffset: 5),
              composing: const TextRange(start: 1, end: 5),
            );
            await tester.pump();
            final value = input.value;
            final editor = tester.widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            );
            for (final size in [
              const Size(700, 479),
              const Size(280, 480),
              const Size(2000, 900),
            ]) {
              tester.view.physicalSize = size;
              tester.view.viewInsets = const FakeViewPadding(bottom: 160);
              await tester.pumpAndSettle();
              expect(
                tester.state<FormState>(find.byType(Form).first),
                same(form),
              );
              expect(tester.state(find.byType(DefinitionFormBody)), same(body));
              expect(tester.widget<TextField>(field).controller, same(input));
              final current = tester.widget<EditableText>(
                find.descendant(of: field, matching: find.byType(EditableText)),
              );
              expect(current.focusNode, same(editor.focusNode));
              expect(current.focusNode.hasFocus, isTrue);
              expect(input.value, value);
              expect(
                field.hitTestable(),
                findsOneWidget,
                reason: '$size at $scale',
              );
              expect(saves, 0);
              expect(tester.takeException(), isNull);
            }
            tester.view.resetViewInsets();
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final kind in ['proxy', 'group', 'proxy-provider']) {
    testWidgets(
      '$kind save exposes the first invalid field in a collapsed chapter',
      (tester) async {
        var saves = 0;
        await forms.openForm(tester, page(kind, () => saves++, invalid: true));
        final chapterId = kind == 'proxy-provider'
            ? 'health-check'
            : 'advanced';
        final chapter = forms.keyed('definition-chapter:$chapterId');
        final header = find
            .descendant(of: chapter, matching: find.byType(ListTile))
            .first;
        final expansion = ExpansibleController.of(tester.element(header));
        if (expansion.isExpanded) {
          expansion.collapse();
          await tester.pumpAndSettle();
        }
        final field = kind == 'proxy'
            ? find.descendant(
                of: proxies.keyed(
                  'proxy-field:common/routing-mark',
                  offstage: true,
                ),
                matching: find.byType(TextField, skipOffstage: false),
                skipOffstage: false,
              )
            : forms.keyed(
                'definition-input:${kind == 'group' ? 'group/timeout' : 'provider/health-check/timeout'}',
                offstage: true,
              );
        final input = tester.widget<TextField>(field).controller!;
        final draft = input.value;
        final save = kind == 'proxy'
            ? proxies.keyed('proxy-save')
            : forms.keyed(
                'definition-save:${kind == 'group' ? 'group' : 'provider'}',
              );
        final saveRect = tester.getRect(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(saves, 0);
        expect(expansion.isExpanded, isTrue);
        expect(field.hitTestable(), findsOneWidget);
        expect(input.value.text, draft.text);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(of: field, matching: find.byType(EditableText)),
              )
              .focusNode
              .hasFocus,
          isTrue,
        );
        expect(tester.getRect(save), saveRect);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final keyboardFirst in [true, false]) {
    testWidgets(
      'short keyboard workspace shows input and error together, keyboard first: $keyboardFirst',
      (tester) async {
        var saves = 0;
        await forms.openForm(
          tester,
          ProxyFormPage(
            initialDefinition: const {
              'type': 'http',
              'name': '',
              'server': 'controlled.fixture.test',
              'port': 443,
            },
            onSave: (_) async => saves++,
          ),
          size: const Size(350, 660),
          scaler: const TextScaler.linear(2),
        );
        addTearDown(tester.view.resetViewInsets);
        if (keyboardFirst) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
        }
        await tester.tap(proxies.keyed('proxy-save'));
        await tester.pumpAndSettle();
        if (!keyboardFirst) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
        }
        final field = proxies.keyed('proxy-field:common/name');
        final strings = AppLocalizations.of(tester.element(field));
        final error = find.descendant(
          of: field,
          matching: find.text(strings.proxyRequired),
        );
        final viewport = tester.getRect(find.byType(SingleChildScrollView));
        final errorBounds = tester.getRect(error);
        expect(errorBounds.top, greaterThanOrEqualTo(viewport.top));
        expect(errorBounds.bottom, lessThanOrEqualTo(viewport.bottom));
        final input = find.descendant(
          of: field,
          matching: find.byType(TextField),
        );
        final inputBounds = tester.getRect(input);
        expect(inputBounds.top, greaterThanOrEqualTo(viewport.top));
        expect(inputBounds.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(input.hitTestable(), findsOneWidget);
        expect(saves, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('an unbuilt numeric record is exposed by its stable ID', (
    tester,
  ) async {
    var saves = 0;
    await forms.openForm(
      tester,
      ProxyFormPage(
        initialDefinition: {
          'type': 'wireguard',
          'name': 'controlled',
          'private-key': 'controlled-key',
          'reserved': List<Object>.generate(
            128,
            (index) => index == 97 ? 256 : index % 256,
          ),
        },
        onSave: (_) async => saves++,
      ),
    );
    const id = 'wireguard/reserved/97';
    expect(forms.keyed('definition-input:$id', offstage: true), findsNothing);
    await tester.tap(proxies.keyed('proxy-save'));
    await tester.pumpAndSettle();
    final field = forms.keyed('definition-input:$id');
    expect(saves, 0);
    expect(field.hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, '256');
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
