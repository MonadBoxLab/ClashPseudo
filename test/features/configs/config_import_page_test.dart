import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/features/configs/configs_page.dart';
import 'package:clash_pseudo/src/features/configs/config_text_page.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:re_editor/re_editor.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImportApp extends AppController {
  _ImportApp() : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  int epoch = 0;
  @override
  int get storageEpoch => epoch;
  @override
  bool get configsCurrent =>
      configsLoaded &&
      state.storageReady &&
      !state.storageRestoring &&
      state.storageEpoch == epoch &&
      configErrorMessage == null &&
      overrideErrorMessage == null &&
      preferencesErrorMessage == null;

  void restore() {
    epoch++;
    collection = ConfigCollection(
      entries: const [
        ConfigEntry(
          id: 'restored',
          name: 'Restored',
          kind: ConfigKind.local,
          revision: 1,
          body: 'restored body',
        ),
      ],
    );
    state = AppSnapshot(phase: 'STOPPED', storageEpoch: epoch);
    notifyListeners();
  }

  final saved = <Map<String, Object?>>[];
  final published = <Map<String, Object?>>[];
  @override
  Future<AppSnapshot?> saveLocal(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    saved.add(command);
    if (command['storageEpoch'] != epoch) {
      return AppSnapshot(
        configStatus: 'notSaved',
        resultMessage: messages.storageUnavailable,
      );
    }
    published.add(command);
    return const AppSnapshot(
      configStatus: 'saved',
      targetId: 'imported',
      savedRevision: 1,
    );
  }
}

void main() {
  late _ImportApp app;
  Future<void> show(
    WidgetTester tester,
    Future<XFile?> Function() picker,
  ) async {
    app = _ImportApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      ConfigsPage(controller: app, selectFile: picker),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加配置'));
    await tester.pumpAndSettle();
  }

  testWidgets('file imports once directly without an editor or naming step', (
    tester,
  ) async {
    const body = '\u{feff}中文🌐\r\n';
    await show(
      tester,
      () async => XFile.fromData(
        Uint8List.fromList(utf8.encode(body)),
        path: '自建.yaml',
      ),
    );
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
    expect(app.saved, [
      {'storageEpoch': 0, 'name': '自建', 'body': body},
    ]);
    expect(find.byType(ConfigTextPage), findsNothing);
    expect(find.byType(ConfigsPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('cancelled file selection submits nothing', (tester) async {
    await show(tester, () async => null);
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
    expect(app.saved, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('late selection after leaving does not submit a body', (
    tester,
  ) async {
    final file = Completer<XFile?>();
    await show(tester, () => file.future);
    await tester.tap(find.text('从文件导入'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '添加配置',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    file.complete(XFile.fromData(Uint8List.fromList([65]), name: 'late.txt'));
    await tester.pumpAndSettle();
    expect(app.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final whilePicker in [false, true]) {
    testWidgets(
      whilePicker
          ? 'file import retains the opening epoch across restore while picking'
          : 'restore retires the file menu without opening its picker',
      (tester) async {
        final pending = Completer<XFile?>();
        const body = 'old selected file body';
        final file = XFile.fromData(
          Uint8List.fromList(utf8.encode(body)),
          path: 'old.yaml',
        );
        await show(tester, () => pending.future);
        final add = find.byTooltip('添加配置');
        final anchor = tester.getRect(add);
        if (!whilePicker) {
          final retired = tester.widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, '从文件导入'),
          );
          app.restore();
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          retired.onPressed!();
          await tester.pumpAndSettle();
          expect(app.saved, isEmpty);
          expect(app.published, isEmpty);
          expect(app.collection.entries.single.body, 'restored body');
          expect(tester.getRect(add), anchor);
          expect(find.byType(AlertDialog), findsNothing);
          pending.complete(file);
          expect(await file.readAsString(), body);
          expect(tester.takeException(), isNull);
          return;
        }
        await tester.tap(find.text('从文件导入'));
        await tester.pumpAndSettle();
        if (whilePicker) {
          app.restore();
          await tester.pump();
        }
        expect(app.storageEpoch, 1);
        expect(tester.getRect(add), anchor);
        pending.complete(file);
        await tester.pumpAndSettle();
        expect(app.saved.single, {
          'storageEpoch': 0,
          'name': 'old',
          'body': body,
        });
        expect(app.published, isEmpty);
        expect(app.collection.entries.single.body, 'restored body');
        expect(
          find.text(
            AppLocalizations.of(tester.element(find.byType(AlertDialog).last))
                .storageUnavailable,
          ),
          findsWidgets,
        );
        expect(await file.readAsString(), body);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(tester.getRect(add), anchor);
        expect(find.text('Restored'), findsOneWidget);
        expect(find.byType(ConfigTextPage), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'name dialog passes its old epoch into the editor after restore',
    (tester) async {
      await show(tester, () async => null);
      await tester.tap(find.text('新建本地配置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Kept draft name');
      final fieldAnchor = tester.getRect(find.byType(TextField));
      app.restore();
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Kept draft name',
      );
      expect(tester.getRect(find.byType(TextField)), fieldAnchor);
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ConfigTextPage>(find.byType(ConfigTextPage)).storageEpoch,
        0,
      );
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      final accepted = editor.controller!.value;
      editor.controller!.text = 'retained body draft';
      await tester.pump();
      expect(editor.controller!.value, same(accepted));
      expect(editor.controller!.text, directConfigTemplate);
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isTrue,
      );
      final strings = AppLocalizations.of(
        tester.element(find.byType(ConfigTextPage)),
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, strings.save))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text(strings.save));
      await tester.pumpAndSettle();
      expect(app.saved, isEmpty);
      expect(app.published, isEmpty);
      expect(app.collection.entries.single.body, 'restored body');
      await tester.tap(find.byKey(const ValueKey('editor-input-notice')));
      await tester.pumpAndSettle();
      expect(find.text(strings.editorContextChanged), findsWidgets);
      await tester.tap(find.text(strings.close));
      await tester.pumpAndSettle();
      expect(editor.controller!.value, same(accepted));
      expect(find.byType(ConfigTextPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('new config asks name before opening unsaved template', (
    tester,
  ) async {
    await show(tester, () async => null);
    await tester.tap(find.text('新建本地配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新配置');
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigTextPage), findsOneWidget);
    expect(find.text('新配置'), findsOneWidget);
    expect(app.saved, isEmpty);
  });
}
