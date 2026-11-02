import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/ui/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import '../../support/strategy_fakes.dart';

class _EpochApp extends StrategyAppFake {
  _EpochApp(super.bridge);
  int epoch = 0;
  @override
  int get storageEpoch => epoch;
}

StrategySnapshot _data({
  TunnelMode mode = TunnelMode.rule,
  bool referenced = false,
  List<StrategyGroup>? groups,
}) => StrategySnapshot(
  generation: previewCore.generation,
  configId: previewCore.configId!,
  revision: previewCore.revision!,
  purpose: previewCore.purpose!,
  composition: previewCore.composition,
  mode: mode,
  globalReferenced: referenced,
  unrestored: {},
  groups:
      groups ??
      [
        StrategyGroup(
          name: 'Alpha',
          rawType: 'select',
          hidden: false,
          now: 'needle-member',
          fixed: '',
          members: const [
            StrategyMember(name: 'needle-member', type: 'Socks5'),
          ],
        ),
        StrategyGroup(
          name: 'Beta',
          rawType: 'url-test',
          hidden: false,
          now: 'Alpha',
          fixed: '',
          members: const [StrategyMember(name: 'Alpha', type: 'Selector')],
        ),
        StrategyGroup(
          name: 'Hidden Alpha',
          rawType: 'select',
          hidden: true,
          now: 'needle-member',
          fixed: '',
          members: const [
            StrategyMember(name: 'needle-member', type: 'Socks5'),
          ],
        ),
        StrategyGroup(
          name: 'GLOBAL',
          rawType: 'select',
          hidden: false,
          now: 'Alpha',
          fixed: '',
          members: const [StrategyMember(name: 'Alpha', type: 'Selector')],
        ),
      ],
);

Future<(StrategyAppFake, StrategyController, StrategyBridgeFake)> _show(
  WidgetTester tester, {
  TunnelMode mode = TunnelMode.rule,
  bool referenced = false,
  String language = 'en',
  TextScaler? textScaler,
  Size size = const Size(700, 900),
  bool dark = false,
  BrandColor brand = BrandColor.cinnabar,
  ValueNotifier<bool>? active,
  StrategySnapshot? data,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final bridge = StrategyBridgeFake()
    ..data = data ?? _data(mode: mode, referenced: referenced);
  final app = _EpochApp(bridge)
    ..preferencesLoaded = true
    ..overridesLoaded = true;
  final controller = StrategyController(app);
  addTearDown(() {
    controller.dispose();
    app.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.forBrightness(
        dark ? Brightness.dark : Brightness.light,
        brand,
      ),
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: textScaler ?? TextScaler.noScaling),
        child: child!,
      ),
      home: active == null
          ? StrategiesPage(controller: controller, active: true)
          : ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (context, visible, _) =>
                  StrategiesPage(controller: controller, active: visible),
            ),
    ),
  );
  await tester.pumpAndSettle();
  return (app, controller, bridge);
}

Finder _group(String name) => find.byKey(ValueKey('strategy-group-$name'));

