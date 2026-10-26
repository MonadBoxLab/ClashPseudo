import 'dart:async';

import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/features/diagnostics/logs_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/nodes_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/result_page_bar.dart';
import 'package:clash_pseudo/src/features/diagnostics/rules_page.dart';
import 'package:clash_pseudo/src/features/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../diagnostics/log_fakes.dart'
    show LogBridge, entry, logResponse, logApp;
import '../diagnostics/node_fakes.dart' as nodes show NodeBridge, page;
import '../diagnostics/rule_fakes.dart' show RuleBridge, rulePage;
import '../diagnostics/runtime_fakes.dart' show TestApp, TestBridge, core;

Future<void> _showPage(
  WidgetTester tester, {
  required Widget page,
  required String language,
  required Brightness brightness,
  BrandColor brand = BrandColor.cinnabar,
  Size windowSize = const Size(320, 900),
  TextScaler textScaler = const TextScaler.linear(2),
  EdgeInsets safeArea = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
  EdgeInsets overlayInsets = EdgeInsets.zero,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = windowSize;
  tester.view.viewPadding = FakeViewPadding(
    left: safeArea.left,
    top: safeArea.top,
    right: safeArea.right,
    bottom: safeArea.bottom,
  );
  tester.view.viewInsets = FakeViewPadding(
    left: viewInsets.left,
    top: viewInsets.top,
    right: viewInsets.right,
    bottom: viewInsets.bottom,
  );
  tester.view.padding = FakeViewPadding(
    left: (safeArea.left - viewInsets.left).clamp(0, double.infinity),
    top: (safeArea.top - viewInsets.top).clamp(0, double.infinity),
    right: (safeArea.right - viewInsets.right).clamp(0, double.infinity),
    bottom: (safeArea.bottom - viewInsets.bottom).clamp(0, double.infinity),
  );
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.forBrightness(brightness, brand),
      locale: Locale(language),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: Padding(padding: overlayInsets, child: child!),
      ),
      home: page,
    ),
  );
}

List<Rect> _rects(WidgetTester tester, List<Finder> controls) => [
  for (final control in controls) tester.getRect(control),
];

void _expectStable(
  WidgetTester tester,
  List<Finder> controls,
  List<Rect> before,
  String phase,
) {
  for (var i = 0; i < controls.length; i++) {
    expect(
      tester.getRect(controls[i]),
      before[i],
      reason: '$phase moved ${controls[i]}',
    );
  }
  expect(tester.takeException(), isNull, reason: phase);
}

Rect _menuWorkspace(BuildContext context) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final box = overlay.context.findRenderObject()! as RenderBox;
  final bounds = box.localToGlobal(Offset.zero) & box.size;
  final window = MediaQueryData.fromView(View.of(context));
  final available = (window.padding + window.viewInsets).deflateRect(
    Offset.zero & window.size,
  );
  return bounds.intersect(available);
}

