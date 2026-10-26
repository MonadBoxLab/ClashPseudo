import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/features/diagnostics/resources_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/resources_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_fakes.dart' show TestApp, core;

class ResourceBridge extends AppBridge {
  final requests = <CoreSnapshot>[];
  final replies = <Completer<Map<String, dynamic>>>[];
  final updates = <Map<String, Object?>>[];
  final updateReplies = <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> resources(CoreSnapshot core) {
    requests.add(core);
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }

  @override
  Future<Map<String, dynamic>> updateResource(
    CoreSnapshot core, {
    required String kind,
    required String name,
  }) => throw StateError('UI must submit resource writes to the engine');
}

class ResourceApp extends TestApp {
  ResourceApp(ResourceBridge super.platform);

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(command);
    final id = 'operation-${commands.length}';
    if (command['action'] == 'updateResource') {
      final bridge = platform as ResourceBridge;
      bridge.updates.add(command);
      final reply = Completer<Map<String, dynamic>>();
      bridge.updateReplies.add(reply);
      unawaited(
        reply.future.then((value) {
          final update = value['update'] as Map;
          publish(
            AppSnapshot(
              phase: state.phase,
              core: state.core,
              resultId: id,
              resultSuccess: update['status'] == 'ok',
              resourceStatus: update['error'] as String? ?? 'ok',
            ),
          );
        }),
      );
    }
    return id;
  }
}

