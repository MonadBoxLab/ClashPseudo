import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configuration/runtime_fakes.dart' show TestApp, core, response;

import 'rule_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'slow rule reads coalesce continuous search to the latest intent',
    (tester) async {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      controller.filter('first');
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        bridge.queries,
        hasLength(1),
        reason: 'one real query may be in flight',
      );
      controller.filter('latest');
      await tester.pump(const Duration(milliseconds: 250));
      expect(bridge.queries, hasLength(1));
      bridge.replies.first.complete(rulePage());
      await tester.pump();
      expect(bridge.queries, hasLength(2));
      expect(bridge.queries.last['search'], 'latest');
      bridge.replies.last.complete(rulePage());
      await tester.pump();
      expect(controller.current, isTrue);
      expect(controller.failed, isFalse);
      controller.setVisible(false);
    },
  );

  for (final intent in ['same', 'search', 'source', 'scope']) {
    testWidgets(
      'out-of-range rule page retains the latest read intent: $intent',
      (tester) async {
        final bridge = RuleBridge();
        final app = TestApp(bridge);
        final controller = RulesController(app)..setVisible(true);
        addTearDown(() {
          controller.dispose();
          app.dispose();
        });
        bridge.replies.single.complete(rulePage());
        await tester.pump();
        final next = controller.next();
        expect(bridge.queries.last['token'], 'c' * 64);
        bridge.replies.last.complete(rulePage(offset: 50));
        await next;
        await tester.pump();
        final retained = controller.rows;
        await tester.pump(const Duration(seconds: 30));
        expect(bridge.queries.last['offset'], 50);
        expect(bridge.queries.last['token'], '');
        switch (intent) {
          case 'search':
            controller.filter('latest');
            await tester.pump(const Duration(milliseconds: 250));
          case 'source':
            app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
          case 'scope':
            controller.selectScope('provider', 'set');
        }
        expect(bridge.queries, hasLength(3));
        bridge.replies.last.complete(rulePage(offset: 50, total: 20));
        await tester.pump();
        expect(bridge.queries, hasLength(4));
        expect(bridge.queries.last['offset'], 0);
        expect(bridge.queries.last['token'], '');
        expect(
          bridge.queries.last['search'],
          intent == 'search' ? 'latest' : '',
        );
        expect(
          bridge.queries.last['kind'],
          intent == 'scope' ? 'provider' : 'main',
        );
        expect(bridge.queries.last['name'], intent == 'scope' ? 'set' : '');
        expect(controller.rows, same(retained));
        bridge.replies.last.complete(
          rulePage(
            kind: intent == 'scope' ? 'provider' : 'main',
            name: intent == 'scope' ? 'set' : '',
            generation: intent == 'source' ? 2 : 1,
            total: 20,
          ),
        );
        await tester.pump();
        expect(controller.offset, 0);
        expect(controller.total, 20);
        expect(controller.rows, hasLength(20));
        expect(controller.source?.generation, intent == 'source' ? 2 : 1);
        expect(controller.current, isTrue);
        controller.setVisible(false);
      },
    );
  }

  testWidgets(
    'rule readPending keeps loading and retries with capped backoff',
    (tester) async {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      for (final delay in [250, 500, 1000, 1000]) {
        final count = bridge.queries.length;
        bridge.replies.last.complete({
          ...response(core(1)),
          'readPending': true,
        });
        await tester.pump();
        expect(controller.loading, isTrue);
        expect(controller.failed, isFalse);
        expect(controller.current, isFalse);
        await tester.pump(Duration(milliseconds: delay - 1));
        expect(bridge.queries, hasLength(count));
        await tester.pump(const Duration(milliseconds: 1));
        expect(bridge.queries, hasLength(count + 1));
      }
      bridge.replies.last.complete({...response(core(1)), 'readPending': true});
      await tester.pump();
      controller.filter('new intent');
      final count = bridge.queries.length;
      await tester.pump(const Duration(milliseconds: 250));
      expect(bridge.queries, hasLength(count + 1));
      expect(bridge.queries.last['search'], 'new intent');
      bridge.replies.last.complete(rulePage());
      await tester.pump();
      expect(controller.current, isTrue);
      expect(controller.loading, isFalse);
      controller.filter('error');
      await tester.pump(const Duration(milliseconds: 250));
      bridge.replies.last.completeError(StateError('real error'));
      await tester.pump();
      expect(controller.failed, isTrue);
      final failedCount = bridge.queries.length;
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.queries, hasLength(failedCount));
      controller.setVisible(false);
    },
  );

  for (final boundary in ['hidden', 'background', 'disposed', 'expired']) {
    for (final waitingForRetry in [false, true]) {
      testWidgets(
        'rule latest intent is cancelled at $boundary boundary retry=$waitingForRetry',
        (tester) async {
          final bridge = RuleBridge();
          final app = TestApp(bridge);
          final controller = RulesController(app, expectedSource: core(1));
          if (waitingForRetry) controller.filter('latest');
          controller.setVisible(true);
          addTearDown(app.dispose);
          if (!waitingForRetry) controller.filter('latest');
          await tester.pump(const Duration(milliseconds: 250));
          if (waitingForRetry) {
            bridge.replies.first.complete({
              ...response(core(1)),
              'readPending': true,
            });
            await tester.pump();
          }
          switch (boundary) {
            case 'hidden':
              controller.setVisible(false);
            case 'background':
              app.setForeground(false);
            case 'disposed':
              controller.dispose();
            case 'expired':
              app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
          }
          if (!waitingForRetry) bridge.replies.first.complete(rulePage());
          await tester.pump(const Duration(seconds: 2));
          expect(bridge.queries, hasLength(1));
          if (boundary == 'hidden' || boundary == 'background') {
            controller.setVisible(true);
            app.setForeground(true);
            await tester.pump();
            expect(bridge.queries, hasLength(2));
            expect(bridge.queries.last['search'], 'latest');
            bridge.replies.last.complete(rulePage());
            await tester.pump();
            expect(controller.current, isTrue);
          }
          if (boundary == 'expired') {
            expect(controller.sourceExpired, isTrue);
            app.publish(AppSnapshot(phase: 'RUNNING', core: core(1)));
            await tester.pump(const Duration(seconds: 2));
            expect(bridge.queries, hasLength(1));
          }
          if (boundary != 'disposed') controller.dispose();
        },
      );
    }
  }

  testWidgets('stale rule pending envelopes fail without retrying', (
    tester,
  ) async {
    for (final field in [
      'generation',
      'composition',
      'configId',
      'revision',
      'purpose',
    ]) {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      bridge.replies.single.complete({
        ...response(core(1)),
        'readPending': true,
        field: null,
      });
      await tester.pump();
      expect(controller.failed, isTrue, reason: field);
      expect(controller.loading, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.queries, hasLength(1));
      controller.dispose();
      app.dispose();
    }
  });

  testWidgets(
    'rule scope replaces queued search without running the old scope',
    (tester) async {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(rulePage());
      await tester.pump();
      controller.filter('old');
      await tester.pump(const Duration(milliseconds: 250));
      controller.filter('latest');
      await tester.pump(const Duration(milliseconds: 250));
      controller.selectScope('provider', 'set');
      expect(bridge.queries, hasLength(2));
      bridge.replies.last.complete(rulePage());
      await tester.pump();
      expect(bridge.queries, hasLength(3));
      expect(bridge.queries.last['kind'], 'provider');
      expect(bridge.queries.last['name'], 'set');
      expect(bridge.queries.last['search'], 'latest');
      bridge.replies.last.complete(
        rulePage(kind: 'provider', name: 'set', total: 2),
      );
      await tester.pump();
      expect(controller.current, isTrue);
      expect(controller.total, 2);
      controller.setVisible(false);
    },
  );

  test('locale changes do not replace a pending rule read', () async {
    setMessageLanguage(AppLanguage.en);
    addTearDown(() => setMessageLanguage(AppLanguage.system));
    final bridge = RuleBridge();
    final app = TestApp(bridge)
      ..commandErrorMessage = messages.requestNotAccepted;
    app.state = AppSnapshot(
      phase: 'RUNNING',
      core: core(1, error: messages.androidErrorBusy),
    );
    final controller = RulesController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    final retained = app.state;
    expect(bridge.queries, hasLength(1));
    setMessageLanguage(AppLanguage.zh);
    app.publish(retained);
    expect(bridge.queries, hasLength(1));
    expect(controller.loading, isTrue);
    expect(app.state, same(retained));
    bridge.replies.single.complete(rulePage());
    await Future<void>.delayed(Duration.zero);
    expect(controller.current, isTrue);
    expect(controller.failed, isFalse);
    expect(controller.rows, hasLength(50));
    expect(app.commands, isEmpty);
  });

  test(
    'scope change keyword-only results and paging reject mixed revisions',
    () async {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(rulePage());
      await Future<void>.delayed(Duration.zero);
      final next = controller.next();
      expect(bridge.queries.last['token'], 'c' * 64);
      bridge.replies.last.complete(rulePage(offset: 50, token: 'd' * 64));
      await next;
      expect(controller.failed, isTrue);
      expect(controller.current, isFalse);
      controller.selectScope('provider', 'set');
      expect(bridge.queries.last['offset'], 0);
      expect(bridge.queries.last['token'], '');
      expect(bridge.queries.last['kind'], 'provider');
      bridge.replies.last.complete(
        rulePage(
          kind: 'provider',
          name: 'set',
          total: 2,
          origin: 'source-rules',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.origin, 'source-rules');
      expect(controller.canPage, isTrue);
      controller.selectScope('provider', 'missing');
      await Future<void>.delayed(Duration.zero);
      expect(bridge.queries.last['kind'], 'provider');
      expect(bridge.queries.last['name'], 'set');
    },
  );

  test(
    'source errors remain explicit instead of becoming empty sets',
    () async {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(
        rulePage(extra: {'error': 'sourceUnavailable', 'total': 0}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.readError!.detail, contains('sourceUnavailable'));
      expect(controller.failed, isTrue);
      expect(controller.current, isFalse);
      expect(controller.rows, isEmpty);
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets(
      'rules $language keep controls stable and identify source wording',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = RuleBridge();
        final app = TestApp(bridge);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: RulesPage(app: app),
          ),
        );
        final strings = lookupAppLocalizations(Locale(language));
        expect(find.textContaining(strings.coreReadLoading), findsNothing);
        final previous = find.widgetWithIcon(IconButton, Icons.chevron_left);
        final rect = tester.getRect(previous);
        bridge.replies.single.complete({
          ...response(core(1)),
          'readPending': true,
        });
        await tester.pump();
        expect(tester.getRect(previous), rect);
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.getRect(previous), rect);
        bridge.replies.last.complete(rulePage());
        await tester.pump();
        expect(tester.getRect(previous), rect);
        await tester.enterText(find.byType(TextField), '  direct  ');
        await tester.pump(const Duration(milliseconds: 250));
        expect(bridge.queries.last['search'], '  direct  ');
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '  direct  ',
        );
        expect(tester.getRect(previous), rect);
        bridge.replies.last.completeError(StateError('fixture failure'));
        await tester.pump();
        expect(tester.getRect(previous), rect);
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'rules automatically read the current page and retain old content after an out-of-range page until the new page completes',
    (tester) async {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.first.complete(rulePage());
      await tester.pump();
      final next = controller.next();
      bridge.replies.last.complete(rulePage(offset: 50));
      await next;
      expect(controller.offset, 50);
      final previous = controller.rows;
      await tester.pump(const Duration(seconds: 30));
      expect(bridge.queries.last['offset'], 50);
      expect(bridge.queries.last['token'], '');
      expect(controller.rows, same(previous));
      final shortened = rulePage(offset: 50, total: 1, token: 'd' * 64);
      bridge.replies.last.complete(shortened);
      await tester.pump();
      expect(bridge.queries.last['offset'], 0);
      expect(bridge.queries.last['token'], '');
      expect(controller.rows, same(previous));
      bridge.replies.last.complete(rulePage(total: 1, token: 'd' * 64));
      await tester.pump();
      expect(controller.offset, 0);
      expect(controller.rows, hasLength(1));
      expect(controller.token, 'd' * 64);
      expect(app.commands, isEmpty);
      controller.setVisible(false);
    },
  );

  group('read passthrough', () {
    testWidgets('rule UI grace keeps the real slot and the captured scope', (
      tester,
    ) async {
      final bridge = RuleBridge();
      final app = TestApp(bridge);
      final controller = RulesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      controller.filter('  latest  ');
      await tester.pump(const Duration(seconds: 6));
      expect(bridge.queries, hasLength(1));
      expect(controller.loading, isTrue);
      expect(controller.failed, isFalse);
      expect(controller.readError!.detail, contains('still pending'));
      await controller.refresh();
      expect(bridge.queries, hasLength(1));
      final first = rulePage();
      bridge.replies.first.complete(first);
      await tester.pump();
      expect(controller.rows, hasLength(50));
      expect(bridge.queries.first['search'], '');
      expect(controller.current, isFalse);
      expect(bridge.queries.first['kind'], 'main');
      expect(bridge.queries.first['name'], '');
      expect(controller.loading, isTrue);
      expect(bridge.queries, hasLength(2));
      expect(bridge.queries.last['search'], '  latest  ');
      final last = rulePage();
      bridge.replies.last.complete(last);
      await tester.pump();
      expect(controller.rows, hasLength(50));
      expect(bridge.queries.last['search'], '  latest  ');
      expect(controller.current, isTrue);
      expect(controller.loading, isFalse);
      expect(controller.readError, isNull);
      controller.setVisible(false);
    });

    testWidgets(
      'rules show only business fields and read errors retain actual causes',
      (tester) async {
        final bridge = RuleBridge();
        final app = TestApp(bridge);
        final taskRoutes = AppTaskNavigatorObserver();
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            navigatorObservers: [taskRoutes],
            home: RulesPage(app: app),
          ),
        );
        final value = rulePage();
        value['unknown-envelope'] = {'original': '${'x' * 20000}tail'};
        final row = ((value['page'] as Map)['rows'] as List).first as Map;
        row['resources'] = ['FutureGeo'];
        row['future-values'] = [false, 0, null, <Object?>[]];
        row['provenance'] = {
          'contributors': [
            {'kind': 'future-kind'},
          ],
        };
        bridge.replies.single.complete(value);
        await tester.pumpAndSettle();
        expect(find.text('set'), findsOneWidget);
        expect(find.byIcon(Icons.data_object), findsNothing);
        expect(find.byIcon(Icons.refresh), findsNothing);
        await tester.tap(find.widgetWithText(ListTile, 'set'));
        await tester.pumpAndSettle();
        expect(find.text('DIRECT'), findsWidgets);
        expect(find.textContaining('FutureGeo'), findsOneWidget);
        expect(find.textContaining('future-values'), findsNothing);
        expect(find.byIcon(Icons.data_object), findsNothing);
        await tester.tap(find.byType(BackButton).last);
        await tester.pumpAndSettle();
        final count = bridge.queries.length;
        await tester.pump(const Duration(seconds: 30));
        expect(bridge.queries, hasLength(count + 1));
        bridge.replies.last.completeError(
          PlatformFailure(
            code: 'native',
            message: 'original-rule-bridge-cause',
            details: messages.androidErrorNativeReadUnavailable
                .withDetail('original-rule-native-cause: fixture-secret')
                .toMap(),
          ),
        );
        await tester.pump();
        await tester.pump();
        await tester.pumpAndSettle();
        final status = find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(TextButton),
            )
            .first;
        expect(tester.widget<TextButton>(status).onPressed, isNotNull);
        expect(status.hitTestable(), findsOneWidget);
        final originContext = tester.element(status);
        final origin = ModalRoute.of(originContext)!;
        final workspace = tester.state<CollectionWorkspaceState>(
          find.byType(CollectionWorkspace),
        );
        expect(app.foreground, isTrue);
        expect(origin.isActive, isTrue);
        expect(origin.isCurrent, isTrue);
        expect(taskRoutes.stack.last, same(origin));
        expect(AppTaskActivity.isActive(originContext), isTrue);
        expect(AppTaskActivity.routeIsActive(origin), isTrue);
        expect(workspace.masterVisible, isTrue);
        expect(workspace.masterPresented, isTrue);
        await tester.tap(status);
        await tester.pump();
        expect(taskRoutes.stack.last, isA<DialogRoute<void>>());
        final popup = taskRoutes.stack.last as DialogRoute<void>;
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          ModalRoute.of(tester.element(find.byType(AlertDialog))),
          same(popup),
        );
        expect(popup.isActive, isTrue);
        expect(popup.isCurrent, isTrue);
        expect(popup.animation!.status, AnimationStatus.forward);
        expect(popup.animation!.value, 0);
        expect(
          AppTaskActivity.routeIsActive(origin, ownedPopup: popup),
          isTrue,
        );
        await tester.pump(
          popup.transitionDuration + const Duration(microseconds: 1),
        );
        expect(taskRoutes.stack.last, same(popup));
        expect(popup.isActive, isTrue);
        expect(popup.isCurrent, isTrue);
        expect(popup.animation!.status, AnimationStatus.completed);
        expect(popup.animation!.value, 1);
        await tester.pumpAndSettle();
        expect(taskRoutes.stack.last, same(popup));
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('original-rule-native-cause: fixture-secret'),
          findsOneWidget,
        );
        expect(
          find.textContaining('original-rule-bridge-cause'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