Future<void> _expectAnchoredMenu(
  WidgetTester tester,
  Finder trigger, {
  required int count,
  required Object selected,
  bool? expectedBelow,
}) async {
  const tolerance = .5;
  final anchor = tester.getRect(trigger);
  final workspace = _menuWorkspace(tester.element(trigger));
  final entries = find.byType(MenuItemButton);
  final frames = <Rect>[];
  await tester.tap(trigger);
  try {
    Finder surface() {
      final surfaces = find.ancestor(
        of: entries.first,
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.type == MaterialType.canvas,
        ),
      );
      final element = surfaces.evaluate().firstWhere(
        (element) =>
            find
                .descendant(
                  of: find.byElementPredicate(
                    (candidate) => identical(candidate, element),
                  ),
                  matching: entries,
                )
                .evaluate()
                .length ==
            count,
      );
      return find.byElementPredicate(
        (candidate) => identical(candidate, element),
      );
    }

    void checkFrame() {
      expect(entries, findsNWidgets(count));
      expect(_menuWorkspace(tester.element(trigger)), workspace);
      final menu = tester.getRect(surface());
      expect(menu.left, greaterThanOrEqualTo(workspace.left - tolerance));
      expect(menu.top, greaterThanOrEqualTo(workspace.top - tolerance));
      expect(menu.right, lessThanOrEqualTo(workspace.right + tolerance));
      expect(menu.bottom, lessThanOrEqualTo(workspace.bottom + tolerance));
      expect(tester.getRect(trigger), anchor);
      expect(tester.takeException(), isNull);
      frames.add(menu);
    }

    for (final elapsed in [
      Duration.zero,
      const Duration(milliseconds: 16),
      const Duration(milliseconds: 80),
    ]) {
      await tester.pump(elapsed);
      checkFrame();
    }
    await tester.pumpAndSettle();
    checkFrame();
    final menu = frames.last;
    final roomBelow = workspace.bottom - anchor.bottom;
    final roomAbove = anchor.top - workspace.top;
    final below = menu.height <= roomBelow + tolerance;
    final above = !below && menu.height <= roomAbove + tolerance;
    if (expectedBelow != null) expect(below, expectedBelow);
    for (final frame in frames) {
      if (menu.width <= anchor.right - workspace.left + tolerance) {
        expect(frame.right, closeTo(anchor.right, tolerance));
      } else {
        expect(frame.left, closeTo(workspace.left, tolerance));
      }
      if (frame.height <= tolerance) continue;
      if (below) {
        expect(frame.top, closeTo(anchor.bottom, tolerance));
      } else if (above) {
        expect(frame.bottom, closeTo(anchor.top, tolerance));
      }
    }
    final checked = entries
        .evaluate()
        .where(
          (element) => find
              .descendant(
                of: find.byWidget(element.widget),
                matching: find.byIcon(Icons.check),
              )
              .evaluate()
              .isNotEmpty,
        )
        .toList();
    expect(checked, hasLength(1));
    expect((checked.single.widget.key as ValueKey).value, selected);
  } finally {
    if (entries.evaluate().isNotEmpty) {
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(tester.getRect(trigger), anchor);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(trigger), anchor);
      await tester.pumpAndSettle();
    }
  }
}

