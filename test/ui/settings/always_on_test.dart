import 'dart:async';

import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/settings/always_on_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'application_fakes.dart';

import 'package:clash_pseudo/src/ui/navigation/page_route.dart';

class _DeferredSettingsBridge extends AccessBridge {
  final openReply = Completer<void>();

  @override
  Future<void> openVpnSettings() {
    opened.add('settings');
    return openReply.future;
  }
}

void expectSystemStates(
  WidgetTester tester, {
  required String alwaysOn,
  required String lockdown,
}) {
  final strings = AppLocalizations.of(
    tester.element(find.byType(AlwaysOnPage)),
  );
  for (final entry in {
    strings.alwaysOnTitle: alwaysOn,
    strings.lockdownTitle: lockdown,
  }.entries) {
    final tile = find.widgetWithText(ListTile, entry.key);
    expect(
      find.descendant(of: tile, matching: find.text(entry.value)),
      findsOneWidget,
    );
    final subtitle = tester.widget<ListTile>(tile).subtitle! as Text;
    expect(subtitle.maxLines, 1);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cached settings callback loses task authority before a frame', (
    tester,
  ) async {
    final bridge = AccessBridge();
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    var active = true;
    await show(
      tester,
      AppTaskActivity(
        active: true,
        isActiveNow: () => active,
        child: AlwaysOnPage(app: app),
      ),
    );
    await tester.pumpAndSettle();
    final open = tester
        .widget<FilledButton>(find.byKey(const ValueKey('always-on-settings')))
        .onPressed!;
    expect(find.byIcon(Icons.refresh), findsNothing);
    final reads = bridge.statusCalls;
    active = false;
    open();
    app.publish(const AppSnapshot(phase: 'STOPPED', generation: 2));
    await tester.pumpAndSettle();
    expect(bridge.opened, isEmpty);
    expect(bridge.statusCalls, reads);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final staleBy in ['task', 'foreground', 'session', 'dispose']) {
    testWidgets('late settings error cannot create feedback after $staleBy', (
      tester,
    ) async {
      final bridge = _DeferredSettingsBridge();
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      var active = true;
      Widget page() => AppTaskActivity(
        active: active,
        isActiveNow: () => active,
        child: AlwaysOnPage(app: app),
      );
      await show(tester, page());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('always-on-settings')));
      await tester.pump();
      expect(bridge.opened, ['settings']);
      if (staleBy == 'task') {
        active = false;
        await show(tester, page());
        active = true;
        await show(tester, page());
      } else if (staleBy == 'foreground') {
        app.setForeground(false);
        app.setForeground(true);
      } else if (staleBy == 'session') {
        app.publish(const AppSnapshot(phase: 'STOPPED', generation: 2));
      } else {
        // Remove the real originating route, then settle its in-flight reply.
        await tester.pumpWidget(const SizedBox());
      }
      bridge.openReply.completeError(
        StateError('late settings cause\ncleanup: fixture'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.opened, ['settings']);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'a reply in the pop-before-frame gap cannot reopen settings feedback',
    (tester) async {
      final bridge = _DeferredSettingsBridge();
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                FocusedPageRoute(builder: (_) => AlwaysOnPage(app: app)),
              ),
              child: const Text('open always-on'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open always-on'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('always-on-settings')));
      await tester.pump();
      final origin = tester.element(find.byType(AlwaysOnPage));
      Navigator.of(origin).pop();
      bridge.openReply.completeError(StateError('reply before reverse frame'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(AlwaysOnPage), findsNothing);
      expect(bridge.opened, ['settings']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'settings feedback retains the original error and its owned popup closes',
    (tester) async {
      final bridge = AccessBridge()..openFails = true;
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(tester, AlwaysOnPage(app: app));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('always-on-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Bad state: settings failed'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      final pageStrings = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnPage)),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.widgetWithText(TextButton, pageStrings.errorDetails),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bad state: settings failed'), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      final strings = AppLocalizations.of(tester.element(dialog));
      await tester.tap(
        find.descendant(of: dialog, matching: find.text(strings.close)),
      );
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('an open VPN settings error follows the UI locale', (
    tester,
  ) async {
    final bridge = AccessBridge()..openFails = true;
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    Widget page() => AlwaysOnPage(app: app);
    await show(tester, page());
    await tester.pumpAndSettle();
    var strings = AppLocalizations.of(tester.element(find.byType(Scaffold)));
    await tester.tap(find.byKey(const ValueKey('always-on-settings')));
    await tester.pumpAndSettle();
    final notice = find.byType(SnackBar);
    expect(notice, findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.descendant(
        of: notice,
        matching: find.text(strings.alwaysOnOpenFailed),
      ),
      findsOneWidget,
    );
    await show(tester, page(), locale: const Locale('en'));
    await tester.pumpAndSettle();
    strings = AppLocalizations.of(tester.element(notice));
    expect(
      find.descendant(
        of: notice,
        matching: find.text(strings.alwaysOnOpenFailed),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'always-on status refreshes on foreground and retains known values on failure',
    (tester) async {
      final bridge = AccessBridge();
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(tester, AlwaysOnPage(app: app));
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnPage)),
      );
      expectSystemStates(
        tester,
        alwaysOn: strings.alwaysOnEnabled,
        lockdown: strings.lockdownDisabled,
      );
      final button = tester.getRect(
        find.byKey(const ValueKey('always-on-settings')),
      );
      bridge.statusFails = true;
      app.setForeground(false);
      app.setForeground(true);
      await tester.pumpAndSettle();
      expect(bridge.statusCalls, 2);
      expectSystemStates(
        tester,
        alwaysOn: strings.alwaysOnEnabled,
        lockdown: strings.lockdownDisabled,
      );
      expect(find.text(strings.vpnStatusReadFailed), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('always-on-settings'))),
        button,
      );
      bridge.statusFails = false;
      bridge.status = const {'alwaysOn': false, 'lockdown': true};
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(strings.retry),
        ),
      );
      await tester.pumpAndSettle();
      expectSystemStates(
        tester,
        alwaysOn: strings.alwaysOnDisabled,
        lockdown: strings.lockdownEnabled,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('always-on-settings'))),
        button,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late Always-on status cannot overwrite a resumed read', (
    tester,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    final bridge = AccessBridge()..statusReply = old;
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, AlwaysOnPage(app: app));
    await tester.pump();
    app.setForeground(false);
    bridge.statusReply = null;
    bridge.status = const {'alwaysOn': false, 'lockdown': false};
    app.setForeground(true);
    await tester.pump();
    expect(bridge.statusCalls, 1);
    old.complete({'alwaysOn': true, 'lockdown': true});
    await tester.pumpAndSettle();
    expect(bridge.statusCalls, 2);
    final strings = AppLocalizations.of(
      tester.element(find.byType(AlwaysOnPage)),
    );
    expectSystemStates(
      tester,
      alwaysOn: strings.alwaysOnDisabled,
      lockdown: strings.lockdownDisabled,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final locale in const [Locale('zh'), Locale('en')]) {
    for (final dark in const [false, true]) {
      testWidgets(
        'Always-on keeps intermediate geometry at large text locale=$locale dark=$dark',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final first = Completer<Map<String, dynamic>>();
          final bridge = AccessBridge()..statusReply = first;
          final app = AccessApp(bridge);
          addTearDown(app.dispose);
          await show(
            tester,
            MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: AlwaysOnPage(app: app),
            ),
            locale: locale,
            dark: dark,
          );
          await tester.pump();
          await tester.scrollUntilVisible(
            find.byIcon(Icons.shield_outlined),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          final palette = SettingsPalette(dark);
          expect(
            tester.widget<Icon>(find.byIcon(Icons.shield_outlined)).color,
            palette.network,
          );
          expect(
            tester.widget<Icon>(find.byIcon(Icons.lock_outline)).color,
            palette.extension,
          );
          final button = find.byKey(const ValueKey('always-on-settings'));
          await tester.scrollUntilVisible(
            button,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          // Finish the initial page animation while the VPN status request remains
          // pending.
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 300));
          final anchor = tester.getRect(button);
          final strings = AppLocalizations.of(
            tester.element(find.byType(AlwaysOnPage)),
          );
          expect(find.byTooltip(strings.vpnStatusLoading), findsNothing);
          expect(find.byIcon(Icons.refresh), findsNothing);
          expectSystemStates(
            tester,
            alwaysOn: strings.alwaysOnUnknown,
            lockdown: strings.alwaysOnUnknown,
          );
          first.complete({'alwaysOn': true, 'lockdown': false});
          await tester.pump();
          expect(tester.getRect(button), anchor);
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(button), anchor);
          final failed = Completer<Map<String, dynamic>>();
          bridge.statusReply = failed;
          app.setForeground(false);
          app.setForeground(true);
          await tester.pump();
          expect(tester.getRect(button), anchor);
          failed.completeError(StateError('status unavailable'));
          await tester.pump();
          expect(tester.getRect(button), anchor);
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(button), anchor);
          bridge.statusReply = null;
          bridge.status = const {'alwaysOn': false, 'lockdown': true};
          app.setForeground(false);
          app.setForeground(true);
          await tester.pump();
          expect(tester.getRect(button), anchor);
          await tester.pumpAndSettle();
          expect(tester.getRect(button), anchor);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final succeeds in [true, false]) {
    testWidgets(
      'VPN status details retain in-flight reads while open: success=$succeeds',
      (tester) async {
        final pending = Completer<Map<String, dynamic>>();
        final bridge = AccessBridge()..statusReply = pending;
        final app = AccessApp(bridge);
        addTearDown(app.dispose);
        await show(tester, AlwaysOnPage(app: app));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        final strings = AppLocalizations.of(
          tester.element(find.byType(AlwaysOnPage)),
        );
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.errorDetails),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        app.publish(app.state);
        if (succeeds) {
          pending.complete({'alwaysOn': true, 'lockdown': false});
        } else {
          pending.completeError(StateError('实际 VPN 状态读取失败'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(bridge.statusCalls, 1);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(strings.close),
          ),
        );
        await tester.pumpAndSettle();
        expect(bridge.statusCalls, 1);
        if (succeeds) {
          expectSystemStates(
            tester,
            alwaysOn: strings.alwaysOnEnabled,
            lockdown: strings.lockdownDisabled,
          );
          expect(find.byType(SnackBar), findsNothing);
        } else {
          expect(find.byType(SnackBar), findsOneWidget);
          await tester.tap(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.text(strings.errorDetails),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('operation-technical-details')),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('实际 VPN 状态读取失败'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'VPN status read failure shows only SnackBar; details retain the original error and allow retry',
    (tester) async {
      final bridge = AccessBridge()..statusFails = true;
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(tester, AlwaysOnPage(app: app));
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlwaysOnPage)),
      );
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(strings.vpnStatusReadFailed), findsOneWidget);
      expect(find.text('Bad state: status failed'), findsNothing);
      final anchor = tester.getRect(
        find.byKey(const ValueKey('always-on-settings')),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.widgetWithText(TextButton, strings.errorDetails),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bad state: status failed'), findsOneWidget);
      bridge.statusFails = false;
      await tester.tap(find.widgetWithText(TextButton, strings.retry));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('always-on-settings'))),
        anchor,
      );
      expectSystemStates(
        tester,
        alwaysOn: strings.alwaysOnEnabled,
        lockdown: strings.lockdownDisabled,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('always-on-settings'))),
        anchor,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('always-on page shows unknown state and opens system settings', (
    tester,
  ) async {
    final bridge = AccessBridge()
      ..status = const {'alwaysOn': null, 'lockdown': null};
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, AlwaysOnPage(app: app));
    await tester.pumpAndSettle();
    final strings = AppLocalizations.of(
      tester.element(find.byType(AlwaysOnPage)),
    );
    expectSystemStates(
      tester,
      alwaysOn: strings.alwaysOnUnknown,
      lockdown: strings.alwaysOnUnknown,
    );
    await tester.tap(find.byKey(const ValueKey('always-on-settings')));
    await tester.pumpAndSettle();
    expect(bridge.opened, ['settings']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('always-on page separates a known lockdown state from unknown', (
    tester,
  ) async {
    final bridge = AccessBridge()
      ..status = const {'alwaysOn': false, 'lockdown': true};
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, AlwaysOnPage(app: app));
    await tester.pumpAndSettle();
    final strings = AppLocalizations.of(
      tester.element(find.byType(AlwaysOnPage)),
    );
    expectSystemStates(
      tester,
      alwaysOn: strings.alwaysOnDisabled,
      lockdown: strings.lockdownEnabled,
    );
    expect(find.text(strings.alwaysOnUnknown), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
