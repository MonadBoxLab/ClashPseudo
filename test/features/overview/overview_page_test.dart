import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/overview/overview_page.dart';
import 'package:clash_pseudo/features/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ViewBridge extends AppBridge {
  @override
  Future<ConnectionSnapshot> recentConnections({
    Map<String, Object?>? detail,
  }) async => ConnectionSnapshot.fromMap({
    'generation': 0,
    'configId': '',
    'revision': 0,
    'phase': 'STOPPED',
    'fresh': false,
    'connections': [],
  });
  @override
  Future<void> releaseConnectionDetail() async {}
}

class ViewController extends AppController {
  ViewController() : super(ViewBridge()) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  final commands = <Map<String, Object?>>[];
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    lastCommandAutomatic = automatic;
    lastCommand = Map.of(command);
    commands.add(command);
    return 'operation-${commands.length}';
  }

  void changed() => notifyListeners();
}

ConfigEntry config(String id, {int revision = 1, String? body = 'config'}) =>
    ConfigEntry(
      id: id,
      name: '配置 $id',
      source: 'https://example.test/config?token=private',
      revision: revision,
      body: body,
    );

void main() {
  late ViewController controller;
  setUp(() => controller = ViewController());
  tearDown(() => controller.dispose());
  final power = find.byKey(const ValueKey('power-button'));

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: OperationFeedback(
        controller: controller,
        child: OverviewPage(controller: controller),
      ),
    ),
  );

  testWidgets('empty overview never dispatches a startup command', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('接管已关闭'), findsWidgets);
    expect(find.text('导入完整配置后，即可启动'), findsWidgets);
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    expect(find.text('导入配置'), findsOneWidget);
    expect(find.text('最近连接'), findsOneWidget);
    expect(find.byTooltip('核实状态'), findsNothing);
    expect(controller.commands, isEmpty);
  });

  testWidgets(
    'connection entry opens a read-only secondary page while stopped',
    (tester) async {
      await show(tester);
      await tester.ensureVisible(find.text('最近连接'));
      await tester.tap(find.text('最近连接'));
      await tester.pumpAndSettle();
      expect(find.text('暂无近期连接'), findsOneWidget);
      expect(controller.commands, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('网络活动'), findsOneWidget);
    },
  );

  testWidgets('unknown is not stopped and cannot start', (tester) async {
    controller.state = const AppSnapshot();
    await show(tester);
    expect(find.text('状态未确认'), findsWidgets);
    expect(find.text('接管已关闭'), findsNothing);
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    await tester.tap(find.text('配置管理'));
    await tester.pumpAndSettle();
    expect(find.text('配置'), findsOneWidget);
    expect(controller.commands, isEmpty);
  });

  testWidgets('initial loading does not masquerade as empty saved data', (
    tester,
  ) async {
    controller.loading = true;
    controller.configsLoaded = false;
    controller.state = const AppSnapshot();
    await show(tester);
    expect(find.text('正在获取状态'), findsWidgets);
    expect(find.text('尚未导入配置'), findsNothing);
    await tester.tap(find.text('配置管理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('配置 · 读取中'), findsOneWidget);
    expect(find.text('尚未保存配置'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HTTP import waits for explicit plaintext confirmation', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('导入配置'));
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

  testWidgets('invalid body blocks start but running may still stop', (
    tester,
  ) async {
    controller.collection = ConfigCollection(
      entries: [config('one', body: null)],
      selectedId: 'one',
    );
    await show(tester);
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    controller.state = const AppSnapshot(
      phase: 'RUNNING',
      configId: 'one',
      revision: 1,
    );
    controller.configError = '配置存储无法读取';
    controller.changed();
    await tester.pump();
    expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
    expect(find.text('配置身份未确认'), findsOneWidget);
    await tester.tap(power);
    expect(controller.commands.single['action'], 'stop');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('actual configuration and revision are not the saved selection', (
    tester,
  ) async {
    controller.collection = ConfigCollection(
      entries: [config('one'), config('two')],
      selectedId: 'two',
    );
    controller.state = const AppSnapshot(
      phase: 'RUNNING',
      configId: 'one',
      revision: 1,
    );
    await show(tester);
    expect(find.text('配置 one'), findsOneWidget);
    expect(find.text('当前选择：配置 two'), findsWidgets);
    controller.collection = ConfigCollection(
      entries: [config('one', revision: 2)],
      selectedId: 'one',
    );
    controller.changed();
    await tester.pump();
    expect(find.text('运行中版本与已保存版本不同'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'normal startup and shutdown never show unknown configuration hint',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      await show(tester);
      final identity = find.byKey(const ValueKey('config-identity'));
      final height = tester.getSize(identity).height;
      final center = tester.getCenter(power);
      for (final snapshot in const [
        AppSnapshot(phase: 'STOPPED', operation: '正在等待 VPN 授权'),
        AppSnapshot(phase: 'STARTING'),
        AppSnapshot(phase: 'RUNNING', configId: 'one', revision: 1),
        AppSnapshot(phase: 'STOPPING'),
        AppSnapshot(phase: 'STOPPED'),
      ]) {
        controller.state = snapshot;
        controller.changed();
        await tester.pump();
        for (final milliseconds in [0, 50, 100, 180]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          expect(find.text('已选配置 · 未确认实际使用'), findsNothing);
          expect(tester.getSize(identity).height, height);
          expect(tester.getCenter(power), center);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unknown identity fades in reserved space but not during initial loading',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      controller.loading = true;
      controller.state = const AppSnapshot();
      await show(tester);
      final identity = find.byKey(const ValueKey('config-identity'));
      final height = tester.getSize(identity).height;
      expect(find.text('已选配置 · 未确认实际使用'), findsNothing);
      controller.loading = false;
      controller.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('已选配置 · 未确认实际使用'), findsWidgets);
      final opacities = tester.widgetList<Opacity>(
        find.descendant(of: identity, matching: find.byType(Opacity)),
      );
      expect(
        opacities.any((widget) => widget.opacity > 0 && widget.opacity < 1),
        isTrue,
      );
      expect(tester.getSize(identity).height, height);
      await tester.pump(const Duration(milliseconds: 150));
      controller.state = const AppSnapshot(phase: 'STOPPED');
      controller.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('已选配置 · 未确认实际使用'), findsOneWidget);
      expect(tester.getSize(identity).height, height);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('已选配置 · 未确认实际使用'), findsNothing);
      expect(tester.getSize(identity).height, height);
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'command feedback never moves the home layout or replays on navigation',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      await show(tester);
      final powerRect = tester.getRect(power);
      for (final action in ['start', 'stop', 'setMode', 'select', 'delete']) {
        controller.lastCommand = {'action': action};
        controller.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: action,
          resultSuccess: true,
          resultMessage: '已完成。',
        );
        controller.changed();
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('已完成。'), findsNothing);
        expect(tester.getRect(power), powerRect);
      }
      for (final message in ['配置解析失败，接管未启动。', '模式已保存供下次启动使用；本次切换未确认。']) {
        controller.lastCommand = {'action': 'setMode'};
        controller.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: message,
          resultMessage: message,
        );
        controller.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(message), findsOneWidget);
        expect(tester.getRect(power), powerRect);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        controller.changed();
        await tester.pump();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.getRect(power), powerRect);
      }
      await tester.tap(find.text('配置管理'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('已完成。'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('redirect risk uses a dialog and never retries without consent', (
    tester,
  ) async {
    await show(tester);
    final rect = tester.getRect(power);
    controller.lastCommand = {
      'action': 'import',
      'source': 'https://example.test',
    };
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      resultId: 'redirect',
      resultMessage: '来源重定向到 HTTP',
      needsHttpConfirmation: true,
    );
    controller.changed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('允许此次明文重定向？'), findsOneWidget);
    expect(tester.getRect(power), rect);
    expect(controller.commands, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.commands, isEmpty);
    expect(tester.getRect(power), rect);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'configuration page does not replay an earlier successful toggle',
    (tester) async {
      controller.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'old',
        resultSuccess: true,
        resultMessage: '接管已停止。',
      );
      await show(tester);
      await tester.tap(find.text('配置管理'));
      await tester.pumpAndSettle();
      expect(find.text('接管已停止。'), findsNothing);
    },
  );

  testWidgets('startup failure stays stopped; cleanup failure stays unknown', (
    tester,
  ) async {
    controller.collection = ConfigCollection(
      entries: [config('one')],
      selectedId: 'one',
    );
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      error: '配置解析失败，接管未启动。',
    );
    await show(tester);
    expect(find.text('接管已关闭'), findsWidgets);
    await tester.tap(find.text('状态异常 · 查看详情').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('配置解析失败，接管未启动。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
    controller.state = const AppSnapshot(error: '资源清理未确认。');
    controller.changed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.text('状态未确认'), findsWidgets);
    expect(find.text('接管已关闭'), findsNothing);
    await tester.tap(find.text('状态异常 · 查看详情').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('资源清理未确认。'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    expect(controller.commands, isEmpty);
  });

  testWidgets('authorization wait is not ready or native starting', (
    tester,
  ) async {
    controller.state = const AppSnapshot(
      phase: 'STOPPED',
      operation: '正在等待 VPN 授权',
    );
    await show(tester);
    expect(find.text('正在等待 VPN 授权'), findsWidgets);
    expect(find.text('正在启动'), findsNothing);
    expect(tester.widget<FilledButton>(power).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed configuration read does not display an empty collection',
    (tester) async {
      controller.configsLoaded = false;
      controller.configError = '无法读取已保存配置，原文件未被修改。';
      await show(tester);
      await tester.tap(find.text('配置管理'));
      await tester.pumpAndSettle();
      expect(find.text('尚未保存配置'), findsNothing);
      expect(find.text('配置 · 未更新'), findsOneWidget);
      await tester.tap(find.byTooltip('配置读取失败'));
      await tester.pumpAndSettle();
      expect(find.text('无法读取已保存配置，原文件未被修改。'), findsOneWidget);
    },
  );

  testWidgets(
    'configuration navigation suspends ripples and restores from source',
    (tester) async {
      controller.collection = ConfigCollection(
        entries: [config('one')],
        selectedId: 'one',
      );
      controller.state = const AppSnapshot(
        phase: 'RUNNING',
        configId: 'one',
        revision: 1,
      );
      await show(tester);
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('配置管理'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final paint = tester
          .widgetList<CustomPaint>(
            find.byType(CustomPaint, skipOffstage: false),
          )
          .map((w) => w.painter)
          .whereType<RipplePainter>()
          .single;
      expect(paint.waves, isEmpty);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'start and stop feedback keep the divider stable at scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        controller.collection = ConfigCollection(
          entries: [config('one')],
          selectedId: 'one',
        );
        await show(tester, scale: scale);
        final surface = find.byKey(const ValueKey('network-surface'));
        final top = tester.getTopLeft(surface);
        for (final snapshot in const [
          AppSnapshot(phase: 'STARTING', operation: '正在启动接管'),
          AppSnapshot(
            phase: 'RUNNING',
            configId: 'one',
            revision: 1,
            resultSuccess: true,
            resultMessage: '接管已启动。',
          ),
          AppSnapshot(phase: 'STOPPING', operation: '正在停止接管'),
          AppSnapshot(
            phase: 'STOPPED',
            resultSuccess: true,
            resultMessage: '接管已停止。',
          ),
        ]) {
          controller.state = snapshot;
          controller.changed();
          await tester.pump();
          for (final milliseconds in [80, 100, 140, 1500]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(tester.getTopLeft(surface), top);
            expect(tester.takeException(), isNull);
          }
        }
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
          Colors.transparent,
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.6, 2.0]) {
      testWidgets('narrow short screen, long name, scale $scale, dark $dark', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 600);
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
        await show(tester, dark: dark, scale: scale);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('token=private'), findsNothing);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(find.text('最近连接').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
