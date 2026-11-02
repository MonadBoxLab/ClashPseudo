import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_editor_limits.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_find_controller.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart';

const _entry = ConfigEntry(
  id: 'local',
  name: 'Controlled local',
  kind: ConfigKind.local,
  revision: 1,
  body: 'safe',
);

class _AuthorityApp extends EditorApp {
  _AuthorityApp() : super(entries: [_entry]) {
    overridesLoaded = true;
    overrides = [_part()];
  }

  // Publish this input separately from the snapshot to exercise both guards.
  @override
  int storageEpoch = 0;
}

OverrideEntry _part({
  String id = 'local',
  int revision = 1,
  bool remote = false,
}) => OverrideEntry(
  id: id,
  name: 'Controlled fragment',
  kind: remote ? ConfigKind.remote : ConfigKind.local,
  revision: revision,
  body: 'safe',
  source: remote ? 'https://fixture.invalid/fragment' : null,
);

void _invalidate(_AuthorityApp app, String reason, bool fragment) {
  switch (reason) {
    case 'revision':
    case 'recreated':
    case 'remote':
      final id = reason == 'recreated' ? 'new-local' : 'local';
      final revision = reason == 'revision' ? 2 : 1;
      final remote = reason == 'remote';
      if (fragment) {
        app.overrides = [_part(id: id, revision: revision, remote: remote)];
      } else {
        app.collection = ConfigCollection(
          entries: [
            ConfigEntry(
              id: id,
              name: _entry.name,
              kind: remote ? ConfigKind.remote : ConfigKind.local,
              revision: revision,
              body: 'safe',
              source: remote ? 'https://fixture.invalid/config' : null,
            ),
          ],
        );
      }
    case 'deleted':
      if (fragment) {
        app.overrides = [];
      } else {
        app.collection = ConfigCollection(entries: []);
      }
    case 'store epoch':
      app.storageEpoch = 1;
    case 'snapshot epoch':
      app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
    case 'background':
      app.setForeground(false);
    case 'busy':
      app.dispatching = true;
    case 'unloaded':
      if (fragment) {
        app.overridesLoaded = false;
      } else {
        app.configsLoaded = false;
      }
    default:
      throw StateError(reason);
  }
  app.updateState(app.state);
}

