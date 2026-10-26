import 'dart:async';

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/settings/always_on_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'application_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(strings.alwaysOnOpenFailed),
      ),
      findsOneWidget,
    );
    await show(tester, page(), locale: const Locale('en'));
    await tester.pumpAndSettle();
    strings = AppLocalizations.of(tester.element(dialog));
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(strings.alwaysOnOpenFailed),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'always-on status refreshes on foreground and failure clears known values',
    (tester) async {
      final bridge = AccessBridge();
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(tester, AlwaysOnPage(app: app));
      await tester.pumpAndSettle();
      expect(find.text('系统状态：已开启'), findsOneWidget);
      final button = tester.getRect(
        find.byKey(const ValueKey('always-on-settings')),
      );
      bridge.statusFails = true;
      app.setForeground(false);
      app.setForeground(true);
      await tester.pumpAndSettle();
      expect(bridge.statusCalls, 2);
      expect(find.text('系统状态：已开启'), findsNothing);
      expect(find.textContaining('请在系统设置确认'), findsWidgets);
      expect(
        tester.getRect(find.byKey(const ValueKey('always-on-settings'))),
        button,
      );
      bridge.statusFails = false;
      bridge.status = const {'alwaysOn': false, 'lockdown': true};
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(find.text('系统状态：未开启'), findsOneWidget);
      expect(find.text('阻止不通过 VPN 的连接：已开启'), findsOneWidget);
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
    await tester.pumpAndSettle();
    old.complete({'alwaysOn': true, 'lockdown': true});
    await tester.pumpAndSettle();
    expect(find.text('系统状态：未开启'), findsOneWidget);
    expect(find.text('系统状态：已开启'), findsNothing);
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
          await tester.pumpAndSettle();
          final anchor = tester.getRect(button);
          final strings = AppLocalizations.of(
            tester.element(find.byType(AlwaysOnPage)),
          );
          first.complete({'alwaysOn': true, 'lockdown': false});
          await tester.pump();
          expect(tester.getRect(button), anchor);
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(button), anchor);
          final failed = Completer<Map<String, dynamic>>();
          bridge.statusReply = failed;
          await tester.tap(find.byTooltip(strings.refresh));
          await tester.pump();
          expect(tester.getRect(button), anchor);
          failed.completeError(StateError('status unavailable'));
          await tester.pump();
          expect(tester.getRect(button), anchor);
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(button), anchor);
          bridge.statusReply = null;
          bridge.status = const {'alwaysOn': false, 'lockdown': true};
          await tester.tap(find.byTooltip(strings.refresh));
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

  testWidgets('always-on page shows unknown state and opens system settings', (
    tester,
  ) async {
    final bridge = AccessBridge()
      ..status = const {'alwaysOn': null, 'lockdown': null};
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, AlwaysOnPage(app: app));
    await tester.pumpAndSettle();
    expect(find.textContaining('请在系统设置确认'), findsWidgets);
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
    expect(find.text('系统状态：未开启'), findsOneWidget);
    expect(find.text('阻止不通过 VPN 的连接：已开启'), findsOneWidget);
    expect(find.text('请在系统设置确认当前状态。'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
