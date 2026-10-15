import 'package:clash_pseudo/app/app_shell.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/features/strategies/strategy_popup.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'strategy_fakes.dart';

void main() {
  late StrategyBridgeFake bridge;
  late StrategyAppFake app;
  setUp(() {
    bridge = StrategyBridgeFake();
    app = StrategyAppFake(bridge);
  });
  tearDown(() => app.dispose());

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    bool animations = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: !animations,
          ),
          child: child!,
        ),
        home: AppShell(controller: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> strategies(WidgetTester tester) async {
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, String name) async {
    final group = find.byKey(ValueKey('strategy-group-$name'));
    await tester.scrollUntilVisible(
      group,
      180,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('strategies-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(group);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'two destinations, lazy strategy reading and secondary configuration route',
    (tester) async {
      await show(tester);
      expect(find.byType(NavigationDestination), findsNWidgets(2));
      expect(bridge.reads, 0);
      expect(app.commands, isEmpty);
      await strategies(tester);
      expect(bridge.reads, 1);
      expect(find.byKey(const ValueKey('strategy-group-隐藏')), findsNothing);
      expect(find.byKey(const ValueKey('strategy-group-GLOBAL')), findsNothing);
      await tester.tap(find.byTooltip('管理配置'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(bridge.reads, 2);
      await tester.tap(find.byType(NavigationDestination).first);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'choice waits for actual result and keeps the member panel open',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '出口');
      final memberA = find.byKey(const ValueKey('strategy-member-0'));
      final memberB = find.byKey(const ValueKey('strategy-member-1'));
      await tester.ensureVisible(memberB);
      final card = find.byKey(const ValueKey('strategy-card-出口'));
      final sourceBefore = tester.getRect(card);
      final popup = find.byKey(const ValueKey('strategy-popup-出口'));
      final popupBefore = tester.getTopLeft(popup);
      await tester.tap(memberB);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('正在切换…'), findsOneWidget);
      expect(tester.getRect(card), sourceBefore);
      expect(tester.getTopLeft(popup), popupBefore);
      expect(
        find.descendant(
          of: memberA,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: memberB,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
      bridge.data = strategyData(now: 'B');
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: previewCore,
        resultId: 'done',
        resultSuccess: true,
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsOneWidget);
      expect(
        find.descendant(
          of: memberB,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(app.commands.single['action'], 'setStrategy');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'load balance is readable without a fictitious single selection',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '均衡');
      expect(find.text('负载均衡 · 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('strategy-automatic')), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const ValueKey('strategy-member-0')))
            .onTap,
        isNull,
      );
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'closing a waiting panel does not cancel or resubmit the choice',
    (tester) async {
      await show(tester);
      await strategies(tester);
      await open(tester, '出口');
      await tester.tap(find.byKey(const ValueKey('strategy-member-1')));
      await tester.pump();
      expect(find.text('正在切换…'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭策略浮窗'));
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsNothing);
      expect(app.commands, hasLength(1));
      bridge.data = strategyData(now: 'B');
      app.state = const AppSnapshot(
        phase: 'STOPPED',
        core: previewCore,
        resultId: 'late',
        resultSuccess: true,
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(app.commands, hasLength(1));
      await open(tester, '出口');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('strategy-member-1')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('popup follows its card instead of the bottom edge', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    final card = tester.getRect(
      find.byKey(const ValueKey('strategy-group-出口')),
    );
    await open(tester, '出口');
    final popup = tester.getRect(
      find.byKey(const ValueKey('strategy-popup-出口')),
    );
    expect(popup.left, card.left);
    expect(popup.top, card.top);
    expect(popup.bottom, lessThan(588));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.textContaining('不会自动启动'), findsNothing);
    expect(find.textContaining('已有连接保持'), findsNothing);
    final reads = bridge.reads;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(bridge.reads, greaterThan(reads));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('popup flips above a low card and stays inside resized screen', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '均衡');
    final card = tester.getRect(
      find.byKey(const ValueKey('strategy-group-均衡')),
    );
    final popup = find.byKey(const ValueKey('strategy-popup-均衡'));
    expect(tester.getRect(popup).overlaps(card), isTrue);
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(popup);
    expect(bounds.left, greaterThanOrEqualTo(12));
    expect(bounds.right, lessThanOrEqualTo(308));
    expect(bounds.top, greaterThanOrEqualTo(12));
    expect(bounds.bottom, lessThanOrEqualTo(588));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [320.0, 1000.0]) {
    testWidgets(
      'member groups can be selected but never opened recursively width=$width',
      (tester) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        bridge.data = StrategySnapshot(
          generation: 7,
          configId: 'one',
          revision: 1,
          purpose: 'PREVIEW',
          globalReferenced: false,
          unrestored: {},
          groups: [
            StrategyGroup(
              name: '父组',
              rawType: 'select',
              hidden: false,
              now: '自动',
              fixed: '',
              members: const [
                StrategyMember(name: '出口', type: 'Socks5'),
                StrategyMember(name: '自动', type: 'url-test'),
              ],
            ),
            ...strategyData().groups,
          ],
        );
        await show(tester);
        await strategies(tester);
        await open(tester, '父组');
        expect(find.byTooltip('展开出口'), findsNothing);
        expect(find.byTooltip('展开自动'), findsNothing);
        expect(find.byIcon(Icons.chevron_right), findsNothing);
        final popup = find.byKey(const ValueKey('strategy-popup-父组'));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('strategy-member-0')),
            matching: find.text('Socks5'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('strategy-member-1')),
            matching: find.text('A'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('strategy-member-1')));
        await tester.pump();
        expect(app.commands.single['name'], '父组');
        expect(app.commands.single['choice'], {
          'type': 'select',
          'member': '自动',
        });
        expect(popup, findsOneWidget);
        expect(find.byType(StrategyPopup), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.byType(StrategyPopup), findsNothing);
        expect(app.commands, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('old popup cannot select a same-named replacement group', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    const replacement = CoreSnapshot(
      generation: 8,
      phase: 'READY',
      purpose: 'PREVIEW',
      configId: 'one',
      revision: 1,
    );
    bridge.data = strategyData(core: replacement);
    app.state = const AppSnapshot(phase: 'STOPPED', core: replacement);
    app.changed();
    await tester.pumpAndSettle();
    expect(find.text('策略已更新，请重新打开。'), findsOneWidget);
    expect(find.byKey(const ValueKey('strategy-member-0')), findsNothing);
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening and closing morph the source without moving the grid', (
    tester,
  ) async {
    await show(tester, animations: true);
    await strategies(tester);
    final card = find.byKey(const ValueKey('strategy-group-出口'));
    final original = tester.getRect(card);
    final sourceOpacity = find
        .ancestor(of: card, matching: find.byType(Opacity))
        .first;
    await tester.tap(card);
    await tester.pump();
    expect(tester.widget<Opacity>(sourceOpacity).opacity, 0);
    final reveal = find.byKey(const ValueKey('strategy-reveal-出口'));
    double paintedWidth() => tester
        .widget<ClipRRect>(reveal)
        .clipper!
        .getClip(tester.getSize(reveal))
        .width;
    expect(paintedWidth(), closeTo(original.width, .01));
    await tester.pump(const Duration(milliseconds: 70));
    expect(paintedWidth(), greaterThan(original.width));
    expect(paintedWidth(), lessThan(420));
    await tester.pumpAndSettle();
    expect(paintedWidth(), 420);
    expect(tester.getRect(card), original);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(tester.widget<Opacity>(sourceOpacity).opacity, 0);
    expect(paintedWidth(), lessThan(420));
    await tester.pumpAndSettle();
    expect(find.byType(StrategyPopup), findsNothing);
    expect(tester.widget<Opacity>(sourceOpacity).opacity, 1);
    expect(tester.getRect(card), original);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('interrupted opening restores source and permits reopening', (
    tester,
  ) async {
    await show(tester, animations: true);
    await strategies(tester);
    final card = find.byKey(const ValueKey('strategy-group-出口'));
    await tester.tap(card);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: card, matching: find.byType(Opacity)).first,
          )
          .opacity,
      1,
    );
    await open(tester, '出口');
    expect(find.byType(StrategyPopup), findsOneWidget);
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'background and context replacement during morph leave no hidden source',
    (tester) async {
      await show(tester, animations: true);
      await strategies(tester);
      final card = find.byKey(const ValueKey('strategy-group-出口'));
      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      app.setForeground(false);
      const replacement = CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'PREVIEW',
        configId: 'one',
        revision: 1,
      );
      bridge.data = strategyData(core: replacement);
      app.state = const AppSnapshot(phase: 'STOPPED', core: replacement);
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('strategy-member-0')), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      app.setForeground(true);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Opacity>(
              find.ancestor(of: card, matching: find.byType(Opacity)).first,
            )
            .opacity,
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'empty group and large member lists retain usable close and scroll',
    (tester) async {
      bridge.data = StrategySnapshot(
        generation: 7,
        configId: 'one',
        revision: 1,
        purpose: 'PREVIEW',
        globalReferenced: false,
        unrestored: {},
        groups: [
          StrategyGroup(
            name: '空组',
            rawType: 'select',
            hidden: false,
            now: '',
            fixed: '',
            members: [],
          ),
          StrategyGroup(
            name: '大量成员',
            rawType: 'select',
            hidden: false,
            now: '节点0',
            fixed: '',
            members: List.generate(
              100,
              (i) => StrategyMember(name: '节点$i', type: 'Socks5'),
            ),
          ),
        ],
      );
      await show(tester);
      await strategies(tester);
      await open(tester, '空组');
      expect(find.text('手动选择 · 0'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭策略浮窗'));
      await tester.pumpAndSettle();
      await open(tester, '大量成员');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('strategy-member-99')),
        400,
        maxScrolls: 30,
        scrollable: find.descendant(
          of: find.byType(StrategyPopup),
          matching: find.byType(Scrollable),
        ),
      );
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(StrategyPopup),
          matching: find.byType(Scrollable),
        ),
      );
      final offset = scroll.position.pixels;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(scroll.position.pixels, offset);
      await tester.tap(find.byTooltip('关闭策略浮窗'));
      await tester.pumpAndSettle();
      expect(find.byType(StrategyPopup), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('read failure removes selection and disables member changes', (
    tester,
  ) async {
    await show(tester);
    await strategies(tester);
    await open(tester, '出口');
    bridge.failRead = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('状态未更新'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(
      tester
          .widget<InkWell>(find.byKey(const ValueKey('strategy-member-1')))
          .onTap,
      isNull,
    );
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('many groups keep scroll position after returning from a popup', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    bridge.data = StrategySnapshot(
      generation: 7,
      configId: 'one',
      revision: 1,
      purpose: 'PREVIEW',
      globalReferenced: false,
      unrestored: {},
      groups: List.generate(
        50,
        (i) => StrategyGroup(
          name: '策略$i',
          rawType: 'select',
          hidden: false,
          now: 'A',
          fixed: '',
          members: const [StrategyMember(name: 'A', type: 'Socks5')],
        ),
      ),
    );
    await show(tester);
    await strategies(tester);
    await open(tester, '策略49');
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const PageStorageKey('strategies-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    final offset = scroll.position.pixels;
    expect(offset, greaterThan(0));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, offset);
    expect(
      find.byKey(const ValueKey('strategy-group-策略49')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final dark in [false, true]) {
    test('navigation and member selection use neutral surfaces dark=$dark', () {
      final theme = dark ? AppTheme.dark : AppTheme.light;
      final palette = HomePalette(dark);
      expect(theme.navigationBarTheme.backgroundColor, palette.surface);
      expect(theme.navigationBarTheme.indicatorColor, palette.soft);
      expect(theme.colorScheme.surfaceContainerHighest, palette.soft);
      expect(
        theme.navigationBarTheme.iconTheme!.resolve({
          WidgetState.selected,
        })!.color,
        palette.accent,
      );
      expect(
        theme.navigationBarTheme.iconTheme!.resolve({})!.color,
        palette.muted,
      );
    });
    testWidgets(
      'long names and unrestored warning remain scrollable dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final name = List.filled(10, '很长的策略名称🌐').join();
        final member = List.filled(10, 'long-node-name🌐').join();
        bridge.data = StrategySnapshot(
          generation: 7,
          configId: 'one',
          revision: 1,
          purpose: 'PREVIEW',
          globalReferenced: false,
          unrestored: {name: 'member-missing'},
          groups: [
            StrategyGroup(
              name: name,
              rawType: 'select',
              hidden: false,
              now: member,
              fixed: '',
              members: [StrategyMember(name: member, type: 'Socks5')],
            ),
          ],
        );
        await show(tester, dark: dark, scale: 2);
        await strategies(tester);
        expect(find.textContaining('原选择未恢复'), findsOneWidget);
        await open(tester, name);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('strategy-member-0')),
          180,
          scrollable: find.descendant(
            of: find.byType(StrategyPopup),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('strategy-member-0')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'strategy cards and automatic sheet fit short double-text screen dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await show(tester, dark: dark, scale: 2);
        await strategies(tester);
        await open(tester, '自动');
        expect(find.byType(StrategyPopup), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('strategy-member-1')),
          120,
          scrollable: find.descendant(
            of: find.byType(StrategyPopup),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('strategy-automatic')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('strategy-automatic')));
        await tester.pump();
        expect(app.commands.single['choice'], {
          'type': 'url-test',
          'member': null,
        });
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
