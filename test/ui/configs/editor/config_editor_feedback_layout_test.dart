import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_editor_limits.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart';

void main() {
  for (final language in ['en', 'zh']) {
    for (final brightness in Brightness.values) {
      for (final brand in BrandColor.values) {
        for (final width in [320.0, 760.0]) {
          for (final scale in [1.0, 1.3, 2.0]) {
            testWidgets(
              'stable editor feedback $language/$brightness/$brand/$width/$scale',
              (tester) async {
                tester.view.physicalSize = Size(width, 960);
                tester.view.devicePixelRatio = 1;
                addTearDown(tester.view.resetPhysicalSize);
                addTearDown(tester.view.resetDevicePixelRatio);
                final entry = ConfigEntry(
                  id: 'local',
                  name: '长配置名称 English 🌐 ' * 5,
                  kind: ConfigKind.local,
                  revision: 1,
                  body: 'safe',
                );
                final app = EditorApp(entries: [entry]);
                addTearDown(app.dispose);
                final strings = lookupAppLocalizations(Locale(language));
                await tester.pumpWidget(
                  MaterialApp(
                    navigatorObservers: [AppTaskNavigatorObserver()],
                    theme: AppTheme.forBrightness(brightness, brand),
                    locale: Locale(language),
                    localizationsDelegates:
                        AppLocalizations.localizationsDelegates,
                    supportedLocales: AppLocalizations.supportedLocales,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: ConfigTextPage(app: app, entry: entry),
                  ),
                );
                await tester.pumpAndSettle();
                final editorFinder = find.byType(CodeEditor);
                final editor = tester
                    .widget<CodeEditor>(editorFinder)
                    .controller!;
                final notice = find.byKey(
                  const ValueKey('editor-input-notice'),
                );
                final save = find.descendant(
                  of: find.byType(AppBar),
                  matching: find.byType(TextButton),
                );
                final title = find.text(entry.name);
                final anchors = [editorFinder, save, title];
                final geometry = anchors.map(tester.getRect).toList();
                Future<void> checkFrames() async {
                  for (final ms in [0, 16, 80, 200]) {
                    await tester.pump(Duration(milliseconds: ms));
                    for (var index = 0; index < anchors.length; index++) {
                      expect(tester.getRect(anchors[index]), geometry[index]);
                    }
                    expect(tester.takeException(), isNull);
                  }
                }

                expect(notice, findsNothing);
                expect(notice.hitTestable(), findsNothing);
                final accepted = editor.value;
                editor.text = 'x' * (maxEditorCodeUnits + 1);
                expect(editor.value, same(accepted));
                await checkFrames();
                expect(
                  find.text(strings.editorChangeTooLong(1, maxEditorCodeUnits)),
                  findsOneWidget,
                );
                expect(find.byType(AlertDialog), findsNothing);
                editor.replaceSelection('draft');
                await checkFrames();
                expect(notice, findsNothing);
                expect(notice.hitTestable(), findsNothing);
                final draft = editor.text;
                app.updateState(
                  const AppSnapshot(
                    phase: 'RUNNING',
                    configId: 'local',
                    revision: 1,
                  ),
                );
                await checkFrames();
                expect(find.text(strings.saveAndApply), findsOneWidget);
                app.dispatching = true;
                app.updateState(app.state);
                await checkFrames();
                expect(tester.widget<TextButton>(save).onPressed, isNull);
                app.dispatching = false;
                app.updateState(app.state);
                await checkFrames();
                expect(tester.widget<TextButton>(save).onPressed, isNotNull);
                app.pending = Completer<AppSnapshot?>();
                await tester.tap(save);
                await checkFrames();
                final savingValue = editor.value;
                editor.replaceSelection('blocked');
                expect(editor.value, same(savingValue));
                await checkFrames();
                app.pending!.complete(
                  const AppSnapshot(
                    configStatus: 'notSaved',
                    resultMessage: AppMessage('configSaveFailed'),
                  ),
                );
                await tester.pumpAndSettle();
                expect(find.byType(SnackBar), findsOneWidget);
                expect(find.byType(AlertDialog), findsNothing);
                await checkFrames();
                await tester.tap(
                  find
                      .descendant(
                        of: find.byType(SnackBar),
                        matching: find.byType(IconButton),
                      )
                      .last,
                );
                await checkFrames();
                expect(editor.text, draft);
                expect(tester.widget<TextButton>(save).onPressed, isNotNull);
                app.pending = Completer<AppSnapshot?>();
                await tester.tap(save);
                await checkFrames();
                app.pending!.complete(null);
                await tester.pumpAndSettle();
                await checkFrames();
                await tester.tap(
                  find
                      .descendant(
                        of: find.byType(SnackBar),
                        matching: find.byType(IconButton),
                      )
                      .last,
                );
                await checkFrames();
                expect(tester.widget<TextButton>(save).onPressed, isNull);
                expect(editor.text, draft);
                expect(app.commands, hasLength(2));
                expect(
                  app.commands.every((command) => command['body'] == draft),
                  isTrue,
                );
              },
            );
          }
        }
      }
    }
  }
}
