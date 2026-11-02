import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_hero.dart';
import 'package:clash_pseudo/src/ui/strategies/mode_sheet.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart';

class _PopupBridge extends StrategyBridgeFake {
  int vpnSettingsOpens = 0;

  @override
  Future<void> openVpnSettings() async {
    vpnSettingsOpens++;
  }
}

class _ReversingPageRoute extends MaterialPageRoute<void> {
  _ReversingPageRoute({required super.builder, super.settings});

  void reverseInPlace() => controller!.reverse();
}

class _ReversingDialogRoute extends DialogRoute<void> {
  _ReversingDialogRoute({required super.context, required super.builder});

  void reverseInPlace() => controller!.reverse();
}

typedef _StopPopup = ({
  Element origin,
  StatusHero hero,
  ModalRoute<dynamic> popup,
  NavigatorState navigator,
  VoidCallback accept,
});

void main() {
  late _PopupBridge bridge;
  late StrategyAppFake app;
  late AppTaskNavigatorObserver outerRoutes;
  late _ReversingPageRoute outerRoute;

  setUp(() {
    bridge = _PopupBridge();
    app = StrategyAppFake(bridge)
      ..preferencesLoaded = true
      ..overridesLoaded = true;
    outerRoutes = AppTaskNavigatorObserver();
  });

  Future<void> mount(
    WidgetTester tester, {
    bool running = false,
    bool reducedMotion = true,
    bool observeOuter = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
    });
    if (running) {
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        generation: 7,
        configId: 'one',
        revision: 1,
        mode: TunnelMode.rule,
        core: vpnCore,
        alwaysOn: true,
      );
      bridge.state = app.state;
    }
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: observeOuter ? [outerRoutes] : [],
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        onGenerateRoute: (settings) {
          outerRoute = _ReversingPageRoute(
            settings: settings,
            builder: (_) => AppShell(controller: app),
          );
          return outerRoute;
        },
      ),
    );
    await tester.pumpAndSettle();
  }

  Element overview(WidgetTester tester) =>
      tester.element(find.byType(OverviewPage, skipOffstage: false));

  void expectCovered(WidgetTester tester, Element origin) {
    expect(
      tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
      isTrue,
    );
    expect(AppTaskActivity.isActive(origin), isFalse);
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(
                  of: find.byType(OverviewPage),
                  matching: find.byType(IgnorePointer),
                )
                .first,
          )
          .ignoring,
      isTrue,
    );
    expect(
      tester
          .widget<ExcludeFocus>(
            find
                .ancestor(
                  of: find.byType(OverviewPage),
                  matching: find.byType(ExcludeFocus),
                )
                .first,
          )
          .excluding,
      isTrue,
    );
    expect(
      tester
          .widget<ExcludeSemantics>(
            find
                .ancestor(
                  of: find.byType(OverviewPage),
                  matching: find.byType(ExcludeSemantics),
                )
                .first,
          )
          .excluding,
      isTrue,
    );
  }

  Future<_StopPopup> openStop(WidgetTester tester) async {
    final origin = overview(tester);
    final hero = tester.widget<StatusHero>(find.byType(StatusHero));
    final strings = AppLocalizations.of(origin);
    await tester.tap(find.byKey(const ValueKey('power-button')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    final popup = ModalRoute.of(tester.element(dialog))!;
    final accept = find.widgetWithText(FilledButton, strings.openVpnSettings);
    expect(accept.hitTestable(), findsOneWidget);
    return (
      origin: origin,
      hero: hero,
      popup: popup,
      navigator: popup.navigator!,
      accept: tester.widget<FilledButton>(accept).onPressed!,
    );
  }

  testWidgets('captured activity reads the current inherited widget', (
    tester,
  ) async {
    addTearDown(app.dispose);
    bool Function({Route<dynamic>? ownedPopup})? captured;
    final child = Builder(
      builder: (context) {
        captured ??= AppTaskActivity.capture(context);
        return const SizedBox.shrink();
      },
    );
    await tester.pumpWidget(AppTaskActivity(active: true, child: child));
    final current = captured!;
    final owner = tester.element(find.byType(AppTaskActivity));
    expect(current(), isTrue);

    await tester.pumpWidget(AppTaskActivity(active: false, child: child));
    expect(tester.element(find.byType(AppTaskActivity)), same(owner));
    expect(captured, same(current));
    expect(current(), isFalse);

    await tester.pumpWidget(AppTaskActivity(active: true, child: child));
    expect(tester.element(find.byType(AppTaskActivity)), same(owner));
    expect(current(), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(current(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real shell root Stop confirmation resumes before the next frame',
    (tester) async {
      await mount(tester, running: true);
      final state = tester.state(find.byType(OverviewPage));
      final stop = await openStop(tester);
      expect(
        stop.popup.navigator,
        same(Navigator.of(stop.origin, rootNavigator: true)),
      );
      expect(outerRoute.isCurrent, isFalse);
      expect(ModalRoute.of(stop.origin)!.isCurrent, isTrue);
      expect(AppTaskNavigatorObserver.isCurrentPage(outerRoute), isTrue);
      expectCovered(tester, stop.origin);
      expect(
        AppTaskActivity.isActive(stop.origin, ownedPopup: stop.popup),
        isTrue,
      );
      expect(stop.hero.isCurrentWithPopup!(stop.popup), isTrue);
      final snapshot = stop.origin
          .findAncestorWidgetOfExactType<AppTaskActivity>()!;
      expect(snapshot.active, isFalse);

      stop.accept();
      await tester
          .idle(); // The real confirmAction Future returns, without a frame.
      expect(bridge.vpnSettingsOpens, 1);
      expect(outerRoute.isCurrent, isTrue);
      expect(AppTaskActivity.isActive(stop.origin), isTrue);
      expect(
        stop.origin.findAncestorWidgetOfExactType<AppTaskActivity>()!.active,
        isFalse,
        reason: 'the strict inherited snapshot has not rebuilt yet',
      );
      expect(snapshot.active, isFalse);
      expect(
        AppTaskActivity.isActive(stop.origin, ownedPopup: stop.popup),
        isFalse,
      );
      stop.accept();
      await tester.idle();
      expect(bridge.vpnSettingsOpens, 1);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(OverviewPage)), same(state));
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real shell internal ModeSheet keeps its owner and can select', (
    tester,
  ) async {
    await mount(tester);
    final origin = overview(tester);
    final state = tester.state(find.byType(OverviewPage));
    final root = ModalRoute.of(origin)!;
    await tester.tap(find.byKey(const ValueKey('mode-trigger')));
    await tester.pumpAndSettle();
    final sheet = tester.element(find.byType(ModeSheet));
    final popup = ModalRoute.of(sheet)!;
    expect(popup.navigator, same(Navigator.of(origin)));
    expect(root.isCurrent, isFalse);
    expect(outerRoute.isCurrent, isTrue);
    expect(AppTaskNavigatorObserver.isCurrentPage(root), isTrue);
    expectCovered(tester, origin);
    final direct = find.byKey(const ValueKey('mode-direct'));
    expect(direct.hitTestable(), findsOneWidget);
    final choose = tester.widget<OutlinedButton>(direct).onPressed!;
    choose();
    await tester.idle();
    expect(app.commands, [
      {'action': 'setMode', 'mode': 'direct', 'storageEpoch': app.storageEpoch},
    ]);
    popup.navigator!.pop();
    await tester.idle();
    expect(root.isCurrent, isTrue);
    expect(AppTaskActivity.isActive(origin), isTrue);
    expect(
      origin.findAncestorWidgetOfExactType<AppTaskActivity>()!.active,
      isFalse,
      reason: 'the internal route handback must not wait for a frame',
    );
    expect(AppTaskActivity.isActive(sheet, ownedPopup: popup), isFalse);
    choose();
    await tester.idle();
    expect(app.commands, hasLength(1));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(OverviewPage)), same(state));
    expect(tester.takeException(), isNull);
  });

  testWidgets('another Popup cannot borrow a real Stop confirmation callback', (
    tester,
  ) async {
    await mount(tester, running: true);
    final stop = await openStop(tester);
    final other = DialogRoute<void>(
      context: stop.origin,
      builder: (_) => const AlertDialog(content: Text('other popup')),
    );
    unawaited(stop.navigator.push(other));
    expect(
      AppTaskActivity.isActive(stop.origin, ownedPopup: stop.popup),
      isFalse,
    );
    stop.accept();
    await tester.idle();
    expect(bridge.vpnSettingsOpens, 0);
    await tester.pumpAndSettle();
    expectCovered(tester, stop.origin);
    stop.navigator.pop();
    await tester.pumpAndSettle();
    expect(stop.hero.isCurrentWithPopup!(stop.popup), isTrue);
    stop.accept();
    await tester.idle();
    expect(bridge.vpnSettingsOpens, 1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('new PageRoute and its Popup retire the original shell owner', (
    tester,
  ) async {
    await mount(tester, running: true);
    final stop = await openStop(tester);
    final next = MaterialPageRoute<void>(builder: (_) => const Scaffold());
    unawaited(stop.navigator.push(next));
    expect(AppTaskNavigatorObserver.isCurrentPage(outerRoute), isFalse);
    expect(stop.hero.isCurrentWithPopup!(stop.popup), isFalse);
    stop.accept();
    await tester.idle();
    expect(bridge.vpnSettingsOpens, 0);
    await tester.pump();
    expect(
      tester
          .widget<OverviewPage>(find.byType(OverviewPage, skipOffstage: false))
          .active,
      isFalse,
      reason:
          'a new Page retires the owner even when strict activity was false',
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OverviewPage>(find.byType(OverviewPage, skipOffstage: false))
          .active,
      isFalse,
    );
    final other = DialogRoute<void>(
      context: stop.origin,
      builder: (_) => const AlertDialog(content: Text('new page popup')),
    );
    unawaited(stop.navigator.push(other));
    expect(AppTaskActivity.isActive(stop.origin, ownedPopup: other), isFalse);
    expect(stop.hero.isCurrentWithPopup!(other), isFalse);
    await tester.pumpAndSettle();
    stop.navigator.pop();
    await tester.pumpAndSettle();
    stop.navigator.pop();
    await tester.pumpAndSettle();
    expect(
      AppTaskActivity.isActive(stop.origin, ownedPopup: stop.popup),
      isTrue,
    );
    expect(
      stop.hero.isCurrentWithPopup!(stop.popup),
      isFalse,
      reason: 'returning does not revive the retired presentation',
    );
    stop.accept();
    await tester.idle();
    expect(bridge.vpnSettingsOpens, 0);
    stop.navigator.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'task round trip cannot lend a new Popup to the old presentation',
    (tester) async {
      await mount(tester, running: true);
      final stop = await openStop(tester);
      stop.navigator.pop();
      await tester.idle();
      final open = tester.widget<AppTaskScope>(find.byType(AppTaskScope)).open;
      open(AppTask.settings);
      await tester.idle();
      expect(AppTaskActivity.isActive(stop.origin), isFalse);
      final other = DialogRoute<void>(
        context: stop.origin,
        builder: (_) => const AlertDialog(content: Text('settings popup')),
      );
      unawaited(stop.navigator.push(other));
      expect(stop.hero.isCurrentWithPopup!(other), isFalse);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OverviewPage>(
              find.byType(OverviewPage, skipOffstage: false),
            )
            .active,
        isFalse,
      );
      stop.navigator.pop();
      await tester.pumpAndSettle();
      open(AppTask.overview);
      await tester.pumpAndSettle();
      final returnedPopup = DialogRoute<void>(
        context: stop.origin,
        builder: (_) => const AlertDialog(content: Text('new overview popup')),
      );
      unawaited(stop.navigator.push(returnedPopup));
      expect(
        AppTaskActivity.isActive(stop.origin, ownedPopup: returnedPopup),
        isTrue,
      );
      expect(stop.hero.isCurrentWithPopup!(returnedPopup), isFalse);
      stop.accept();
      await tester.idle();
      expect(bridge.vpnSettingsOpens, 0);
      stop.navigator.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('background retires a real confirmation before the next frame', (
    tester,
  ) async {
    await mount(tester, running: true);
    final stop = await openStop(tester);
    app.setForeground(false);
    expect(
      AppTaskActivity.isActive(stop.origin, ownedPopup: stop.popup),
      isFalse,
    );
    stop.accept();
    await tester.idle();
    expect(bridge.vpnSettingsOpens, 0);
    await tester.pumpAndSettle();
    expect(
      tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
      isFalse,
    );
    app.setForeground(true);
    await tester.pumpAndSettle();
    expect(
      AppTaskActivity.isActive(stop.origin, ownedPopup: stop.popup),
      isTrue,
    );
    expect(stop.hero.isCurrentWithPopup!(stop.popup), isFalse);
    stop.accept();
    await tester.idle();
    expect(bridge.vpnSettingsOpens, 0);
    stop.navigator.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Popup reverse is not retirement of the underlying shell page', (
    tester,
  ) async {
    await mount(tester, reducedMotion: false);
    final origin = overview(tester);
    final popup = _ReversingDialogRoute(
      context: origin,
      builder: (_) => const AlertDialog(content: Text('reversing popup')),
    );
    unawaited(Navigator.of(origin, rootNavigator: true).push(popup));
    await tester.pumpAndSettle();
    popup.reverseInPlace();
    expect(popup.isCurrent, isTrue);
    expect(popup.animation!.status, AnimationStatus.reverse);
    expect(AppTaskNavigatorObserver.isCurrentPage(outerRoute), isTrue);
    expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isFalse);
    await tester.pump(const Duration(milliseconds: 16));
    expectCovered(tester, origin);
    popup.navigator!.pop();
    await tester.pumpAndSettle();
    expect(
      tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('PageRoute reverse retires shell ownership while still current', (
    tester,
  ) async {
    await mount(tester, reducedMotion: false);
    final origin = overview(tester);
    outerRoute.reverseInPlace();
    expect(outerRoute.isCurrent, isTrue);
    expect(outerRoute.isActive, isTrue);
    expect(outerRoute.animation!.status, AnimationStatus.reverse);
    expect(AppTaskNavigatorObserver.isCurrentPage(outerRoute), isFalse);
    expect(AppTaskActivity.isActive(origin), isFalse);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  for (final replace in [false, true]) {
    testWidgets(
      'removed/replaced shell root cannot own its old Popup $replace',
      (tester) async {
        await mount(tester, running: true);
        final stop = await openStop(tester);
        if (replace) {
          stop.navigator.replace(
            oldRoute: outerRoute,
            newRoute: MaterialPageRoute<void>(builder: (_) => const Scaffold()),
          );
        } else {
          stop.navigator.removeRoute(outerRoute);
        }
        expect(AppTaskNavigatorObserver.isCurrentPage(outerRoute), isFalse);
        expect(
          AppTaskActivity.isActive(stop.origin, ownedPopup: stop.popup),
          isFalse,
        );
        stop.accept();
        await tester.idle();
        expect(bridge.vpnSettingsOpens, 0);
        if (!replace) {
          expect(stop.popup.isActive, isTrue);
          expect(stop.popup.isCurrent, isTrue);
        }
        await tester.pump();
        expect(tester.takeException(), isNull);
        if (!replace) {
          expect(stop.popup.isActive, isTrue);
          expect(stop.popup.isCurrent, isTrue);
        }
      },
    );
  }

  testWidgets('unobserved outer coverage fails closed in the real shell', (
    tester,
  ) async {
    await mount(tester, observeOuter: false);
    final origin = overview(tester);
    final popup = DialogRoute<void>(
      context: origin,
      builder: (_) => const AlertDialog(content: Text('unobserved popup')),
    );
    unawaited(Navigator.of(origin, rootNavigator: true).push(popup));
    expect(AppTaskNavigatorObserver.isCurrentPage(outerRoute), isFalse);
    expect(AppTaskActivity.isActive(origin, ownedPopup: popup), isFalse);
    await tester.pumpAndSettle();
    expect(
      tester.widget<OverviewPage>(find.byType(OverviewPage)).active,
      isFalse,
    );
    popup.navigator!.pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