Future<void> _verifyResultPaging(
  WidgetTester tester, {
  required TestApp app,
  required Widget page,
  required List<Map<String, Object?>> queries,
  required List<Completer<Map<String, dynamic>>> replies,
  required Map<String, dynamic> Function(int offset, bool empty) result,
  required String language,
  required Brightness brightness,
  bool rules = false,
}) async {
  try {
    await _showPage(
      tester,
      page: page,
      language: language,
      brightness: brightness,
    );
    final strings = AppLocalizations.of(
      tester.element(find.byType(ResultPageBar)),
    );
    final previous = find.byTooltip(strings.previousPage);
    final next = find.byTooltip(strings.nextPage);
    final refresh = find.byTooltip(strings.refresh);
    final controls = [
      find.byType(TextField),
      find.byTooltip(strings.clearSearch),
      previous,
      next,
      refresh,
      find.byType(ResultPageBar),
    ];
    final before = _rects(tester, controls);
    final label = find.byKey(const ValueKey('result-page-range'));
    final zero = strings.resultCount(0);
    expect(zero, contains('0'));
    expect(zero, contains(language == 'en' ? 'results' : '结果'));
    expect(
      strings.resultRange(1, 50, 51),
      contains(language == 'en' ? 'results' : '条'),
    );

    void check(String expected, {bool back = false, bool forward = false}) {
      final unconfirmed = [
        strings.coreReadLoading,
        strings.coreReadFailed,
        strings.coreSnapshotStale,
      ].contains(expected);
      expect(tester.widget<Text>(label).data, unconfirmed ? '—' : expected);
      if (unconfirmed) {
        expect(find.textContaining(expected), findsOneWidget);
      }
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_left),
            )
            .onPressed,
        back ? isNotNull : isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_right),
            )
            .onPressed,
        forward ? isNotNull : isNull,
      );
      if (expected != zero) {
        expect(
          find.descendant(
            of: find.byType(ResultPageBar),
            matching: find.text(zero),
          ),
          findsNothing,
        );
      }
      _expectStable(tester, controls, before, expected);
    }

    Future<void> pumpReply({bool empty = false}) async {
      // The first pump can precede the rebuild scheduled by Future.timeout.
      // Check that delivery frame too, before asserting the applied result.
      for (var frame = 0; frame < 2; frame++) {
        await tester.pump();
        if (!empty) expect(tester.widget<Text>(label).data, isNot(zero));
        _expectStable(tester, controls, before, 'reply delivery frame $frame');
      }
    }

    expect(queries, hasLength(1));
    check(strings.coreReadLoading);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.coreReadLoading);
    replies.last.completeError(StateError('initial read failed'));
    await pumpReply();
    check(strings.coreReadFailed);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.coreReadFailed);

    await tester.tap(refresh);
    await tester.pump();
    expect(queries, hasLength(2));
    check(strings.coreReadLoading);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.coreReadLoading);
    replies.last.complete(result(0, false));
    await pumpReply();
    check(strings.resultRange(1, 50, 51), forward: true);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.resultRange(1, 50, 51), forward: true);

    await tester.tap(next);
    await tester.pump();
    expect(queries.last['offset'], 50);
    check(strings.coreReadLoading);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.coreReadLoading);
    replies.last.completeError(StateError('next page failed'));
    await pumpReply();
    check(strings.coreReadFailed);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.coreReadFailed);

    await tester.tap(refresh);
    await tester.pump();
    expect(queries.last['offset'], 0);
    check(strings.coreReadLoading);
    replies.last.complete(result(0, false));
    await pumpReply();
    check(strings.resultRange(1, 50, 51), forward: true);
    await tester.tap(next);
    await tester.pump();
    check(strings.coreReadLoading);
    replies.last.complete(result(50, false));
    await pumpReply();
    check(strings.resultRange(51, 51, 51), back: true);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.resultRange(51, 51, 51), back: true);
    await tester.tap(previous);
    await tester.pump();
    check(strings.coreReadLoading);
    replies.last.complete(result(0, false));
    await pumpReply();
    check(strings.resultRange(1, 50, 51), forward: true);

    if (rules) {
      await _expectAnchoredMenu(
        tester,
        find.byTooltip(strings.ruleScope),
        count: 3,
        selected: ('main', ''),
      );
      check(strings.resultRange(1, 50, 51), forward: true);
    }

    app.setForeground(false);
    await tester.pump();
    check(strings.coreSnapshotStale);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.coreSnapshotStale);
    app.setForeground(true);
    await tester.pump();
    check(strings.coreReadLoading);
    replies.last.complete(result(0, false));
    await pumpReply();
    check(strings.resultRange(1, 50, 51), forward: true);

    final readCount = queries.length;
    await tester.enterText(
      find.byType(TextField),
      'nothing matches this search',
    );
    await tester.pump();
    check(strings.coreSnapshotStale);
    await tester.pump(const Duration(milliseconds: 249));
    expect(queries, hasLength(readCount));
    check(strings.coreSnapshotStale);
    await tester.pump(const Duration(milliseconds: 1));
    expect(queries, hasLength(readCount + 1));
    expect(queries.last['offset'], 0);
    check(strings.coreReadLoading);
    replies.last.complete(result(0, true));
    await pumpReply(empty: true);
    check(zero);
    await tester.pump(const Duration(milliseconds: 16));
    check(zero);

    await tester.tap(refresh);
    await tester.pump();
    check(strings.coreReadLoading);
    replies.last.completeError(StateError('empty result refresh failed'));
    await pumpReply();
    check(strings.coreReadFailed);
    await tester.pump(const Duration(milliseconds: 16));
    check(strings.coreReadFailed);
  } finally {
    app.setForeground(false);
    await tester.pumpWidget(const SizedBox.shrink());
    for (final reply in replies) {
      if (!reply.isCompleted) reply.complete(result(0, true));
    }
    await tester.pump();
    app.dispose();
  }
}

void _expectLogsFillBody(WidgetTester tester, String phase) {
  final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
  final body = find.byWidget(scaffold.body!);
  final column = find.descendant(of: body, matching: find.byType(Column)).first;
  final children = tester.widget<Column>(column).children;
  final bodyRect = tester.getRect(body);
  final header = tester.getRect(find.byWidget(children.first));
  final reading = tester.getRect(find.byWidget(children.last));
  expect(header.top, closeTo(bodyRect.top, .5), reason: phase);
  expect(reading.top, closeTo(header.bottom, .5), reason: phase);
  expect(reading.bottom, closeTo(bodyRect.bottom, .5), reason: phase);
  expect(reading.width, closeTo(bodyRect.width, .5), reason: phase);
  expect(
    reading.height,
    closeTo(bodyRect.height - header.height, .5),
    reason: phase,
  );
  expect(reading.height, greaterThanOrEqualTo(bodyRect.height / 2 - .5));
  final strings = AppLocalizations.of(tester.element(body));
  expect(find.text(strings.coreLogsExplanation), findsNothing);
  expect(tester.takeException(), isNull, reason: phase);
}

