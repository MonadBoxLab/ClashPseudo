import 'dart:ui' as ui;

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overview/overview_page.dart';
import 'package:clash_pseudo/src/features/overview/widgets/session_uptime.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'overview_page_test.dart' show ViewController, config;

const _image = ValueKey('overview-background-image');

int _difference(Color a, Color b) {
  final first = a.toARGB32();
  final second = b.toARGB32();
  return [
    for (final shift in [16, 8, 0])
      (((first >> shift) & 255) - ((second >> shift) & 255)).abs(),
  ].reduce((a, b) => a > b ? a : b);
}

double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return first > second
      ? (first + .05) / (second + .05)
      : (second + .05) / (first + .05);
}

Future<List<Color>> _samples(WidgetTester tester, List<Offset> points) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_image),
      );
      final image = await boundary.toImage();
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (final point in points)
            Color.fromARGB(
              bytes.getUint8(
                (point.dy.round() * image.width + point.dx.round()) * 4 + 3,
              ),
              bytes.getUint8(
                (point.dy.round() * image.width + point.dx.round()) * 4,
              ),
              bytes.getUint8(
                (point.dy.round() * image.width + point.dx.round()) * 4 + 1,
              ),
              bytes.getUint8(
                (point.dy.round() * image.width + point.dx.round()) * 4 + 2,
              ),
            ),
        ];
      } finally {
        image.dispose();
      }
    }))!;

