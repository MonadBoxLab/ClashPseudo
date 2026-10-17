import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/features/configs/configs_page.dart';
import 'package:clash_pseudo/features/configs/config_text_page.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImportApp extends AppController {
  _ImportApp() : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  final saved = <Map<String, Object?>>[];
  @override
  Future<AppSnapshot?> saveLocal(Map<String, Object?> command) async {
    saved.add(command);
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
      {'name': '自建', 'body': body},
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
