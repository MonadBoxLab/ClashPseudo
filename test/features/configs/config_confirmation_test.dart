import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/widgets/confirm_action.dart';
import 'package:clash_pseudo/features/configs/widgets/import_dialog.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
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
      '将停止此配置的接管；更新成功后重新启动。',
    ),
    (
      const AppSnapshot(phase: 'RUNNING', configId: 'other'),
      'target',
      '不会切换或停止其他配置的接管。',
    ),
    (const AppSnapshot(phase: 'STOPPED'), 'target', '更新后不会自动启动接管。'),
    (const AppSnapshot(), 'target', '接管状态尚未确认，请先核实运行状态。'),
  ]) {
    testWidgets(
      'duplicate consequence follows actual identity ${scenario.$3}',
      (tester) async {
        final app = _ImportApp(scenario.$1, scenario.$2);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
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
        expect(find.textContaining('下载失败后也不能再次启动'), findsOneWidget);
        expect(app.commands, isEmpty);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(app.commands, isEmpty);
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
                      title: '覆盖更新配置？',
                      subject: subject,
                      message:
                          '此来源已保存，将更新该条目，不新增配置。'
                          '\n\n旧正文将失效，下载失败后也不能再次启动。',
                      confirmLabel: '覆盖更新',
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

  testWidgets('optional import name uses business length without truncation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: const Scaffold(body: ImportDialog())),
    );
    final field = find.byType(TextField).last;
    final boundary = '${'👨‍👩‍👧‍👦' * 11}abc';
    for (final name in [boundary, '$boundary🌐', '']) {
      await tester.enterText(field, name);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, name);
      expect(find.text('${name.runes.length}/80'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
            null,
        name.runes.length <= 80,
      );
    }
  });
}
