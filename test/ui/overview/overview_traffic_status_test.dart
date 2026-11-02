import 'dart:async';
import 'dart:ui' as ui;

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/model/traffic_snapshot.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fakes.dart';

import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

void main() {
  late AppTaskNavigatorObserver taskRoutes;
  setUp(() => taskRoutes = AppTaskNavigatorObserver());

  testWidgets(
    'overview details expose the runtime failed snapshot original error without changing its source',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 900);
      addTearDown(tester.view.reset);
      const original =
          'traffic retain original\ncause: EOF\nsuppressed: native release';
      final bridge = TrafficBridge()
        ..value = data(failed: true, error: original);
      final app = TrafficApp(bridge);
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [taskRoutes],
            theme: AppTheme.light,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: OverviewPage(controller: app),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 320));
        final traffic = tester
            .widget<TrafficPanel>(find.byType(TrafficPanel))
            .traffic;
        expect(traffic.errorMessage?.detail, original);
        expect(traffic.data?.generation, core.generation);
        expect(traffic.data?.activeCount, isNull);
        await tester.tap(find.byKey(const ValueKey('status-details')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining(original), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.textContaining(original), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
        final strings = AppLocalizations.of(
          tester.element(find.byType(AlertDialog)),
        );
        final close = find.widgetWithText(TextButton, strings.close);
        expect(close.hitTestable(), findsOneWidget);
        await tester.tap(close);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          tester.widget<TrafficPanel>(find.byType(TrafficPanel)).traffic,
          same(traffic),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      }
    },
  );

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 700.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets(
          'traffic has no explanatory control $language/$width/$scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1800);
            addTearDown(tester.view.reset);
            final bridge = TrafficBridge();
            final app = TrafficApp(bridge)
              ..state = const AppSnapshot(phase: 'STOPPED')
              ..collection = ConfigCollection(
                selectedId: 'one',
                entries: const [
                  ConfigEntry(
                    id: 'one',
                    name: 'Local',
                    kind: ConfigKind.local,
                    revision: 1,
                    body: 'rules: [MATCH,DIRECT]',
                  ),
                ],
              );
            await tester.pumpWidget(
              MaterialApp(
                navigatorObservers: [taskRoutes],
                theme: AppTheme.light,
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: OverviewPage(controller: app),
              ),
            );
            await tester.pump();
            final strings = AppLocalizations.of(
              tester.element(find.byType(OverviewPage)),
            );
            final anchors = [
              find.byKey(const ValueKey('power-button')),
              find.byKey(const ValueKey('mode-trigger')),
              find.byKey(const ValueKey('network-surface')),
            ];
            final rects = anchors.map(tester.getRect).toList();
            void check() {
              expect(anchors.map(tester.getRect).toList(), rects);
              expect(
                find.byKey(const ValueKey('traffic-status')),
                findsNothing,
              );
              expect(
                find.descendant(
                  of: find.byType(TrafficPanel),
                  matching: find.byType(IconButton),
                ),
                findsNothing,
              );
              for (final text in [
                strings.waitingTakeover,
                strings.waitingSample,
                strings.waitingStatusSync,
                strings.waitingUpdate,
              ]) {
                expect(find.text(text), findsNothing);
                expect(find.byTooltip(text), findsNothing);
              }
              expect(tester.takeException(), isNull);
            }

            check();
            expect(find.text(strings.stateStopped), findsOneWidget);
            expect(bridge.reads, 0);
            bridge.pending = Completer<TrafficSnapshot>();
            app.state = const AppSnapshot(
              phase: 'RUNNING',
              generation: 1,
              core: core,
              runningSinceElapsedMs: 1,
              elapsedRealtimeMs: 1000,
            );
            app.changed();
            for (final ms in [0, 16, 100, 180, 320]) {
              await tester.pump(Duration(milliseconds: ms));
              check();
            }
            final pending = bridge.pending!;
            bridge.pending = null;
            pending.complete(data());
            await tester.pump();
            check();
            bridge.fail = true;
            await tester.pump(const Duration(seconds: 1));
            for (final ms in [0, 16, 100, 180]) {
              await tester.pump(Duration(milliseconds: ms));
              check();
            }
            expect(find.text(strings.statusIssue), findsOneWidget);
            final details = find.byKey(const ValueKey('status-details'));
            expect(tester.getSize(details).height, greaterThanOrEqualTo(48));
            final node = tester.getSemantics(details);
            expect(node.label, strings.statusIssue);
            expect(node.rect.height, greaterThanOrEqualTo(48));
            expect(
              node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
              isTrue,
            );
            expect(details.hitTestable(), findsOneWidget);
            await tester.tap(details);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.textContaining(strings.trafficUpdateFailed),
              ),
              findsOneWidget,
            );
            expect(find.textContaining('Bad state: failed'), findsNothing);
            await tester.tap(
              find.byKey(const ValueKey('operation-technical-details')),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 250));
            expect(find.textContaining('Bad state: failed'), findsOneWidget);
            final close = find.widgetWithText(TextButton, strings.close);
            expect(close.hitTestable(), findsOneWidget);
            await tester.tap(close);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            bridge.fail = false;
            await tester.pump(const Duration(seconds: 2));
            for (final ms in [0, 16, 100, 180]) {
              await tester.pump(Duration(milliseconds: ms));
              check();
            }
            expect(find.text(strings.statusIssue), findsNothing);
            app.state = const AppSnapshot(phase: 'STOPPED');
            app.changed();
            for (final ms in [0, 16, 100, 180, 320]) {
              await tester.pump(Duration(milliseconds: ms));
              check();
            }
            expect(find.byType(AlertDialog), findsNothing);
            await tester.pumpWidget(const SizedBox());
            app.dispose();
          },
          semanticsEnabled: true,
        );
      }
    }
  }
}
