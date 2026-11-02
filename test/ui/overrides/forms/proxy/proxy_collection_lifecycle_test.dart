import 'dart:convert';

import 'package:clash_pseudo/src/ui/overrides/forms/shared/form_body.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proxy_form_test.dart' as forms;

class _CollectionTextScaler extends TextScaler {
  const _CollectionTextScaler();
  @override
  double scale(double fontSize) => fontSize * (fontSize <= 18 ? 1.8 : 1.3);
  @override
  double get textScaleFactor => 1.5;
}

String _id(String kind) => switch (kind) {
  'strings' => 'ssh/host-key',
  'numbers' => 'wireguard/reserved',
  'mapping' => 'http/headers',
  _ => 'vmess/http-opts/headers',
};

Map<String, Object?> _seed(String kind, int count) {
  final mapping = <String, Object?>{
    for (var i = 0; i < count; i++)
      'X-Controlled-$i': kind == 'mapping' ? 'value-$i' : ['value-$i', ''],
  };
  return {
    'name': 'controlled collection',
    'type': switch (kind) {
      'strings' => 'ssh',
      'numbers' => 'wireguard',
      'mapping' => 'http',
      _ => 'vmess',
    },
    'future': {
      'retained': [false, 0, '', null],
    },
    if (kind != 'numbers') ...{'server': '192.0.2.1', 'port': 18080},
    if (kind == 'strings') ...{
      'username': 'controlled',
      'host-key': [
        for (var i = 0; i < count; i++)
          i % 4 == 0 ? '' : 'controlled-$i · 中文 é 🚀',
      ],
    },
    if (kind == 'numbers') ...{
      'private-key': 'controlled-not-a-real-key',
      'reserved': <Object?>[for (var i = 0; i < count; i++) i % 256],
    },
    if (kind == 'mapping') 'headers': mapping,
    if (kind == 'list-mapping') ...{
      'uuid': 'controlled',
      'alterId': 0,
      'cipher': 'auto',
      'network': 'http',
      'http-opts': {'headers': mapping},
    },
  };
}

