import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/model/config_entry.dart';

import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shared/definition_forms_test.dart' as forms;

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _open(
  WidgetTester tester,
  Map<String, Object?> original,
  Future<void> Function(Map<String, Object?>) save, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open-group'),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => StrategyGroupFormPage(
                  initialDefinition: original,
                  onSave: save,
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(_key('open-group'));
  await tester.pumpAndSettle();
  // Capture the later geometry anchors only after the real type trigger is
  // exposed above the fixed save area, including the draft notice at 2x text.
  final type = _key('definition-menu:group/type');
  await tester.ensureVisible(type);
  await tester.pumpAndSettle();
  expect(type.hitTestable(), findsOneWidget);
}

Future<void> _selectType(WidgetTester tester, String type) async {
  await tester.tap(_key('definition-menu:group/type'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byWidgetPredicate(
      (widget) => widget is MenuItemButton && widget.key == ValueKey(type),
    ),
  );
}

void main() {
  // Independent public GroupCommonOption and concrete Option type inputs.
  const common = <String, Object?>{
    'name': '本地 group with an intentionally long name',
    'proxies': <String>['DIRECT', 'Not yet defined'],
    'use': <String>[],
    'url': '',
    'interval': 0,
    'timeout': 0,
    'max-failed-times': 0,
    'empty-fallback': '',
    'lazy': false,
    'disable-udp': false,
    'filter': '',
    'exclude-filter': '',
    'exclude-type': '',
    'expected-status': '',
    'include-all': false,
    'include-all-proxies': false,
    'include-all-providers': false,
    'hidden': false,
    'icon': '',
    'unknown-future-option': <String, Object?>{
      'unicode': '保留🧭',
      'false': false,
      'zero': 0,
      'empty': '',
      'null': null,
      'map': <String, Object?>{},
      'list': <Object?>[null, false, 0, '', <String>[]],
    },
  };
  const specific = <String, Map<String, Object?>>{
    'select': {'default-selected': 'DIRECT'},
    'url-test': {'tolerance': 0},
    'fallback': {},
    'load-balance': {'strategy': 'consistent-hashing', 'hash-key': ''},
  };

  for (final from in specific.keys) {
    for (final to in specific.keys) {
      testWidgets(
        '$from to $to changes only the discriminator and preserves untouched options',
        (tester) async {
          final original = <String, Object?>{
            ...common,
            'type': from,
            ...specific[from]!,
          };
          final before = jsonEncode(original);
          final completed = Completer<void>();
          Map<String, Object?>? saved;
          await _open(tester, original, (value) {
            saved = value;
            return completed.future;
          }, scale: 2);
          final anchors = [
            find.byType(AppBar),
            _key('definition-menu:group/type'),
            _key('definition-input:group/name'),
            _key('definition-save:group'),
          ];
          final positions = anchors.map(tester.getRect).toList();
          await _selectType(tester, to);
          for (final elapsed in [0, 16, 80, 250]) {
            await tester.pump(Duration(milliseconds: elapsed));
            expect(anchors.map(tester.getRect).toList(), positions);
            expect(tester.takeException(), isNull);
          }
          await tester.pumpAndSettle();
          await tester.tap(_key('definition-save:group'));
          for (final elapsed in [0, 16, 80]) {
            await tester.pump(Duration(milliseconds: elapsed));
            expect(anchors.map(tester.getRect).toList(), positions);
          }
          expect(saved, <String, Object?>{
            ...common,
            'type': to,
            ...specific[from]!,
          });
          expect(jsonEncode(original), before);
          completed.complete();
          await tester.pumpAndSettle();
          expect(find.byType(StrategyGroupFormPage), findsNothing);
        },
      );
    }
  }

  testWidgets('inactive foreign options are not swept on an unrelated switch', (
    tester,
  ) async {
    final original = <String, Object?>{
      ...common,
      'type': 'select',
      'default-selected': 'DIRECT',
      'tolerance': 27,
      'strategy': 'sticky-sessions',
      'hash-key': 'in-user',
    };
    Map<String, Object?>? saved;
    await _open(tester, original, (value) async => saved = value);
    await _selectType(tester, 'fallback');
    await tester.pumpAndSettle();
    await tester.tap(_key('definition-save:group'));
    await tester.pumpAndSettle();
    expect(saved, {...original, 'type': 'fallback'});
  });

  for (final type in specific.keys) {
    testWidgets('$type branch survives switching back, failure and retry', (
      tester,
    ) async {
      final original = <String, Object?>{
        ...common,
        'type': type,
        ...specific[type]!,
      };
      var pending = Completer<void>();
      final seen = <Map<String, Object?>>[];
      await _open(tester, original, (value) {
        seen.add(value);
        return pending.future;
      }, scale: 2);
      final save = _key('definition-save:group');
      final name = _key('definition-input:group/name');
      final anchors = [tester.getRect(save), tester.getRect(name)];
      await _selectType(tester, type == 'select' ? 'url-test' : 'select');
      await tester.pumpAndSettle();
      await _selectType(tester, type);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pump();
      expect(seen.single, original);
      pending.completeError(ConfigFailure(messages.overrideChangedReopen));
      for (final elapsed in [0, 16, 80]) {
        await tester.pump(Duration(milliseconds: elapsed));
        expect([tester.getRect(save), tester.getRect(name)], anchors);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      expect(find.byType(StrategyGroupFormPage), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(tester.widget<TextField>(name).controller!.text, common['name']);
      pending = Completer<void>();
      await tester.tap(save);
      await tester.pump();
      expect(seen, [original, original]);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(StrategyGroupFormPage), findsNothing);
    });
  }

  testWidgets(
    'explicitly unsetting modeled raw shapes removes only touched fields',
    (tester) async {
      final original = <String, Object?>{
        'type': 'select',
        'name': 'Explicit unset',
        'use': null,
        'timeout': null,
        'lazy': 'false',
        'filter': <Object?>[0],
        'unknown': null,
      };
      Map<String, Object?>? saved;
      await _open(tester, original, (value) async => saved = value);
      await forms.expandAncestors(
        tester,
        forms.keyed('definition-original:group/timeout', offstage: true),
      );
      Future<void> tap(Finder field) async {
        await tester.pump();
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.tap(field);
        await tester.pumpAndSettle();
      }

      await tap(_key('definition-unset-original:group/timeout'));
      final use = forms.keyed('definition-original:group/use', offstage: true);
      await forms.expandAncestors(tester, use);
      await tap(_key('definition-unset-original:group/use'));
      await tap(_key('definition-presence:group/use'));
      await tap(_key('definition-presence:group/use'));
      final timeout = _key('definition-input:group/timeout');
      await tester.ensureVisible(timeout);
      await tester.enterText(timeout, '1');
      await tester.enterText(timeout, '');
      await tap(_key('definition-unset-original:group/lazy'));
      await tap(_key('definition-menu:group/lazy'));
      await tap(find.byKey(const ValueKey('false')));
      await tap(_key('definition-menu:group/lazy'));
      await tap(find.byKey(const ValueKey('\u0000unset')));
      await tap(_key('definition-unset-original:group/filter'));
      await tap(_key('definition-presence:group/filter'));
      final filter = _key('definition-input:group/filter');
      await tester.ensureVisible(filter);
      await tester.enterText(filter, 'temporary');
      await tap(_key('definition-presence:group/filter'));
      await tap(_key('definition-save:group'));
      expect(saved, {
        'type': 'select',
        'name': 'Explicit unset',
        'unknown': null,
      });
      expect(original.containsKey('use'), isTrue);
      expect(original['filter'], [0]);
    },
  );

  for (final to in ['select', 'fallback']) {
    testWidgets(
      'unrepresentable and explicit null fields survive save to $to',
      (tester) async {
        final original = <String, Object?>{
          'type': 'select',
          'name': 'Unchanged raw shapes',
          'proxies': 'DIRECT',
          'use': null,
          'timeout': null,
          'lazy': 'false',
          'filter': <Object?>[false, 0],
          'unknown': null,
        };
        Map<String, Object?>? saved;
        await _open(tester, original, (value) async => saved = value);
        await _selectType(tester, to);
        await tester.pumpAndSettle();
        await tester.tap(_key('definition-save:group'));
        await tester.pumpAndSettle();
        expect(saved, {...original, 'type': to});
      },
    );
  }
}
