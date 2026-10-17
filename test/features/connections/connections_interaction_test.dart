import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/connections/connections_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connections_test.dart' as fixtures;

void main() {
  late fixtures.ConnectionBridgeFake bridge;
  late fixtures.ConnectionAppFake app;
  setUp(() {
    bridge = fixtures.ConnectionBridgeFake();
    app = fixtures.ConnectionAppFake(bridge);
  });
  tearDown(() => app.dispose());

  Future<void> show(
    WidgetTester tester, {
    double scale = 1,
    bool reduceMotion = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: ConnectionsPage(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('traffic-only updates keep the scroll origin, scale=$scale', (
      tester,
    ) async {
      List<Map<String, dynamic>> rows(int bytes) => List.generate(
        1000,
        (i) => fixtures.row(i.toString().padLeft(4, '0'), download: bytes),
      );
      bridge.data = fixtures.snapshot(rows(100));
      await show(tester, scale: scale);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final offset = scroll.offset;
      final top = tester.getTopLeft(find.byType(CustomScrollView)).dy;
      final target = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere(
            (text) =>
                (text.data?.endsWith('fixture.test') ?? false) &&
                tester.getTopLeft(find.text(text.data!)).dy >= top,
          )
          .data!;
      final position = tester.getTopLeft(find.text(target)).dy;
      for (final bytes in [101, 105, 120]) {
        bridge.data = fixtures.snapshot(rows(bytes));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(scroll.offset, offset);
        expect(tester.getTopLeft(find.text(target)).dy, position);
        expect(find.text('↓ $bytes B'), findsWidgets);
      }
      // A new unit/width can change row height and must keep the reading anchor.
      bridge.data = fixtures.snapshot(rows(1024 * 1024));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        (tester.getTopLeft(find.text(target)).dy - position).abs(),
        lessThan(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'large variable-height insertions and eviction preserve visible content, scale=$scale',
      (tester) async {
        Map<String, dynamic> oldRow(int i) => fixtures.row(
          i.toString().padLeft(4, '0'),
          host:
              '${i.toString().padLeft(4, '0')}.${'long-' * (i % 6)}fixture.test',
        );
        bridge.data = fixtures.snapshot(List.generate(1000, oldRow));
        await show(tester, scale: scale);
        expect(find.byType(InkWell).evaluate().length, lessThan(70));
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1800),
        );
        await tester.pumpAndSettle();
        final top = tester.getTopLeft(find.byType(CustomScrollView)).dy;
        final visible = find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data?.endsWith('fixture.test') ?? false),
        );
        final anchorText = tester.widgetList<Text>(visible).firstWhere((
          widget,
        ) {
          final y = tester.getTopLeft(find.text(widget.data!)).dy;
          return y >= top && y < top + 300;
        }).data!;
        final anchor = find.text(anchorText);
        final before = tester.getTopLeft(anchor).dy;
        bridge.data = fixtures.snapshot([
          ...List.generate(
            1000,
            (i) => {
              ...fixtures.row(
                'new$i',
                host: 'new-$i.${'variable-' * (i % 8)}fixture.test',
              ),
              'start': '2026-10-16T10:00:00Z',
            },
          ),
          ...List.generate(500, (i) => {...oldRow(i), 'active': false}),
        ]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect((tester.getTopLeft(anchor).dy - before).abs(), lessThan(1));
        expect(find.byType(InkWell).evaluate().length, lessThan(70));
        bridge.data = fixtures.snapshot(
          List.generate(498, (i) => oldRow(i + 2)),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect((tester.getTopLeft(anchor).dy - before).abs(), lessThan(1));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('live list updates while covered list waits for return', (
    tester,
  ) async {
    await show(tester);
    bridge.data = fixtures.snapshot([fixtures.row('new')]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('one.fixture.test'), findsNothing);
    expect(find.text('new.fixture.test'), findsOneWidget);
    await tester.tap(find.text('new.fixture.test'));
    await tester.pumpAndSettle();
    final covered = tester
        .widgetList<SliverList>(find.byType(SliverList, skipOffstage: false))
        .last
        .delegate;
    bridge.data = fixtures.snapshot([fixtures.row('new', download: 45)]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
      identical(
        tester
            .widgetList<SliverList>(
              find.byType(SliverList, skipOffstage: false),
            )
            .last
            .delegate,
        covered,
      ),
      isTrue,
    );
    expect(find.text('累计 45 B'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('↓ 45 B'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('menu cancellation preserves position and returns focus', (
    tester,
  ) async {
    bridge.data = fixtures.snapshot(
      List.generate(100, (i) => fixtures.row('$i')),
    );
    await show(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    final viewportTop = tester.getTopLeft(find.byType(CustomScrollView)).dy;
    final target = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere(
          (text) =>
              (text.data?.endsWith('fixture.test') ?? false) &&
              tester.getTopLeft(find.text(text.data!)).dy >= viewportTop,
        )
        .data!;
    final position = tester.getTopLeft(find.text(target)).dy;
    await tester.tap(find.byTooltip('筛选命中规则'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(PopupMenuItem<int>), findsWidgets);
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('全部规则').last)).pop();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text(target)).dy, position);
    final button = tester.widget<TextButton>(
      find.descendant(
        of: find.byTooltip('筛选命中规则'),
        matching: find.byType(TextButton),
      ),
    );
    expect(button.focusNode!.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'lifecycle and rule filters combine; all rules is a selection, not cancel',
    (tester) async {
      bridge.data = fixtures.snapshot([
        fixtures.row('active'),
        {...fixtures.row('inactive'), 'active': false},
        {...fixtures.row('match', rule: 'Match'), 'active': false},
      ]);
      await show(tester, reduceMotion: true);
      await tester.tap(find.text('全部连接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不活跃'));
      await tester.pumpAndSettle();
      expect(find.text('active.fixture.test'), findsNothing);
      expect(find.text('inactive.fixture.test'), findsOneWidget);
      await tester.tap(find.byTooltip('筛选命中规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Domain · fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('match.fixture.test'), findsNothing);
      expect(find.text('inactive.fixture.test'), findsOneWidget);
      await tester.tap(find.byTooltip('筛选命中规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部规则'));
      await tester.pumpAndSettle();
      expect(find.text('match.fixture.test'), findsOneWidget);
      expect(find.text('active.fixture.test'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