class _EpochSettingsApp extends TestApp {
  _EpochSettingsApp() : super(TestBridge()) {
    preferencesLoaded = true;
    preferences = const AppPreferences(language: AppLanguage.en);
  }
  int epoch = 1;
  @override
  int get storageEpoch => epoch;
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(Map.of(command));
    lastCommand = Map.of(command);
    lastCommandAutomatic = automatic;
    if (command['storageEpoch'] != epoch) {
      commandErrorMessage = messages.storageUnavailable;
      notifyListeners();
      return null;
    }
    commandErrorMessage = null;
    preferences = preferences.withAppearance(
      command['field'] as String,
      command['value'] as String,
    );
    notifyListeners();
    return 'operation-${commands.length}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scene in [
    (
      name: 'safe window',
      size: const Size(480, 720),
      safe: const EdgeInsets.fromLTRB(12, 24, 16, 20),
      keyboard: EdgeInsets.zero,
      overlay: EdgeInsets.zero,
      alignment: Alignment.topRight,
      count: 3,
      below: true,
    ),
    (
      name: 'above keyboard',
      size: const Size(480, 720),
      safe: const EdgeInsets.fromLTRB(12, 24, 16, 20),
      keyboard: const EdgeInsets.only(bottom: 240),
      overlay: EdgeInsets.zero,
      alignment: Alignment.bottomRight,
      count: 3,
      below: false,
    ),
    (
      name: 'offset overlay',
      size: const Size(640, 900),
      safe: const EdgeInsets.fromLTRB(12, 24, 16, 64),
      keyboard: EdgeInsets.zero,
      overlay: const EdgeInsets.fromLTRB(40, 60, 40, 200),
      alignment: Alignment.topRight,
      count: 3,
      below: true,
    ),
    (
      name: 'scroll above keyboard',
      size: const Size(480, 720),
      safe: const EdgeInsets.fromLTRB(12, 24, 16, 20),
      keyboard: const EdgeInsets.only(bottom: 280),
      overlay: EdgeInsets.zero,
      alignment: Alignment.topRight,
      count: 12,
      below: null,
    ),
  ]) {
    testWidgets('menu uses its actual overlay workspace: ${scene.name}', (
      tester,
    ) async {
      await _showPage(
        tester,
        page: Scaffold(
          body: SafeArea(
            child: Align(
              alignment: scene.alignment,
              child: ChoiceMenuButton<int>(
                options: {for (var i = 0; i < scene.count; i++) i: 'Option $i'},
                value: 0,
                onSelected: (_) =>
                    fail('Opening and closing must not select an option'),
                child: const SizedBox(
                  width: 220,
                  height: 48,
                  child: Text('Open menu'),
                ),
              ),
            ),
          ),
        ),
        language: 'en',
        brightness: Brightness.light,
        windowSize: scene.size,
        textScaler: const TextScaler.linear(1.3),
        safeArea: scene.safe,
        viewInsets: scene.keyboard,
        overlayInsets: scene.overlay,
      );
      await tester.pumpAndSettle();
      await _expectAnchoredMenu(
        tester,
        find.byType(ChoiceMenuButton<int>),
        count: scene.count,
        selected: 0,
        expectedBelow: scene.below,
      );
    });
  }

  testWidgets(
    'old rendered preference callback cannot borrow a new epoch before the next frame',
    (tester) async {
      final app = _EpochSettingsApp();
      try {
        await _showPage(
          tester,
          page: SettingsPage(app: app),
          language: 'en',
          brightness: Brightness.light,
        );
        final trigger = find.ancestor(
          of: find.byIcon(Icons.translate_rounded),
          matching: find.byType(ChoiceMenuButton<String>),
        );
        await tester.ensureVisible(trigger);
        await tester.pumpAndSettle();
        final old = tester.widget<ChoiceMenuButton<String>>(trigger);
        app.epoch = 2;
        app.preferences = const AppPreferences(language: AppLanguage.zh);
        app.publish(app.state);
        old.onSelected('zh');
        expect(app.commands.single['storageEpoch'], 1);
        expect(app.commandErrorMessage, messages.storageUnavailable);
        expect(app.preferences.language, AppLanguage.zh);
        await tester.pumpAndSettle();
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      }
    },
  );

  testWidgets(
    'an already open preference menu cannot acquire the restored epoch on rebuild',
    (tester) async {
      final app = _EpochSettingsApp();
      try {
        await _showPage(
          tester,
          page: OperationFeedback(
            controller: app,
            child: SettingsPage(app: app),
          ),
          language: 'en',
          brightness: Brightness.light,
        );
        final trigger = find.ancestor(
          of: find.byIcon(Icons.translate_rounded),
          matching: find.byType(ChoiceMenuButton<String>),
        );
        await tester.ensureVisible(trigger);
        await tester.pumpAndSettle();
        final anchor = tester.getRect(trigger);
        expect(app.canChangePreferences, isTrue);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(3));
        final chinese = find.byWidgetPredicate(
          (widget) =>
              widget is MenuItemButton && widget.key == const ValueKey('zh'),
        );
        final oldSelection = tester.widget<MenuItemButton>(chinese).onPressed!;
        expect(find.text('中文'), findsOneWidget);
        app.epoch = 2;
        app.preferences = const AppPreferences(language: AppLanguage.zh);
        app.publish(app.state);
        for (final elapsed in [
          Duration.zero,
          const Duration(milliseconds: 16),
          const Duration(milliseconds: 80),
        ]) {
          await tester.pump(elapsed);
          expect(tester.getRect(trigger), anchor);
        }
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        oldSelection();
        await tester.pumpAndSettle();
        expect(app.commands, isEmpty);
        expect(app.preferences.language, AppLanguage.zh);
        expect(tester.getRect(trigger), anchor);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        final english = find.byWidgetPredicate(
          (widget) =>
              widget is MenuItemButton && widget.key == const ValueKey('en'),
        );
        await tester.ensureVisible(english);
        await tester.pumpAndSettle();
        await tester.tap(english);
        await tester.pumpAndSettle();
        expect(app.commands.last, {
          'action': 'setPreference',
          'field': 'language',
          'value': 'en',
          'storageEpoch': 2,
        });
        expect(app.preferences.language, AppLanguage.en);
        expect(tester.getRect(trigger), anchor);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
      }
    },
  );

  for (final language in ['zh', 'en']) {
    for (final brightness in Brightness.values) {
      for (final brand in BrandColor.values) {
        testWidgets(
          'settings categories retain semantic colors at 320/2x $language $brightness $brand',
          (tester) async {
            final app = TestApp(TestBridge())
              ..preferencesLoaded = true
              ..preferences = AppPreferences(brand: brand);
            try {
              await _showPage(
                tester,
                page: SettingsPage(app: app),
                language: language,
                brightness: brightness,
                brand: brand,
              );
              final palette = SettingsPalette(brightness == Brightness.dark);
              expect({
                palette.appearance,
                palette.language,
                palette.configuration,
                palette.network,
                palette.extension,
                palette.diagnostics,
              }, hasLength(6));
              expect(
                tester
                    .widget<Icon>(find.byIcon(Icons.brightness_6_outlined))
                    .color,
                palette.appearance,
              );
              expect(
                tester.widget<Icon>(find.byIcon(Icons.translate_rounded)).color,
                palette.language,
              );
              expect(
                tester.widget<Icon>(find.byIcon(Icons.palette_outlined)).color,
                AppTheme.forBrightness(brightness, brand).colorScheme.primary,
              );
              final roles = {
                Icons.restart_alt: palette.network,
                Icons.description_outlined: palette.configuration,
                Icons.extension_outlined: palette.extension,
                Icons.data_object: palette.configuration,
                Icons.dns_outlined: palette.network,
                Icons.account_tree_outlined: palette.network,
                Icons.rule_outlined: palette.configuration,
                Icons.cloud_download_outlined: palette.network,
                Icons.swap_vert_rounded: palette.network,
                Icons.manage_search_outlined: palette.network,
                Icons.receipt_long_outlined: palette.diagnostics,
                Icons.folder_open_outlined: HomePalette.of(
                  tester.element(find.byType(SettingsPage)),
                ).localSource,
                Icons.save_alt: HomePalette.of(
                  tester.element(find.byType(SettingsPage)),
                ).syncAction,
                Icons.apps_outlined: palette.diagnostics,
                Icons.shield_outlined: palette.network,
                Icons.info_outline: palette.configuration,
              };
              final scrollable = find
                  .descendant(
                    of: find.byType(SettingsPage),
                    matching: find.byType(Scrollable),
                  )
                  .first;
              for (final role in roles.entries) {
                final icon = find.byIcon(role.key);
                await tester.scrollUntilVisible(
                  icon,
                  180,
                  scrollable: scrollable,
                );
                await tester.pumpAndSettle();
                expect(
                  tester.widget<Icon>(icon).color,
                  role.value,
                  reason: '$brand must not recolor the ${role.key} category',
                );
                expect(tester.takeException(), isNull);
              }
              expect(app.commands, isEmpty);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              app.dispose();
            }
          },
        );
      }

      testWidgets(
        'selected settings menus remain anchored within the workspace at 320/2x $language $brightness',
        (tester) async {
          final app = TestApp(TestBridge())
            ..preferencesLoaded = false
            ..preferences = const AppPreferences(
              appearance: AppAppearance.dark,
              brand: BrandColor.cobalt,
              language: AppLanguage.en,
            );
          try {
            await _showPage(
              tester,
              page: SettingsPage(app: app),
              language: language,
              brightness: brightness,
              brand: BrandColor.cobalt,
            );
            final choices = {
              Icons.brightness_6_outlined: 'dark',
              Icons.palette_outlined: 'cobalt',
              Icons.translate_rounded: 'en',
            };
            final triggers = [
              for (final icon in choices.keys)
                find.ancestor(
                  of: find.byIcon(icon),
                  matching: find.byType(ChoiceMenuButton<String>),
                ),
            ];
            final before = _rects(tester, triggers);
            for (final trigger in triggers) {
              expect(
                tester.widget<ChoiceMenuButton<String>>(trigger).enabled,
                isFalse,
              );
            }
            await tester.tap(triggers.first);
            await tester.pump();
            expect(
              find.byWidgetPredicate((widget) => widget is MenuItemButton),
              findsNothing,
            );
            _expectStable(tester, triggers, before, 'preferences not ready');
            app.preferencesLoaded = true;
            app.publish(app.state);
            await tester.pump();
            _expectStable(tester, triggers, before, 'preferences become ready');
            await tester.pump(const Duration(milliseconds: 16));
            _expectStable(
              tester,
              triggers,
              before,
              'enabled intermediate frame',
            );
            for (final trigger in triggers) {
              expect(
                tester.widget<ChoiceMenuButton<String>>(trigger).enabled,
                isTrue,
              );
            }
            for (final choice in choices.entries) {
              await _expectAnchoredMenu(
                tester,
                find.ancestor(
                  of: find.byIcon(choice.key),
                  matching: find.byType(ChoiceMenuButton<String>),
                ),
                count: 3,
                selected: choice.value,
              );
            }
            expect(app.commands, isEmpty);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            app.dispose();
          }
        },
      );

      testWidgets(
        'rules distinguish results from pending and failed reads without moving controls at 320/2x $language $brightness',
        (tester) async {
          final bridge = RuleBridge();
          final app = TestApp(bridge);
          await _verifyResultPaging(
            tester,
            app: app,
            page: RulesPage(app: app),
            queries: bridge.queries,
            replies: bridge.replies,
            result: (offset, empty) =>
                rulePage(offset: offset, total: empty ? 0 : 51),
            language: language,
            brightness: brightness,
            rules: true,
          );
        },
      );

      testWidgets(
        'nodes distinguish results from pending and failed reads without moving controls at 320/2x $language $brightness',
        (tester) async {
          final bridge = nodes.NodeBridge();
          final app = TestApp(bridge);
          await _verifyResultPaging(
            tester,
            app: app,
            page: NodesPage(app: app),
            queries: bridge.queries,
            replies: bridge.replies,
            result: (offset, empty) {
              final value = nodes.page(offset: offset);
              if (empty) {
                value['page'] = {
                  ...value['page'] as Map,
                  'nodes': <Map<String, dynamic>>[],
                  'total': 0,
                  'nextOffset': -1,
                };
              }
              return value;
            },
            language: language,
            brightness: brightness,
          );
        },
      );

      testWidgets(
        'logs fill the remaining reading height through intermediate frames at 320/2x $language $brightness',
        (tester) async {
          final bridge = LogBridge();
          final app = logApp(bridge);
          try {
            await _showPage(
              tester,
              page: CoreLogsPage(app: app),
              language: language,
              brightness: brightness,
            );
            final strings = AppLocalizations.of(
              tester.element(find.byType(CoreLogsPage)),
            );
            final refresh = find.byTooltip(strings.refresh);
            final controls = [
              find.byType(TextField),
              find.byTooltip(strings.clearSearch),
              find.byTooltip(strings.logLevel),
              find.byTooltip(strings.logClearLocal),
              find.byTooltip(strings.logBackToLatest),
              refresh,
            ];
            final before = _rects(tester, controls);
            void check(String phase) {
              _expectLogsFillBody(tester, phase);
              _expectStable(tester, controls, before, phase);
            }

            Future<void> pumpReply(String phase) async {
              for (var frame = 0; frame < 2; frame++) {
                await tester.pump();
                check('$phase delivery frame $frame');
              }
            }

            check('initial loading');
            await tester.pump(const Duration(milliseconds: 16));
            check('waiting frame');
            bridge.replies.single.completeError(
              StateError('initial logs failed'),
            );
            await pumpReply('initial failure');
            expect(find.textContaining(strings.coreReadFailed), findsOneWidget);
            await tester.tap(refresh);
            await tester.pump();
            check('retry loading');
            bridge.replies.last.complete(
              logResponse(
                core(1),
                entries: [
                  for (var i = 1; i <= 20; i++)
                    entry(
                      i,
                      'info',
                      language == 'zh'
                          ? '会话日志 $i：这是一条需要在窄屏大字号下换行的日志内容。'
                          : 'Session log $i: a long entry wraps on a narrow screen with large text.',
                    ),
                ],
                total: 20,
                next: 20,
              ),
            );
            await pumpReply('populated response');
            await tester.pump(const Duration(milliseconds: 16));
            check('populated settled frame');
            expect(find.byType(CustomScrollView), findsOneWidget);
            await _expectAnchoredMenu(
              tester,
              find.byTooltip(strings.logLevel),
              count: 4,
              selected: 'info',
            );
            check('level menu dismissed');

            await tester.pump(const Duration(milliseconds: 610));
            expect(bridge.replies.last.isCompleted, isFalse);
            check('poll waiting');
            bridge.replies.last.completeError(StateError('poll failed'));
            await pumpReply('poll failure retains the reading area');
            await tester.tap(refresh);
            await tester.pump();
            check('retry clears data without shrinking the reading area');
            bridge.replies.last.complete(
              logResponse(
                core(1),
                entries: [entry(21, 'info', 'Recovered session log')],
                total: 21,
                next: 21,
              ),
            );
            await pumpReply('recovered');
            app.setForeground(false);
            await tester.pump();
            check('foreground context invalidated');
            app.setForeground(true);
            await tester.pump();
            check('foreground recovery waits for its own response');
            bridge.replies.last.complete(
              logResponse(core(1), total: 21, next: 21),
            );
            await pumpReply('foreground recovery');
            await tester.enterText(find.byType(TextField), 'no-matching-entry');
            await tester.pump();
            check('empty local filter');
            expect(find.text(strings.noSearchResults), findsOneWidget);
            tester.view.viewInsets = const FakeViewPadding(bottom: 300);
            await tester.pump(const Duration(milliseconds: 16));
            check('keyboard reduces the available body');
            await tester.tap(find.byTooltip(strings.clearSearch));
            await tester.pump();
            check('clear filter with keyboard visible');
            await tester.tap(find.byTooltip(strings.logClearLocal));
            await tester.pump();
            check('local clear with keyboard visible');
          } finally {
            app.setForeground(false);
            await tester.pumpWidget(const SizedBox.shrink());
            for (final reply in bridge.replies) {
              if (!reply.isCompleted) reply.complete(logResponse(core(1)));
            }
            await tester.pump();
            app.dispose();
          }
        },
      );
    }
  }
}
