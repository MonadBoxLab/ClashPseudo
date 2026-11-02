import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shared/definition_forms_test.dart' as forms;

const _scope = 'provider/override/proxy-name';

Finder _inputs() => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return widget is TextField &&
      key is ValueKey<String> &&
      key.value.startsWith('definition-input:$_scope/') &&
      !key.value.contains('/prototype/');
});

Future<void> _open(
  WidgetTester tester,
  List<Map<String, Object?>> rows, {
  required ValueChanged<Map<String, Object?>> onSave,
  Size size = const Size(440, 1136),
  Locale locale = const Locale('en'),
  TextScaler scaler = TextScaler.noScaling,
}) async {
  await forms.openForm(
    tester,
    ProviderFormPage(
      ruleProvider: false,
      initialName: 'controlled-provider',
      initialDefinition: {
        'type': 'inline',
        'override': {'proxy-name': rows},
      },
      onSave: (_, definition) async => onSave(definition),
    ),
    size: size,
    locale: locale,
    scaler: scaler,
  );
  await forms.expandAncestors(
    tester,
    forms.keyed('provider-replacement-list', offstage: true),
  );
}

void main() {
  testWidgets('128 replacement rows construct only the visible inputs', (
    tester,
  ) async {
    await _open(
      tester,
      List.generate(
        128,
        (index) => {'pattern': 'old-$index', 'target': 'new-$index'},
      ),
      onSave: (_) {},
    );
    expect(_inputs().evaluate().length, lessThan(60));
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'zh']) {
    for (final width in [320.0, 1704.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '4096 replacements retain offscreen edits and row identities $language/$width/$scale',
          (tester) async {
            final built = <String>{};
            final previous = debugOnRebuildDirtyWidget;
            debugOnRebuildDirtyWidget = (element, builtOnce) {
              previous?.call(element, builtOnce);
              final key = element.widget.key;
              if (element.widget is TextField &&
                  key is ValueKey<String> &&
                  key.value.startsWith('definition-input:$_scope/') &&
                  !key.value.contains('/prototype/')) {
                built.add(key.value);
              }
            };
            addTearDown(() => debugOnRebuildDirtyWidget = previous);
            final rows = List.generate(
              4096,
              (index) => <String, Object?>{
                'pattern': 'old-$index · 测试 é 🚀',
                'target': 'new-$index',
                'future': {
                  'retained': [false, 0, '', null],
                },
              },
            );
            Map<String, Object?>? saved;
            await _open(
              tester,
              rows,
              onSave: (value) => saved = value,
              size: Size(width, 1136),
              locale: Locale(language),
              scaler: TextScaler.linear(scale),
            );
            expect(_inputs().evaluate().length, lessThan(60));
            expect(
              forms.keyed('definition-input:$_scope/4095/pattern'),
              findsNothing,
            );
            final list = forms.keyed('provider-replacement-list');
            await tester.ensureVisible(list);
            await tester.pumpAndSettle();
            final scrollable = find
                .descendant(of: list, matching: find.byType(Scrollable))
                .first;
            final position = tester.state<ScrollableState>(scrollable).position;
            position.jumpTo(position.maxScrollExtent);
            await tester.pumpAndSettle();
            await forms.text(tester, '$_scope/4095/pattern', 'edited-last');
            FocusManager.instance.primaryFocus?.unfocus();
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(
              forms.keyed('definition-remove:$_scope/4094'),
              -300,
              scrollable: scrollable,
            );
            final remove = tester
                .widget<IconButton>(
                  forms.keyed('definition-remove:$_scope/4094'),
                )
                .onPressed!;
            remove();
            remove();
            await tester.pumpAndSettle();
            final up = tester
                .widget<IconButton>(forms.keyed('definition-up:$_scope/4095'))
                .onPressed!;
            up();
            up();
            await tester.pumpAndSettle();
            position.jumpTo(0);
            await tester.pumpAndSettle();
            expect(
              forms.keyed('definition-input:$_scope/4095/pattern'),
              findsNothing,
            );
            expect(
              tester.state<ScrollableState>(scrollable).position,
              same(position),
            );
            expect(built.length, lessThan(120));
            await forms.tap(tester, forms.keyed('definition-save:provider'));
            final expected = [...rows]..removeAt(4094);
            final edited = {...expected.removeLast(), 'pattern': 'edited-last'};
            expected.insert(expected.length - 2, edited);
            expect(saved, {
              'type': 'inline',
              'override': {'proxy-name': expected},
            });
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('an unbuilt empty replacement pattern cannot be saved', (
    tester,
  ) async {
    final rows = List.generate(
      4096,
      (index) => <String, Object?>{
        'pattern': index == 2048 ? '' : 'old-$index',
        'target': '',
      },
    );
    final untouched = [
      for (final row in rows) {...row},
    ];
    Map<String, Object?>? saved;
    Future<void> open() =>
        _open(tester, rows, onSave: (value) => saved = value);
    await open();
    final save = forms.keyed('definition-save:provider');
    await forms.tap(tester, save);
    expect(saved, {
      'type': 'inline',
      'override': {'proxy-name': rows},
    });
    expect(find.byType(ProviderFormPage), findsNothing);
    saved = null;
    await open();
    final presence = forms.keyed('definition-presence:$_scope');
    await forms.tap(tester, presence);
    expect(tester.widget<Switch>(presence).value, isFalse);
    await forms.tap(tester, presence);
    expect(tester.widget<Switch>(presence).value, isTrue);
    expect(
      tester
          .widget<TextField>(forms.keyed('definition-input:$_scope/0/pattern'))
          .controller!
          .text,
      rows.first['pattern'],
    );
    expect(forms.keyed('definition-input:$_scope/2048/pattern'), findsNothing);
    if (const bool.fromEnvironment('validationDisableReplacementParent')) {
      // Host-only negative control: remove only the real parent validator.
      final element = find
          .byWidgetPredicate(
            (widget) => widget is FormField<List<Map<String, Object?>>>,
          )
          .evaluate()
          .single;
      final original = element.widget as FormField<List<Map<String, Object?>>>;
      element.owner!.buildScope(
        element,
        () => element.update(
          FormField<List<Map<String, Object?>>>(
            key: original.key,
            initialValue: original.initialValue,
            onSaved: original.onSaved,
            builder: original.builder,
          ),
        ),
      );
    }
    final before = tester.getRect(save);
    await forms.tap(tester, save);
    expect(saved, isNull);
    expect(tester.getRect(save), before);
    expect(tester.takeException(), isNull);
    await forms.tap(tester, forms.keyed('definition-presence:$_scope'));
    await forms.tap(tester, save);
    expect(saved, {'type': 'inline'});
    expect(rows, untouched);
    expect(tester.takeException(), isNull);
  });
}