void main() {
  for (final width in [320.0, 1704.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'network surface meets navigation and the right edge without brand-colored corners $width/$dark',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1136);
          tester.view.padding = const FakeViewPadding(right: 16, bottom: 20);
          addTearDown(tester.view.reset);
          final app = ViewController();
          final palette = HomePalette(dark);
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? AppTheme.dark : AppTheme.light,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: child!,
                ),
                home: RepaintBoundary(
                  key: _image,
                  child: Scaffold(
                    body: OverviewPage(controller: app),
                    bottomNavigationBar: NavigationBar(
                      key: const ValueKey('test-bottom-navigation'),
                      backgroundColor: palette.surface,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.home),
                          label: 'Home',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.settings),
                          label: 'Settings',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            for (final phase in ['STOPPED', 'RUNNING']) {
              app.state = AppSnapshot(phase: phase);
              app.changed();
              await tester.pump();
              final scroll = tester
                  .state<ScrollableState>(
                    find
                        .descendant(
                          of: find.byType(OverviewPage),
                          matching: find.byType(Scrollable),
                        )
                        .first,
                  )
                  .position;
              scroll.jumpTo(scroll.maxScrollExtent);
              await tester.pump();
              final panel = tester.getRect(
                find.byKey(const ValueKey('network-surface')),
              );
              final navigation = tester.getRect(
                find.byKey(const ValueKey('test-bottom-navigation')),
              );
              expect(panel.bottom, closeTo(navigation.top, .01));
              expect(panel.right, width);
              final colors = await _samples(tester, [
                Offset(panel.left + 1, panel.bottom - 2),
                Offset(panel.right - 2, panel.bottom - 2),
                Offset(panel.right - 2, panel.center.dy),
                if (width > 840) Offset(panel.right - 2, panel.top + 2),
              ]);
              for (final color in colors) {
                expect(
                  _difference(color, palette.surface),
                  lessThanOrEqualTo(1),
                );
              }
              expect(tester.takeException(), isNull);
            }
          } finally {
            await tester.pumpWidget(const SizedBox());
            app.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'the glow follows the power control while the short page scrolls',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1704, 320);
      addTearDown(tester.view.reset);
      final app = ViewController()
        ..collection = ConfigCollection(
          entries: [config('one')],
          selectedId: 'one',
        )
        ..state = const AppSnapshot(
          phase: 'RUNNING',
          generation: 1,
          configId: 'one',
          revision: 1,
        );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.forBrightness(Brightness.light, BrandColor.cobalt),
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RepaintBoundary(
              key: _image,
              child: OverviewPage(controller: app),
            ),
          ),
        );
        await tester.pump();
        final power = find.byKey(const ValueKey('power-button'));
        final before = tester.getRect(power);
        final first = (await _samples(tester, [
          before.center + Offset(before.width * 1.25, 0),
        ])).single;
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
        await tester.pump(const Duration(milliseconds: 400));
        final after = tester.getRect(power);
        expect(after.center.dy, lessThan(before.center.dy - 30));
        final next = (await _samples(tester, [
          after.center + Offset(after.width * 1.25, 0),
        ])).single;
        expect(
          _difference(first, next),
          lessThanOrEqualTo(1),
          reason: 'The background must scroll with its control, not stay fixed to the viewport.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
      }
    },
  );

  for (final width in [320.0, 1704.0]) {
    for (final brand in BrandColor.values) {
      for (final dark in [false, true]) {
        testWidgets(
          'reduced motion applies the full field and button together $width/$brand/$dark',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1136);
            addTearDown(tester.view.reset);
            final app = ViewController()
              ..collection = ConfigCollection(
                entries: [config('one')],
                selectedId: 'one',
              );
            final palette = HomePalette(dark, brand: brand);
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: AppTheme.forBrightness(
                    dark ? Brightness.dark : Brightness.light,
                    brand,
                  ),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      disableAnimations: true,
                      textScaler: TextScaler.linear(1.3),
                    ),
                    child: child!,
                  ),
                  home: OverviewPage(controller: app),
                ),
              );
              await tester.pump();
              final power = find.byKey(const ValueKey('power-button'));
              final mode = find.byKey(const ValueKey('mode-trigger'));
              final panel = find.byKey(const ValueKey('network-surface'));
              final anchors = [
                tester.getRect(power),
                tester.getRect(mode),
                tester.getRect(panel),
              ];
              final stoppedFace = tester
                  .widget<FilledButton>(power)
                  .style!
                  .backgroundColor!
                  .resolve({})!;
              for (final phase in [
                'STARTING',
                'RUNNING',
                'STOPPING',
                'RUNNING',
                'STOPPED',
                'UNKNOWN',
                'RUNNING',
                'STOPPED',
              ]) {
                app.state = AppSnapshot(
                  phase: phase,
                  generation: 1,
                  configId: 'one',
                  revision: 1,
                );
                app.changed();
                await tester.pump();
                final field = tester.widget<DecoratedBox>(
                  find.byKey(const ValueKey('overview-brand-field')),
                );
                expect(
                  (field.decoration as BoxDecoration).color,
                  phase == 'RUNNING' ? palette.hero : palette.background,
                );
                final button = tester.widget<FilledButton>(power);
                if (phase == 'RUNNING' || phase == 'STOPPED') {
                  final face = button.style!.backgroundColor!.resolve({})!;
                  expect(face.a, 1);
                  expect(face == stoppedFace, phase == 'STOPPED');
                  expect(
                    _contrast(
                      face,
                      button.style!.foregroundColor!.resolve({})!,
                    ),
                    greaterThanOrEqualTo(4.5),
                  );
                }
                expect([
                  tester.getRect(power),
                  tester.getRect(mode),
                  tester.getRect(panel),
                ], anchors);
                expect(tester.takeException(), isNull);
              }
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              app.dispose();
            }
          },
        );
      }
    }
  }

  for (final width in [599.0, 600.0, 601.0, 1704.0]) {
    testWidgets(
      'status-bar inset remains legible beside the neutral rail $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.reset);
        final app = ViewController()
          ..collection = ConfigCollection(
            entries: [config('one')],
            selectedId: 'one',
          )
          ..state = const AppSnapshot(
            phase: 'RUNNING',
            generation: 1,
            configId: 'one',
            revision: 1,
          );
        const palette = HomePalette(false, brand: BrandColor.cobalt);
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.forBrightness(
                Brightness.light,
                BrandColor.cobalt,
              ),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: const EdgeInsets.only(top: 24),
                  viewPadding: const EdgeInsets.only(top: 24),
                ),
                child: child!,
              ),
              home: RepaintBoundary(
                key: _image,
                child: OverviewPage(controller: app),
              ),
            ),
          );
          await tester.pump();
          final colors = await _samples(tester, [
            const Offset(2, 12),
            Offset(width - 3, 12),
            const Offset(2, 90),
          ]);
          for (final color in colors.take(2)) {
            expect(
              _difference(
                color,
                width >= 600 ? palette.background : palette.hero,
              ),
              lessThanOrEqualTo(1),
            );
          }
          expect(_difference(colors[2], palette.hero), lessThanOrEqualTo(1));
          final overlay = tester
              .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
                find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
              )
              .value;
          final icon = overlay.statusBarIconBrightness == Brightness.light
              ? Colors.white
              : Colors.black;
          expect(_contrast(icon, colors.first), greaterThanOrEqualTo(4.5));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
        }
      },
    );
  }

  for (final brand in BrandColor.values) {
    for (final dark in [false, true]) {
      testWidgets(
        'narrow brand field keeps system icons legible $brand/$dark',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          addTearDown(tester.view.reset);
          final app = ViewController()
            ..collection = ConfigCollection(
              entries: [config('one')],
              selectedId: 'one',
            );
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: AppTheme.forBrightness(
                  dark ? Brightness.dark : Brightness.light,
                  brand,
                ),
                locale: const Locale('en'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: RepaintBoundary(
                  key: _image,
                  child: OverviewPage(controller: app),
                ),
              ),
            );
            await tester.pump();
            for (final phase in ['RUNNING', 'STOPPED']) {
              app.state = AppSnapshot(
                phase: phase,
                generation: 1,
                configId: 'one',
                revision: 1,
              );
              app.changed();
              for (final ms in [
                0,
                for (var frame = 0; frame < 20; frame++) 16,
              ]) {
                await tester.pump(Duration(milliseconds: ms));
                final background = (await _samples(tester, [
                  const Offset(2, 30),
                ])).single;
                final overlay = tester
                    .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
                      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
                    )
                    .value;
                final icon = overlay.statusBarIconBrightness == Brightness.light
                    ? Colors.white
                    : Colors.black;
                expect(_contrast(icon, background), greaterThanOrEqualTo(4.5));
                expect(tester.takeException(), isNull);
              }
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            app.dispose();
          }
        },
      );
    }
  }

  for (final brand in BrandColor.values) {
    for (final dark in [false, true]) {
      for (final language in ['en', 'zh']) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('wide overview keeps a solid field and contrasting power control '
              '${brand.name}/$dark/$language/$scale', (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(1704, 1136);
            addTearDown(tester.view.reset);
            final app = ViewController()
              ..collection = ConfigCollection(
                entries: [config('one')],
                selectedId: 'one',
              );
            final palette = HomePalette(dark, brand: brand);
            final strongestGlow = palette.hero;
            const running = AppSnapshot(
              phase: 'RUNNING',
              generation: 1,
              configId: 'one',
              revision: 1,
            );
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: AppTheme.forBrightness(
                    dark ? Brightness.dark : Brightness.light,
                    brand,
                  ),
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: RepaintBoundary(
                    key: _image,
                    child: OverviewPage(controller: app),
                  ),
                ),
              );
              await tester.pump();
              final power = find.byKey(const ValueKey('power-button'));
              final mode = find.byKey(const ValueKey('mode-trigger'));
              final panel = find.byKey(const ValueKey('network-surface'));
              final anchors = [
                tester.getRect(power),
                tester.getRect(mode),
                tester.getRect(panel),
              ];
              final bounds = anchors.last;
              expect(bounds.right, tester.view.physicalSize.width);
              final workspace = tester.getRect(
                find.byKey(const ValueKey('overview-workspace')),
              );
              final seamY = bounds.top + 90;
              final points = [
                Offset(2, seamY),
                Offset(workspace.left + 16, seamY),
                Offset(workspace.left + 2, seamY),
                Offset(workspace.left + 2, seamY),
                Offset(bounds.left - 2, bounds.top + 2),
                Offset(bounds.left + 2, bounds.top + 2),
                Offset(bounds.left + 3, bounds.top + 3),
                Offset(bounds.left - 8, bounds.top + 100),
                anchors.first.center + Offset(anchors.first.width * 1.25, 0),
                Offset(bounds.center.dx, bounds.top + 12),
                Offset(workspace.left + 8, seamY),
                Offset(bounds.left - 8, seamY),
                Offset(workspace.left / 2, seamY),
                anchors.first.center + const Offset(0, -30),
              ];
              void stable() {
                expect([
                  tester.getRect(power),
                  tester.getRect(mode),
                  tester.getRect(panel),
                ], anchors);
                expect(tester.takeException(), isNull);
              }

              Future<List<Color>> checkFrame() async {
                stable();
                final colors = await _samples(tester, points);
                for (final pair in [(2, 3), (4, 5)]) {
                  expect(
                    _difference(colors[pair.$1], colors[pair.$2]),
                    lessThanOrEqualTo(2),
                    reason: 'The workspace edge and rounded corner preserve the background.',
                  );
                }
                for (final index in [0, 1, 12]) {
                  expect(
                    _difference(colors[index], colors[8]),
                    lessThanOrEqualTo(2),
                    reason: 'The full-width field stays solid, including both outer gutters and intermediate frames.',
                  );
                }
                final textInk = tester
                    .widget<SessionUptime>(find.byType(SessionUptime))
                    .color;
                expect(
                  _contrast(textInk, colors[7]),
                  greaterThanOrEqualTo(4.5),
                );
                final button = tester.widget<FilledButton>(power);
                final states = <WidgetState>{
                  if (button.onPressed == null) WidgetState.disabled,
                };
                final style = button.style!;
                final face = Color.alphaBlend(
                  style.backgroundColor!.resolve(states)!,
                  colors[8],
                );
                expect(_difference(face, colors[13]), lessThanOrEqualTo(2));
                if (button.onPressed != null || app.busy) {
                  expect(
                    _contrast(
                      style.foregroundColor!.resolve(states)!,
                      colors[13],
                    ),
                    greaterThanOrEqualTo(4.5),
                  );
                }
                return colors;
              }

              Future<void> checkOverlay() async {
                final overlay = tester
                    .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
                      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
                    );
                final background = (await _samples(tester, [
                  points.first,
                ])).single;
                final icon =
                    overlay.value.statusBarIconBrightness == Brightness.light
                    ? Colors.white
                    : Colors.black;
                expect(_contrast(icon, background), greaterThanOrEqualTo(4.5));
              }

              final stopped = await checkFrame();
              final stoppedFace = stopped[13];
              expect(
                _contrast(stoppedFace, stopped[8]),
                greaterThanOrEqualTo(3),
              );
              expect(
                tester
                    .widget<FilledButton>(power)
                    .style!
                    .backgroundColor!
                    .resolve({})!
                    .a,
                1,
              );
              app.state = running;
              app.changed();
              List<Color>? live;
              for (final ms in [
                0,
                for (var frame = 0; frame < 20; frame++) 16,
              ]) {
                await tester.pump(Duration(milliseconds: ms));
                live = await checkFrame();
              }
              await checkOverlay();
              expect(
                _difference(live![7], palette.hero),
                lessThanOrEqualTo(2),
                reason: 'The continuous brand field must reach the activity panel, not fade to a pale halo.',
              );
              expect(
                _difference(live[6], palette.background),
                greaterThanOrEqualTo(3),
                reason:
                    'The broad glow reaches behind the rounded panel corner.',
              );
              expect(
                _difference(live[7], palette.background),
                greaterThanOrEqualTo(8),
                reason:
                    'Do not reduce the glow to a small spot around the button.',
              );
              expect(
                _difference(live[9], palette.surface),
                lessThanOrEqualTo(2),
              );
              for (final index in [8, 10, 11]) {
                expect(
                  _difference(live[index], palette.hero),
                  lessThanOrEqualTo(2),
                  reason: 'The header, power control and mode area share one solid brand field.',
                );
              }
              expect(_difference(live[12], palette.hero), lessThanOrEqualTo(2));
              final buttonStyle = tester.widget<FilledButton>(power).style!;
              final runningFace = buttonStyle.backgroundColor!.resolve({})!;
              expect(runningFace.a, 1);
              expect(_difference(live[13], stoppedFace), greaterThan(2));
              final channels = [runningFace.r, runningFace.g, runningFace.b]
                ..sort();
              expect(channels.last - channels.first, lessThan(.05));
              expect(buttonStyle.shape!.resolve({}), isA<CircleBorder>());
              expect(
                _contrast(runningFace, strongestGlow),
                greaterThanOrEqualTo(3),
              );
              expect(
                _contrast(
                  buttonStyle.foregroundColor!.resolve({})!,
                  Color.alphaBlend(
                    buttonStyle.backgroundColor!.resolve({})!,
                    strongestGlow,
                  ),
                ),
                greaterThanOrEqualTo(4.5),
              );
              for (final guideline in [
                androidTapTargetGuideline,
                labeledTapTargetGuideline,
                textContrastGuideline,
              ]) {
                await expectLater(tester, meetsGuideline(guideline));
              }
              for (final (state, ms) in [
                (const AppSnapshot(phase: 'STOPPING'), 0),
                (const AppSnapshot(phase: 'STOPPING'), 80),
                (running, 0),
                (running, 40),
                (const AppSnapshot(phase: 'STOPPED'), 0),
                (const AppSnapshot(phase: 'STOPPED'), 16),
                (const AppSnapshot(phase: 'STOPPED'), 80),
                (const AppSnapshot(phase: 'STOPPED'), 320),
              ]) {
                app.state = state;
                app.changed();
                await tester.pump(Duration(milliseconds: ms));
                await checkFrame();
                await checkOverlay();
              }
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              app.dispose();
            }
          }, semanticsEnabled: true);
        }
      }
    }
  }
}
