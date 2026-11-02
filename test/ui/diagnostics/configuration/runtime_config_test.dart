import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/diagnostics/configuration/runtime_config_controller.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/diagnostics/configuration/runtime_config_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    'late runtime results retain their source and the real read slot',
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
      expect(bridge.requests, hasLength(1));
      expect(controller.loading, isTrue);
      bridge.replies[0].complete(response(core(1)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.lines, isNotEmpty);
      expect(controller.data!['generation'], 1);
      expect(controller.status, RuntimeConfigStatus.stale);
      expect(controller.hasCurrentSource, isFalse);
      expect(controller.loading, isTrue);
      expect(bridge.requests, hasLength(2));
      bridge.replies[1].complete(response(core(2)));
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.live);
      expect(controller.hasCurrentSource, isTrue);
      await controller.refresh();
      app.setForeground(false);
      final late = {
        ...response(core(2)),
        'configuration': {'late-original': 'fixture-secret'},
      };
      bridge.replies[2].complete(late);
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.stale);
      expect(controller.loading, isFalse);
      expect(controller.data, late);
      expect(controller.lines.join('\n'), contains('fixture-secret'));
      expect(controller.hasCurrentSource, isFalse);
      expect(bridge.requests, hasLength(3));
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

  test(
    'mismatched identities retain data without authorizing it as current',
    () async {
      final bridge = TestBridge();
      final app = TestApp(bridge);
      final controller = RuntimeConfigController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      bridge.replies.single.complete(response(core(1)));
      await Future<void>.delayed(Duration.zero);
      await controller.refresh();
      final mismatched = {
        ...response(core(1)),
        'composition': 'wrong',
        'configuration': {
          'future-field': [false, 0, null],
        },
      };
      bridge.replies.last.complete(mismatched);
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.stale);
      expect(controller.hasCurrentSource, isFalse);
      expect(controller.data, mismatched);
      expect(controller.readError, isNull);
      final previous = controller.lines;
      await controller.refresh();
      bridge.replies.last.completeError(
        PlatformFailure(
          code: 'native',
          message: 'original bridge error',
          details: messages.androidErrorNativeReadUnavailable
              .withDetail('original native error: fixture-token')
              .toMap(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, RuntimeConfigStatus.failed);
      expect(controller.lines, previous);
      expect(controller.data, mismatched);
      expect(
        controller.readError!.detail,
        contains('original native error: fixture-token'),
      );
      expect(controller.readError!.detail, contains('original bridge error'));
      expect(controller.hasCurrentSource, isFalse);
    },
  );

  testWidgets('runtime UI grace does not finish or overlap the actual read', (
    tester,
  ) async {
    final bridge = TestBridge();
    final app = TestApp(bridge);
    final controller = RuntimeConfigController(app)..setVisible(true);
    addTearDown(() {
      controller.dispose();
      app.dispose();
    });
    await tester.pump(const Duration(seconds: 6));
    expect(controller.loading, isTrue);
    expect(controller.canRefresh, isFalse);
    expect(controller.status, RuntimeConfigStatus.stale);
    await controller.refresh();
    expect(bridge.requests, hasLength(1));
    bridge.replies.single.complete(response(core(1)));
    await tester.pump();
    expect(controller.loading, isFalse);
    expect(controller.status, RuntimeConfigStatus.live);
    expect(controller.hasCurrentSource, isTrue);
    expect(controller.readError, isNull);
  });

  testWidgets('runtime original-data view copies the complete envelope', (
    tester,
  ) async {
    final bridge = TestBridge();
    final app = TestApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OperationNoticeHost(child: RuntimeConfigPage(app: app)),
      ),
    );
    final value = {
      ...response(core(1)),
      'configuration': {
        'authentication': ['fixture-user:fixture-password'],
        'future-empty': <Object?>[],
      },
      'unknown-envelope': {'original': '${'x' * 20000}tail'},
    };
    bridge.replies.single.complete(value);
    await tester.pump();
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
    expect(copied, contains('fixture-user:fixture-password'));
    expect(copied, contains('tail'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final recovered in [false, true]) {
    testWidgets('菜单详情仅在错误仍有效时打开，错误已恢复：$recovered', (tester) async {
      final bridge = TestBridge();
      final app = TestApp(bridge)
        ..commandErrorMessage = messages.requestNotAccepted;
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          navigatorObservers: [AppTaskNavigatorObserver()],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OperationNoticeHost(child: RuntimeConfigPage(app: app)),
        ),
      );
      bridge.replies.single.complete(response(core(1)));
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(RuntimeConfigPage)),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.widgetWithIcon(IconButton, Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(strings.moreActions));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(strings.errorDetails), findsOneWidget);
      if (recovered) {
        app.commandErrorMessage = null;
        app.publish(app.state);
        await tester.pump();
      }
      await tester.tap(find.text(strings.errorDetails));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(AlertDialog),
        recovered ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('读取失败按来源和连续周期反馈，旧操作不能影响新提示', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = TestBridge();
    final app = TestApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OperationNoticeHost(child: RuntimeConfigPage(app: app)),
      ),
    );
    final strings = AppLocalizations.of(
      tester.element(find.byType(RuntimeConfigPage)),
    );
    final search = tester.widget<TextField>(find.byType(TextField));
    bridge.replies.single.complete(response(core(1)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'mode');
    await tester.pump();
    search.controller!.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 3,
    );
    final anchor = tester.getRect(find.byType(TextField));
    final selection = search.controller!.selection;
    final line = find.text('  "mode": "rule",');
    final lineRect = tester.getRect(line);
    Future<void> refresh() async {
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.refresh));
      await tester.pump();
    }

    Finder noticeButton(String label) => find.descendant(
      of: find.byType(SnackBar),
      matching: find.widgetWithText(TextButton, label),
    );
    Finder closeNotice() => find.descendant(
      of: find.byType(SnackBar),
      matching: find.widgetWithIcon(IconButton, Icons.close),
    );
    await refresh();
    bridge.replies.last.completeError(StateError('first-original'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.getRect(find.byType(TextField)), anchor);
    expect(tester.getRect(line), lineRect);
    expect(search.controller!.selection, selection);
    final oldRetry = tester
        .widget<TextButton>(noticeButton(strings.retry))
        .onPressed!;
    final oldDetails = tester
        .widget<TextButton>(noticeButton(strings.errorDetails))
        .onPressed!;
    final oldClose = tester.widget<IconButton>(closeNotice()).onPressed!;
    await tester.tap(closeNotice());
    await tester.pumpAndSettle();
    await refresh();
    bridge.replies.last.completeError(StateError('same-cycle-original'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.getRect(line), lineRect);
    await refresh();
    bridge.replies.last.complete(response(core(1)));
    await tester.pumpAndSettle();
    await refresh();
    bridge.replies.last.completeError(StateError('next-cycle-original'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    final requests = bridge.requests.length;
    oldRetry();
    oldDetails();
    oldClose();
    await tester.pumpAndSettle();
    expect(bridge.requests, hasLength(requests));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(noticeButton(strings.errorDetails));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
    await tester.pumpAndSettle();
    expect(find.textContaining('next-cycle-original'), findsWidgets);
    expect(find.textContaining('first-original'), findsNothing);
    app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    bridge.replies.last.completeError(StateError('new-source-original'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.getRect(find.byType(TextField)), anchor);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller,
      same(search.controller),
    );
    expect(search.controller!.text, 'mode');
    expect(search.controller!.selection, selection);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旧来源失败在真实读取结束后不成为新来源的提示', (tester) async {
    final bridge = TestBridge();
    final app = TestApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: OperationNoticeHost(child: RuntimeConfigPage(app: app)),
      ),
    );
    app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
    bridge.replies.first.completeError(StateError('retired-source-original'));
    await tester.pump();
    expect(bridge.requests, hasLength(2));
    expect(find.byType(SnackBar), findsNothing);
    bridge.replies.last.complete(response(core(2)));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('retired-source-original'), findsNothing);
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
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
            home: OperationNoticeHost(child: RuntimeConfigPage(app: app)),
          ),
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(RuntimeConfigPage)),
        );
        expect(
          find.byKey(const ValueKey('runtime-refresh-pending')),
          findsOneWidget,
        );
        expect(find.text(strings.runtimeConfigLoading), findsNothing);
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
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.refresh));
        await tester.pump();
        expect(tester.getRect(find.byType(TextField)), searchRect);
        bridge.replies.last.completeError(StateError('fixture failure'));
        await tester.pump();
        expect(tester.getRect(find.byType(TextField)), searchRect);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.byKey(const ValueKey('runtime-read-error-motion')),
          findsNothing,
        );
        expect(tester.getRect(find.byType(TextField)), searchRect);
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
