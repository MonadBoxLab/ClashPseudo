import 'package:clash_pseudo/src/app/app_shell.dart';
import 'package:clash_pseudo/src/app/app_task.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/workspace_window.dart';
import 'package:clash_pseudo/src/features/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/text_scalers.dart';

import '../features/strategies/strategy_fakes.dart';

void main() {
  for (final language in ['en', 'zh']) {
    for (final scaler in [
      TextScaler.noScaling,
      const TextScaler.linear(1.3),
      const TextScaler.linear(2),
      const NonlinearTextScaler(),
    ]) {
      testWidgets('workspace capacity and actual minimum $language/$scaler', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.reset);
        final app = StrategyAppFake(StrategyBridgeFake())
          ..preferencesLoaded = true
          ..overridesLoaded = true;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: scaler),
              child: WorkspaceWindow(controller: app, child: child!),
            ),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(AppShell));
        final strings = AppLocalizations.of(context);
        final labels = {
          AppTask.overview: strings.overview,
          AppTask.strategies: strings.strategies,
          AppTask.connections: strings.connectionsNavigation,
          AppTask.configurations: strings.configurationsNavigation,
          AppTask.settings: strings.settings,
        };
        WorkspaceLayout resolve(
          Size size, [
          EdgeInsets padding = EdgeInsets.zero,
          EdgeInsets viewInsets = EdgeInsets.zero,
        ]) => WorkspaceLayout.resolve(
          size: size,
          padding: padding,
          viewInsets: viewInsets,
          textScaler: scaler,
          textDirection: TextDirection.ltr,
          labelStyle: Theme.of(context).textTheme.labelMedium!,
          labels: labels,
        );
        for (final width in [
          279.0,
          280.0,
          281.0,
          320.0,
          599.0,
          600.0,
          601.0,
          700.0,
          839.0,
          840.0,
          841.0,
          1000.0,
          1199.0,
          1200.0,
          1201.0,
          1400.0,
          1599.0,
          1600.0,
          1601.0,
          1704.0,
        ]) {
          for (final height in [
            279.0,
            280.0,
            281.0,
            479.0,
            480.0,
            481.0,
            899.0,
            900.0,
            901.0,
          ]) {
            for (final padding in [
              EdgeInsets.zero,
              const EdgeInsets.fromLTRB(8, 24, 8, 24),
            ]) {
              final layout = resolve(Size(width, height), padding);
              if (!layout.supported) continue;
              expect(layout.tasks.length, inInclusiveRange(3, 5));
              expect(layout.tasks, [
                AppTask.overview,
                AppTask.strategies,
                if (layout.tasks.length >= 4) AppTask.connections,
                if (layout.tasks.length == 5) AppTask.configurations,
                AppTask.settings,
              ]);
              expect(width - padding.horizontal, greaterThanOrEqualTo(280));
              expect(height - padding.vertical, greaterThanOrEqualTo(280));
              if (layout.rail) {
                expect(
                  width - padding.horizontal - layout.navigationWidth,
                  greaterThanOrEqualTo(280),
                );
              } else {
                expect(
                  height - padding.vertical - layout.navigationHeight,
                  greaterThanOrEqualTo(160),
                );
                expect(
                  (width - padding.horizontal) / layout.tasks.length,
                  greaterThanOrEqualTo(64),
                );
              }
            }
          }
        }
        expect(
          resolve(
            const Size(1704, 901),
            EdgeInsets.zero,
            const EdgeInsets.only(bottom: 622),
          ).supported,
          isFalse,
        );
        expect(
          resolve(
            const Size(1704, 901),
            EdgeInsets.zero,
            const EdgeInsets.only(bottom: 621),
          ).supported,
          isTrue,
        );
        expect(
          resolve(
            const Size(1704, 901),
            const EdgeInsets.only(left: 24),
            const EdgeInsets.only(right: 1401),
          ).supported,
          isFalse,
        );
        expect(resolve(const Size(279, 900)).supported, isFalse);
        expect(resolve(const Size(1704, 279)).supported, isFalse);
        expect(resolve(const Size(280, 900)).supported, isTrue);
        expect(
          resolve(const Size(280, 900)).tasks.length,
          language == 'en' ? 3 : 4,
        );
        expect(resolve(const Size(1704, 901)).tasks, const [
          AppTask.overview,
          AppTask.strategies,
          AppTask.connections,
          AppTask.configurations,
          AppTask.settings,
        ]);
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(strings.settings),
          ),
        );
        await tester.pumpAndSettle();
        final settings = tester.state(find.byType(SettingsPage));
        for (final size in [
          const Size(280, 280),
          const Size(281, 281),
          const Size(320, 280),
          const Size(599, 479),
          const Size(600, 480),
          const Size(601, 481),
          const Size(1000, 320),
          const Size(1400, 899),
          const Size(1704, 901),
          const Size(279, 900),
          const Size(1704, 279),
          const Size(320, 900),
        ]) {
          tester.view.physicalSize = size;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.state(find.byType(SettingsPage, skipOffstage: false)),
            same(settings),
          );
          final unsupported = find
              .text(strings.enlargeWindow)
              .evaluate()
              .isNotEmpty;
          if (size.width < 280 || size.height < 280) {
            expect(unsupported, isTrue);
          } else if (scaler == TextScaler.noScaling ||
              size.width >= 320 && size.height >= 479 ||
              size == const Size(1000, 320)) {
            expect(unsupported, isFalse);
          }
          if (!unsupported) {
            final rail = find.byType(NavigationRail);
            final bar = find.byType(NavigationBar);
            expect(rail.evaluate().length + bar.evaluate().length, 1);
            final rect = tester.getRect(rail.evaluate().isEmpty ? bar : rail);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width + .01));
            expect(rect.bottom, lessThanOrEqualTo(size.height + .01));
            final page = tester.getRect(find.byType(SettingsPage));
            expect(page.width, greaterThanOrEqualTo(280));
            expect(page.height, greaterThanOrEqualTo(160));
          }
          expect(app.commands, isEmpty);
          expect(tester.takeException(), isNull, reason: '$size/$scaler');
        }
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      });
    }
  }
}
