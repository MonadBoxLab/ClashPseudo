import 'dart:async';

import 'package:clash_pseudo/src/features/configs/widgets/config_field_dialog.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> open(
    WidgetTester tester,
    Future<bool> Function(String) submit, {
    bool source = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<String>(
                context: context,
                builder: (_) => ConfigFieldDialog(
                  initial: source
                      ? 'https://example.test/source#section'
                      : 'Original',
                  source: source,
                  onSubmit: submit,
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
  }

  testWidgets('rejected asynchronous submission preserves text and geometry', (
    tester,
  ) async {
    final pending = Completer<bool>();
    final submitted = <String>[];
    await open(tester, (value) {
      submitted.add(value);
      return pending.future;
    });
    await tester.enterText(find.byType(TextField), 'Draft after restore');
    await tester.pumpAndSettle();
    final field = tester.getRect(find.byType(TextField));
    final button = find.widgetWithText(TextButton, en.save);
    final save = tester.getRect(button);
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(submitted, ['Draft after restore']);
    expect(tester.getRect(find.byType(TextField)), field);
    expect(tester.getRect(button), save);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Draft after restore',
    );
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    expect(tester.getRect(find.byType(TextField)), field);
    expect(tester.getRect(button), save);
  });

  testWidgets(
    'an accepted old value cannot discard input typed while waiting',
    (tester) async {
      final pending = Completer<bool>();
      final submitted = <String>[];
      await open(tester, (value) {
        submitted.add(value);
        return submitted.length == 1 ? pending.future : Future.value(true);
      });
      await tester.tap(find.widgetWithText(TextButton, en.save));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Newer draft');
      await tester.pump();
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Newer draft',
      );
      await tester.tap(find.widgetWithText(TextButton, en.save));
      await tester.pumpAndSettle();
      expect(submitted, ['Original', 'Newer draft']);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('acceptance retires only its own dialog below a newer result', (
    tester,
  ) async {
    final pending = Completer<bool>();
    await open(tester, (_) {
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(ConfigFieldDialog)),
          builder: (context) => AlertDialog(
            title: const Text('Newer result'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Dismiss result'),
              ),
            ],
          ),
        ),
      );
      return pending.future;
    });
    await tester.tap(find.widgetWithText(TextButton, en.save));
    await tester.pumpAndSettle();
    expect(find.text('Newer result'), findsOneWidget);
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Newer result'), findsOneWidget);
    expect(find.byType(ConfigFieldDialog), findsNothing);
    await tester.tap(find.text('Dismiss result'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a late accepted callback cannot close a replacement dialog', (
    tester,
  ) async {
    final pending = Completer<bool>();
    await open(tester, (_) => pending.future);
    await tester.tap(find.widgetWithText(TextButton, en.save));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, en.cancel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'canonical source acceptance closes without treating normalization as editing',
    (tester) async {
      String? submitted;
      await open(tester, (value) async {
        submitted = value;
        return true;
      }, source: true);
      await tester.tap(find.widgetWithText(TextButton, en.saveAndUpdate));
      await tester.pumpAndSettle();
      expect(submitted, 'https://example.test/source');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
