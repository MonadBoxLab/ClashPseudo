import 'dart:convert';

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/widgets/confirm_action.dart';
import 'package:clash_pseudo/src/features/configs/widgets/import_dialog.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImportApp extends AppController {
  _ImportApp(AppSnapshot snapshot, String selected) : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = snapshot;
    collection = ConfigCollection(
      entries: const [
        ConfigEntry(
          id: 'target',
          name: '包含中文与 English 的长配置名称',
          source: 'https://fixture.test/config',
          revision: 1,
          body: 'rules: []',
        ),
        ConfigEntry(
          id: 'other',
          name: 'Other',
          source: 'https://fixture.test/other',
          revision: 1,
          body: '',
        ),
      ],
      selectedId: selected,
    );
  }
  final commands = <Map<String, Object?>>[];
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(command);
    return 'accepted';
  }
}

void main() {
  for (final scenario in [
    (
      const AppSnapshot(phase: 'RUNNING', configId: 'target'),
      'other',
      '更新成功后，若运行内容改变，将重新连接此配置的接管。',
    ),
    (
      const AppSnapshot(phase: 'RUNNING', configId: 'other'),
      'target',
      '不会切换或停止其他配置的接管。',
    ),
    (const AppSnapshot(phase: 'STOPPED'), 'target', '更新后不会自动启动接管。'),
    (const AppSnapshot(), 'target', '连接状态尚未确认；更新将按实际运行状态处理。'),
  ]) {
    testWidgets(
      'duplicate consequence follows actual identity ${scenario.$3}',
      (tester) async {
        final app = _ImportApp(scenario.$1, scenario.$2);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            theme: AppTheme.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openImport(
                    context,
                    app,
                    source: 'https://fixture.test/config',
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载并保存'));
        await tester.pumpAndSettle();
        expect(find.text('覆盖更新配置？'), findsOneWidget);
        expect(find.text('包含中文与 English 的长配置名称'), findsOneWidget);
        expect(find.textContaining(scenario.$3), findsOneWidget);
        expect(find.textContaining('下载失败将保留原正文与连接。'), findsOneWidget);
        expect(app.commands, isEmpty);
        await tester.tap(find.text('取消').hitTestable());
        await tester.pumpAndSettle();
        expect(app.commands, isEmpty);
        expect(find.byType(ImportDialog), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'https://fixture.test/config',
        );
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull,
        );
        await tester.tap(find.text('取消').hitTestable());
        await tester.pumpAndSettle();
      },
    );
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('confirmation long object scrolls dark=$dark scale=$scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final subject = '长配置名称与English🌐' * 12;
        bool? accepted;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            theme: dark ? AppTheme.dark : AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: const EdgeInsets.only(bottom: 100),
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    accepted = await confirmAction(
                      context,
                      title: (strings) => strings.overwriteConfigTitle,
                      subject: subject,
                      message: (strings) =>
                          '${strings.overwriteConfigMessage}'
                          '\n\n${strings.overwriteKeepsOnFailure}',
                      confirmLabel: (strings) => strings.overwrite,
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
        expect((dialog.title! as Text).data, '覆盖更新配置？');
        expect(find.text(subject), findsOneWidget);
        expect(tester.takeException(), isNull);
        final button = find.widgetWithText(FilledButton, '覆盖更新');
        final rect = tester.getRect(button);
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -1200),
        );
        for (var i = 0; i < 14; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(button), rect);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(accepted, isTrue);
      });
    }
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('import validation preserves anchors $language/$scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = lookupAppLocalizations(Locale(language));
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
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
                  onPressed: () => showDialog<Map<String, Object?>>(
                    context: context,
                    builder: (_) => const ImportDialog(),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final source = find.byType(TextField).first;
        await tester.enterText(source, 'ftp://fixture.test/config');
        await tester.pumpAndSettle();
        final anchors = [
          find.text(strings.importFullConfig),
          source,
          find.byType(TextField).last,
          find.widgetWithText(FilledButton, strings.downloadAndSave),
          find.widgetWithText(TextButton, strings.cancel),
        ];
        final rects = anchors.map(tester.getRect).toList();
        Future<void> expectStableFrames() async {
          for (var frame = 0; frame < 16; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            for (var i = 0; i < anchors.length; i++) {
              expect(tester.getRect(anchors[i]), rects[i]);
            }
            expect(tester.takeException(), isNull);
          }
        }

        await tester.tap(anchors[3]);
        await expectStableFrames();
        expect(find.byType(ImportDialog), findsOneWidget);
        expect(
          tester.widget<TextField>(source).controller!.text,
          'ftp://fixture.test/config',
        );
        await tester.enterText(source, 'http://fixture.test/config');
        await expectStableFrames();
        await tester.tap(find.byTooltip(strings.showUrl));
        await expectStableFrames();
        expect(tester.widget<TextField>(source).obscureText, isFalse);
        await tester.tap(anchors.last);
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets('optional import name uses business length without truncation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: ImportDialog()),
      ),
    );
    final field = find.byType(TextField).last;
    final boundary = '${'👨‍👩‍👧‍👦' * 3}abcde';
    expect(utf8.encode(boundary).length, 80);
    for (final name in [
      boundary,
      '$boundary🌐',
      '${'👨‍👩‍👧‍👦' * 11}abc',
      '',
    ]) {
      await tester.enterText(field, name);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, name);
      expect(find.text('${utf8.encode(name).length}/80 B'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
            null,
        utf8.encode(name).length <= 80,
      );
    }
  });
}
