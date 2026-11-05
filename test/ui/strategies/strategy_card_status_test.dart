import 'package:clash_pseudo/src/model/delay_result.dart';
import 'package:clash_pseudo/src/ui/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_card_status.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart';

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
          for (final member in ['A', '测试🌐']) {
            testWidgets(
              '策略卡片当前成员与 delay 状态保持几何稳定 $locale $dark $width $scale $member',
              (tester) async {
                tester.view.physicalSize = Size(width, 1000);
                tester.view.devicePixelRatio = 1;
                addTearDown(tester.view.resetPhysicalSize);
                addTearDown(tester.view.resetDevicePixelRatio);
                final bridge = StrategyBridgeFake()
                  ..data = strategyData(now: member, currentIdentity: 'source');
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
                await tester.idle();
                expect(controller.loading, isFalse);
                expect(controller.data, same(bridge.data));
                // 等初次加载的 header 动画结束，再记录卡片几何。
                await tester.pumpAndSettle();
                expect(tester.binding.transientCallbackCount, 0);
                expect(tester.takeException(), isNull);
                final current = find.byKey(
                  const ValueKey('strategy-current-出口'),
                );
                expect(tester.widget<Text>(current).data, member);
                final keys = [
                  'strategy-card-出口',
                  'strategy-name-出口',
                  'strategy-current-出口',
                  'strategy-status-出口',
                ];
                final rectangles = {
                  for (final key in keys)
                    key: tester.getRect(find.byKey(ValueKey(key))),
                };
                expect(
                  rectangles['strategy-card-出口']!.contains(
                    rectangles['strategy-current-出口']!.bottomRight,
                  ),
                  isTrue,
                );
                for (final status in DelayMemberStatus.values) {
                  controller.rememberDelay('出口', previewCore, {
                    member: DelayMemberResult(
                      name: member,
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
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('delay 数值区域按字体度量，较长状态在同一区域水平阅读 $language/$scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  final width = StrategyCardStatus.width(context);
                  return SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final status in DelayMemberStatus.values)
                          StrategyCardStatus(
                            key: ValueKey(status),
                            slotWidth: width,
                            result: DelayMemberResult(
                              name: 'node',
                              status: status,
                              delay: status == DelayMemberStatus.success
                                  ? 65535
                                  : null,
                            ),
                          ),
                        StrategyCardStatus(
                          key: const ValueKey('large-delay'),
                          slotWidth: width,
                          result: const DelayMemberResult(
                            name: 'node',
                            status: DelayMemberStatus.success,
                            delay: 123456789,
                          ),
                        ),
                        StrategyCardStatus(
                          key: const ValueKey('reject'),
                          slotWidth: width,
                          rejected: true,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
        for (final key in [
          for (final status in DelayMemberStatus.values) ValueKey(status),
          const ValueKey('large-delay'),
          const ValueKey('reject'),
        ]) {
          final slot = find.byKey(key);
          final context = tester.element(slot);
          final text = find.descendant(of: slot, matching: find.byType(Text));
          expect(tester.getSize(slot).width, StrategyCardStatus.width(context));
          expect(
            tester.getSize(slot).height,
            StrategyCardStatus.height(context),
          );
          final numeric = TextPainter(
            text: TextSpan(
              text: '00000 ms',
              style: DefaultTextStyle.of(context).style
                  .merge(StrategyCardStatus.styleOf(context)),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          expect(tester.getSize(slot).width, numeric.width.ceilToDouble());
          numeric.dispose();
          final reader = find.descendant(
            of: slot,
            matching: find.byType(SingleChildScrollView),
          );
          expect(
            tester.widget<SingleChildScrollView>(reader).scrollDirection,
            Axis.horizontal,
          );
          final scroll = tester.state<ScrollableState>(
            find.descendant(of: reader, matching: find.byType(Scrollable)),
          );
          final overflow =
              (tester.getSize(text).width - tester.getSize(slot).width).clamp(
                0.0,
                double.infinity,
              );
          expect(scroll.position.maxScrollExtent, closeTo(overflow, .01));
          if (overflow > 0) {
            await tester.drag(reader, const Offset(300, 0));
            await tester.pumpAndSettle();
            expect(scroll.position.pixels, closeTo(overflow, .01));
          }
          expect(tester.widget<Text>(text).softWrap, isFalse);
          expect(
            tester.widget<Text>(text).overflow,
            isNot(TextOverflow.ellipsis),
          );
          expect(
            tester.widget<Text>(text).style!.fontFeatures,
            contains(const FontFeature.tabularFigures()),
          );
        }
        expect(find.text('65535 ms'), findsOneWidget);
        expect(find.text('123456789 ms'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
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
    expect(find.text('Failed'), findsNothing);
    expect(find.text('0 ms'), findsNothing);
  });
}
