import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/model/traffic_snapshot.dart';
import 'package:clash_pseudo/src/ui/overview/traffic_controller.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/traffic_panel.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fakes.dart';

class PanelBridge extends TrafficBridge {
  int? memory = 134217728;
  bool memoryValid = true;
  bool coreValid = true;
  @override
  Future<Map<String, dynamic>> coreMemory(CoreSnapshot source) async => {
    'valid': coreValid,
    'processId': source.processId,
    'processRssBytes': coreValid ? 64000000 : null,
    'sampledAt': DateTime.now().millisecondsSinceEpoch,
    if (!coreValid) 'error': 'core unavailable',
  };

  @override
  Future<Map<String, dynamic>> appMemory() async => {
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

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('内存首行对齐连接，预览内存另起一行 $language $scale', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 1800);
        addTearDown(tester.view.reset);
        final app = TrafficApp(PanelBridge())
          ..state = const AppSnapshot(phase: 'STOPPED');
        final traffic = TrafficController(app)..setVisible(true);
        Widget host(double width) => MaterialApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: width,
                child: TrafficPanel(
                  traffic: traffic,
                  visible: true,
                  width: width,
                  onOpen: () {},
                ),
              ),
            ),
          ),
        );
        Finder textIn(String key) => find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(Text),
        );
        double baseline(Finder finder) {
          final paragraph = tester.renderObject<RenderParagraph>(finder);
          return tester.getTopLeft(finder).dy +
              paragraph.getDryBaseline(
                paragraph.constraints,
                TextBaseline.alphabetic,
              )!;
        }

        try {
          await tester.pumpWidget(host(1000));
          await tester.pump();
          final appText = textIn('traffic-memory-app');
          final countText = textIn('traffic-active-count');
          expect(appText, findsOneWidget);
          expect(
            tester.widget<Text>(appText).data,
            language == 'en' ? 'App memory 134.2 MB' : '应用内存 134.2 MB',
          );
          expect(
            find.byKey(const ValueKey('traffic-memory-core')),
            findsNothing,
          );
          if (scale == 1.0) {
            expect(baseline(appText), closeTo(baseline(countText), .01));
          } else {
            expect(
              tester.getTopLeft(appText).dy,
              greaterThanOrEqualTo(tester.getBottomLeft(countText).dy),
            );
          }
          final panel = tester.getRect(find.byType(TrafficPanel));
          final firstLine = tester.getRect(appText);
          app.state = const AppSnapshot(
            phase: 'STOPPED',
            core: CoreSnapshot(
              processId: 'preview-memory-core',
              inputId: 'preview-memory-input',
              generation: 8,
              configId: 'one',
              revision: 1,
              composition: 'one',
              purpose: 'PREVIEW',
              phase: 'READY',
            ),
          );
          app.changed();
          await tester.pump(const Duration(seconds: 1));
          final coreText = textIn('traffic-memory-core');
          expect(coreText, findsOneWidget);
          expect(
            tester.widget<Text>(coreText).data,
            language == 'en' ? 'Core memory 64.0 MB' : '内核内存 64.0 MB',
          );
          expect(tester.getRect(find.byType(TrafficPanel)), panel);
          expect(tester.getRect(appText), firstLine);
          if (scale == 1.0) {
            expect(baseline(appText), closeTo(baseline(countText), .01));
          } else {
            expect(
              tester.getTopLeft(appText).dy,
              greaterThanOrEqualTo(tester.getBottomLeft(countText).dy),
            );
          }
          expect(
            tester.getTopLeft(coreText).dy,
            closeTo(tester.getBottomLeft(appText).dy, .01),
          );
          expect(
            tester.getTopLeft(coreText).dx,
            closeTo(tester.getTopLeft(appText).dx, .01),
          );
          tester.view.physicalSize = const Size(240, 1800);
          await tester.pumpWidget(host(240));
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            tester.getTopLeft(appText).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(countText).dy),
          );
          for (final text in [appText, coreText]) {
            expect(tester.widget<Text>(text).softWrap, isFalse);
            expect(tester.widget<Text>(text).maxLines, 1);
            expect(
              tester.renderObject<RenderParagraph>(text).textScaler.scale(12),
              12 * scale,
            );
          }
          expect(find.byType(FittedBox), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          traffic.dispose();
          app.dispose();
        }
      });
    }
  }

  for (final width in [320.0, 1704.0]) {
    testWidgets('内存分别显示 App 和 Core，停止仅保留 App，状态不改变布局 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1800);
      addTearDown(tester.view.reset);
      final bridge = PanelBridge();
      final app = TrafficApp(bridge)
        ..state = const AppSnapshot(
          phase: 'RUNNING',
          generation: 1,
          core: CoreSnapshot(
            processId: 'memory-core',
            inputId: 'memory-input',
            generation: 7,
            configId: 'one',
            revision: 1,
            composition: 'one',
            purpose: 'RUNNING',
            phase: 'READY',
          ),
        );
      final traffic = TrafficController(app)..setVisible(true);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: width,
                child: TrafficPanel(
                  traffic: traffic,
                  visible: true,
                  width: width,
                  onOpen: () {},
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
      final memory = find.byKey(const ValueKey('traffic-memory'));
      final memoryRect = tester.getRect(memory);
      void stableMemory() {
        expect(tester.getRect(find.byType(TrafficPanel)), panel);
        expect(tester.getRect(memory), memoryRect);
        final value = find
            .descendant(of: memory, matching: find.byType(Text))
            .last;
        expect(tester.widget<Text>(value).maxLines, 1);
        expect(tester.widget<Text>(value).softWrap, isFalse);
        expect(tester.widget<Text>(value).data, isNot(contains('\n')));
        expect(
          find.descendant(
            of: memory,
            matching: find.byType(SingleChildScrollView),
          ),
          findsNWidgets(traffic.coreMemoryRunning ? 2 : 1),
        );
      }

      stableMemory();

      expect(find.text(strings.memoryApplication('134.2')), findsOneWidget);
      expect(find.text(strings.memoryCore('64.0')), findsOneWidget);
      bridge.coreValid = false;
      await tester.pump(const Duration(seconds: 1));
      stableMemory();
      expect(find.text(strings.memoryApplication('134.2')), findsOneWidget);
      expect(find.text(strings.memoryCore('—')), findsOneWidget);
      bridge.coreValid = true;
      bridge.memoryValid = false;
      await tester.pump(const Duration(seconds: 1));
      stableMemory();
      expect(find.text(strings.memoryApplication('—')), findsOneWidget);
      expect(find.text(strings.memoryCore('64.0')), findsOneWidget);
      bridge.memoryValid = true;
      app.state = const AppSnapshot(phase: 'STOPPED');
      app.changed();
      await tester.pump(const Duration(seconds: 1));
      stableMemory();
      expect(find.text(strings.memoryApplication('134.2')), findsOneWidget);
      expect(find.textContaining(strings.memoryCore('64.0')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      traffic.dispose();
      app.dispose();
    });
  }

  testWidgets(
    'live numbers update on the native reply without waiting for visual motion',
    (tester) async {
      final bridge = PanelBridge()..totals(2048, 1024);
      final app = TrafficApp(bridge);
      final traffic = TrafficController(app)..setVisible(true);
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: TrafficPanel(
                  traffic: traffic,
                  visible: true,
                  width: 360,
                  onOpen: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final panel = tester.state(find.byType(TrafficPanel));
        final anchor = tester.getRect(
          find.byKey(const ValueKey('traffic-download-total')),
        );
        bridge.totals(4096, 8192);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Downloaded 8.00 KiB'), findsOneWidget);
        expect(find.text('Uploaded 4.00 KiB'), findsOneWidget);
        expect(find.text('Downloaded 1.00 KiB'), findsNothing);
        expect(
          tester.getRect(find.byKey(const ValueKey('traffic-download-total'))),
          anchor,
        );
        expect(tester.state(find.byType(TrafficPanel)), same(panel));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        traffic.dispose();
        app.dispose();
      }
    },
  );

  testWidgets(
    'traffic section reflow keeps chart identity and has reversible intermediate height',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1800);
      addTearDown(tester.view.reset);
      final bridge = PanelBridge();
      final app = TrafficApp(bridge);
      final traffic = TrafficController(app)..setVisible(true);
      Widget host(double scale, {bool reduced = false, double width = 700}) =>
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: MediaQueryData(
                textScaler: TextScaler.linear(scale),
                disableAnimations: reduced,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: TrafficPanel(
                        traffic: traffic,
                        visible: true,
                        width: width,
                        onOpen: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
      final metrics = find.byKey(const ValueKey('traffic-metrics-layout'));
      Rect uploadRect() => tester
          .getRect(find.byKey(const ValueKey('traffic-upload-direction')))
          .shift(-tester.getTopLeft(metrics));
      Rect memoryRect() => tester
          .getRect(find.byKey(const ValueKey('traffic-memory')))
          .shift(
            -tester.getTopLeft(
              find.byKey(const ValueKey('traffic-summary-layout')),
            ),
          );
      try {
        await tester.pumpWidget(host(1));
        await tester.pump();
        final chartStates = [
          for (var i = 0; i < 2; i++)
            tester.state(find.byType(TrafficChart).at(i)),
        ];
        final rowHeight = tester.getSize(metrics).height;
        final rowLeft = uploadRect().left;
        final summaryRowLeft = memoryRect().left;
        expect(rowLeft, greaterThan(0));
        expect(summaryRowLeft, greaterThan(0));
        await tester.pumpWidget(host(2));
        final first = tester.getSize(metrics).height;
        await tester.pump(const Duration(milliseconds: 70));
        final middle = tester.getSize(metrics).height;
        final middleLeft = uploadRect().left;
        expect(middle, greaterThan(first));
        expect(middleLeft, inExclusiveRange(0, rowLeft));
        expect(uploadRect().top, greaterThan(0));
        expect(memoryRect().left, inExclusiveRange(0, summaryRowLeft));
        final summaryMiddleLeft = memoryRect().left;
        await tester.pumpWidget(host(1));
        expect(uploadRect().left, closeTo(middleLeft, .01));
        expect(memoryRect().left, closeTo(summaryMiddleLeft, .01));
        await tester.pump(const Duration(milliseconds: 16));
        expect(uploadRect().left, greaterThan(middleLeft));
        expect(memoryRect().left, greaterThan(summaryMiddleLeft));
        await tester.pump(const Duration(milliseconds: 220));
        expect(tester.getSize(metrics).height, closeTo(rowHeight, .01));
        var previousWidth = 700.0;
        for (final width in [250.0, 270.0, 245.0, 280.0]) {
          double base(double value) =>
              (value + (value * .06).clamp(16.0, 48.0)) / 2;
          final uploadFraction = uploadRect().left / base(previousWidth);
          final memoryFraction = memoryRect().left / base(previousWidth);
          await tester.pumpWidget(host(1, width: width));
          expect(
            uploadRect().left / base(width),
            closeTo(uploadFraction, .001),
          );
          expect(
            memoryRect().left / base(width),
            closeTo(memoryFraction, .001),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(uploadRect().left / base(width), inInclusiveRange(0, 1));
          expect(memoryRect().left / base(width), inInclusiveRange(0, 1));
          expect(tester.takeException(), isNull);
          previousWidth = width;
        }
        await tester.pumpWidget(host(2, reduced: true));
        await tester.pump();
        final stackedHeight = tester.getSize(metrics).height;
        expect(stackedHeight, greaterThan(middle));
        expect(uploadRect().left, 0);
        expect(memoryRect().left, 0);
        expect(uploadRect().top, greaterThan(0));
        expect(memoryRect().top, greaterThan(0));
        for (var i = 0; i < 2; i++) {
          expect(
            tester.state(find.byType(TrafficChart).at(i)),
            same(chartStates[i]),
          );
        }
        expect(
          tester.widget<TrafficPanel>(find.byType(TrafficPanel)).traffic,
          same(traffic),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        traffic.dispose();
        app.dispose();
      }
    },
  );

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
              find.text(strings.memoryApplication('134.2')),
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
            expect(find.text(strings.memoryApplication('—')), findsOneWidget);
            expect(
              find.byTooltip(
                RegExp(RegExp.escape(strings.processMemoryUnavailable)),
              ),
              findsOneWidget,
            );
            expect(
              find.byTooltip(
                '${strings.processMemoryUnavailable}\nunavailable',
              ),
              findsOneWidget,
            );
            expect(traffic.memoryErrorMessage?.detail, 'unavailable');
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
              find.text(strings.memoryApplication('134.2')),
              findsOneWidget,
            );
            expect(traffic.memoryUnavailable, isFalse);
            expect(traffic.memoryErrorMessage, isNull);
            expect(
              find.byTooltip(
                RegExp(RegExp.escape(strings.processMemoryUnavailable)),
              ),
              findsNothing,
            );
            expect(find.byTooltip(RegExp('unavailable')), findsNothing);
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
