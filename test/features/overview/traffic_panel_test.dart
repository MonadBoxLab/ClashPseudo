import 'dart:io';

import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/features/overview/traffic_window.dart';
import 'package:clash_pseudo/src/features/overview/traffic_controller.dart';
import 'package:clash_pseudo/src/features/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fakes.dart';

class PanelBridge extends TrafficBridge {
  int? memory = 134217728;
  bool memoryValid = true;
  @override
  Future<Map<String, dynamic>> processMemory() async => {
    'processRssBytes': memory,
    'sampledAt': DateTime.now().millisecondsSinceEpoch,
    'valid': memoryValid,
    if (!memoryValid) 'error': 'unavailable',
  };

  void totals(int? upload, int? download) {
    value = TrafficSnapshot.fromMap({
      'generation': 7,
      'configId': 'one',
      'revision': 1,
      'sessionGeneration': 1,
      'phase': 'RUNNING',
      'fresh': true,
      'elapsedMs': 1000,
      'sampledAt': 1000,
      'failed': false,
      'upload': 999999999999.0,
      'download': 0,
      'activeCount': 999999999,
      'sessionUploadBytes': upload,
      'sessionDownloadBytes': download,
      'points': [
        {'elapsedMs': 0, 'upload': 1024, 'download': 0},
        {'elapsedMs': 1000, 'upload': 999999999999.0, 'download': 0},
      ],
    });
  }
}

