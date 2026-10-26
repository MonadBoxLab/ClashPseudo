import 'package:clash_pseudo/src/features/overrides/definition_form_body.dart';
import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';
import 'package:clash_pseudo/src/features/overrides/strategy_group_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'definition_forms_test.dart' as forms;

Widget embedded(Widget child) {
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  return DefinitionFormBody(
    form: GlobalKey<FormState>(),
    controller: scroll,
    chapters: [
      DefinitionFormChapter(id: 'embedded', title: 'Values', children: [child]),
    ],
  );
}

void main() {
  testWidgets('embedded empty list does not add window padding a second time', (
    tester,
  ) async {
    await forms.openForm(
      tester,
      Scaffold(
        body: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 900),
            padding: EdgeInsets.only(top: 36, bottom: 24),
            viewPadding: EdgeInsets.only(top: 36, bottom: 24),
          ),
          child: embedded(
            DefinitionStringListField(
              id: 'embedded',
              label: 'Values',
              initialValue: const [],
              optional: false,
              allowEmptyItems: true,
              onSaved: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(forms.keyed('definition-list:embedded')).height,
      0,
      reason: 'The surrounding page, not an embedded field, owns system insets',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard metrics do not move an embedded empty-list action', (
    tester,
  ) async {
    final media = ValueNotifier(
      const MediaQueryData(
        size: Size(320, 900),
        padding: EdgeInsets.only(top: 36, bottom: 24),
        viewPadding: EdgeInsets.only(top: 36, bottom: 24),
      ),
    );
    addTearDown(media.dispose);
    await forms.openForm(
      tester,
      Scaffold(
        body: ValueListenableBuilder<MediaQueryData>(
          valueListenable: media,
          builder: (_, data, child) => MediaQuery(data: data, child: child!),
          child: embedded(
            DefinitionStringListField(
              id: 'keyboard-embedded',
              label: 'Values',
              initialValue: const [],
              optional: false,
              allowEmptyItems: true,
              onSaved: (_) {},
            ),
          ),
        ),
      ),
    );
    final list = forms.keyed('definition-list:keyboard-embedded');
    final add = forms.keyed('definition-add:keyboard-embedded');
    final before = tester.getRect(add);
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable.first).position;
    for (final bottom in [240.0, 0.0, 320.0, 0.0]) {
      media.value = media.value.copyWith(
        viewInsets: EdgeInsets.only(bottom: bottom),
        padding: EdgeInsets.only(top: 36, bottom: bottom == 0 ? 24 : 0),
      );
      for (final ms in [0, 16, 80]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(tester.getSize(list).height, 0);
        expect(tester.getRect(add), before);
        expect(
          tester.state<ScrollableState>(scrollable.first).position,
          same(position),
        );
        expect(tester.takeException(), isNull);
      }
    }
  });

  for (final (count, language, width, scale) in [
    (128, 'en', 320.0, 1.0),
    for (final language in ['en', 'zh'])
      for (final width in [320.0, 1704.0])
        for (final scale in [1.0, 2.0]) (4096, language, width, scale),
  ]) {
    testWidgets('group $count members stay lazy $language/$width/$scale', (
      tester,
    ) async {
      final builtRows = <String>{};
      final previousBuild = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousBuild?.call(element, builtOnce);
        final key = element.widget.key;
        if (element.widget is TextField &&
            key is ValueKey<String> &&
            key.value.startsWith('definition-input:group/proxies/') &&
            !key.value.endsWith('/prototype')) {
          builtRows.add(key.value);
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousBuild);
      Map<String, Object?>? saved;
      final members = List.generate(
        count,
        (index) => index.isEven
            ? 'member-$index · 中文 é 🚀 ${'long name ' * 8}'
            : 'member-$index',
      );
      final original = <String, Object?>{
        'name': 'many-members',
        'type': 'select',
        'proxies': members,
        'unknown': {'retained': false},
      };
      await forms.openForm(
        tester,
        StrategyGroupFormPage(
          initialDefinition: original,
          members: const ['DIRECT', 'REJECT'],
          onSave: (definition) async => saved = definition,
        ),
        size: Size(width, 1136),
        locale: Locale(language),
        scaler: TextScaler.linear(scale),
      );
      final inputs = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return widget is TextField &&
            key is ValueKey<String> &&
            key.value.startsWith('definition-input:group/proxies/') &&
            !key.value.endsWith('/prototype');
      });
      expect(inputs.evaluate().length, lessThan(60));
      final list = forms.keyed('definition-list:group/proxies');
      await tester.ensureVisible(list);
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable.first).position;
      await forms.tap(
        tester,
        forms.keyed('definition-suggestions:group/proxies/0'),
      );
      await forms.tap(tester, forms.keyed('DIRECT'));
      expect(
        tester
            .widget<TextField>(forms.keyed('definition-input:group/proxies/0'))
            .controller!
            .text,
        'DIRECT',
      );
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await forms.text(tester, 'group/proxies/${count - 1}', 'edited-last');
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        forms.keyed('definition-input:group/proxies/${count - 1}'),
        findsNothing,
      );
      await forms.tap(tester, forms.keyed('definition-add:group/proxies'));
      await forms.text(tester, 'group/proxies/$count', 'appended');
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final up = tester
          .widget<IconButton>(forms.keyed('definition-up:group/proxies/$count'))
          .onPressed!;
      up();
      up();
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scrollable.first).position,
        same(position),
      );
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(inputs.evaluate().length, lessThan(60));
      expect(
        builtRows.length,
        lessThan(100),
        reason: 'Far jumps must not build the intermediate text inputs',
      );
      await forms.tap(tester, forms.keyed('definition-save:group'));
      final expected = [
        'DIRECT',
        ...members.skip(1).take(count - 2),
        'edited-last',
      ]..insert(count - 2, 'appended');
      expect(saved, {...original, 'proxies': expected});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'excluded list keeps its draft but does not validate or save it',
    (tester) async {
      Map<String, Object?>? saved;
      final members = List.generate(4096, (index) => 'member-$index')
        ..[2048] = '';
      await forms.openForm(
        tester,
        StrategyGroupFormPage(
          initialDefinition: {
            'name': 'excluded-members',
            'type': 'select',
            'proxies': members,
          },
          onSave: (definition) async => saved = definition,
        ),
      );
      final presence = forms.keyed('definition-presence:group/proxies');
      await forms.tap(tester, presence);
      await forms.tap(tester, presence);
      expect(
        tester
            .widget<TextField>(forms.keyed('definition-input:group/proxies/0'))
            .controller!
            .text,
        members.first,
      );
      await forms.tap(tester, presence);
      await forms.tap(tester, forms.keyed('definition-save:group'));
      expect(saved, {'name': 'excluded-members', 'type': 'select'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unbuilt empty member blocks saving until its draft is repaired',
    (tester) async {
      Map<String, Object?>? saved;
      final members = List.generate(4096, (index) => 'member-$index');
      members[2048] = '';
      await forms.openForm(
        tester,
        StrategyGroupFormPage(
          initialDefinition: {
            'name': 'invalid-middle',
            'type': 'select',
            'proxies': members,
          },
          onSave: (definition) async => saved = definition,
        ),
      );
      final invalidInput = forms.keyed('definition-input:group/proxies/2048');
      final list = forms.keyed('definition-list:group/proxies');
      final add = forms.keyed('definition-add:group/proxies');
      final addOffset = tester.getTopLeft(add).dy - tester.getTopLeft(list).dy;
      expect(invalidInput, findsNothing);
      await forms.tap(tester, forms.keyed('definition-save:group'));
      expect(saved, isNull);
      expect(find.byType(StrategyGroupFormPage), findsOneWidget);
      expect(
        tester.getTopLeft(add).dy - tester.getTopLeft(list).dy,
        closeTo(addOffset, .01),
        reason: 'List validation must not insert height or move its actions',
      );
      await tester.ensureVisible(list);
      await tester.pumpAndSettle();
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable.first).position;
      position.jumpTo(position.maxScrollExtent * 2048 / 4095);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        invalidInput,
        100,
        scrollable: scrollable.first,
      );
      await forms.text(tester, 'group/proxies/2048', 'repaired-middle');
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(invalidInput, findsNothing);
      await forms.tap(tester, forms.keyed('definition-save:group'));
      final expected = [...members]..[2048] = 'repaired-middle';
      expect(saved, {
        'name': 'invalid-middle',
        'type': 'select',
        'proxies': expected,
      });
      expect(tester.takeException(), isNull);
    },
  );
}