Future<void> _save(WidgetTester tester) async {
  await forms.tap(tester, forms.keyed('proxy-save'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<ScrollController> _reveal(WidgetTester tester, String kind) async {
  final id = _id(kind);
  await forms.openGroup(tester, id);
  final list = forms.keyed(
    '${kind.contains('mapping') ? 'definition-header-list' : 'definition-list'}:$id',
  );
  await tester.ensureVisible(list);
  await tester.pumpAndSettle();
  return tester.widget<ListView>(list).controller!;
}

void main() {
  for (final kind in ['strings', 'numbers', 'mapping', 'list-mapping']) {
    for (final language in ['en', 'zh']) {
      for (final width in [320.0, 1704.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            '4096 $kind edit and offscreen save $language $width $scale',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = Size(width, 1136);
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final original = _seed(kind, 4096);
              final untouched = jsonDecode(jsonEncode(original));
              Map<String, Object?>? saved;
              await forms.openForm(
                tester,
                original['type'] as String,
                initialDefinition: original,
                locale: Locale(language),
                scaler: TextScaler.linear(scale),
                onSave: (value) async => saved = value,
              );
              final scroll = await _reveal(tester, kind);
              final position = scroll.position;
              expect(
                find.byType(TextField, skipOffstage: false).evaluate().length,
                lessThan(100),
              );
              scroll.jumpTo(scroll.position.maxScrollExtent);
              await tester.pumpAndSettle();
              final id = _id(kind);
              final expected = jsonDecode(jsonEncode(original)) as Map;
              if (kind.contains('mapping')) {
                final edit = forms.keyed('definition-edit:$id/4095');
                await tester.ensureVisible(edit);
                await tester.tap(edit);
                await tester.pumpAndSettle();
                await forms.fillScalar(
                  tester,
                  '$id/4095',
                  'key',
                  'X-Edited-4095',
                );
                if (kind == 'mapping') {
                  await forms.fillScalar(tester, '$id/4095', 'value', '');
                  expect(find.byType(DefinitionStringListField), findsNothing);
                } else {
                  await forms.fillScalar(
                    tester,
                    '$id/4095/values/0',
                    'value',
                    'edited-value',
                  );
                }
                await tester.tap(
                  forms.keyed('definition-save-header:$id/4095'),
                );
                await tester.pumpAndSettle();
                expect(identical(scroll.position, position), isTrue);
                final map = kind == 'mapping'
                    ? expected['headers'] as Map
                    : (expected['http-opts'] as Map)['headers'] as Map;
                map.remove('X-Controlled-4095');
                map['X-Edited-4095'] = kind == 'mapping'
                    ? ''
                    : ['edited-value', ''];
                await tester.tap(forms.keyed('definition-edit:$id/4095'));
                await tester.pumpAndSettle();
                expect(find.text('X-Edited-4095'), findsOneWidget);
                await forms.fillScalar(
                  tester,
                  '$id/4095',
                  'key',
                  'X-Cancelled-4095',
                );
                await tester.tap(find.byType(BackButton));
                await tester.pumpAndSettle();
                final strings = AppLocalizations.of(
                  tester.element(find.byType(AlertDialog)),
                );
                await tester.tap(find.text(strings.discard));
                await tester.pumpAndSettle();
              } else {
                await forms.fillScalar(
                  tester,
                  '$id/4095',
                  'value',
                  kind == 'numbers' ? 17 : 'edited-last · 中文 🚀',
                );
                (expected[kind == 'numbers' ? 'reserved' : 'host-key']
                    as List)[4095] = kind == 'numbers'
                    ? 17
                    : 'edited-last · 中文 🚀';
                tester.testTextInput.hide();
                FocusManager.instance.primaryFocus?.unfocus();
                await tester.pumpAndSettle();
              }
              scroll.jumpTo(0);
              await tester.pumpAndSettle();
              expect(forms.keyed('definition-input:$id/4095'), findsNothing);
              await _save(tester);
              expect(saved, expected);
              expect(original, untouched);
            },
          );
        }
      }
    }
  }

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 1704.0]) {
      for (final scaler in [
        TextScaler.noScaling,
        TextScaler.linear(2),
        const _CollectionTextScaler(),
      ]) {
        testWidgets(
          'numeric collection validation frames retain anchors $language $width $scaler',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1136);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetViewInsets);
            final original = _seed('numbers', 3);
            Map<String, Object?>? saved;
            await forms.openForm(
              tester,
              'wireguard',
              initialDefinition: original,
              locale: Locale(language),
              scaler: scaler,
              onSave: (value) async => saved = value,
            );
            final scroll = await _reveal(tester, 'numbers');
            final input = forms.keyed('definition-input:wireguard/reserved/0');
            await tester.ensureVisible(input);
            await tester.enterText(input, '256');
            tester.view.viewInsets = const FakeViewPadding(bottom: 360);
            await tester.pumpAndSettle();
            await tester.ensureVisible(input);
            await tester.pumpAndSettle();
            await Scrollable.ensureVisible(
              tester.element(input),
              alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
            );
            await tester.pumpAndSettle();
            final viewport = tester.getRect(forms.keyed('proxy-form-scroll'));
            expect(
              tester.getRect(input).top,
              greaterThanOrEqualTo(viewport.top),
            );
            expect(
              tester.getRect(input).bottom,
              lessThanOrEqualTo(viewport.bottom),
            );
            final save = forms.keyed('proxy-save');
            final list = forms.keyed('definition-list:wireguard/reserved');
            final beforeInput = tester.getRect(input);
            final beforeSave = tester.getRect(save);
            final beforeList = tester.getRect(list);
            final position = scroll.position;
            final pixels = scroll.offset;
            final controller = tester.widget<TextField>(input).controller!;
            controller.selection = const TextSelection(
              baseOffset: 1,
              extentOffset: 2,
            );
            final selection = controller.selection;
            final focus = FocusManager.instance.primaryFocus;
            await tester.tap(save);
            for (final ms in [0, 16, 32, 80]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(saved, isNull);
              expect(tester.getRect(input), beforeInput);
              expect(tester.getRect(save), beforeSave);
              expect(tester.getRect(list), beforeList);
              expect(scroll.position, same(position));
              expect(scroll.offset, pixels);
              expect(FocusManager.instance.primaryFocus, focus);
              expect(controller.selection, selection);
              expect(controller.text, '256');
              expect(tester.takeException(), isNull);
            }
            tester.view.viewInsets = const FakeViewPadding();
            await tester.pumpAndSettle();
            await tester.enterText(input, '17');
            await tester.pumpAndSettle();
            await _save(tester);
            expect(saved, {
              ...original,
              'reserved': [17, 1, 2],
            });
          },
        );
      }
    }
  }

  for (final invalid in [256, -1, '', '1e3', '18446744073709551616']) {
    testWidgets(
      'unmounted numeric item $invalid is validated by the complete parent draft',
      (tester) async {
        final original = _seed('numbers', 4096);
        (original['reserved'] as List)[4095] = invalid;
        final untouched = jsonDecode(jsonEncode(original));
        Map<String, Object?>? saved;
        Future<void> open() => forms.openForm(
          tester,
          'wireguard',
          initialDefinition: original,
          onSave: (value) async => saved = value,
        );
        await open();
        await _save(tester);
        expect(saved, original);
        saved = null;
        await open();
        final scroll = await _reveal(tester, 'numbers');
        final presence = forms.keyed('definition-presence:wireguard/reserved');
        await tester.ensureVisible(presence);
        await tester.tap(presence);
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(presence).value, isFalse);
        await tester.tap(presence);
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(presence).value, isTrue);
        expect(
          tester
              .widget<TextField>(
                forms.keyed('definition-input:wireguard/reserved/0'),
              )
              .controller!
              .text,
          '0',
        );
        final list = forms.keyed('definition-list:wireguard/reserved');
        final add = forms.keyed('definition-add:wireguard/reserved');
        final relative = tester.getTopLeft(add) - tester.getTopLeft(list);
        expect(
          forms.keyed('definition-input:wireguard/reserved/4095'),
          findsNothing,
        );
        await _save(tester);
        expect(saved, isNull);
        expect(tester.getTopLeft(add) - tester.getTopLeft(list), relative);
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        await forms.fillScalar(tester, 'wireguard/reserved/4095', 'value', 17);
        tester.testTextInput.hide();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        await _save(tester);
        final expected = jsonDecode(jsonEncode(original)) as Map;
        (expected['reserved'] as List)[4095] = 17;
        expect(saved, expected);
        expect(original, untouched);
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final kind in ['strings', 'numbers', 'mapping']) {
      testWidgets(
        'actual input semantics retain the field label $kind $language',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final original = _seed(kind, 1);
            await forms.openForm(
              tester,
              original['type'] as String,
              initialDefinition: original,
              locale: Locale(language),
              onSave: (_) async {},
            );
            await _reveal(tester, kind);
            final id = _id(kind);
            if (kind == 'mapping') {
              await tester.tap(forms.keyed('definition-edit:$id/0'));
              await tester.pumpAndSettle();
            }
            final input = forms.keyed(
              'definition-input:$id/0${kind == 'mapping' ? '/key' : ''}',
            );
            await tester.ensureVisible(input);
            await tester.pumpAndSettle();
            final data = tester.getSemantics(input).getSemanticsData();
            expect(data.flagsCollection.isTextField, isTrue);
            expect(
              data.label,
              kind == 'mapping'
                  ? AppLocalizations.of(tester.element(input)).proxyMapKey
                  : kind == 'numbers'
                  ? '#1\nreserved'
                  : '#1\nhost-key',
            );
            expect(
              data.value,
              kind == 'mapping'
                  ? 'X-Controlled-0'
                  : kind == 'numbers'
                  ? '0'
                  : '',
            );
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }

  for (final kind in ['strings', 'mapping']) {
    testWidgets(
      'covered collection refuses retained row and presence actions $kind',
      (tester) async {
        final original = _seed(kind, 2);
        Map<String, Object?>? saved;
        await forms.openForm(
          tester,
          original['type'] as String,
          initialDefinition: original,
          onSave: (value) async => saved = value,
        );
        await _reveal(tester, kind);
        final id = _id(kind);
        final remove = tester
            .widget<IconButton>(forms.keyed('definition-remove:$id/0'))
            .onPressed!;
        final add = tester
            .widget<TextButton>(forms.keyed('definition-add:$id'))
            .onPressed!;
        final presence = tester
            .widget<Switch>(forms.keyed('definition-presence:$id'))
            .onChanged!;
        final context = tester.element(forms.definitionCollection(id));
        final navigator = Navigator.of(context);
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('cover collection')),
          ),
        );
        await tester.pumpAndSettle();
        remove();
        add();
        presence(false);
        await tester.pumpAndSettle();
        expect(find.text('cover collection'), findsOneWidget);
        navigator.pop();
        await tester.pumpAndSettle();
        await _save(tester);
        expect(saved, original);
      },
    );
  }

  testWidgets('custom item validation covers unmounted rows before saving', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var saves = 0;
    List<String>? saved;
    final original = [for (var i = 0; i < 128; i++) i == 127 ? '256' : '1'];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: DefinitionFormBody(
                  form: form,
                  controller: controller,
                  children: [
                    DefinitionStringListField(
                      id: 'custom-items',
                      label: 'Controlled bytes',
                      initialValue: original,
                      numeric: true,
                      signed: false,
                      unit: 'bytes',
                      optional: false,
                      isValidItem: (value) => value != '256',
                      invalidMessage: 'Controlled item is invalid',
                      onSaved: (value) => saved = value,
                    ),
                  ],
                ),
              ),
              FilledButton(
                onPressed: () {
                  if (form.currentState!.validate()) {
                    form.currentState!.save();
                    saves++;
                  }
                },
                child: const Text('Submit controlled draft'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(forms.keyed('definition-input:custom-items/127'), findsNothing);
    if (const bool.fromEnvironment('validationDisableCollectionParent')) {
      final element = find
          .byWidgetPredicate((widget) => widget is FormField<List<String>>)
          .evaluate()
          .single;
      final originalField = element.widget as FormField<List<String>>;
      element.owner!.buildScope(
        element,
        () => element.update(
          FormField<List<String>>(
            key: originalField.key,
            initialValue: originalField.initialValue,
            onSaved: originalField.onSaved,
            builder: originalField.builder,
          ),
        ),
      );
    }
    await tester.tap(find.text('Submit controlled draft'));
    await tester.pump();
    expect(saves, 0);
    expect(saved, isNull);
    final list = forms.keyed('definition-list:custom-items');
    final scroll = tester.widget<ListView>(list).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final last = forms.keyed('definition-input:custom-items/127');
    await tester.ensureVisible(last);
    expect(
      tester.widget<TextField>(last).keyboardType,
      const TextInputType.numberWithOptions(signed: false),
    );
    await tester.enterText(last, '17');
    await tester.pump();
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit controlled draft'));
    await tester.pump();
    expect(saves, 1);
    expect(saved, [...original.take(127), '17']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scalar mapping cancellation does not add an empty header', (
    tester,
  ) async {
    final original = _seed('mapping', 1);
    Map<String, Object?>? saved;
    await forms.openForm(
      tester,
      'http',
      initialDefinition: original,
      onSave: (value) async => saved = value,
    );
    await _reveal(tester, 'mapping');
    await forms.addRow(tester, 'http/headers');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await _save(tester);
    expect(saved, original);
  });
}