void main() {
  setUpAll(() async {
    for (final entry in const {
      'Roboto': String.fromEnvironment('D7_TEST_FONT'),
      'Ahem': String.fromEnvironment('D7_TEST_FONT'),
      'MaterialIcons': String.fromEnvironment('D7_ICON_FONT'),
    }.entries) {
      if (entry.value.isEmpty) continue;
      final loader = FontLoader(entry.key)
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(entry.value).readAsBytes()),
          ),
        );
      await loader.load();
    }
  });

  for (final (language, downloaded, uploaded, connections) in [
    ('en', 'Downloaded', 'Uploaded', 'Connections'),
    ('zh', '累计下载', '累计上传', '连接'),
  ]) {
    testWidgets(
      'directional totals replace the old session wording $language',
      (tester) async {
        final bridge = PanelBridge()..totals(2048, 1024);
        final app = TrafficApp(bridge);
        final traffic = TrafficController(app)..setVisible(true);
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale(language),
              home: Scaffold(
                body: TrafficPanel(
                  traffic: traffic,
                  visible: true,
                  width: 360,
                  onOpen: () {},
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('$downloaded 1.00 KiB'), findsOneWidget);
          expect(find.text('$uploaded 2.00 KiB'), findsOneWidget);
          expect(find.text('$connections 999999999'), findsOneWidget);
          expect(find.textContaining('This session'), findsNothing);
          expect(find.textContaining('本次累计'), findsNothing);
          expect(
            find.bySemanticsLabel(RegExp('$downloaded 1.00 KiB')),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel(RegExp('$uploaded 2.00 KiB')),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel(RegExp('This session|本次累计')),
            findsNothing,
          );
          app.state = const AppSnapshot(phase: 'STOPPED');
          app.changed();
          await tester.pump();
          expect(find.text('$downloaded —'), findsOneWidget);
          expect(find.text('$uploaded —'), findsOneWidget);
          expect(find.text('$connections —'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
          await tester.pumpWidget(const SizedBox());
          traffic.dispose();
          app.dispose();
        }
      },
    );
  }

  for (final language in ['zh', 'en']) {
    for (final width in [280.0, 360.0, 700.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'totals and memory hold their slots for every value/status $language $width $scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1200);
            addTearDown(tester.view.reset);
            final bridge = PanelBridge()..totals(0, 1024);
            final app = TrafficApp(bridge);
            final traffic = TrafficController(app)..setVisible(true);
            var opens = 0;
            await tester.pumpWidget(
              MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: Locale(language),
                theme: ThemeData(
                  brightness: language == 'en'
                      ? Brightness.dark
                      : Brightness.light,
                ),
                home: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(scale),
                    disableAnimations: true,
                  ),
                  child: Scaffold(
                    body: SingleChildScrollView(
                      child: Material(
                        child: TrafficPanel(
                          traffic: traffic,
                          visible: true,
                          width: width,
                          onOpen: () => opens++,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final strings = AppLocalizations.of(
              tester.element(find.byType(TrafficPanel)),
            );
            final panel = tester.getRect(find.byType(TrafficPanel));
            final keys = [
              'traffic-upload-total',
              'traffic-download-total',
              'traffic-active-count',
              'traffic-memory',
              'traffic-download-reading',
              'traffic-upload-reading',
              'traffic-download-direction',
              'traffic-upload-direction',
            ];
            final anchors = {
              for (final key in keys)
                key: tester.getRect(find.byKey(ValueKey(key))),
            };
            final charts = [
              for (
                var i = 0;
                i < find.byType(TrafficChart).evaluate().length;
                i++
              )
                tester.getRect(find.byType(TrafficChart).at(i)),
            ];
            expect(
              find.text('Last 30 seconds · Independent scales'),
              findsNothing,
            );
            expect(find.text('近 30 秒 · 各图独立尺度'), findsNothing);
            expect(find.byKey(const ValueKey('traffic-caption')), findsNothing);
            expect(charts, hasLength(2));
            for (var i = 0; i < charts.length; i++) {
              expect(charts[i].height, greaterThanOrEqualTo(80));
              final prefix = i == 0 ? 'traffic-download' : 'traffic-upload';
              final reading = anchors['$prefix-reading']!;
              final direction = anchors['$prefix-direction']!;
              expect(reading.top - direction.bottom, closeTo(24, .01));
              expect(charts[i].top - reading.bottom, closeTo(4, .01));
              final total =
                  anchors[i == 0
                      ? 'traffic-download-total'
                      : 'traffic-upload-total']!;
              expect(total.top - charts[i].bottom, closeTo(12, .01));
              final chart = tester.widget<TrafficChart>(
                find.byType(TrafficChart).at(i),
              );
              final points = chart.plot
                  .positions(chart.size)
                  .whereType<Offset>();
              expect(
                chart.size.height - 20,
                greaterThanOrEqualTo(60),
                reason:
                    'The chart needs a real drawing area, not just padding.',
              );
              expect(points, isNotEmpty);
            }
            void check() {
              expect(tester.getRect(find.byType(TrafficPanel)), panel);
              for (final entry in anchors.entries) {
                expect(
                  tester.getRect(find.byKey(ValueKey(entry.key))),
                  entry.value,
                  reason: entry.key,
                );
              }
              for (
                var i = 0;
                i < find.byType(TrafficChart).evaluate().length;
                i++
              ) {
                expect(
                  tester.getRect(find.byType(TrafficChart).at(i)),
                  charts[i],
                );
              }
              expect(tester.takeException(), isNull);
            }

            expect(find.text('${strings.trafficUploaded} 0 B'), findsOneWidget);
            expect(
              find.text('${strings.trafficDownloaded} 1.00 KiB'),
              findsOneWidget,
            );
            expect(
              find.text('${strings.processMemory} 128 MiB'),
              findsOneWidget,
            );
            await tester.tap(find.byKey(const ValueKey('traffic-memory')));
            await tester.pump();
            expect(opens, 0);
            expect(
              find.ancestor(
                of: find.byKey(const ValueKey('traffic-memory')),
                matching: find.byType(InkWell),
              ),
              findsNothing,
            );
            for (final values in [
              (1024, 1073741824, 1099511627776),
              (0x7fffffffffffffff, 0, 0),
              (null, null, null),
            ]) {
              bridge.totals(values.$1, values.$2);
              bridge.memory = values.$3;
              bridge.memoryValid = values.$3 != null;
              await tester.pump(const Duration(seconds: 1));
              for (final ms in [0, 16, 100, 200]) {
                await tester.pump(Duration(milliseconds: ms));
                check();
              }
            }
            expect(find.text('${strings.processMemory} —'), findsOneWidget);
            expect(
              find.byTooltip(strings.processMemoryUnavailable),
              findsOneWidget,
            );
            bridge.fail = true;
            await tester.pump(const Duration(seconds: 1));
            check();
            bridge.fail = false;
            bridge.memory = 134217728;
            bridge.memoryValid = true;
            app.state = const AppSnapshot(phase: 'STOPPED');
            app.changed();
            await tester.pump();
            for (final ms in [0, 16, 100, 200]) {
              await tester.pump(Duration(milliseconds: ms));
              check();
            }
            expect(
              find.text('${strings.processMemory} 128 MiB'),
              findsOneWidget,
            );
            expect(find.text('${strings.trafficDownloaded} —'), findsOneWidget);
            expect(find.text('${strings.trafficUploaded} —'), findsOneWidget);
            expect(
              find.text('${strings.trafficConnections} —'),
              findsOneWidget,
            );
            await tester.pumpWidget(const SizedBox());
            traffic.dispose();
            app.dispose();
          },
        );
      }
    }
  }
}
