import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart';

void main() {
  // These are injected operation receipts, not evidence of an actual store write.
  for (final (name, creating, id, revision) in [
    ('null target ID', true, null, 1),
    ('empty target ID', true, '', 1),
    ('missing saved revision', false, 'local', null),
    ('zero revision', false, 'local', 0),
    ('negative revision', true, 'created', -1),
    ('different target ID', false, 'other', 2),
  ]) {
    testWidgets('a saved status with $name cannot adopt a saved identity', (
      tester,
    ) async {
      const entry = ConfigEntry(
        id: 'local',
        name: 'Local',
        kind: ConfigKind.local,
        revision: 1,
        body: 'original',
      );
      final app = EditorApp(entries: creating ? [] : [entry]);
      addTearDown(app.dispose);
      app.outcome = AppSnapshot(
        configStatus: 'saved',
        resultSuccess: true,
        targetId: id,
        savedRevision: revision,
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ConfigTextPage(
                    app: app,
                    entry: creating ? null : entry,
                    initialText: 'original',
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      editor.controller!.text = 'retained draft';
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(app.commands, hasLength(1));
      expect(app.commands.single['body'], 'retained draft');
      expect(find.byType(ConfigTextPage), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(editor.controller!.text, 'retained draft');
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
            .onPressed,
        isNull,
      );
      // Unknown saved identity blocks resubmission, not local draft recovery.
      editor.controller!.replaceSelection(' kept');
      expect(editor.controller!.text, contains(' kept'));
      expect(app.commands, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a thrown receipt retains the draft and blocks another submission',
    (tester) async {
      final app = EditorApp()..pending = Completer<AppSnapshot?>();
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConfigTextPage(app: app, initialText: 'retained draft'),
        ),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .controller!;
      await tester.tap(find.text('Save'));
      await tester.pump();
      app.pending!.completeError(StateError('receipt transport fixture'));
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(TextButton),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(strings.resultUnconfirmed),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('receipt transport fixture'), findsNothing);
      await tester.tap(find.text(strings.technicalDetails));
      await tester.pumpAndSettle();
      expect(find.textContaining('receipt transport fixture'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(controller.text, 'retained draft');
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
            .onPressed,
        isNull,
      );
      controller.replaceSelection('recover ');
      expect(controller.text, contains('recover '));
      expect(app.commands, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a retired task adopts its save receipt without closing on return',
    (tester) async {
      final app = EditorApp()..pending = Completer<AppSnapshot?>();
      final active = ValueNotifier(true);
      addTearDown(app.dispose);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                FocusedPageRoute(
                  builder: (_) => ValueListenableBuilder<bool>(
                    valueListenable: active,
                    builder: (_, value, child) => AppTaskActivity(
                      active: value,
                      isActiveNow: () => active.value,
                      child: child!,
                    ),
                    child: ConfigTextPage(app: app, initialText: 'saved draft'),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pump();
      active.value = false;
      await tester.pump();
      app.collection = ConfigCollection(
        entries: const [
          ConfigEntry(
            id: 'created',
            name: 'Local',
            kind: ConfigKind.local,
            revision: 1,
            body: 'saved draft',
          ),
        ],
      );
      app.pending!.complete(
        const AppSnapshot(
          configStatus: 'saved',
          resultSuccess: true,
          targetId: 'created',
          savedRevision: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      active.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(ConfigTextPage), findsOneWidget);
      final controller = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .controller!;
      expect(controller.text, 'saved draft');
      controller.replaceSelection('fresh ');
      app.pending = Completer<AppSnapshot?>();
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(app.commands, hasLength(2));
      expect(app.commands.last['id'], 'created');
      expect(app.commands.last['revision'], 1);
      app.pending!.complete(const AppSnapshot(configStatus: 'notSaved'));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
