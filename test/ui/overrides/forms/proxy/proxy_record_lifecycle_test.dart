import 'dart:convert';

import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proxy_form_test.dart' as forms;

Map<String, Object?> _seed(int count) => {
  'name': 'controlled peers',
  'type': 'wireguard',
  'private-key': 'controlled-not-a-real-key',
  'future-root': [false, 0, '', null],
  'peers': [
    for (var i = 0; i < count; i++)
      {
        'server': '192.0.2.1',
        'port': 18000 + i,
        'public-key': 'controlled-public-$i',
        'allowed-ips': <String>[],
        'future-peer': {'id': i, 'enabled': false, 'value': ''},
      },
  ],
};

Finder _row(int ordinal) => find.ancestor(
  of: find.text('peers $ordinal'),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is ListTile &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'proxy-row:wireguard/peers/',
        ),
  ),
);

String _scope(WidgetTester tester, Finder row) =>
    (tester.widget<ListTile>(row).key! as ValueKey<String>).value.substring(
      'proxy-row:'.length,
    );

Future<ScrollController> _reveal(WidgetTester tester) async {
  final group = forms.keyed('proxy-group:wireguard/peers', offstage: true);
  await forms.expandAncestors(tester, group);
  final header = find
      .descendant(
        of: group,
        matching: find.byType(ListTile, skipOffstage: false),
      )
      .first;
  final controller = ExpansibleController.of(tester.element(header));
  if (!controller.isExpanded) {
    controller.expand();
    await tester.pumpAndSettle();
  }
  final list = forms.keyed('proxy-record-list:wireguard/peers');
  await tester.ensureVisible(list);
  await tester.pumpAndSettle();
  return tester.widget<ListView>(list).controller!;
}

Future<String> _edit(WidgetTester tester, int ordinal) async {
  final scope = _scope(tester, _row(ordinal));
  final edit = forms.keyed('proxy-edit:$scope');
  await tester.ensureVisible(edit);
  await tester.tap(edit);
  await tester.pumpAndSettle();
  return scope;
}

