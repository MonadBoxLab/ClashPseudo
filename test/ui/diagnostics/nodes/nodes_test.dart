import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configuration/runtime_fakes.dart' show TestApp, core, response;

import 'node_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'slow node reads coalesce continuous search to the latest intent',
    (tester) async {
      final bridge = NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
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
      bridge.replies.first.complete(page());
      await tester.pump();
      expect(bridge.queries, hasLength(2));
      expect(bridge.queries.last['search'], 'latest');
      bridge.replies.last.complete(page());
      await tester.pump();
      expect(controller.current, isTrue);
      expect(controller.failed, isFalse);
    },
  );

  testWidgets(
    'node readPending keeps loading and retries with capped backoff',
    (tester) async {
      final bridge = NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
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
      bridge.replies.last.complete(page());
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
    },
  );

  for (final boundary in ['hidden', 'background', 'disposed', 'expired']) {
    for (final waitingForRetry in [false, true]) {
      testWidgets(
        'node latest intent is cancelled at $boundary boundary retry=$waitingForRetry',
        (tester) async {
          final bridge = NodeBridge();
          final app = TestApp(bridge);
          final controller = NodesController(app, expectedSource: core(1));
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
          if (!waitingForRetry) bridge.replies.first.complete(page());
          await tester.pump(const Duration(seconds: 2));
          expect(bridge.queries, hasLength(1));
          if (boundary == 'hidden' || boundary == 'background') {
            controller.setVisible(true);
            app.setForeground(true);
            await tester.pump();
            expect(bridge.queries, hasLength(2));
            expect(bridge.queries.last['search'], 'latest');
            bridge.replies.last.complete(page());
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

  testWidgets('stale node pending envelopes fail without retrying', (
    tester,
  ) async {
    for (final field in [
      'generation',
      'composition',
      'configId',
      'revision',
      'purpose',
    ]) {
      final bridge = NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
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

  test('locale changes do not replace a pending node read', () async {
    setMessageLanguage(AppLanguage.en);
    addTearDown(() => setMessageLanguage(AppLanguage.system));
    final bridge = NodeBridge();
    final app = TestApp(bridge)
      ..commandErrorMessage = messages.requestNotAccepted;
    app.state = AppSnapshot(
      phase: 'RUNNING',
      core: core(1, error: messages.androidErrorBusy),
    );
    final controller = NodesController(app)..setVisible(true);
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
    bridge.replies.single.complete(page());
    await Future<void>.delayed(Duration.zero);
    expect(controller.current, isTrue);
    expect(controller.failed, isFalse);
    expect(controller.nodes, hasLength(50));
    expect(app.commands, isEmpty);
  });

  test(
    'pagination retains source token and detail return retains page',
    () async {
      final bridge = NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(page());
      await Future<void>.delayed(Duration.zero);
      final next = controller.next();
      expect(bridge.queries.last['offset'], 50);
      expect(bridge.queries.last['token'], 'a' * 64);
      bridge.replies.last.complete(page(offset: 50));
      await next;
      expect(controller.nodes.single['name'], 'node-50');
      controller.setVisible(false);
      controller.setVisible(true);
      expect(bridge.queries.last['offset'], 50);
      bridge.replies.last.complete(page(offset: 50));
      await Future<void>.delayed(Duration.zero);
      expect(controller.offset, 50);
      final refresh = controller.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.queries.last['offset'], 0);
      expect(bridge.queries.last['token'], '');
      bridge.replies.last.complete(page());
      await refresh;
      await Future<void>.delayed(Duration.zero);
      expect(controller.offset, 0);
    },
  );

  test(
    'provider revision mismatch disables paging without mixing rows',
    () async {
      final bridge = NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(page());
      await Future<void>.delayed(Duration.zero);
      final oldRows = controller.nodes;
      final next = controller.next();
      bridge.replies.last.complete(page(offset: 50, token: 'b' * 64));
      await next;
      expect(controller.failed, isTrue);
      expect(controller.current, isFalse);
      expect(controller.canPage, isFalse);
      expect(controller.nodes, same(oldRows));
    },
  );

  test(
    'late nodes retain the captured generation without becoming current',
    () async {
      final bridge = NodeBridge();
      final app = TestApp(bridge);
      final controller = NodesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
      expect(bridge.queries, hasLength(1));
      expect(controller.loading, isTrue);
      bridge.replies.first.complete(page());
      await Future<void>.delayed(Duration.zero);
      expect(controller.nodes, hasLength(50));
      expect(controller.data!['generation'], 1);
      expect(controller.current, isFalse);
      expect(controller.source!.generation, 1);
      expect(bridge.queries, hasLength(2));
      bridge.replies.last.complete(page(generation: 2));
      await Future<void>.delayed(Duration.zero);
      expect(controller.current, isTrue);
      expect(controller.data!['generation'], 2);
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets('nodes $language keeps paging controls stable and search raw', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = NodeBridge();
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
          home: NodesPage(app: app),
        ),
      );
      final strings = lookupAppLocalizations(Locale(language));
      expect(find.textContaining(strings.coreReadLoading), findsNothing);
      final previous = find.widgetWithIcon(IconButton, Icons.chevron_left);
      final rect = tester.getRect(previous);
      final search = find.byType(TextField);
      final searchRect = tester.getRect(search);
      final searchState = tester.state(search);
      final searchController = tester.widget<TextField>(search).controller;
      expect(find.byKey(const ValueKey('node-status-slot')), findsNothing);
      void headerUnchanged() {
        expect(tester.getRect(search), searchRect);
        expect(tester.state(search), same(searchState));
        expect(
          tester.widget<TextField>(search).controller,
          same(searchController),
        );
      }

      bridge.replies.single.complete({
        ...response(core(1)),
        'readPending': true,
      });
      await tester.pump();
      expect(tester.getRect(previous), rect);
      headerUnchanged();
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.getRect(previous), rect);
      headerUnchanged();
      bridge.replies.last.complete(page());
      await tester.pumpAndSettle();
      expect(find.textContaining(strings.runtimeConfigLive), findsNothing);
      expect(tester.getRect(previous), rect);
      headerUnchanged();
      final first = find.widgetWithText(ListTile, 'node-0');
      expect(first, findsOneWidget);
      expect(first.hitTestable(), findsOneWidget);
      final rowRect = tester.getRect(first);
      await tester.enterText(find.byType(TextField), '  provider  ');
      await tester.pump(const Duration(milliseconds: 250));
      expect(bridge.queries.last['search'], '  provider  ');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '  provider  ',
      );
      expect(tester.getRect(previous), rect);
      headerUnchanged();
      expect(tester.getRect(first), rowRect);
      bridge.replies.last.completeError(StateError('fixture error'));
      await tester.pump();
      expect(tester.getRect(previous), rect);
      headerUnchanged();
      expect(tester.getRect(first), rowRect);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  group('read passthrough', () {
    testWidgets(
      'node UI grace keeps the real slot and the latest query intent',
      (tester) async {
        final bridge = NodeBridge();
        final app = TestApp(bridge);
        final controller = NodesController(app)..setVisible(true);
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
        final first = page();
        bridge.replies.first.complete(first);
        await tester.pump();
        expect(controller.data, first);
        expect(controller.dataQuery!['search'], '');
        expect(controller.current, isFalse);
        expect(controller.loading, isTrue);
        expect(bridge.queries, hasLength(2));
        expect(bridge.queries.last['search'], '  latest  ');
        final last = page();
        bridge.replies.last.complete(last);
        await tester.pump();
        expect(controller.data, last);
        expect(controller.dataQuery!['search'], '  latest  ');
        expect(controller.current, isTrue);
        expect(controller.loading, isFalse);
        expect(controller.readError, isNull);
      },
    );

    testWidgets(
      'node feedback and raw copy keep unknown fields and original errors',
      (tester) async {
        final bridge = NodeBridge();
        final app = TestApp(bridge);
        final taskRoutes = AppTaskNavigatorObserver();
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            navigatorObservers: [taskRoutes],
            home: NodesPage(app: app),
          ),
        );
        final value = page();
        value['unknown-envelope'] = {'original': '${'x' * 20000}tail'};
        final row = ((value['page'] as Map)['nodes'] as List).first as Map;
        row['sourceKind'] = 'future-source';
        row['future-values'] = [false, 0, null, <Object?>[]];
        row['provenance'] = {
          'contributors': [
            {'kind': 'future-kind'},
          ],
        };
        bridge.replies.single.complete(value);
        await tester.pump();
        expect(find.text('node-0'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Icons.data_object));
        await tester.pumpAndSettle();
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await tester.tap(find.byKey(const ValueKey('original-text-copy')));
        await tester.pump();
        expect(copied, const JsonEncoder.withIndent('  ').convert(value));
        expect(row['provenance'], isA<Map>());
        await tester.pageBack();
        await tester.pump();
        if (!bridge.replies.last.isCompleted) {
          bridge.replies.last.complete(value);
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pump();
        bridge.replies.last.completeError(
          PlatformFailure(
            code: 'native',
            message: 'original-node-bridge-cause',
            details: messages.androidErrorNativeReadUnavailable
                .withDetail('original-node-native-cause: fixture-secret')
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
          find.textContaining('original-node-native-cause: fixture-secret'),
          findsOneWidget,
        );
        expect(
          find.textContaining('original-node-bridge-cause'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
