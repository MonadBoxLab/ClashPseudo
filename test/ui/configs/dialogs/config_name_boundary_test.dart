import 'package:clash_pseudo/src/ui/configs/dialogs/config_field_dialog.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/import_dialog.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = [
    (name: 'a' * 80, bytes: 80, valid: true, label: 'ASCII boundary'),
    (name: 'a' * 81, bytes: 81, valid: false, label: 'ASCII overflow'),
    (name: '${'中' * 26}ab', bytes: 80, valid: true, label: 'CJK boundary'),
    (name: '中' * 27, bytes: 81, valid: false, label: 'CJK overflow'),
    (name: '🌐' * 20, bytes: 80, valid: true, label: 'emoji boundary'),
    (name: '🌐' * 21, bytes: 84, valid: false, label: 'emoji overflow'),
    (
      name: '${'é' * 26}ab',
      bytes: 80,
      valid: true,
      label: 'combining boundary',
    ),
    (name: 'é' * 27, bytes: 81, valid: false, label: 'combining overflow'),
    (
      name: '  ${'🌐' * 20}\t',
      bytes: 83,
      valid: false,
      label: 'surrounding whitespace counts toward capacity',
    ),
    (name: '  🌐\t', bytes: 7, valid: true, label: 'retained whitespace'),
    (name: ' \t ', bytes: 3, valid: false, label: 'blank name'),
  ];

  for (final sample in cases) {
    for (final language in ['en', 'zh']) {
      for (final kind in ['name', 'config import', 'plugin import']) {
        for (final semantics in [false, true]) {
          testWidgets(
            '$language $kind UTF-8 counter semantics=$semantics: ${sample.label}',
            (tester) async {
              final handle = tester.ensureSemantics();
              try {
                await tester.pumpWidget(
                  MaterialApp(
                    locale: Locale(language),
                    localizationsDelegates:
                        AppLocalizations.localizationsDelegates,
                    supportedLocales: AppLocalizations.supportedLocales,
                    home: Builder(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => kind == 'name'
                                ? const ConfigFieldDialog(initial: '')
                                : ImportDialog(
                                    fragment: kind == 'plugin import',
                                  ),
                          ),
                          child: const Text('Open'),
                        ),
                      ),
                    ),
                  ),
                );
                await tester.tap(find.text('Open'));
                await tester.pumpAndSettle();
                final strings = AppLocalizations.of(
                  tester.element(find.byType(AlertDialog)),
                );
                final field = find.byType(TextField).at(kind == 'name' ? 0 : 1);
                if (semantics) {
                  await tester.tap(field);
                  await tester.pumpAndSettle();
                  final owner = tester
                      .element(field)
                      .findRenderObject()!
                      .owner!
                      .semanticsOwner!;
                  final inputs = <SemanticsNode>[];
                  void visit(SemanticsNode node) {
                    if (node.getSemanticsData().flagsCollection.isTextField) {
                      inputs.add(node);
                    }
                    node.visitChildren((child) {
                      visit(child);
                      return true;
                    });
                  }

                  visit(owner.rootSemanticsNode!);
                  expect(
                    inputs,
                    hasLength(
                      kind == 'name'
                          ? 1
                          : kind == 'config import'
                          ? 2
                          : 3,
                    ),
                  );
                  final node = inputs[kind == 'name' ? 0 : 1];
                  expect(
                    node.getSemanticsData().hasAction(SemanticsAction.setText),
                    isTrue,
                  );
                  owner.performAction(
                    node.id,
                    SemanticsAction.setText,
                    sample.name,
                  );
                } else {
                  await tester.enterText(field, sample.name);
                }
                await tester.pump();
                expect(find.text('${sample.bytes}/80 B'), findsOneWidget);
                final button = kind == 'name'
                    ? find.widgetWithText(TextButton, strings.save)
                    : find.widgetWithText(
                        FilledButton,
                        strings.downloadAndSave,
                      );
                final enabled = kind == 'name'
                    ? tester.widget<TextButton>(button).onPressed != null
                    : tester.widget<FilledButton>(button).onPressed != null;
                expect(enabled, sample.valid);
                expect(
                  tester.widget<TextField>(field).controller!.text,
                  sample.name,
                );
                if (kind == 'name') {
                  expect(
                    tester.widget<TextField>(field).decoration!.labelText,
                    strings.definitionFormName,
                  );
                }
                expect(tester.takeException(), isNull);
              } finally {
                handle.dispose();
              }
            },
          );
        }
      }
    }
  }
}
