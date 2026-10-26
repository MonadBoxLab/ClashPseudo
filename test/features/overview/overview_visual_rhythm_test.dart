import 'dart:convert';

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overview/overview_page.dart';
import 'package:clash_pseudo/src/features/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
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
}
