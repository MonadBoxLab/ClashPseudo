import 'dart:async';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/components/input/task_shortcuts.dart';
import 'package:clash_pseudo/src/ui/connections/connection_controller.dart';
import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/ui/connections/connections_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderOpacity;
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/connection_fakes.dart' as fixtures;

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
    ValueNotifier<bool>? activity,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: activity == null
            ? ConnectionsPage(app: app)
            : ValueListenableBuilder<bool>(
                valueListenable: activity,
                child: ConnectionsPage(app: app),
                builder: (context, active, child) =>
                    AppTaskActivity(active: active, child: child!),
              ),
      ),
    );
    await tester.pumpAndSettle();
  }

  VoidCallback captureDisconnect(WidgetTester tester) {
    final button = find.byKey(const ValueKey('connection-detail-actions'));
    expect(button, findsOneWidget);
    final menu = tester.widget<ChoiceMenuButton<String>>(
      find.ancestor(
        of: button,
        matching: find.byType(ChoiceMenuButton<String>),
      ),
    );
    return () => menu.onSelected('connection-disconnect');
  }

  for (final width in [700.0, 1200.0]) {
    testWidgets(
      'visible master retains the shared read while detail selection survives, width=$width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.reset);
        final pending = Completer<ConnectionSnapshot>();
        try {
          await show(tester);
          await tester.tap(find.text('one.fixture.test'));
          await tester.pumpAndSettle();
          final workspaceFinder = find.byType(CollectionWorkspace);
          expect(workspaceFinder, findsOneWidget);
          final workspace = tester.state<CollectionWorkspaceState>(
            workspaceFinder,
          );
          final dynamic detail = tester
              .widget<CollectionWorkspace>(workspaceFinder)
              .detail;
          final controller = detail.controller as ConnectionController;
          final detailState = tester.state(find.byWidget(detail as Widget));
          final lease = controller.detailLease;
          final source = controller.detailSource!;
          expect(lease, isNotNull);
          expect(controller.active, isTrue);
          expect(controller.canClose, isTrue);
          final close = captureDisconnect(tester);

          void expectSelection() {
            expect(workspaceFinder, findsOneWidget);
            final dynamic selected = tester
                .widget<CollectionWorkspace>(workspaceFinder)
                .detail;
            expect(selected.controller, same(controller));
            expect(
              tester.state(find.byWidget(selected as Widget)),
              same(detailState),
            );
            expect(controller.detailLease, same(lease));
            expect(controller.detailSource, same(source));
            expect(controller.data!.source.matchesIdentity(source), isTrue);
            expect(source.matchesIdentity(app.state.core), isTrue);
          }

          final master = find.byKey(const ValueKey('connection-reading-list'));
          void expectMasterWindow(String id, int download) {
            expect(master, findsOneWidget);
            expect(
              find
                  .descendant(
                    of: master,
                    matching: find.text('$id.fixture.test'),
                  )
                  .hitTestable(),
              findsOneWidget,
            );
            expect(
              find
                  .descendant(of: master, matching: find.text('↓ $download B'))
                  .hitTestable(),
              findsOneWidget,
            );
          }

          final beforePending = bridge.reads;
          final previous = controller.data;
          bridge.pending = pending;
          await tester.pump(const Duration(seconds: 1));
          expect(bridge.reads, beforePending + 1);
          expect(bridge.readOwners.last, same(lease));
          expect(pending.isCompleted, isFalse);
          expect(controller.data, same(previous));
          final drained = fixtures.snapshot([
            fixtures.row('one', download: 20),
          ]);
          bridge.data = drained;
          bridge.pending = null;
          pending.complete(drained);
          await tester.pump();
          expect(pending.isCompleted, isTrue);
          expect(controller.data, same(drained));
          expect(controller.current, isTrue);
          expectSelection();

          final beforeMaster = bridge.reads;
          workspace.showMaster();
          await tester.pump();
          expect(workspace.masterVisible, isTrue);
          expect(workspace.detailVisible, width == 1200);
          expect(controller.active, isTrue);
          expect(controller.canClose, isTrue);
          expect(bridge.reads, beforeMaster);
          expect(bridge.releasedOwners, isEmpty);
          expectSelection();
          if (width == 700) {
            close();
            expect(app.commands, isEmpty);
          }

          final masterWindow = fixtures.snapshot([
            fixtures.row('one', download: 31),
          ]);
          bridge.data = masterWindow;
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(bridge.reads, beforeMaster + 1);
          expect(bridge.readOwners.last, same(lease));
          expect(controller.data, same(masterWindow));
          expect(controller.detail!.download, 31);
          expectMasterWindow('one', 31);
          expectSelection();

          final reveal = find.byKey(const ValueKey('collection-show-details'));
          if (width == 700) {
            expect(reveal, findsOneWidget);
            await tester.tap(reveal);
            await tester.pump();
            expect(workspace.masterVisible, isFalse);
          } else {
            expect(reveal, findsNothing);
            expect(workspace.masterVisible, isTrue);
          }
          expect(workspace.detailVisible, isTrue);
          expectSelection();
          await tester.pumpAndSettle();
          final beforeDetail = bridge.reads;
          final detailWindow = fixtures.snapshot([
            fixtures.row('one', download: 42),
          ]);
          bridge.data = detailWindow;
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(bridge.reads, beforeDetail + 1);
          expect(controller.data, same(detailWindow));
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('connection-detail-scroll')),
              matching: find.text('累计 42 B'),
            ),
            findsOneWidget,
          );
          expectSelection();

          final currentDetail = tester
              .widget<CollectionWorkspace>(workspaceFinder)
              .detail!;
          final back = find.descendant(
            of: find.byWidget(currentDetail),
            matching: find.byType(BackButton),
          );
          expect(back, findsOneWidget);
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(
            tester.widget<CollectionWorkspace>(workspaceFinder).detail,
            isNull,
          );
          expect(controller.detail, isNull);
          expect(controller.detailLease, isNull);
          expect(bridge.releasedOwners, [lease]);
          expect(workspace.masterVisible, isTrue);
          expect(controller.active, isTrue);
          final beforeClose = bridge.reads;
          final closedWindow = fixtures.snapshot([
            fixtures.row('after-close', download: 53),
          ]);
          bridge.data = closedWindow;
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(bridge.reads, beforeClose + 1);
          expect(bridge.readOwners.last, isNull);
          expect(controller.data, same(closedWindow));
          expect(closedWindow.source.matchesIdentity(source), isTrue);
          expectMasterWindow('after-close', 53);
          expect(app.commands, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          bridge.pending = null;
          if (!pending.isCompleted) {
            pending.complete(bridge.data);
            await tester.pump();
          }
        }
      },
    );
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'raw SDK expansion preserves reader, animates height and revokes collapse actions reduced=$reduced',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(700, 1000);
        addTearDown(tester.view.reset);
        var copies = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') copies++;
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await show(tester, reduceMotion: reduced);
        await tester.tap(find.text('one.fixture.test'));
        await tester.pumpAndSettle();
        final tile = find.byType(ExpansionTile);
        await tester.ensureVisible(find.text('原始数据'));
        final collapsed = tester.getSize(tile).height;
        await tester.tap(find.text('原始数据'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        final opening = tester.getSize(tile).height;
        if (!reduced) {
          expect(opening, greaterThan(collapsed));
          expect(opening, lessThan(collapsed + 360));
        }
        await tester.pump(const Duration(milliseconds: 300));
        final expanded = tester.getSize(tile).height;
        expect(expanded, greaterThanOrEqualTo(collapsed + 360));
        final reader = find.byKey(
          const ValueKey('connection-raw-reader'),
          skipOffstage: false,
        );
        final readerState = tester.state(reader);
        final copy = tester
            .widget<IconButton>(
              find.byKey(const ValueKey('original-text-copy')),
            )
            .onPressed!;
        await tester.tap(find.text('原始数据'));
        await tester.pump();
        copy();
        await tester.pump();
        expect(copies, 0);
        final view = tester.widget<OriginalTextView>(reader);
        expect(view.isCurrent!(), isFalse);
        expect(tester.state(reader), same(readerState));
        await tester.pump(const Duration(milliseconds: 60));
        final closing = tester.getSize(tile).height;
        if (!reduced) {
          expect(closing, greaterThan(collapsed));
          expect(closing, lessThan(expanded));
        } else {
          expect(closing, closeTo(collapsed, .1));
        }
        await tester.tap(find.text('原始数据'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        if (!reduced) expect(tester.getSize(tile).height, greaterThan(closing));
        expect(tester.state(reader), same(readerState));
        expect(tester.widget<OriginalTextView>(reader).isCurrent!(), isTrue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'real detail first-frame retreat revokes raw and close, quick reversal retains reading identity',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1000);
      addTearDown(tester.view.reset);
      var copies = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') copies++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      final workspaceFinder = find.byType(CollectionWorkspace);
      final workspace = tester.state<CollectionWorkspaceState>(workspaceFinder);
      final dynamic detail = tester
          .widget<CollectionWorkspace>(workspaceFinder)
          .detail;
      final controller = detail.controller as ConnectionController;
      final detailState = tester.state(find.byWidget(detail as Widget));
      final close = captureDisconnect(tester);
      await tester.ensureVisible(find.text('原始数据'));
      await tester.tap(find.text('原始数据'));
      await tester.pumpAndSettle();
      final reader = find.byKey(
        const ValueKey('connection-raw-reader'),
        skipOffstage: false,
      );
      final rawState = tester.state(reader);
      final copy = tester
          .widget<IconButton>(find.byKey(const ValueKey('original-text-copy')))
          .onPressed!;
      final scroll = find.byKey(
        const ValueKey('connection-detail-scroll'),
        skipOffstage: false,
      );
      final left = tester.getTopLeft(scroll).dx;
      final width = tester.getSize(scroll).width;
      final scrollable = find
          .descendant(
            of: scroll,
            matching: find.byType(Scrollable, skipOffstage: false),
          )
          .first;
      final scrollState = tester.state<ScrollableState>(scrollable);
      final scrollPosition = scrollState.position;
      final scrollOffset = scrollPosition.pixels;
      // The pane's layout Opacity, not the selection-replacement FadeTransition.
      final paneFade = find.ancestor(
        of: scroll,
        matching: find.descendant(
          of: workspaceFinder,
          matching: find.byType(Opacity, skipOffstage: false),
        ),
      );
      expect(paneFade, findsOneWidget);
      double opacity() => tester.renderObject<RenderOpacity>(paneFade).opacity;
      void expectReadingIdentity() {
        final dynamic nextDetail = tester
            .widget<CollectionWorkspace>(workspaceFinder)
            .detail;
        expect(nextDetail.controller, same(controller));
        expect(
          tester.state(find.byWidget(nextDetail as Widget)),
          same(detailState),
        );
        expect(tester.state(reader), same(rawState));
        expect(tester.state<ScrollableState>(scrollable), same(scrollState));
        expect(scrollState.position, same(scrollPosition));
        expect(scrollPosition.pixels, scrollOffset);
        expect(tester.getTopLeft(scroll).dx, closeTo(left, .01));
        expect(tester.getSize(scroll).width, closeTo(width, .01));
      }

      expect(opacity(), 1);
      workspace.showMaster();
      await tester.pump();
      expect(workspace.detailVisible, isFalse);
      expect(tester.widget<OriginalTextView>(reader).isCurrent!(), isFalse);
      expect(opacity(), 1);
      expectReadingIdentity();
      copy();
      close();
      await tester.pump();
      expect(copies, 0);
      expect(app.commands, isEmpty);
      await tester.pump(const Duration(milliseconds: 60));
      final retreat = opacity();
      expect(retreat, greaterThan(0));
      expect(retreat, lessThan(1));
      expectReadingIdentity();
      final reveal = tester
          .widget<IconButton>(
            find.descendant(
              of: find.byType(CollectionDetailsAction),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed!;
      reveal();
      await tester.pump();
      expect(opacity(), closeTo(retreat, .001));
      expectReadingIdentity();
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(), greaterThan(retreat));
      expect(opacity(), lessThan(1));
      expectReadingIdentity();
      expect(tester.widget<OriginalTextView>(reader).isCurrent!(), isTrue);
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      expectReadingIdentity();

      workspace.showMaster();
      await tester.pump();
      expect(workspace.detailVisible, isFalse);
      expect(tester.widget<OriginalTextView>(reader).isCurrent!(), isFalse);
      copy();
      close();
      await tester.pump();
      expect(copies, 0);
      expect(app.commands, isEmpty);
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(), greaterThan(0));
      expect(opacity(), lessThan(1));
      await tester.pumpAndSettle();
      expect(opacity(), 0);
      expectReadingIdentity();
      expect(tester.widget<OriginalTextView>(reader).isCurrent!(), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'retained task exit rejects captured connection actions before any animation completes',
    (tester) async {
      final activity = ValueNotifier(true);
      addTearDown(activity.dispose);
      await show(tester, activity: activity);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      final close = captureDisconnect(tester);
      final reads = bridge.reads;
      activity.value = false;
      await tester.pump();
      close();
      await tester.pump(const Duration(seconds: 2));
      expect(app.commands, isEmpty);
      expect(bridge.reads, reads);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final scale in [1.0, 2.0]) {
    for (final lifecycle in [true, false]) {
      testWidgets(
        'owned filter menu stays live but another route pauses reads $scale $lifecycle',
        (tester) async {
          bridge.data = fixtures.snapshot([
            fixtures.row('one'),
            fixtures.row('two'),
          ]);
          await show(tester, scale: scale, reduceMotion: true);
          final trigger = lifecycle
              ? find.byKey(
                  tester
                      .widget<TextButton>(
                        find.widgetWithText(TextButton, '全部连接'),
                      )
                      .key!,
                )
              : find.byTooltip('筛选命中规则');
          final triggerRect = tester.getRect(trigger);
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          final entries = find.byType(MenuItemButton);
          final positions = tester
              .widgetList<MenuItemButton>(entries)
              .map((item) => tester.getRect(find.byWidget(item)))
              .toList();
          final labels = tester
              .widgetList<Text>(
                find.descendant(of: entries, matching: find.byType(Text)),
              )
              .map((text) => text.data)
              .toList();
          final before = bridge.reads;
          bridge.data = fixtures.snapshot([
            fixtures.row('one', download: 2048),
            fixtures.row('two'),
            fixtures.row('three', rule: 'NewRule'),
          ]);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(bridge.reads, greaterThan(before));
          expect(find.text('↓ 2.0 KiB'), findsOneWidget);
          expect(tester.getRect(trigger), triggerRect);
          expect(
            tester
                .widgetList<MenuItemButton>(entries)
                .map((item) => tester.getRect(find.byWidget(item)))
                .toList(),
            positions,
          );
          expect(
            tester
                .widgetList<Text>(
                  find.descendant(of: entries, matching: find.byType(Text)),
                )
                .map((text) => text.data)
                .toList(),
            labels,
          );
          final navigator = tester.state<NavigatorState>(
            find.byType(Navigator),
          );
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('other route')),
            ),
          );
          await tester.pumpAndSettle();
          final coveredReads = bridge.reads;
          await tester.pump(const Duration(seconds: 3));
          expect(bridge.reads, coveredReads);
          navigator.pop();
          await tester.pumpAndSettle();
          expect(bridge.reads, greaterThan(coveredReads));
          expect(find.byType(MenuItemButton), findsNothing);
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(MenuItemButton, lifecycle ? '全部连接' : '全部规则'),
          );
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
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

  for (final width in [800.0, 1200.0]) {
    testWidgets('list follows actual pane visibility at width=$width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester);
      bridge.data = fixtures.snapshot([fixtures.row('new')]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('one.fixture.test'), findsNothing);
      expect(find.text('new.fixture.test'), findsOneWidget);
      await tester.tap(find.text('new.fixture.test'));
      await tester.pumpAndSettle();
      final delegate = tester
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
          delegate,
        ),
        width == 800,
      );
      expect(find.text('累计 45 B'), findsOneWidget);
      if (width == 1200) expect(find.text('↓ 45 B'), findsOneWidget);
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      expect(find.text('↓ 45 B'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'filter cancellation restores page shortcuts without revoking focus, reduced=$reduced',
      (tester) async {
        await show(tester, reduceMotion: reduced);
        final shortcuts = find.byType(TaskShortcuts);
        final capturedSearch = tester
            .widget<TaskShortcuts>(shortcuts)
            .onSearch!;
        final filter = find.byTooltip('筛选命中规则');
        expect(filter, findsOneWidget);
        final trigger = find.descendant(
          of: filter,
          matching: find.byType(TextButton),
        );
        expect(trigger, findsOneWidget);
        final triggerKey = tester.widget<TextButton>(trigger).key!;
        final filterButton = find.byKey(triggerKey);
        expect(filterButton, findsOneWidget);
        await tester.tap(filterButton);
        // onOpened changes the callback gate before the next rebuild.
        capturedSearch();
        expect(find.byType(TextField), findsNothing);
        await tester.pumpAndSettle();
        expect(tester.widget<TaskShortcuts>(shortcuts).enabled, isTrue);
        expect(
          tester.widget<TaskShortcuts>(shortcuts).shortcutsEnabled,
          isFalse,
        );
        expect(filterButton, findsOneWidget);
        final button = tester.widget<TextButton>(filterButton);
        expect(button.focusNode!.canRequestFocus, isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(find.byType(TextField), findsNothing);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TaskShortcuts>(shortcuts).shortcutsEnabled,
          isTrue,
        );
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget);
        final capturedEscape = tester
            .widget<TaskShortcuts>(shortcuts)
            .onEscape!;
        expect(filterButton, findsOneWidget);
        await tester.tap(filterButton);
        capturedEscape();
        expect(find.byType(TextField), findsOneWidget);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TaskShortcuts>(shortcuts).shortcutsEnabled,
          isFalse,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TaskShortcuts>(shortcuts).shortcutsEnabled,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'late filter close cannot restore shortcuts for another owner or retired task',
    (tester) async {
      final activity = ValueNotifier(true);
      addTearDown(activity.dispose);
      await show(tester, activity: activity);
      final shortcuts = find.byType(TaskShortcuts);
      final capturedSearch = tester.widget<TaskShortcuts>(shortcuts).onSearch!;
      final menus = tester
          .widgetList<ChoiceMenuButton<int>>(find.byType(ChoiceMenuButton<int>))
          .toList();
      expect(menus, hasLength(2));
      // Drive captured consumer notifications, including an older menu's late
      // close, independently of the SDK's exclusive visible menu overlay.
      menus.first.onOpened!();
      menus.last.onOpened!();
      menus.first.onClosed!();
      capturedSearch();
      expect(find.byType(TextField), findsNothing);
      await tester.pump();
      expect(tester.widget<TaskShortcuts>(shortcuts).enabled, isTrue);
      expect(tester.widget<TaskShortcuts>(shortcuts).shortcutsEnabled, isFalse);
      menus.first.onClosed!();
      await tester.pump();
      expect(tester.widget<TaskShortcuts>(shortcuts).shortcutsEnabled, isFalse);
      activity.value = false;
      await tester.pump();
      menus.last.onClosed!();
      capturedSearch();
      await tester.pump();
      expect(tester.widget<TaskShortcuts>(shortcuts).enabled, isFalse);
      expect(tester.widget<TaskShortcuts>(shortcuts).shortcutsEnabled, isTrue);
      expect(find.byType(TextField), findsNothing);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
    expect(find.byType(MenuItemButton), findsWidgets);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
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