Future<(_AuthorityApp, CodeEditor)> _show(
  WidgetTester tester, {
  bool fragment = false,
  bool readOnly = false,
}) async {
  final app = _AuthorityApp();
  addTearDown(app.dispose);
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [AppTaskNavigatorObserver()],
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ConfigTextPage(
        app: app,
        entry: _entry,
        readOnly: readOnly,
        onSave: fragment
            ? (command, owner) => app.saveLocal(command, feedbackOwner: owner)
            : null,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (app, tester.widget<CodeEditor>(find.byType(CodeEditor)));
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const noticeKey = ValueKey('editor-input-notice');

  for (final fragment in [false, true]) {
    for (final reason in [
      'revision',
      'recreated',
      'remote',
      'deleted',
      'store epoch',
      'snapshot epoch',
      'background',
      'busy',
      'unloaded',
    ]) {
      testWidgets(
        'draft remains editable while stale save identity is refused: $reason, fragment=$fragment',
        (tester) async {
          final (app, editor) = await _show(tester, fragment: fragment);
          final controller = editor.controller!;
          controller.text = 'dirty';
          controller.selection = const CodeLineSelection.collapsed(
            index: 0,
            offset: 5,
          );
          controller.composing = const TextRange(start: 1, end: 3);
          await tester.pumpAndSettle();
          final before = controller.value;
          final previous = controller.preValue;
          final undo = controller.canUndo;
          final editorRect = tester.getRect(find.byType(CodeEditor));
          expect(find.byKey(noticeKey), findsNothing);
          _invalidate(app, reason, fragment);
          expect(controller.value, same(before));
          expect(controller.preValue, same(previous));
          expect(controller.canUndo, undo);
          // A changed save target does not confiscate the local draft.
          // Input from the current foreground page remains ordinary editor input.
          controller.replaceSelection('x');
          if (reason == 'background') {
            expect(controller.value, same(before));
            expect(controller.preValue, same(previous));
            expect(controller.canUndo, undo);
          } else {
            expect(controller.text, 'dirtyx');
            expect(controller.canUndo, isTrue);
            controller.undo();
            expect(controller.text, 'dirty');
          }
          expect(app.commands, isEmpty);
          for (final ms in [0, 16, 80, 200]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(tester.getRect(find.byType(CodeEditor)), editorRect);
            expect(find.byKey(noticeKey), findsNothing);
            expect(
              tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
              reason == 'background',
            );
            expect(
              tester
                  .widget<TextButton>(find.widgetWithText(TextButton, en.save))
                  .onPressed,
              isNull,
            );
            expect(find.byType(AlertDialog), findsNothing);
            expect(tester.takeException(), isNull);
          }
          controller.selectAll();
          if (reason == 'background') {
            expect(controller.value, same(before));
            expect(controller.selection.isCollapsed, isTrue);
          } else {
            expect(controller.selectedText, 'dirty');
          }
          expect(controller.codeLines.equals(before.codeLines), isTrue);
          expect(app.commands, isEmpty);
        },
      );

      testWidgets(
        'late clipboard cannot use retired input admission: $reason, fragment=$fragment',
        (tester) async {
          final clipboard = Completer<Object?>();
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.getData') return clipboard.future;
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final (app, editor) = await _show(tester, fragment: fragment);
          final controller = editor.controller!;
          final before = controller.value;
          controller.paste();
          await tester.pump();
          _invalidate(app, reason, fragment);
          clipboard.complete({'text': 'late'});
          await tester.pump();
          expect(controller.value, same(before));
          expect(controller.canUndo, isFalse);
          expect(app.commands, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'clipboard acquired before a transient busy operation stays invalid after recovery',
    (tester) async {
      final clipboard = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return clipboard.future;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (app, editor) = await _show(tester);
      final controller = editor.controller!;
      final before = controller.value;
      controller.paste();
      await tester.pump();
      app.dispatching = true;
      app.updateState(app.state);
      app.dispatching = false;
      app.updateState(app.state);
      clipboard.complete({'text': 'stale'});
      await tester.pump();
      expect(controller.value, same(before));
      controller.replaceSelection('fresh');
      expect(controller.text, 'freshsafe');
      expect(app.commands, isEmpty);
      await tester.pump(const Duration(milliseconds: 20));
    },
  );

  testWidgets(
    'saving invalidates a pending clipboard even when a failed save restores editing',
    (tester) async {
      final clipboard = Completer<Object?>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return clipboard.future;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (app, editor) = await _show(tester);
      final controller = editor.controller!;
      controller.text = 'draft';
      final before = controller.value;
      controller.paste();
      await tester.pump();
      app.pending = Completer<AppSnapshot?>();
      await tester.tap(find.text(en.save));
      await tester.pump();
      controller.replaceSelection('blocked');
      expect(controller.value, same(before));
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
      clipboard.complete({'text': 'stale'});
      await tester.pump();
      expect(controller.value, same(before));
      expect(app.commands.single['body'], 'draft');
      controller.replaceSelection('fresh');
      expect(controller.text, contains('fresh'));
    },
  );

  testWidgets('readonly permits selection and find navigation but never text', (
    tester,
  ) async {
    final (app, editor) = await _show(tester, readOnly: true);
    final controller = editor.controller!;
    controller.selectAll();
    final before = controller.value;
    expect(controller.selectedText, 'safe');
    controller.replaceSelection('blocked');
    expect(controller.value, same(before));
    await tester.tap(find.byTooltip(en.find));
    await tester.pumpAndSettle();
    final findController = editor.findController! as ConfigFindController;
    findController.findInputController.text = 'af';
    await tester.pump(const Duration(milliseconds: 121));
    // Advance root-isolate I/O, then FakeAsync microtasks for compute's continuation.
    for (
      var attempt = 0;
      attempt < 100 && findController.value?.searching == true;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(findController.value!.searching, isFalse);
    expect(findController.value!.result!.matches, hasLength(1));
    findController.nextMatch();
    expect(controller.text, 'safe');
    expect(app.commands, isEmpty);
  });

  testWidgets(
    'real find TextField rejects the entire oversized composing update and keeps its slot',
    (tester) async {
      final (app, editor) = await _show(tester);
      expect(find.byKey(noticeKey), findsNothing);
      final editorRect = tester.getRect(find.byType(CodeEditor));
      await tester.tap(find.byTooltip(en.find));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextField));
      final findController = editor.findController! as ConfigFindController;
      final query = '🌐' * (maxEditorCodeUnits ~/ 2);
      final input = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
        composing: TextRange(start: 0, end: query.length),
      );
      tester.testTextInput.updateEditingValue(input);
      await tester.pump();
      expect(findController.findInputController.value, input);
      final accepted = findController.value;
      tester.testTextInput.updateEditingValue(
        input.copyWith(
          text: '${query}x',
          selection: TextSelection.collapsed(offset: query.length + 1),
          composing: TextRange(start: 0, end: query.length + 1),
        ),
      );
      await tester.pump();
      expect(findController.findInputController.value, input);
      expect(findController.value, same(accepted));
      expect(tester.testTextInput.editingState!['text'], query);
      expect(tester.testTextInput.editingState!['composingBase'], 0);
      expect(
        tester.testTextInput.editingState!['composingExtent'],
        query.length,
      );
      expect(find.byKey(noticeKey), findsNothing);
      expect(tester.getRect(find.byType(CodeEditor)), editorRect);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text(en.editorQueryTooLong(maxEditorCodeUnits)),
        findsOneWidget,
      );
      findController.findInputController.clear();
      await tester.pumpAndSettle();
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
