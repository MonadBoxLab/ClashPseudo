import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_editor_limits.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
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
            for (final readOnly in [false, true]) {
              testWidgets(
                'oversized editor admission $language/$brightness/$brand/$width/$scale/readonly=$readOnly',
                (tester) async {
                  tester.view.devicePixelRatio = 1;
                  tester.view.physicalSize = Size(width, 720);
                  addTearDown(tester.view.resetDevicePixelRatio);
                  addTearDown(tester.view.resetPhysicalSize);
                  final app = EditorApp();
                  addTearDown(app.dispose);
                  final body = 'x' * (maxEditorCodeUnits + 1);
                  final entry = ConfigEntry(
                    id: 'local',
                    name: 'Original name',
                    kind: ConfigKind.local,
                    revision: 1,
                    body: body,
                  );
                  final strings = lookupAppLocalizations(Locale(language));
                  await tester.pumpWidget(
                    MaterialApp(
                      localizationsDelegates:
                          AppLocalizations.localizationsDelegates,
                      supportedLocales: AppLocalizations.supportedLocales,
                      locale: Locale(language),
                      theme: AppTheme.forBrightness(brightness, brand),
                      builder: (context, child) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: TextScaler.linear(scale)),
                        child: child!,
                      ),
                      home: ConfigTextPage(
                        app: app,
                        entry: entry,
                        readOnly: readOnly,
                      ),
                    ),
                  );
                  await tester.pumpAndSettle();
                  expect(find.byType(CodeEditor), findsNothing);
                  expect(find.byType(OriginalTextView), findsOneWidget);
                  expect(find.byType(SelectableText), findsWidgets);
                  expect(find.byType(TextField), findsNothing);
                  expect(find.byType(CircularProgressIndicator), findsNothing);
                  expect(
                    find.text(strings.editorLineTooLong(1, maxEditorCodeUnits)),
                    findsOneWidget,
                  );
                  expect(
                    tester
                        .widget<IconButton>(
                          find.widgetWithIcon(IconButton, Icons.search),
                        )
                        .onPressed,
                    isNull,
                  );
                  expect(
                    tester
                        .widget<IconButton>(
                          find.widgetWithIcon(IconButton, Icons.wrap_text),
                        )
                        .onPressed,
                    isNull,
                  );
                  expect(find.text(body), findsNothing);
                  expect(entry.body, body);
                  expect(app.commands, isEmpty);
                  final error = tester.takeException();
                  if (error != null) debugDumpRenderTree();
                  expect(error, isNull);
                  await tester.pumpWidget(const SizedBox.shrink());
                },
              );
            }
          }
        }
      }
    }
  }

  testWidgets('exactly 32768 code units still open the wrapped editor', (
    tester,
  ) async {
    final app = EditorApp();
    addTearDown(app.dispose);
    final body = 'x' * maxEditorCodeUnits;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConfigTextPage(app: app, initialText: body),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    expect(editor.controller!.text, body);
    expect(editor.wordWrap, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '16MiB oversized raw text opens a complete read-only preview through compute',
    (tester) async {
      final app = EditorApp();
      addTearDown(app.dispose);
      final body = 'x' * maxConfigBytes;
      const locale = Locale('en');
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: ConfigTextPage(app: app, initialText: body),
        ),
      );
      await tester.runAsync(() async {
        final elapsed = Stopwatch()..start();
        while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty &&
            elapsed.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pump();
      expect(
        find.text(
          lookupAppLocalizations(locale)
              .editorLineTooLong(1, maxEditorCodeUnits),
        ),
        findsOneWidget,
      );
      expect(find.byType(CodeEditor), findsNothing);
      expect(find.byType(OriginalTextView), findsOneWidget);
      expect(find.byType(SelectableText), findsWidgets);
      expect(find.byType(TextField), findsNothing);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
