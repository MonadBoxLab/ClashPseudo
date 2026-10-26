import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/diagnostics/runtime_config_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/runtime_config_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'locale changes do not replace a pending runtime configuration read',
    () async {
      setMessageLanguage(AppLanguage.en);
      addTearDown(() => setMessageLanguage(AppLanguage.system));
      final bridge = TestBridge();
      final app = TestApp(bridge)
        ..commandErrorMessage = messages.requestNotAccepted;
      app.state = AppSnapshot(
        phase: 'RUNNING',
        core: core(1, error: messages.androidErrorBusy),
      );
      final controller = RuntimeConfigController(app)..setVisible(true);
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
      bridge.replies.single.complete(response(core(1)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.live);
      expect(controller.hasCurrentSource, isTrue);
      expect(app.commands, isEmpty);
    },
  );

  test(
    'late results cannot cross generation or foreground boundaries',
    () async {
      final bridge = TestBridge();
      final app = TestApp(bridge);
      final controller = RuntimeConfigController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      expect(bridge.requests, hasLength(1));
      app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
      bridge.replies[0].complete(response(core(1)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.lines, isEmpty);
      bridge.replies[1].complete(response(core(2)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.live);
      expect(controller.hasCurrentSource, isTrue);
      await controller.refresh();
      app.setForeground(false);
      bridge.replies[2].complete(response(core(2)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.stale);
    },
  );

  test(
    'preview preparation is on demand, once, and never starts VPN',
    () async {
      final bridge = TestBridge();
      final app = TestApp(bridge)..state = const AppSnapshot(phase: 'STOPPED');
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
      final controller = RuntimeConfigController(app);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      expect(app.commands, isEmpty);
      controller.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      expect(app.commands.single['action'], 'prepareStrategies');
      app.publish(const AppSnapshot(phase: 'STOPPED'));
      expect(app.commands, hasLength(1));
      app.publish(
        AppSnapshot(
          phase: 'STOPPED',
          core: core(1, purpose: 'PREVIEW'),
        ),
      );
      bridge.replies.single.complete(response(core(1, purpose: 'PREVIEW')));
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.preview);
    },
  );

  test('wrong composition and query errors retain only an explicitly stale snapshot', () async {
    final bridge = TestBridge();
    final app = TestApp(bridge);
    final controller = RuntimeConfigController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    bridge.replies.single.complete(response(core(1)));
    await Future<void>.delayed(Duration.zero);
    final previous = controller.lines;
    await controller.refresh();
    bridge.replies.last.complete({
      ...response(core(1)),
      'composition': 'wrong',
    });
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, RuntimeConfigStatus.failed);
    expect(controller.lines, previous);
    await controller.refresh();
    bridge.replies.last.completeError(StateError('unavailable'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.status, RuntimeConfigStatus.failed);
  });

  for (final language in ['zh', 'en']) {
    testWidgets(
      'runtime page $language preserves controls through refresh, failure and search',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = TestBridge();
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
            home: RuntimeConfigPage(app: app),
          ),
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(RuntimeConfigPage)),
        );
        expect(find.text(strings.runtimeConfigLoading), findsOneWidget);
        expect(find.byIcon(Icons.info_outline), findsNothing);
        final searchRect = tester.getRect(find.byType(TextField));
        bridge.replies.single.complete(response(core(1)));
        await tester.pump();
        expect(tester.getRect(find.byType(TextField)), searchRect);
        await tester.enterText(find.byType(TextField), 'authentication');
        await tester.pump();
        expect(find.textContaining('authentication'), findsWidgets);
        expect(find.textContaining('mixed-port'), findsNothing);
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pump();
        expect(tester.getRect(find.byType(TextField)), searchRect);
        bridge.replies.last.completeError(StateError('fixture failure'));
        await tester.pump();
        expect(tester.getRect(find.byType(TextField)), searchRect);
        final failureText = find.text(strings.runtimeConfigFailed);
        expect(failureText, findsOneWidget);
        expect(
          tester.widget<Text>(failureText).style!.color,
          Theme.of(tester.element(failureText)).colorScheme.error,
        );
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byType(TextField));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