Map<String, dynamic> resourcePage(
  CoreSnapshot source, {
  List<Map<String, dynamic>>? rows,
}) => {
  'generation': source.generation,
  'configId': source.configId,
  'revision': source.revision,
  'composition': source.composition,
  'purpose': source.purpose,
  'resources':
      rows ??
      [
        {
          'kind': 'proxyProvider',
          'name': 'remote',
          'vehicleType': 'HTTP',
          'source': 'https://example.test/…',
          'count': 3,
          'updatedAt': '2026-10-18T08:00:00Z',
          'updateSupported': true,
        },
        {
          'kind': 'ruleProvider',
          'name': 'inline',
          'vehicleType': 'Inline',
          'source': '',
          'count': 1,
          'behavior': 'Domain',
          'updateSupported': false,
        },
      ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in ['proxyProvider', 'ruleProvider']) {
    testWidgets(
      '$kind properties explain missing original options and keep raw secrets unavailable',
      (tester) async {
        final bridge = ResourceBridge();
        final app = ResourceApp(bridge);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ResourcesPage(app: app),
          ),
        );
        bridge.replies.single.complete(
          resourcePage(
            core(1),
            rows: [
              {
                'kind': kind,
                'name': 'loaded-provider',
                'vehicleType': 'HTTP',
                'source': 'https://example.test/…',
                'count': 3,
                'updateSupported': true,
                if (kind == 'ruleProvider') ...{
                  'behavior': 'Domain',
                  'format': 'yaml',
                },
              },
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'loaded-provider'));
        await tester.pumpAndSettle();
        final details = find.byType(Scaffold).last;
        final strings = AppLocalizations.of(tester.element(details));
        expect(
          find.text(strings.providerRuntimePropertiesOnly),
          findsOneWidget,
        );
        expect(
          find.descendant(of: details, matching: find.byType(TextField)),
          findsNothing,
        );
        expect(find.text(strings.save), findsNothing);
        if (kind == 'ruleProvider') {
          expect(find.text('format: yaml'), findsOneWidget);
        }
        app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
        bridge.replies.last.complete(resourcePage(core(2)));
        await tester.pumpAndSettle();
        expect(find.text(strings.coreSnapshotStale), findsWidgets);
        final members = find.widgetWithText(
          TextButton,
          kind == 'proxyProvider' ? strings.proxyNodes : strings.ruleSets,
        );
        expect(tester.widget<TextButton>(members).onPressed, isNull);
        expect(app.commands, isEmpty);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test('locale changes do not replace a pending resource read', () async {
    setMessageLanguage(AppLanguage.en);
    addTearDown(() => setMessageLanguage(AppLanguage.system));
    final bridge = ResourceBridge();
    final app = ResourceApp(bridge)
      ..commandErrorMessage = messages.requestNotAccepted;
    app.state = AppSnapshot(
      phase: 'RUNNING',
      core: core(1, error: messages.androidErrorBusy),
    );
    final controller = ResourcesController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    final retained = app.state;
    expect(bridge.requests, hasLength(1));
    setMessageLanguage(AppLanguage.zh);
    app.publish(retained);
    expect(bridge.requests, hasLength(1));
    expect(controller.loading, isTrue);
    expect(app.state, same(retained));
    bridge.replies.single.complete(resourcePage(core(1)));
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, ResourcesStatus.live);
    expect(controller.resources, hasLength(2));
    expect(app.commands, isEmpty);
  });

  test(
    'old rows retain their source and cannot update a replacement core',
    () async {
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
      final controller = ResourcesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(resourcePage(core(1)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.current, isTrue);
      expect(controller.source!.generation, 1);
      app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
      expect(controller.current, isFalse);
      await controller.update('proxyProvider', 'remote');
      expect(bridge.updates, isEmpty);
      bridge.replies.last.completeError(StateError('read failed'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.resources, hasLength(2));
      expect(controller.source!.generation, 1);
      expect(controller.status, ResourcesStatus.failed);
      expect(controller.current, isFalse);
      await controller.update('proxyProvider', 'remote');
      expect(bridge.updates, isEmpty);
    },
  );

  test('accepted update survives leaving page and old results do not label new rows', () async {
    final bridge = ResourceBridge();
    final app = ResourceApp(bridge);
    final controller = ResourcesController(app)..setVisible(true);
    addTearDown(app.dispose);
    bridge.replies.single.complete(resourcePage(core(1)));
    await Future<void>.delayed(Duration.zero);
    final pending = controller.update('proxyProvider', 'remote');
    expect(bridge.updates.single, {
      'action': 'updateResource',
      'generation': 1,
      'composition': core(1).composition,
      'configId': 'main',
      'revision': 1,
      'purpose': 'VPN',
      'kind': 'proxyProvider',
      'name': 'remote',
    });
    app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
    bridge.replies.last.complete(resourcePage(core(2)));
    await Future<void>.delayed(Duration.zero);
    bridge.updateReplies.single.complete({
      'update': {'error': 'stopped'},
    });
    await pending;
    expect(controller.updateError('proxyProvider', 'remote'), isNull);
    expect(controller.resultCode, isNull);
    controller.dispose();
    expect(bridge.updates, hasLength(1));
  });

  test(
    'disposing resource page does not cancel accepted engine work',
    () async {
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
      final controller = ResourcesController(app)..setVisible(true);
      addTearDown(app.dispose);
      bridge.replies.single.complete(resourcePage(core(1)));
      await Future<void>.delayed(Duration.zero);
      var done = false;
      final pending = controller
          .update('proxyProvider', 'remote')
          .then((_) => done = true);
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      expect(app.commands.single['action'], 'updateResource');
      bridge.updateReplies.single.complete({
        'update': {'status': 'ok'},
      });
      await pending;
      expect(done, isTrue);
      expect(app.commands, hasLength(1));
    },
  );

  test(
    'failed reread keeps prior source but disables same-context writes',
    () async {
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
      final controller = ResourcesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(resourcePage(core(1)));
      await Future<void>.delayed(Duration.zero);
      final pending = controller.update('proxyProvider', 'remote');
      bridge.updateReplies.single.complete({
        'update': {'status': 'ok'},
      });
      await pending;
      bridge.replies.last.completeError(StateError('failed actual reread'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.resources.first['count'], 3);
      expect(controller.source!.generation, 1);
      expect(controller.current, isFalse);
      expect(controller.status, ResourcesStatus.failed);
      await controller.update('proxyProvider', 'remote');
      expect(bridge.updates, hasLength(1));
    },
  );

  test(
    'manual update is accepted once and a failure keeps prior rows',
    () async {
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
      final controller = ResourcesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(resourcePage(core(1)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, ResourcesStatus.live);
      expect(controller.resources, hasLength(2));

      final pending = controller.update('proxyProvider', 'remote');
      expect(controller.isUpdating('proxyProvider', 'remote'), isTrue);
      // Retain the single native write through a repeated tap.
      await controller.update('proxyProvider', 'remote');
      expect(bridge.updates, hasLength(1));

      bridge.updateReplies.single.complete({
        'update': {'error': 'updateFailed'},
      });
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(controller.updateError('proxyProvider', 'remote'), 'updateFailed');
      expect(controller.resources, hasLength(2));
      expect(controller.resources.first['count'], 3);
      expect(controller.isUpdating('proxyProvider', 'remote'), isFalse);
      // A re-read was requested after the failure to show core-reported values.
      expect(bridge.requests, hasLength(2));
      bridge.replies.last.complete(resourcePage(core(1)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.resources.first['count'], 3);
    },
  );

  test(
    'successful update re-reads the core and drops stale row errors',
    () async {
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
      final controller = ResourcesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(resourcePage(core(1)));
      await Future<void>.delayed(Duration.zero);
      final pending = controller.update('proxyProvider', 'remote');
      bridge.updateReplies.single.complete({
        'update': {'status': 'ok'},
      });
      await pending;
      bridge.replies.last.complete(
        resourcePage(
          core(1),
          rows: [
            {
              'kind': 'proxyProvider',
              'name': 'remote',
              'vehicleType': 'HTTP',
              'source': 'https://example.test/…',
              'count': 9,
              'updateSupported': true,
            },
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.resources.single['count'], 9);
      expect(controller.updateError('proxyProvider', 'remote'), isNull);
    },
  );

  test(
    'unsupported resources and closed contexts never issue updates',
    () async {
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
      final controller = ResourcesController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(resourcePage(core(1)));
      await Future<void>.delayed(Duration.zero);
      await controller.update('ruleProvider', 'inline');
      await controller.update('proxyProvider', 'missing');
      expect(bridge.updates, isEmpty);
      controller.setVisible(false);
      await controller.update('proxyProvider', 'remote');
      expect(bridge.updates, isEmpty);
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets(
      'resource sizes use binary units instead of raw bytes $language',
      (tester) async {
        final bridge = ResourceBridge();
        final app = ResourceApp(bridge);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ResourcesPage(app: app),
          ),
        );
        bridge.replies.single.complete(
          resourcePage(
            core(1),
            rows: [
              {
                'kind': 'geo',
                'name': 'MMDB',
                'vehicleType': 'File',
                'source': '',
                'bytes': 8348509,
                'updateSupported': false,
              },
            ],
          ),
        );
        await tester.pump();
        expect(find.textContaining('7.96 MiB'), findsOneWidget);
        expect(find.textContaining('8348509'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets('resources $language keep search and update controls stable', (
      tester,
    ) async {
      // Use narrow width and large text with a tall viewport so rows remain built for
      // geometry checks.
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
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
          home: ResourcesPage(app: app),
        ),
      );
      final strings = lookupAppLocalizations(Locale(language));
      expect(find.textContaining(strings.coreReadLoading), findsOneWidget);
      final search = find.byType(TextField);
      final rect = tester.getRect(search);
      bridge.replies.single.complete(resourcePage(core(1)));
      await tester.pump();
      expect(tester.getRect(search), rect);
      expect(find.text('remote'), findsOneWidget);
      final rows = find.descendant(
        of: find.byType(SliverList),
        matching: find.byType(ListTile),
      );
      final separators = find.descendant(
        of: find.byType(SliverList),
        matching: find.byType(Divider),
      );
      expect(rows, findsNWidgets(2));
      expect(
        tester
            .widgetList<ListTile>(rows)
            .map((row) => (row.title! as Text).data),
        ['remote', 'inline'],
      );
      expect(separators, findsOneWidget);
      final divider = tester.widget<Divider>(separators);
      expect(divider.height, 1);
      expect(divider.indent, 16);
      expect(divider.endIndent, 16);
      for (final row in tester.widgetList<ListTile>(rows)) {
        expect(
          row.contentPadding,
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        );
      }
      final rowRects = [tester.getRect(rows.at(0)), tester.getRect(rows.at(1))];
      final dividerRect = tester.getRect(separators);
      expect(dividerRect.top, rowRects.first.bottom);
      expect(dividerRect.bottom, rowRects.last.top);
      await tester.enterText(search, 'inline');
      await tester.pump();
      expect(find.text('remote'), findsNothing);
      expect(separators, findsNothing);
      expect(tester.getRect(search), rect);
      await tester.enterText(search, '');
      await tester.pump();
      expect(find.text('remote'), findsOneWidget);
      expect(separators, findsOneWidget);
      void checkRows() {
        expect(tester.getRect(rows.at(0)), rowRects.first);
        expect(tester.getRect(rows.at(1)), rowRects.last);
        expect(tester.getRect(separators), dividerRect);
        expect(tester.getRect(search), rect);
        expect(tester.takeException(), isNull);
      }

      checkRows();

      // The first row is the proxy provider; its label changes while updating,
      // so anchor geometry on the widget rather than on the label text.
      final button = find.byType(TextButton).first;
      final buttonRect = tester.getRect(button);
      await tester.tap(button);
      await tester.pump();
      expect(tester.getRect(button), buttonRect);
      checkRows();
      bridge.updateReplies.single.complete({
        'update': {'error': 'updateFailed'},
      });
      for (final milliseconds in [0, 16, 100, 200]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(tester.getRect(button), buttonRect);
        checkRows();
      }
      bridge.replies.last.complete(resourcePage(core(1)));
      await tester.pump();
      expect(tester.getRect(button), buttonRect);
      checkRows();

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