Future<void> _save(WidgetTester tester) async {
  await forms.tap(tester, forms.keyed('proxy-save'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _touchRecords(WidgetTester tester, String id) async {
  final presence = forms.keyed('proxy-enable:$id', offstage: true);
  await forms.expandAncestors(tester, presence);
  expect(tester.widget<Switch>(presence).value, isTrue);
  for (final enabled in [false, true]) {
    await tester.ensureVisible(presence);
    await tester.tap(presence);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(presence).value, enabled);
  }
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
  final dialog = find.byType(AlertDialog);
  if (dialog.evaluate().isNotEmpty) {
    final strings = AppLocalizations.of(tester.element(dialog));
    await tester.tap(find.text(strings.discard));
    await tester.pumpAndSettle();
  }
}

class _RecordTextScaler extends TextScaler {
  const _RecordTextScaler();
  @override
  double scale(double fontSize) => fontSize * (fontSize <= 18 ? 1.8 : 1.3);
  @override
  double get textScaleFactor => 1.5;
}

void main() {
  for (final language in ['en', 'zh']) {
    for (final width in [320.0, 1704.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '4096 peers edit, cancel, remove and save $language $width $scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1136);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final original = _seed(4096);
            final untouched = jsonDecode(jsonEncode(original));
            Map<String, Object?>? saved;
            await forms.openForm(
              tester,
              'wireguard',
              initialDefinition: original,
              locale: Locale(language),
              scaler: TextScaler.linear(scale),
              onSave: (value) async => saved = value,
            );
            final scroll = await _reveal(tester);
            expect(
              find.byType(TextField, skipOffstage: false).evaluate().length,
              lessThan(100),
            );
            expect(
              find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is ListTile &&
                        widget.key is ValueKey<String> &&
                        (widget.key! as ValueKey<String>).value.startsWith(
                          'proxy-row:wireguard/peers/',
                        ),
                  )
                  .evaluate()
                  .length,
              lessThan(60),
            );
            scroll.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
            final position = scroll.position;
            final scope = await _edit(tester, 4096);
            await forms.fillScalar(tester, scope, 'port', 51821);
            await _save(tester);
            expect(identical(scroll.position, position), isTrue);
            await _edit(tester, 4096);
            expect(find.text('51821'), findsOneWidget);
            await forms.fillScalar(tester, scope, 'port', 51822);
            await _back(tester);
            await _edit(tester, 4096);
            expect(find.text('51821'), findsOneWidget);
            await _back(tester);
            final remove = tester
                .widget<IconButton>(forms.keyed('proxy-remove:$scope'))
                .onPressed!;
            remove();
            await tester.pump();
            remove();
            await tester.pump();
            scroll.jumpTo(0);
            await tester.pumpAndSettle();
            expect(_row(4096), findsNothing);
            await _save(tester);
            expect(saved, {
              ...original,
              'peers': (original['peers']! as List).take(4095).toList(),
            });
            expect(original, untouched);
          },
        );
      }
    }
  }

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 1704.0]) {
      for (final scaler in [
        TextScaler.noScaling,
        TextScaler.linear(2),
        const _RecordTextScaler(),
      ]) {
        testWidgets(
          'record error and keyboard frames retain anchors $language $width $scaler',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1136);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetViewInsets);
            final original = _seed(3);
            var saves = 0;
            await forms.openForm(
              tester,
              'wireguard',
              initialDefinition: original,
              locale: Locale(language),
              scaler: scaler,
              onSave: (_) async {
                saves++;
              },
            );
            final parentScroll = await _reveal(tester);
            // SDK ensureVisible aligns each ancestor to the icon's box. Capture
            // the reading anchor after that deliberate preparation, before tap.
            final firstScope = _scope(tester, _row(1));
            await tester.ensureVisible(forms.keyed('proxy-edit:$firstScope'));
            await tester.pumpAndSettle();
            final parentPosition = parentScroll.position;
            final parentPixels = parentScroll.offset;
            final parentRect = tester.getRect(_row(1));
            final scope = await _edit(tester, 1);
            final title = find.descendant(
              of: find.byType(AppBar),
              matching: find.text('peers'),
            );
            expect(
              MediaQuery.textScalerOf(tester.element(title)).scale(22),
              scaler.scale(22),
            );
            await forms.fillScalar(tester, scope, 'port', 65536);
            tester.view.viewInsets = const FakeViewPadding(bottom: 360);
            await tester.pumpAndSettle();
            final input = forms.keyed('proxy-field:$scope/port');
            await tester.ensureVisible(input);
            await tester.pumpAndSettle();
            final save = forms.keyed('proxy-save');
            final saveRect = tester.getRect(save);
            final inputRect = tester.getRect(input);
            final titleRect = tester.getRect(title);
            final editable = tester.widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            );
            editable.controller.selection = const TextSelection(
              baseOffset: 2,
              extentOffset: 5,
            );
            final selection = editable.controller.selection;
            final position = tester
                .state<ScrollableState>(
                  find
                      .descendant(
                        of: forms.keyed('proxy-form-scroll'),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                )
                .position;
            final pixels = position.pixels;
            final focus = FocusManager.instance.primaryFocus;
            await tester.tap(save);
            for (final ms in [0, 16, 32, 80]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(save), saveRect);
              expect(tester.getRect(input), inputRect);
              expect(tester.getRect(title), titleRect);
              expect(position.pixels, pixels);
              expect(FocusManager.instance.primaryFocus, focus);
              expect(editable.controller.selection, selection);
              expect(editable.controller.text, '65536');
              expect(saves, 0);
              expect(tester.takeException(), isNull);
            }
            tester.view.viewInsets = const FakeViewPadding();
            await tester.pumpAndSettle();
            await _back(tester);
            expect(identical(parentScroll.position, parentPosition), isTrue);
            expect(parentScroll.offset, parentPixels);
            expect(tester.getRect(_row(1)), parentRect);
            await _save(tester);
            expect(saves, 1);
          },
        );
      }
    }
  }

  for (final invalid in [65536, -1, 'not-an-integer']) {
    testWidgets(
      'unmounted port $invalid in an edited parent draft cannot bypass validation',
      (tester) async {
        final original = _seed(4096);
        ((original['peers']! as List).last as Map)['port'] = invalid;
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
        expect(find.byType(ProxyFormPage), findsNothing);
        saved = null;
        await open();
        final scroll = await _reveal(tester);
        await _touchRecords(tester, 'wireguard/peers');
        expect(_row(4096), findsNothing);
        if (const bool.fromEnvironment('validationDisableRecordParent')) {
          final element = forms
              .keyed('proxy-collection:wireguard/peers')
              .evaluate()
              .single;
          final originalField = element.widget as FormField<bool>;
          element.owner!.buildScope(
            element,
            () => element.update(
              FormField<bool>(
                key: originalField.key,
                initialValue: originalField.initialValue,
                onSaved: originalField.onSaved,
                builder: originalField.builder,
              ),
            ),
          );
        }
        await _save(tester);
        expect(saved, isNull);
        final field = tester.state<FormFieldState<bool>>(
          forms.keyed('proxy-collection:wireguard/peers'),
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(ProxyFormPage)),
        );
        expect(field.errorText, strings.proxyInvalidPort);
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final scope = await _edit(tester, 4096);
        await forms.fillScalar(tester, scope, 'port', 51821);
        await _save(tester);
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        await _save(tester);
        final expected = jsonDecode(jsonEncode(original)) as Map;
        ((expected['peers'] as List).last as Map)['port'] = 51821;
        expect(saved, expected);
        expect(original, untouched);
      },
    );
  }

  testWidgets(
    'unmounted reserved byte is validated, disabled peers preserve the draft',
    (tester) async {
      final original = _seed(128);
      ((original['peers']! as List).last as Map)['reserved'] = [0, 256];
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
      expect(find.byType(ProxyFormPage), findsNothing);
      saved = null;
      await open();
      await _reveal(tester);
      await _touchRecords(tester, 'wireguard/peers');
      expect(_row(128), findsNothing);
      await _save(tester);
      expect(saved, isNull);
      final toggle = forms.keyed('proxy-enable:wireguard/peers');
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _save(tester);
      expect(saved, isNull);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _save(tester);
      expect(saved, Map<String, Object?>.of(original)..remove('peers'));
      expect(original, untouched);
    },
  );

  testWidgets('adding then cancelling does not create or enable absent peers', (
    tester,
  ) async {
    final original = _seed(0)..remove('peers');
    Map<String, Object?>? saved;
    await forms.openForm(
      tester,
      'wireguard',
      initialDefinition: original,
      onSave: (value) async => saved = value,
    );
    await _reveal(tester);
    final toggle = forms.keyed('proxy-enable:wireguard/peers');
    expect(tester.widget<Switch>(toggle).value, isFalse);
    final add = forms.keyed('proxy-add:wireguard/peers');
    await tester.ensureVisible(add);
    final oldAdd = tester.widget<TextButton>(add).onPressed!;
    oldAdd();
    oldAdd();
    await tester.pumpAndSettle();
    expect(find.byType(ProxyFormPage, skipOffstage: false), findsNWidgets(2));
    await _back(tester);
    expect(tester.widget<Switch>(toggle).value, isFalse);
    await _save(tester);
    expect(saved, original);
    oldAdd();
    await tester.pumpAndSettle();
    expect(find.byType(ProxyFormPage), findsNothing);
  });

  testWidgets(
    'covered parent cannot save, remove, toggle or open another record',
    (tester) async {
      var saves = 0;
      await forms.openForm(
        tester,
        'wireguard',
        initialDefinition: _seed(3),
        onSave: (_) async {
          saves++;
        },
      );
      await _reveal(tester);
      final scope = _scope(tester, _row(1));
      final parentSave = tester
          .widget<FilledButton>(forms.keyed('proxy-save'))
          .onPressed!;
      final edit = tester
          .widget<IconButton>(forms.keyed('proxy-edit:$scope'))
          .onPressed!;
      final remove = tester
          .widget<IconButton>(forms.keyed('proxy-remove:$scope'))
          .onPressed!;
      final toggle = tester
          .widget<Switch>(forms.keyed('proxy-enable:wireguard/peers'))
          .onChanged!;
      edit();
      await tester.pumpAndSettle();
      parentSave();
      remove();
      toggle(false);
      edit();
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(find.byType(ProxyFormPage, skipOffstage: false), findsNWidgets(2));
      final childSave = tester
          .widget<FilledButton>(forms.keyed('proxy-save'))
          .onPressed!;
      final context = tester.element(find.byType(ProxyFormPage));
      final navigator = Navigator.of(context);
      navigator.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('cover'))),
      );
      await tester.pumpAndSettle();
      childSave();
      await tester.pumpAndSettle();
      expect(find.text('cover'), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      childSave();
      childSave();
      await tester.pumpAndSettle();
      expect(find.byType(ProxyFormPage), findsOneWidget);
      expect(
        tester
            .widget<Switch>(forms.keyed('proxy-enable:wireguard/peers'))
            .value,
        isTrue,
      );
      expect(_row(1), findsOneWidget);
      expect(_row(3), findsOneWidget);
      await _save(tester);
      expect(saves, 1);
      childSave();
      remove();
      edit();
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.byType(ProxyFormPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offscreen required orbit values are validated before any child is built',
    (tester) async {
      var saves = 0;
      Map<String, Object?>? saved;
      final original = <String, Object?>{
        'name': 'controlled orbit',
        'type': 'zerotier',
        'network': 'controlled',
        'orbit': [
          for (var i = 0; i < 4096; i++)
            {'world': i == 4095 ? '' : 'controlled-$i', 'seed': 'controlled'},
        ],
      };
      final untouched = jsonDecode(jsonEncode(original));
      Future<void> open() => forms.openForm(
        tester,
        'zerotier',
        initialDefinition: original,
        onSave: (value) async {
          saved = value;
          saves++;
        },
      );
      await open();
      await _save(tester);
      expect(saves, 1);
      expect(saved, original);
      expect(find.byType(ProxyFormPage), findsNothing);
      saves = 0;
      saved = null;
      await open();
      await _touchRecords(tester, 'zerotier/orbit');
      expect(find.text('orbit 4096'), findsNothing);
      expect(find.byType(ProxyFormPage, skipOffstage: false), findsOneWidget);
      await _save(tester);
      expect(saves, 0);
      expect(saved, isNull);
      final field = tester.state<FormFieldState<bool>>(
        forms.keyed('proxy-collection:zerotier/orbit', offstage: true),
      );
      expect(field.hasError, isTrue);
      expect(original, untouched);
    },
  );

  for (final language in ['en', 'zh']) {
    testWidgets(
      'record prototype and hidden errors leave the reachable semantics tree $language',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await forms.openForm(
            tester,
            'wireguard',
            initialDefinition: _seed(128),
            locale: Locale(language),
            onSave: (_) async {},
          );
          final scroll = await _reveal(tester);
          List<String> labels() {
            var root = tester.getSemantics(forms.keyed('proxy-save'));
            while (root.parent != null) {
              root = root.parent!;
            }
            final result = <String>[];
            void collect(SemanticsNode node) {
              result.add(node.getSemanticsData().label);
              node.visitChildren((child) {
                collect(child);
                return true;
              });
            }

            collect(root);
            return result;
          }

          final strings = AppLocalizations.of(
            tester.element(find.byType(ProxyFormPage)),
          );
          bool hasRow(List<String> values, int number) => values.any(
            (value) => RegExp('(^|\\n)peers $number(\\n|\$)').hasMatch(value),
          );
          final before = labels();
          expect(hasRow(before, 1), isTrue);
          expect(hasRow(before, 128), isFalse);
          expect(
            before.any((value) => value.contains(strings.proxyInvalidPort)),
            isFalse,
          );
          expect(
            before.any((value) => value.contains(strings.proxyRequired)),
            isFalse,
          );
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          final after = labels();
          expect(hasRow(after, 128), isTrue);
          expect(hasRow(after, 1), isFalse);
          expect(
            after.any((value) => value.contains(strings.proxyInvalidPort)),
            isFalse,
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets('disposed record owner and child reject every retained action', (
    tester,
  ) async {
    var saves = 0;
    await forms.openForm(
      tester,
      'wireguard',
      initialDefinition: _seed(3),
      onSave: (_) async {
        saves++;
      },
    );
    await _reveal(tester);
    final scope = _scope(tester, _row(1));
    final remove = tester
        .widget<IconButton>(forms.keyed('proxy-remove:$scope'))
        .onPressed!;
    final edit = tester
        .widget<IconButton>(forms.keyed('proxy-edit:$scope'))
        .onPressed!;
    edit();
    await tester.pumpAndSettle();
    final save = tester
        .widget<FilledButton>(forms.keyed('proxy-save'))
        .onPressed!;
    await tester.pumpWidget(const SizedBox());
    save();
    remove();
    edit();
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(tester.takeException(), isNull);
  });

  for (final bad in ['weight', 'base', 'pair']) {
    testWidgets('unmounted nested traffic step validates $bad', (tester) async {
      var saves = 0;
      final step = <String, Object?>{
        'next-step': [
          {'weight': bad == 'weight' ? 2147483648 : 1},
        ],
        'wait-time': {
          'base-nanoseconds': bad == 'base'
              ? -1
              : bad == 'pair'
              ? 9223372036854775807
              : 0,
          'uniform-random-multiplier-nanoseconds': bad == 'pair' ? 2 : 0,
        },
      };
      final original = <String, Object?>{
        'name': 'controlled steps',
        'type': 'vmess',
        'server': '192.0.2.1',
        'port': 18080,
        'uuid': 'controlled',
        'alterId': 0,
        'cipher': 'auto',
        'tlsmirror-opts': {
          'embedded-traffic-generator': {
            'steps': [
              for (var i = 0; i < 128; i++)
                i == 127 ? step : <String, Object?>{},
            ],
          },
        },
      };
      final untouched = jsonDecode(jsonEncode(original));
      Map<String, Object?>? saved;
      Future<void> open() => forms.openForm(
        tester,
        'vmess',
        initialDefinition: original,
        onSave: (value) async {
          saved = value;
          saves++;
        },
      );
      await open();
      await _save(tester);
      expect(saves, 1);
      expect(saved, original);
      expect(find.byType(ProxyFormPage), findsNothing);
      saves = 0;
      saved = null;
      await open();
      await _touchRecords(
        tester,
        'vmess/tlsmirror-opts/embedded-traffic-generator/steps',
      );
      expect(find.text('steps 128'), findsNothing);
      expect(find.byType(ProxyFormPage, skipOffstage: false), findsOneWidget);
      await _save(tester);
      expect(saves, 0);
      expect(saved, isNull);
      final field = tester.state<FormFieldState<bool>>(
        forms.keyed(
          'proxy-collection:vmess/tlsmirror-opts/embedded-traffic-generator/steps',
          offstage: true,
        ),
      );
      expect(field.hasError, isTrue);
      expect(original, untouched);
    });
  }
}
