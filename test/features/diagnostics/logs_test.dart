import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/diagnostics/logs_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/logs_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_fakes.dart' show core;

import 'log_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'closed log source decoding and bridge query preserve the actual window',
    (tester) async {
      final snapshot = AppSnapshot.fromMap({
        'phase': 'STOPPED',
        'configId': 'new selection',
        'revision': 9,
        'core': {'generation': 8, 'phase': 'EMPTY'},
        'logSource': {
          'generation': 7,
          'phase': 'EMPTY',
          'purpose': 'VPN',
          'configId': 'actual session',
          'revision': 2,
          'composition': 'actual composition',
          'logWindow': 'native-window',
        },
      });
      final source = snapshot.logSource!;
      expect(source.ready, isFalse);
      expect(source.configId, 'actual session');
      expect(source.revision, 2);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
        expect(call.method, 'logs');
        expect(call.arguments, {
          'generation': 7,
          'composition': 'actual composition',
          'query': {'after': 4, 'limit': 200, 'window': 'native-window'},
        });
        return jsonEncode(logResponse(source, next: 4));
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppBridge.channel, null),
      );
      final response = await AppBridge().logs(source, {
        'after': 4,
        'limit': 200,
      });
      expect((response['logs'] as Map)['window'], 'native-window');
    },
  );

  testWidgets('only an absent log window prepares one on-demand preview', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge)..state = const AppSnapshot(phase: 'STOPPED');
    app.collection = ConfigCollection(
      entries: const [
        ConfigEntry(
          id: 'main',
          name: 'Fixture',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
      ],
      selectedId: 'main',
    );
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    expect(app.commands.single['action'], 'prepareStrategies');
    app.publish(app.state);
    expect(app.commands, hasLength(1));
    final source = logSource(core(2, purpose: 'PREVIEW'));
    app.publish(
      AppSnapshot(
        phase: 'STOPPED',
        core: core(2, purpose: 'PREVIEW'),
        logSource: source,
      ),
    );
    bridge.replies.single.complete(
      logResponse(source, entries: [entry(1, 'info', 'preview log')], next: 1),
    );
    await tester.pump();
    expect(controller.status, CoreLogsStatus.preview);
    expect(app.commands, hasLength(1));
    controller.setVisible(false);
  });

  for (final failed in [false, true]) {
    testWidgets(
      'first open reads ${failed ? 'failed' : 'stopped'} recent window without preparing preview',
      (tester) async {
        final bridge = LogBridge();
        final source = logSource(core(7), recent: true);
        final app = logApp(bridge)
          ..state = AppSnapshot(
            phase: 'STOPPED',
            core: CoreSnapshot(
              generation: 9,
              error: failed ? messages.androidErrorBusy : null,
            ),
            logSource: source,
          );
        app.collection = ConfigCollection(
          entries: const [
            ConfigEntry(
              id: 'selected',
              name: 'Different selection',
              kind: ConfigKind.local,
              revision: 4,
              body: '{}',
            ),
          ],
          selectedId: 'selected',
        );
        final controller = CoreLogsController(app)..setVisible(true);
        addTearDown(() {
          controller.dispose();
          app.dispose();
        });
        expect(app.commands, isEmpty);
        expect(bridge.requests, hasLength(1));
        bridge.replies.single.complete(
          logResponse(
            source,
            entries: [entry(1, 'error', 'stopped or failed session tail')],
            total: 1,
            next: 1,
          ),
        );
        await tester.pump();
        expect(
          controller.entries.single['text'],
          'stopped or failed session tail',
        );
        expect(controller.status.name, 'recent');
        await controller.refresh();
        expect(app.commands, isEmpty);
        expect(bridge.requests, hasLength(2));
        bridge.replies.last.complete(logResponse(source));
        await tester.pump();
        controller.setVisible(false);
      },
    );
  }

  testWidgets(
    'actual window replacement rejects late logs even with the same core identity',
    (tester) async {
      final bridge = LogBridge();
      final app = logApp(bridge);
      final controller = CoreLogsController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      final replacement = logSource(core(1), window: 'replacement');
      app.publish(
        AppSnapshot(phase: 'RUNNING', core: core(1), logSource: replacement),
      );
      bridge.replies.first.complete(
        logResponse(
          core(1),
          entries: [entry(1, 'info', 'old window')],
          next: 1,
        ),
      );
      await tester.pump();
      expect(controller.entries, isEmpty);
      expect(bridge.replies, hasLength(2));
      bridge.replies.last.complete(
        logResponse(
          replacement,
          entries: [entry(1, 'info', 'real replacement')],
          next: 1,
        ),
      );
      await tester.pump();
      expect(controller.entries.single['text'], 'real replacement');
      controller.setVisible(false);
    },
  );

  for (final bytes in [false, true]) {
    testWidgets(
      '${bytes ? 'byte' : 'count'} eviction keeps variable-height reading anchor on every frame',
      (tester) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = LogBridge();
        final app = logApp(bridge);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: CoreLogsPage(app: app),
          ),
        );
        final count = bytes ? 128 : 1000;
        String text(int seq) {
          final content = bytes
              ? 'variable height 日文 ' * (seq.isEven ? 340 : 350)
              : 'variable height row ' * (seq % 5 + 1);
          return 'reading-$seq $content';
        }

        // Deliver actual 200-row bridge pages. Both budgets are exercised in the
        // controller rather than removing rows from an artificial widget fixture.
        for (var start = 1; start <= count; start += 200) {
          final end = (start + 199).clamp(1, count);
          bridge.replies.last.complete(
            logResponse(
              core(1),
              entries: [
                for (var seq = start; seq <= end; seq++)
                  entry(seq, 'info', text(seq)),
              ],
              total: end,
              next: end,
            ),
          );
          await tester.pump();
          await tester.pump();
          if (end != count) {
            await tester.pump(const Duration(milliseconds: 610));
          }
        }
        final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
        final scroll = scrollbar.controller!;
        scroll.jumpTo(scroll.position.maxScrollExtent * .4);
        await tester.pump();
        await tester.pump();
        final controller = tester
            .widgetList<ListenableBuilder>(find.byType(ListenableBuilder))
            .map((widget) => widget.listenable)
            .whereType<CoreLogsController>()
            .single;
        expect(controller.follow, isFalse);
        final viewport = tester.getRect(find.byType(Scrollbar));
        final candidates = tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .where((widget) {
              final rect = tester.getRect(find.byWidget(widget));
              return rect.bottom > viewport.top && rect.top < viewport.bottom;
            })
            .toList();
        expect(candidates, isNotEmpty);
        final anchor = candidates.first.data!;
        final seq = int.parse(
          anchor.split(' ').first.substring('reading-'.length),
        );
        expect(
          seq,
          greaterThan(10),
          reason: 'the reader must survive head eviction',
        );
        final before = tester.getRect(
          find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == anchor,
          ),
        );
        final appended = bytes ? 12 : 25;
        for (var batch = 0; batch < 2; batch++) {
          await tester.pump(const Duration(milliseconds: 610));
          final start = count + batch * appended;
          bridge.replies.last.complete(
            logResponse(
              core(1),
              entries: [
                for (var seq = start + 1; seq <= start + appended; seq++)
                  entry(seq, 'info', text(seq)),
              ],
              total: count,
              dropped: (batch + 1) * appended,
              next: start + appended,
            ),
          );
          for (var frame = 0; frame < 3; frame++) {
            await tester.pump(
              frame == 2 ? const Duration(milliseconds: 16) : Duration.zero,
            );
            expect(
              tester.getRect(
                find.byWidgetPredicate(
                  (widget) => widget is SelectableText && widget.data == anchor,
                ),
              ),
              before,
              reason: 'eviction batch $batch delivery frame $frame',
            );
            expect(controller.follow, isFalse);
            expect(tester.takeException(), isNull);
          }
        }
        expect(controller.entries.first['seq'], greaterThan(1));
        controller.filter('no matching log fixture');
        await tester.pump();
        expect(find.byType(SelectableText), findsNothing);
        controller.filter('');
        await tester.pump();
        expect(
          scroll.offset,
          0,
          reason: 'filter reset must not revive a previous center',
        );
        controller.setFollow(true);
        await tester.pumpAndSettle();
        expect(controller.follow, isTrue);
        expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, .5));
        controller.clear();
        await tester.pump();
        expect(find.byType(SelectableText), findsNothing);
        app.setForeground(false);
        await tester.pumpWidget(const SizedBox());
        for (final reply in bridge.replies) {
          if (!reply.isCompleted) reply.complete(logResponse(core(1)));
        }
        await tester.pump();
        app.dispose();
      },
    );
  }

  testWidgets('locale changes do not replace a pending log read', (
    tester,
  ) async {
    setMessageLanguage(AppLanguage.en);
    addTearDown(() => setMessageLanguage(AppLanguage.system));
    final bridge = LogBridge();
    final app = logApp(bridge);
    app.state = AppSnapshot(
      phase: 'RUNNING',
      core: core(1, error: messages.androidErrorBusy),
      logSource: logSource(core(1)),
    );
    final controller = CoreLogsController(app)..setVisible(true);
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
    bridge.replies.single.complete(
      logResponse(core(1), entries: [entry(1, 'info', 'retained')], next: 1),
    );
    await tester.pump();
    expect(controller.status, CoreLogsStatus.live);
    expect(controller.entries.single['text'], 'retained');
    expect(app.commands, isEmpty);
    controller.setVisible(false);
  });

  testWidgets('pending logs drain before a resumed read and never wedge', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    app.setForeground(false);
    await tester.pump();
    app.setForeground(true);
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests, hasLength(1));
    bridge.replies.first.complete(
      logResponse(core(1), entries: [entry(1, 'info', 'old')], next: 1),
    );
    await tester.pump();
    expect(controller.entries, isEmpty);
    expect(bridge.requests, hasLength(2));
    bridge.replies.last.complete(
      logResponse(core(1), entries: [entry(2, 'info', 'fresh')], next: 2),
    );
    await tester.pump();
    expect(controller.loading, isFalse);
    expect(controller.entries.single['text'], 'fresh');
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests, hasLength(3));
    bridge.replies.last.complete(logResponse(core(1), next: 2));
    await tester.pump();
    controller.setVisible(false);
  });

  testWidgets('becoming ready starts ongoing log polling', (tester) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    app.publish(const AppSnapshot(phase: 'STOPPED'));
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    expect(bridge.requests, isEmpty);
    app.publish(
      AppSnapshot(
        phase: 'RUNNING',
        core: core(1),
        logSource: logSource(core(1)),
      ),
    );
    expect(bridge.requests, hasLength(1));
    bridge.replies.first.complete(logResponse(core(1)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests, hasLength(2));
    bridge.replies.last.complete(logResponse(core(1)));
    await tester.pump();
    controller.setVisible(false);
  });

  testWidgets('local log pages retain at most one MiB of UTF-8 text', (
    tester,
  ) async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    final text = '日' * 2700;
    for (var page = 0; page < 2; page++) {
      bridge.replies.last.complete(
        logResponse(
          core(1),
          entries: [
            for (var index = 1; index <= 100; index++)
              entry(page * 100 + index, 'info', text),
          ],
          total: 100,
          next: (page + 1) * 100,
        ),
      );
      await tester.pump();
      if (page == 0) {
        await tester.pump(const Duration(milliseconds: 700));
      }
    }
    expect(controller.entries.length, 129);
    expect(controller.entries.first['seq'], 72);
    expect(controller.entries.last['seq'], 200);
    controller.clear();
    await tester.pump(const Duration(milliseconds: 700));
    expect(bridge.requests.last['after'], 200);
    bridge.replies.last.complete(
      logResponse(core(1), entries: [entry(201, 'info', text)], next: 201),
    );
    await tester.pump();
    expect(controller.entries, hasLength(1));
    controller.setVisible(false);
  });

  test('log pages append by sequence and reject mismatched paging', () async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app, poll: const Duration(hours: 1))
      ..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    expect(bridge.requests.single, {'after': 0, 'limit': 200});
    bridge.replies.single.complete(
      logResponse(
        core(1),
        entries: [entry(1, 'info', 'started'), entry(2, 'error', 'failed')],
        total: 2,
        next: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.entries, hasLength(2));
    expect(controller.status, CoreLogsStatus.live);

    await controller.refresh();
    expect(bridge.requests.last, {'after': 0, 'limit': 200});
    bridge.replies.last.complete(
      logResponse(
        core(1),
        entries: [entry(1, 'info', 'x'), entry(3, 'warning', 'y')],
        total: 2,
        next: 5,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // next must equal the last entry's seq; a mismatch is a broken snapshot.
    expect(controller.status, CoreLogsStatus.failed);
  });

  test('level filtering and clear stay local', () async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app, poll: const Duration(hours: 1))
      ..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    bridge.replies.single.complete(
      logResponse(
        core(1),
        entries: [
          entry(1, 'debug', 'dns lookup'),
          entry(2, 'info', 'connected'),
          entry(3, 'error', 'timeout token=abc'),
        ],
        total: 3,
        next: 3,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    controller.setLevel('warning');
    expect(controller.visible.map((row) => row['seq']), [3]);
    controller.filter('timeout');
    expect(controller.visible, hasLength(1));
    controller.filter('connected');
    expect(controller.visible, isEmpty);
    controller.filter('');
    controller.setLevel('debug');
    controller.clear();
    expect(controller.entries, isEmpty);
    expect(controller.total, 0);
    expect(bridge.requests, hasLength(1));
  });

  test('a new core session resets the local window', () async {
    final bridge = LogBridge();
    final app = logApp(bridge);
    final controller = CoreLogsController(app, poll: const Duration(hours: 1))
      ..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    bridge.replies.single.complete(
      logResponse(
        core(1),
        entries: [entry(1, 'info', 'old')],
        total: 1,
        next: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    app.publish(
      AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 2,
          phase: 'READY',
          purpose: 'VPN',
          configId: 'main',
          revision: 1,
          composition: '["main",1,[99]]',
        ),
        logSource: CoreSnapshot(
          generation: 2,
          phase: 'READY',
          purpose: 'VPN',
          configId: 'main',
          revision: 1,
          composition: '["main",1,[99]]',
          logWindow: '2',
        ),
      ),
    );
    expect(controller.entries, isEmpty);
    expect(bridge.requests.last, {'after': 0, 'limit': 200});
  });

  for (final language in ['zh', 'en']) {
    testWidgets('logs $language keep controls stable with new entries', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = LogBridge();
      final app = logApp(bridge);
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
          home: CoreLogsPage(app: app),
        ),
      );
      final search = find.byType(TextField);
      final rect = tester.getRect(search);
      bridge.replies.single.complete(
        logResponse(
          core(1),
          entries: [entry(1, 'info', 'connected to proxy')],
          total: 1,
          next: 1,
        ),
      );
      await tester.pump();
      expect(tester.getRect(search), rect);
      expect(find.textContaining('connected to proxy'), findsOneWidget);

      await tester.enterText(search, 'missing');
      await tester.pump();
      expect(find.textContaining('connected to proxy'), findsNothing);
      expect(tester.getRect(search), rect);
      await tester.enterText(search, '');
      await tester.pump();

      // Wait for the next actual poll, then verify the warning entry and stable header
      // geometry.
      await tester.pump(const Duration(milliseconds: 700));
      expect(bridge.replies, hasLength(2));
      bridge.replies.last.complete(
        logResponse(
          core(1),
          entries: [
            entry(2, 'warning', 'retrying'),
            entry(3, 'error', 'password=[redacted]'),
          ],
          total: 3,
          next: 3,
        ),
      );
      await tester.pump();
      expect(tester.getRect(search), rect);
      expect(find.textContaining('retrying'), findsOneWidget);
      expect(
        find.textContaining('password=[redacted]', skipOffstage: false),
        findsOneWidget,
      );

      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });
  }
}