Finder _button(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

void main() {
  for (final language in ['en', 'zh']) {
    for (final (scale, scaler) in [
      ('1.0', TextScaler.linear(1)),
      ('1.3', TextScaler.linear(1.3)),
      ('2.0', TextScaler.linear(2)),
      ('nonlinear', const NonlinearTextScaler()),
    ]) {
      for (final width in [280.0, 320.0, 700.0, 1704.0]) {
        for (final brand in BrandColor.values) {
          for (final dark in [false, true]) {
            testWidgets(
              'search toolbar stays stable and legible $language/$scale/$width/$brand/$dark',
              (tester) async {
                final (_, controller, _) = await _show(
                  tester,
                  language: language,
                  textScaler: scaler,
                  size: Size(width, 1000),
                  brand: brand,
                  dark: dark,
                );
                try {
                  final strings = lookupAppLocalizations(Locale(language));
                  final title = tester.renderObject<RenderParagraph>(
                    find.text(strings.strategyGroups),
                  );
                  expect(
                    title.size.height,
                    greaterThanOrEqualTo(
                      title.getMaxIntrinsicHeight(double.infinity) - .01,
                    ),
                  );
                  final toolbar = tester.getRect(find.byType(AppBar));
                  final card = tester.getRect(_group('Alpha'));
                  await tester.tap(find.byTooltip(strings.searchStrategies));
                  for (final ms in [0, 16, 80, 200]) {
                    await tester.pump(Duration(milliseconds: ms));
                    expect(tester.getRect(find.byType(AppBar)), toolbar);
                    expect(tester.getRect(_group('Alpha')), card);
                    expect(find.byType(TextField), findsOneWidget);
                    expect(find.byType(EditableText), findsOneWidget);
                    expect(tester.takeException(), isNull);
                  }
                  expect(
                    tester
                        .widget<TextField>(find.byType(TextField))
                        .decoration!
                        .hintText,
                    strings.searchStrategies,
                  );
                  final editable = tester
                      .state<EditableTextState>(find.byType(EditableText))
                      .renderEditable;
                  expect(
                    editable.size.height,
                    greaterThanOrEqualTo(editable.preferredLineHeight),
                  );
                  expect(
                    tester.getCenter(find.byType(EditableText)).dy,
                    closeTo(tester.getCenter(find.byType(TextField)).dy, .01),
                  );
                  for (final guideline in [
                    androidTapTargetGuideline,
                    labeledTapTargetGuideline,
                    textContrastGuideline,
                  ]) {
                    await expectLater(tester, meetsGuideline(guideline));
                  }
                  await tester.enterText(find.byType(TextField), 'Alpha');
                  await tester.pump();
                  expect(
                    tester.getCenter(find.byType(EditableText)).dy,
                    closeTo(tester.getCenter(find.byType(TextField)).dy, .01),
                  );
                  expect(
                    editable
                        .getLocalRectForCaret(const TextPosition(offset: 5))
                        .height,
                    lessThanOrEqualTo(editable.preferredLineHeight + .01),
                  );
                  await tester.tap(find.byTooltip(strings.clearSearch));
                  await tester.pump();
                  await tester.tap(find.byTooltip(strings.exitSearch));
                  for (final ms in [0, 16, 80, 200]) {
                    await tester.pump(Duration(milliseconds: ms));
                    expect(tester.getRect(find.byType(AppBar)), toolbar);
                    expect(tester.getRect(_group('Alpha')), card);
                    expect(find.byType(EditableText), findsNothing);
                    expect(tester.takeException(), isNull);
                  }
                } finally {
                  controller.setVisible(false);
                  await tester.pumpWidget(const SizedBox.shrink());
                }
              },
              semanticsEnabled: true,
            );
          }
        }
      }
    }
  }

  for (final (mode, referenced, visible) in [
    (TunnelMode.rule, false, false),
    (TunnelMode.rule, true, true),
    (TunnelMode.global, false, true),
    (TunnelMode.direct, true, false),
  ]) {
    testWidgets('search respects GLOBAL visibility $mode/$referenced', (
      tester,
    ) async {
      final (_, controller, _) = await _show(
        tester,
        mode: mode,
        referenced: referenced,
      );
      try {
        await tester.tap(find.byTooltip('Search strategies'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'global');
        await tester.pump();
        expect(_group('GLOBAL'), visible ? findsOneWidget : findsNothing);
        expect(_group('Alpha'), findsNothing);
      } finally {
        controller.setVisible(false);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  testWidgets('search combines the hidden toggle with the same name query', (
    tester,
  ) async {
    final (_, controller, _) = await _show(tester);
    try {
      await tester.tap(find.byTooltip('Search strategies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pump();
      expect(_group('Hidden Alpha'), findsNothing);
      await tester.tap(find.byTooltip('Show hidden groups'));
      await tester.pump();
      expect(_group('Hidden Alpha'), findsOneWidget);
      expect(_group('Alpha'), findsOneWidget);
      expect(_group('Beta'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Alpha',
      );
      await tester.tap(find.byTooltip('Hide hidden groups'));
      await tester.pump();
      expect(_group('Hidden Alpha'), findsNothing);
    } finally {
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'X reads current raw input and retired search callbacks stay retired',
    (tester) async {
      final (_, controller, _) = await _show(tester);
      try {
        await tester.tap(find.byTooltip('Search strategies'));
        await tester.pumpAndSettle();
        final exit = tester.widget<IconButton>(_button('Exit search'));
        const value = TextEditingValue(
          text: 'Alpha',
          selection: TextSelection.collapsed(offset: 5),
          composing: TextRange(start: 0, end: 5),
        );
        tester.testTextInput.updateEditingValue(value);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.value,
          value,
        );
        exit.onPressed!();
        await tester.pump();
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.tap(find.byTooltip('Exit search'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Search strategies'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Beta');
        await tester.pump();
        exit.onPressed!();
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Beta',
        );
        expect(_group('Beta'), findsOneWidget);
      } finally {
        controller.setVisible(false);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'hidden and background pages retire focus without losing their query',
    (tester) async {
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final (app, controller, _) = await _show(tester, active: active);
      try {
        await tester.tap(find.byTooltip('Search strategies'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Alpha');
        await tester.pump();
        final old = tester.widget<IconButton>(_button('Clear search'));
        final bar = tester.widget<TextField>(find.byType(TextField));
        expect(bar.focusNode!.hasFocus, isTrue);
        active.value = false;
        await tester.pump();
        expect(bar.focusNode!.hasFocus, isFalse);
        expect(bar.focusNode!.canRequestFocus, isFalse);
        old.onPressed!();
        active.value = true;
        await tester.pumpAndSettle();
        expect(bar.controller!.text, 'Alpha');
        expect(bar.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.tap(find.byType(TextField));
        await tester.pump();
        final beforeBackground = tester.widget<IconButton>(
          _button('Clear search'),
        );
        app.setForeground(false);
        await tester.pump();
        expect(bar.focusNode!.hasFocus, isFalse);
        expect(bar.focusNode!.canRequestFocus, isFalse);
        beforeBackground.onPressed!();
        app.setForeground(true);
        await tester.pumpAndSettle();
        beforeBackground.onPressed!();
        expect(bar.controller!.text, 'Alpha');
        expect(bar.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
      } finally {
        controller.setVisible(false);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('restoration epoch rejects old toolbar callbacks', (
    tester,
  ) async {
    final (app, controller, _) = await _show(tester);
    try {
      await tester.tap(find.byTooltip('Search strategies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pump();
      final old = tester.widget<IconButton>(_button('Clear search'));
      (app as _EpochApp).epoch++;
      app.changed();
      await tester.pump();
      old.onPressed!();
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Alpha',
      );
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    } finally {
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('floating keyboard back retires focus before closing search', (
    tester,
  ) async {
    final (_, controller, _) = await _show(tester);
    try {
      await tester.tap(find.byTooltip('Search strategies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Alpha');
      await tester.pump();
      expect(tester.view.viewInsets.bottom, 0);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Alpha');
      expect(field.focusNode!.hasFocus, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(StrategiesPage), findsOneWidget);
    } finally {
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'native docked keyboard dismissal does not require a third back',
    (tester) async {
      final (_, controller, _) = await _show(tester);
      try {
        await tester.tap(find.byTooltip('Search strategies'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Alpha');
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pump();
        tester.view.resetViewInsets();
        await tester.pump();
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, 'Alpha');
        expect(field.focusNode!.hasFocus, isFalse);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
      } finally {
        controller.setVisible(false);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('window resize with keyboard insets preserves the search focus', (
    tester,
  ) async {
    final (_, controller, _) = await _show(tester);
    try {
      await tester.tap(find.byTooltip('Search strategies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Alpha');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump();
      tester.view.physicalSize = const Size(800, 900);
      tester.view.resetViewInsets();
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'Alpha');
      expect(field.focusNode!.hasFocus, isTrue);
    } finally {
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('back dismisses the keyboard before closing search', (
    tester,
  ) async {
    final (_, controller, _) = await _show(tester);
    try {
      await tester.tap(find.byTooltip('Search strategies'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Alpha');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Alpha',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(StrategiesPage), findsOneWidget);
    } finally {
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'member popup returns to the same search without reopening its keyboard',
    (tester) async {
      final (_, controller, _) = await _show(tester);
      try {
        await tester.tap(find.byTooltip('Search strategies'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Alpha');
        await tester.pump();
        await tester.tap(_group('Alpha'));
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isFalse);
        final popup = find.byKey(const ValueKey('strategy-reveal-Alpha'));
        expect(popup, findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(popup, findsNothing);
        final search = tester.widget<TextField>(find.byType(TextField));
        expect(search.controller!.text, 'Alpha');
        expect(search.focusNode!.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(_group('Alpha'), findsOneWidget);
        expect(_group('Beta'), findsNothing);
      } finally {
        controller.setVisible(false);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'effective query and data refresh preserve reading; a changed query returns to top',
    (tester) async {
      final definitions = [
        for (var i = 0; i < 200; i++)
          StrategyGroup(
            name: 'Alpha ${i.toString().padLeft(3, '0')}',
            rawType: 'select',
            hidden: false,
            now: 'needle-member',
            fixed: '',
            members: const [
              StrategyMember(name: 'needle-member', type: 'Direct'),
            ],
          ),
      ];
      final (_, controller, bridge) = await _show(
        tester,
        data: _data(groups: definitions),
      );
      try {
        await tester.tap(find.byTooltip('Search strategies'));
        await tester.pumpAndSettle();
        final field = find.byType(TextField);
        await tester.enterText(field, 'alpha');
        await tester.pump();
        final viewportFinder = find.byKey(
          const PageStorageKey('strategies-scroll'),
        );
        final scrolling = find
            .descendant(of: viewportFinder, matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(scrolling).position;
        position.jumpTo(2800);
        await tester.pump();
        final viewport = tester.getRect(viewportFinder);
        final visible =
            find
                .byWidgetPredicate(
                  (widget) =>
                      widget is InkWell &&
                      widget.key is ValueKey<String> &&
                      (widget.key! as ValueKey<String>).value.startsWith(
                        'strategy-group-',
                      ),
                )
                .evaluate()
                .map(
                  (element) => (
                    element.widget.key!,
                    tester.getRect(find.byWidget(element.widget)),
                  ),
                )
                .where(
                  (row) =>
                      row.$2.top >= viewport.top &&
                      row.$2.bottom <= viewport.bottom,
                )
                .toList()
              ..sort((a, b) => a.$2.top.compareTo(b.$2.top));
        expect(visible, isNotEmpty);
        final anchor = find.byKey(visible.first.$1);
        final before = tester.getRect(anchor);
        final pixels = position.pixels;
        await tester.enterText(field, '  ALPHA  ');
        for (final ms in [0, 16, 80]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(
            tester.state<ScrollableState>(scrolling).position,
            same(position),
          );
          expect(position.pixels, pixels);
          expect(tester.getRect(anchor), before);
        }
        bridge.data = _data(
          groups: [
            StrategyGroup(
              name: 'Alpha inserted',
              rawType: 'select',
              hidden: false,
              now: 'needle-member',
              fixed: '',
              members: const [
                StrategyMember(name: 'needle-member', type: 'Direct'),
              ],
            ),
            ...definitions,
          ],
        );
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(tester.getRect(anchor).top, closeTo(before.top, .01));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '  ALPHA  ',
        );
        await tester.enterText(field, 'Alpha 01');
        await tester.pump();
        expect(position.pixels, 0);
        expect(_group('Alpha 010'), findsOneWidget);
        expect(_group('Alpha inserted'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        controller.setVisible(false);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'parent group search matches names, not types or nested members',
    (tester) async {
      final (app, controller, bridge) = await _show(tester);
      expect(_group('Alpha'), findsOneWidget);
      expect(_group('Beta'), findsOneWidget);
      final reads = bridge.reads;
      final search = find.byTooltip('Search strategies');
      expect(search, findsOneWidget);
      await tester.tap(search);
      for (final ms in [0, 16, 80, 200]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(find.byType(TextField), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      final field = find.byType(TextField);
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
        'Search strategies',
      );
      await tester.enterText(field, 'aLpHa');
      await tester.pump();
      expect(_group('Alpha'), findsOneWidget);
      expect(_group('Beta'), findsNothing);
      expect(_group('Hidden Alpha'), findsNothing);
      for (final query in ['select', 'url-test', 'needle-member']) {
        await tester.enterText(field, query);
        await tester.pump();
        expect(_group('Alpha'), findsNothing);
        expect(_group('Beta'), findsNothing);
        expect(find.text('No matching strategy groups'), findsOneWidget);
      }
      expect(bridge.reads, reads);
      expect(app.commands, isEmpty);
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('parent group search clears raw input before exiting', (
    tester,
  ) async {
    final (_, controller, _) = await _show(tester);
    await tester.tap(find.byTooltip('Search strategies'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.enterText(field, '   ');
    await tester.pump();
    expect(_group('Alpha'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    final search = tester.widget<TextField>(find.byType(TextField));
    expect(search.controller!.text, isEmpty);
    expect(search.focusNode!.hasFocus, isTrue);
    await tester.tap(find.byTooltip('Exit search'));
    for (final ms in [0, 16, 80, 200]) {
      await tester.pump(Duration(milliseconds: ms));
      expect(find.byType(TextField), findsNothing);
    }
    expect(find.byTooltip('Search strategies'), findsOneWidget);
    controller.setVisible(false);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
