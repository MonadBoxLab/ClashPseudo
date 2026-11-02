import 'dart:convert';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/overview/overview_page.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_hero.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_text.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/power_ripples.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import 'overview_page_test.dart' show ViewController, config;

void main() {
  for (final language in ['en', 'zh']) {
    for (final width in [320.0, 700.0, 1704.0]) {
      for (final (scaleName, scaler) in [
        ('1', TextScaler.noScaling),
        ('1.3', const TextScaler.linear(1.3)),
        ('2', const TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets('shared traffic rhythm $language/$width/$scaleName', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1136);
          addTearDown(tester.view.reset);
          final app = ViewController()
            ..collection = ConfigCollection(
              entries: [config('one')],
              selectedId: 'one',
            );
          try {
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: AppTheme.light,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: scaler),
                  child: child!,
                ),
                home: OverviewPage(controller: app),
              ),
            );
            await tester.pump();
            final surface = find.byKey(const ValueKey('network-surface'));
            final keys = [
              for (final direction in ['download', 'upload']) ...[
                'traffic-$direction-direction',
                'traffic-$direction-reading',
                'traffic-$direction-total',
              ],
              'traffic-active-count',
              'traffic-memory',
            ];
            final anchors = {
              for (final key in keys)
                key: tester.getRect(find.byKey(ValueKey(key))),
            };
            final panel = tester.getRect(surface);
            final charts = [
              for (final element in find.byType(TrafficChart).evaluate())
                tester.getRect(find.byWidget(element.widget)),
            ];
            debugPrint(
              'TRAFFIC_RHYTHM ${jsonEncode({
                'sample': '$language/$width/$scaleName',
                'surface': [panel.left, panel.top, panel.width, panel.height],
                'readings': [
                  for (final direction in ['download', 'upload']) anchors['traffic-$direction-reading']!.top,
                ],
                'charts': [for (final chart in charts) chart.height],
              })}',
            );
            for (final direction in ['download', 'upload']) {
              expect(
                anchors['traffic-$direction-reading']!.top -
                    anchors['traffic-$direction-direction']!.bottom,
                closeTo(24, .01),
                reason:
                    'Direction and value stay in the same stable metric group.',
              );
            }
            for (final chart in charts) {
              expect(chart.height - 20, greaterThanOrEqualTo(60));
            }
            for (final state in const [
              AppSnapshot(),
              AppSnapshot(phase: 'STARTING'),
              AppSnapshot(
                phase: 'RUNNING',
                generation: 1,
                configId: 'one',
                revision: 1,
              ),
              AppSnapshot(phase: 'STOPPING'),
              AppSnapshot(phase: 'STOPPED'),
            ]) {
              app.state = state;
              app.changed();
              for (final ms in [0, 16, 80, 200, 320]) {
                await tester.pump(Duration(milliseconds: ms));
                expect(tester.getRect(surface), panel);
                for (final entry in anchors.entries) {
                  expect(
                    tester.getRect(find.byKey(ValueKey(entry.key))),
                    entry.value,
                    reason: entry.key,
                  );
                }
                for (var i = 0; i < charts.length; i++) {
                  expect(
                    tester.getRect(find.byType(TrafficChart).at(i)),
                    charts[i],
                  );
                }
                expect(tester.takeException(), isNull);
              }
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            app.dispose();
          }
        });
      }
    }
  }

  group('短屏 Overview 层级', () {
    testWidgets('短状态在连续切换中保留阅读位置', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.reset);
      final app = ViewController()
        ..collection = ConfigCollection(
          entries: [config('one')],
          selectedId: 'one',
        )
        ..state = AppSnapshot(
          phase: 'STOPPED',
          operation: messages.sourceUsedBy(
            'Long current configuration and platform operation ' * 4,
          ),
        );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: OverviewPage(controller: app),
          ),
        );
        await tester.pump();
        final subtitle = find.byKey(const ValueKey('uptime-subtitle'));
        final mode = find.byKey(const ValueKey('mode-trigger'));
        final reader = tester.state(subtitle);
        final anchors = [
          find.byKey(const ValueKey('power-button')),
          mode,
          find.byKey(const ValueKey('network-surface')),
        ];
        final rects = anchors.map(tester.getRect).toList();
        app.state = AppSnapshot(
          phase: 'STOPPED',
          operation: messages.stageUpdatingConfig,
        );
        app.changed();
        await tester.pump();
        for (final ms in [40, 40, 16, 40, 80, 100, 200]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(
            tester.getRect(subtitle).bottom,
            lessThanOrEqualTo(tester.getRect(mode).top + .01),
          );
          expect(tester.state(subtitle), same(reader));
          expect(anchors.map(tester.getRect).toList(), rects);
          expect(tester.takeException(), isNull);
          if (ms == 16) {
            app.state = AppSnapshot(
              phase: 'STOPPED',
              operation: messages.stageStopping,
            );
            app.changed();
            await tester.pump();
          }
        }
        final visible = find.descendant(
          of: subtitle,
          matching: find.byType(Text),
        );
        expect(
          tester.widget<Text>(visible).data,
          lookupAppLocalizations(const Locale('en')).stageStopping,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      }
    });
    for (final language in ['en', 'zh']) {
      for (final dark in [false, true]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('短状态与流量读数保持布局 $language/dark=$dark/scale=$scale', (
            tester,
          ) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(360, 640);
            addTearDown(tester.view.reset);
            final app = ViewController()
              ..collection = ConfigCollection(
                entries: [config('one')],
                selectedId: 'one',
              );
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      disableAnimations: true,
                    ),
                    child: child!,
                  ),
                  home: OverviewPage(controller: app),
                ),
              );
              await tester.pump();
              final hero = find.byType(StatusHero);
              expect(tester.widget<StatusHero>(hero).compact, isTrue);
              final button = find.byKey(const ValueKey('power-button'));
              expect(
                tester.getSize(button),
                const Size.square(PowerRipples.buttonDiameter),
              );
              final download = find.byKey(
                const ValueKey('traffic-download-reading'),
              );
              final upload = find.byKey(
                const ValueKey('traffic-upload-reading'),
              );
              if (scale == 1) {
                expect(tester.getRect(download).bottom, lessThanOrEqualTo(640));
                expect(
                  tester.getRect(upload).top,
                  tester.getRect(download).top,
                );
                expect(
                  tester
                      .getRect(
                        find.byKey(const ValueKey('traffic-upload-total')),
                      )
                      .top,
                  tester
                      .getRect(
                        find.byKey(const ValueKey('traffic-download-total')),
                      )
                      .top,
                );
              }
              final pageState = tester.state(find.byType(OverviewPage));
              final textState = tester.state(
                find.byKey(const ValueKey('uptime-subtitle')),
              );
              final scroll = tester
                  .state<ScrollableState>(find.byType(Scrollable).first)
                  .position;
              final longName = language == 'en'
                  ? 'Waiting for the current configuration and platform operation to finish before the next action.'
                  : '正在更新当前配置并等待系统操作完成，请在更新结束后再切换模式、修改插件或启动接管。';
              final operation = messages.sourceUsedBy(longName);
              final strings = AppLocalizations.of(tester.element(hero));
              app.state = AppSnapshot(phase: 'STOPPED', operation: operation);
              app.changed();
              await tester.pump();
              final subtitle = find.byKey(const ValueKey('uptime-subtitle'));
              expect(tester.widget<StatusText>(subtitle).maxLines, 1);
              expect(tester.widget<StatusText>(subtitle).style!.fontSize, 12);
              final visible = find.descendant(
                of: subtitle,
                matching: find.byType(Text),
              );
              expect(
                tester.widget<Text>(visible).data,
                strings.statusProcessing,
              );
              expect(find.textContaining(longName), findsNothing);
              expect(tester.widget<Text>(visible).maxLines, 1);
              expect(tester.widget<Text>(visible).softWrap, isFalse);
              expect(
                tester.getRect(visible).width,
                lessThanOrEqualTo(tester.getRect(hero).width - 48),
              );
              expect(
                tester.getRect(subtitle).bottom,
                lessThanOrEqualTo(
                  tester
                          .getRect(find.byKey(const ValueKey('mode-trigger')))
                          .top +
                      .01,
                ),
              );
              await tester.ensureVisible(download);
              await tester.pump();
              expect(download.hitTestable(), findsOneWidget);
              expect(tester.state(find.byType(OverviewPage)), same(pageState));
              expect(tester.state(subtitle), same(textState));
              expect(
                tester
                    .state<ScrollableState>(find.byType(Scrollable).first)
                    .position,
                same(scroll),
              );
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox());
              app.dispose();
            }
          });
        }
      }
    }
  });
}
