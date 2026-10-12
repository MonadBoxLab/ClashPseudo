import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/overview/overview_page.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ViewController extends AppController {
  ViewController() : super(AppBridge()) {
    loading = false;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  final commands = <Map<String, Object?>>[];
  @override
  Future<void> submit(Map<String, Object?> command) async {
    commands.add(command);
  }
}

void main() {
  late ViewController controller;
  setUp(() {
    controller = ViewController();
  });
  tearDown(() {
    controller.dispose();
  });

  testWidgets('empty overview never dispatches a startup command', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: OverviewPage(controller: controller)),
    );
    expect(find.text('接管已关闭'), findsOneWidget);
    expect(find.text('尚未导入配置'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '启动接管'),
    );
    expect(button.onPressed, isNull);
    expect(controller.commands, isEmpty);
  });

  testWidgets('unknown state is not shown as stopped or offered startup', (
    tester,
  ) async {
    controller.state = const AppSnapshot();
    await tester.pumpWidget(
      MaterialApp(home: OverviewPage(controller: controller)),
    );
    expect(find.text('状态未确认'), findsOneWidget);
    expect(find.text('接管已关闭'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '启动接管'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('HTTP import waits for explicit plaintext confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: OverviewPage(controller: controller)),
    );
    await tester.tap(find.byTooltip('导入完整配置'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'http://example.test/config?token=private',
    );
    await tester.tap(find.text('下载并保存'));
    await tester.pumpAndSettle();
    expect(controller.commands, isEmpty);
    expect(find.text('使用 HTTP 明文来源？'), findsOneWidget);
    await tester.tap(find.text('仍然下载'));
    await tester.pumpAndSettle();
    expect(controller.commands.single['allowHttp'], true);
    expect(controller.commands.single['source'], contains('token=private'));
  });

  testWidgets(
    'long names and large text fit a narrow viewport without showing tokens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      controller.collection = ConfigCollection(
        entries: [
          ConfigEntry(
            id: 'one',
            name: '很长的配置名称' * 12,
            source: 'https://example.test/config?token=private',
            revision: 1,
            body: 'config',
          ),
        ],
        selectedId: 'one',
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: OverviewPage(controller: controller),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('token=private'), findsNothing);
    },
  );
}
