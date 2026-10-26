import 'package:clash_pseudo/src/features/strategies/delay_result.dart';
import 'package:clash_pseudo/src/features/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_card_status.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'strategy_fakes.dart';

void main() {
  testWidgets(
    'card observations never survive member or provider replacement',
    (tester) async {
      final bridge = StrategyBridgeFake()
        ..data = strategyData(currentIdentity: 'first');
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app)..setVisible(true);
      await tester.pump();
      final result = const DelayMemberResult(
        name: 'A',
        identity: 'first',
        status: DelayMemberStatus.success,
        delay: 0,
      );
      controller.rememberDelay('出口', previewCore, {'A': result});
      expect(controller.cardDelay(controller.data!.find('出口')!), same(result));
      controller.finishCardDelay('出口');
      expect(controller.cardDelay(controller.data!.find('出口')!), same(result));
      for (final replacement in [
        strategyData(currentIdentity: 'replacement'),
        strategyData(currentIdentity: 'first'),
        strategyData(now: 'B', currentIdentity: 'other-member'),
      ]) {
        bridge.data = replacement;
        await tester.pump(const Duration(seconds: 5));
        expect(controller.cardDelay(controller.data!.find('出口')!), isNull);
      }
      controller.rememberDelay('出口', previewCore, {'A': result});
      expect(controller.cardDelay(controller.data!.find('出口')!), isNull);
      expect(bridge.delayStarts, isEmpty);
      expect(app.commands, isEmpty);
      controller.dispose();
      app.dispose();
    },
  );

  testWidgets(
    'unfinished, expired and load-balance observations are not retained',
    (tester) async {
      final bridge = StrategyBridgeFake()
        ..data = strategyData(currentIdentity: 'source');
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app)..setVisible(true);
      await tester.pump();
      for (final status in [
        DelayMemberStatus.running,
        DelayMemberStatus.pending,
      ]) {
        controller.rememberDelay('出口', previewCore, {
          'A': DelayMemberResult(name: 'A', identity: 'source', status: status),
        });
        expect(controller.cardDelay(controller.data!.find('出口')!), isNotNull);
        controller.finishCardDelay('出口');
        expect(controller.cardDelay(controller.data!.find('出口')!), isNull);
      }
      controller.rememberDelay('出口', previewCore, {
        'A': const DelayMemberResult(
          name: 'A',
          identity: 'source',
          status: DelayMemberStatus.failed,
        ),
      });
      controller.finishCardDelay('出口', expired: true);
      expect(controller.cardDelay(controller.data!.find('出口')!), isNull);
      controller.rememberDelay('均衡', previewCore, {
        'A': const DelayMemberResult(
          name: 'A',
          identity: 'source',
          status: DelayMemberStatus.success,
          delay: 12,
        ),
      });
      expect(controller.cardDelay(controller.data!.find('均衡')!), isNull);
      controller.dispose();
      app.dispose();
    },
  );

  for (final locale in ['zh', 'en']) {
    for (final dark in [false, true]) {
      for (final width in [280.0, 360.0, 700.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            'card status keeps names, pin and geometry stable $locale $dark $width $scale',
            (tester) async {
              tester.view.physicalSize = Size(width, 1000);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final bridge = StrategyBridgeFake()
                ..data = strategyData(currentIdentity: 'source');
              final app = StrategyAppFake(bridge);
              final controller = StrategyController(app);
              await tester.pumpWidget(
                MaterialApp(
                  locale: Locale(locale),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  theme: ThemeData(
                    brightness: dark ? Brightness.dark : Brightness.light,
                  ),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: StrategiesPage(controller: controller, active: true),
                ),
              );
              await tester.pump();
              await tester.pump();
              final keys = [
                'strategy-card-出口',
                'strategy-name-出口',
                'strategy-current-出口',
                'strategy-status-出口',
                'strategy-pin-出口',
              ];
              final rectangles = {
                for (final key in keys)
                  key: tester.getRect(find.byKey(ValueKey(key))),
              };
              for (final status in DelayMemberStatus.values) {
                controller.rememberDelay('出口', previewCore, {
                  'A': DelayMemberResult(
                    name: 'A',
                    identity: 'source',
                    status: status,
                    delay: status == DelayMemberStatus.success ? 0 : null,
                  ),
                });
                for (final milliseconds in [0, 16, 100, 200]) {
                  await tester.pump(Duration(milliseconds: milliseconds));
                  for (final key in keys) {
                    expect(
                      tester.getRect(find.byKey(ValueKey(key))),
                      rectangles[key],
                      reason: '$status $key',
                    );
                  }
                  expect(tester.takeException(), isNull);
                }
                if (status == DelayMemberStatus.success) {
                  expect(find.text('0 ms'), findsOneWidget);
                }
              }
              expect(bridge.delayStarts, isEmpty);
              expect(app.commands, isEmpty);
              await tester.pumpWidget(const SizedBox());
              controller.dispose();
              app.dispose();
            },
          );
        }
      }
    }
  }

  testWidgets('reject status is distinct from a failed test', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: const [
              StrategyCardStatus(slotWidth: 100, rejected: true),
              StrategyCardStatus(
                slotWidth: 100,
                result: DelayMemberResult(
                  name: 'proxy',
                  status: DelayMemberStatus.failed,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('0 ms'), findsNothing);
  });
}
