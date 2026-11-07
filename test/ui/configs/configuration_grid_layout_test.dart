import 'dart:ui' show SemanticsAction, Tristate;

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/configs/configs_page.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/ui/overrides/overrides_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

class _GridApp extends AppController {
  _GridApp() : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    overridesLoaded = true;
    preferencesLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }
  void changed() => notifyListeners();
}

ConfigEntry _config(int i) => ConfigEntry(
  id: 'entry-$i',
  name: 'Entry $i — 本地配置',
  kind: ConfigKind.local,
  revision: 1,
  body: 'rules: []',
);
OverrideEntry _plugin(int i) => OverrideEntry(
  id: 'entry-$i',
  name: 'Entry $i — 本地插件',
  kind: ConfigKind.local,
  revision: 1,
  body: '{}',
  enabled: i.isEven,
);

Future<void> _show(
  WidgetTester tester,
  _GridApp app,
  bool plugins, {
  String language = 'en',
  TextScaler scaler = TextScaler.noScaling,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1704, 1136);
  addTearDown(tester.view.reset);
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
      home: OperationNoticeHost(
        child: plugins ? OverridesPage(app: app) : ConfigsPage(controller: app),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['en', 'zh']) {
    testWidgets(
      'configuration selection and runtime state are presented separately $language',
      (tester) async {
        final app = _GridApp()
          ..collection = ConfigCollection(
            entries: [_config(0), _config(1)],
            selectedId: 'entry-0',
          )
          ..state = const AppSnapshot(
            phase: 'RUNNING',
            configId: 'entry-1',
            revision: 0,
          );
        try {
          await _show(tester, app, false, language: language);
          final strings = AppLocalizations.of(
            tester.element(find.byType(ConfigsPage)),
          );
          final first = find.byKey(const ValueKey('config-entry-0'));
          final second = find.byKey(const ValueKey('config-entry-1'));
          expect(
            tester.widget<Text>(find.text(_config(0).name)).style!.fontWeight,
            FontWeight.w700,
          );
          expect(
            tester.widget<Text>(find.text(_config(1).name)).style!.fontWeight,
            FontWeight.w400,
          );
          expect(
            find.text(language == 'en' ? 'Selected' : '已选择'),
            findsNothing,
          );
          expect(
            find.descendant(
              of: first,
              matching: find.textContaining(strings.runningOldBody),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: second,
              matching: find.textContaining(strings.runningOldBody),
            ),
            findsOneWidget,
          );
          app.collection = ConfigCollection(
            entries: [_config(0), _config(1)],
            selectedId: 'entry-1',
          );
          app.changed();
          await tester.pumpAndSettle();
          expect(
            tester.widget<Text>(find.text(_config(0).name)).style!.fontWeight,
            FontWeight.w400,
          );
          expect(
            tester.widget<Text>(find.text(_config(1).name)).style!.fontWeight,
            FontWeight.w700,
          );
          expect(find.textContaining(strings.runningOldBody), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
        }
      },
    );
  }
  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets(
        'configuration empty state aligns with the content centerline $language/$scale',
        (tester) async {
          final app = _GridApp();
          try {
            await _show(
              tester,
              app,
              false,
              language: language,
              scaler: TextScaler.linear(scale),
            );
            final strings = AppLocalizations.of(
              tester.element(find.byType(ConfigsPage)),
            );
            for (final width in [320.0, 360.0, 411.0, 480.0, 1200.0]) {
              tester.view.physicalSize = Size(width, 1136);
              await tester.pumpAndSettle();
              for (final target in [
                find.byIcon(Icons.description_outlined),
                find.text(strings.noSavedConfigs),
                find.text(strings.importOrCreateHint),
                find.widgetWithText(FilledButton, strings.addConfig),
              ]) {
                final rect = tester.getRect(target);
                expect(rect.center.dx, closeTo(width / 2, .01));
                expect(rect.left, greaterThanOrEqualTo(20 - .01));
                expect(rect.right, lessThanOrEqualTo(width - 20 + .01));
              }
              expect(
                tester
                    .widget<Text>(find.text(strings.importOrCreateHint))
                    .textAlign,
                TextAlign.center,
              );
              final button = find.widgetWithText(
                FilledButton,
                strings.addConfig,
              );
              await tester.ensureVisible(button);
              await tester.tap(button);
              await tester.pumpAndSettle();
              expect(find.text(strings.importFromFile), findsOneWidget);
              await tester.binding.handlePopRoute();
              await tester.pumpAndSettle();
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
  for (final language in ['en', 'zh']) {
    testWidgets(
      'configs chained visual anchors rebase live content without restarting projection $language',
      (tester) async {
        final app = _GridApp()
          ..collection = ConfigCollection(
            entries: [for (var i = 0; i < 4096; i++) _config(i)],
            selectedId: 'entry-0',
          );
        try {
          await _show(
            tester,
            app,
            false,
            language: language,
            scaler: const TextScaler.linear(1.3),
          );
          final cards = find.byWidgetPredicate(
            (widget) =>
                widget is Card &&
                widget.key is ValueKey<String> &&
                (widget.key as ValueKey<String>).value.startsWith(
                  'config-entry-',
                ),
          );
          final viewport = find.byType(CustomScrollView);
          final scroll = tester.state<ScrollableState>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          );
          final position = scroll.position;
          position.jumpTo(2400);
          await tester.pumpAndSettle();
          (Key, double) reading() {
            final bounds = tester.getRect(viewport);
            final visible =
                cards.evaluate().where((element) {
                  final rect = tester.getRect(find.byKey(element.widget.key!));
                  return rect.top >= bounds.top && rect.top < bounds.bottom;
                }).toList()..sort((a, b) {
                  final ar = tester.getRect(find.byKey(a.widget.key!));
                  final br = tester.getRect(find.byKey(b.widget.key!));
                  final vertical = ar.top.compareTo(br.top);
                  return vertical == 0 ? ar.left.compareTo(br.left) : vertical;
                });
            expect(visible, isNotEmpty);
            final key = visible.first.widget.key!;
            return (key, tester.getTopLeft(find.byKey(key)).dy);
          }

          Animation<double> motion(Key key) =>
              tester
                      .widget<AnimatedBuilder>(
                        find
                            .ancestor(
                              of: find.byKey(key),
                              matching: find.byType(AnimatedBuilder),
                            )
                            .first,
                      )
                      .animation
                  as Animation<double>;
          void check((Key, double) anchor, Element element) {
            expect(find.byKey(anchor.$1), findsOneWidget);
            expect(tester.element(find.byKey(anchor.$1)), same(element));
            expect(
              tester.getTopLeft(find.byKey(anchor.$1)).dy,
              closeTo(anchor.$2, .01),
            );
            expect(scroll.position, same(position));
            expect(cards.evaluate().length, lessThan(100));
            expect(
              find.byKey(const ValueKey('config-entry-4095')),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
          }

          // Each resize begins before the preceding 180ms motion completes.
          for (final width in [
            1599.0,
            1600.0,
            1601.0,
            1199.0,
            1200.0,
            1201.0,
          ]) {
            final anchor = reading();
            final element = tester.element(find.byKey(anchor.$1));
            tester.view.physicalSize = Size(width, 1136);
            for (final milliseconds in [0, 16, 100]) {
              await tester.pump(Duration(milliseconds: milliseconds));
              check(anchor, element);
            }
            expect(motion(anchor.$1).status, AnimationStatus.forward);
            expect(motion(anchor.$1).value, lessThan(1));
          }

          // Scroll while moving, then change content without changing columns
          // or width. The new presentation must not reuse the earlier origins.
          position.jumpTo(position.pixels + 24);
          await tester.pump(const Duration(milliseconds: 16));
          final anchor = reading();
          final element = tester.element(find.byKey(anchor.$1));
          final driver = motion(anchor.$1);
          expect(driver.status, AnimationStatus.forward);
          final id = (anchor.$1 as ValueKey<String>).value.substring(
            'config-'.length,
          );
          final entry = app.collection.find(id)!;
          app.collection = app.collection.replace(
            entry.renamed('${entry.name} ${'natural content ' * 3}'),
          );
          app.changed();
          await tester.pump();
          check(anchor, element);
          expect(motion(anchor.$1), same(driver));
          expect(driver.value, 0);
          for (final milliseconds in [16, 80]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            check(anchor, element);
          }
          final progress = driver.value;
          expect(progress, greaterThan(0));
          expect(progress, lessThan(1));
          app.state = AppSnapshot(
            phase: 'RUNNING',
            configId: id,
            revision: entry.revision,
            operation: messages.stageStartingTunnel,
          );
          app.changed();
          await tester.pump();
          check(anchor, element);
          expect(driver.value, progress);
          await tester.pump(const Duration(milliseconds: 16));
          check(anchor, element);
          expect(driver.value, greaterThan(progress));
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
        }
      },
    );
  }
  for (final plugins in [false, true]) {
    final kind = plugins ? 'plugins' : 'configs';
    testWidgets('$kind card menus remain in the real semantics tree', (
      tester,
    ) async {
      final app = _GridApp()
        ..collection = ConfigCollection(
          entries: [_config(0)],
          selectedId: 'entry-0',
        )
        ..overrides = [_plugin(0)];
      try {
        await _show(tester, app, plugins);
        tester.view.physicalSize = const Size(601, 810);
        await tester.pumpAndSettle();
        final card = find.byKey(
          ValueKey('${plugins ? 'override' : 'config'}-entry-0'),
        );
        final trigger = find.byIcon(Icons.more_vert);
        final cardRect = tester.getRect(card);
        final triggerRect = tester.getRect(trigger);
        await tester.tap(trigger);
        for (final ms in [0, 16, 80, 200, 200]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.getRect(card), cardRect);
          expect(tester.getRect(trigger), triggerRect);
          expect(tester.takeException(), isNull);
        }
        expect(find.widgetWithText(MenuItemButton, 'Rename'), findsOneWidget);
        final pointer = tester.widget<IgnorePointer>(
          find
              .ancestor(
                of: find.widgetWithText(MenuItemButton, 'Rename'),
                matching: find.byType(IgnorePointer),
              )
              .first,
        );
        expect(pointer.ignoring, isFalse);
        expect(find.semantics.byLabel('Rename'), findsOneWidget);
        expect(find.semantics.byLabel('Delete'), findsOneWidget);
        if (plugins) {
          final strings = AppLocalizations.of(
            tester.element(find.byType(OverridesPage)),
          );
          for (final label in [
            strings.overrideMoveUp,
            strings.overrideMoveDown,
          ]) {
            final node = find.semantics.byLabel(label).evaluate().single;
            expect(node.flagsCollection.isEnabled, Tristate.isFalse);
            expect(
              node.getSemanticsData().hasAction(SemanticsAction.tap),
              isFalse,
            );
          }
        }
        for (final guideline in [
          androidTapTargetGuideline,
          labeledTapTargetGuideline,
          textContrastGuideline,
        ]) {
          await expectLater(tester, meetsGuideline(guideline));
        }
        await tester.binding.handlePopRoute();
        for (final ms in [0, 16, 80, 200, 200]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(find.semantics.byLabel('Rename'), findsNothing);
          expect(find.semantics.byLabel('Delete'), findsNothing);
          expect(tester.getRect(card), cardRect);
          expect(tester.getRect(trigger), triggerRect);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
      }
    }, semanticsEnabled: true);
    testWidgets(
      plugins
          ? 'plugins use a single priority-ordered list'
          : 'configs form bounded grid rows',
      (tester) async {
        final app = _GridApp()
          ..collection = ConfigCollection(
            entries: [for (var i = 0; i < 12; i++) _config(i)],
            selectedId: 'entry-0',
          )
          ..overrides = [for (var i = 0; i < 12; i++) _plugin(i)];
        try {
          await _show(tester, app, plugins);
          final cards = find.byType(Card);
          expect(cards.evaluate().length, greaterThanOrEqualTo(2));
          final first = tester.getRect(cards.at(0));
          final second = tester.getRect(cards.at(1));
          if (plugins) {
            expect(second.top, greaterThanOrEqualTo(first.bottom));
            expect(second.left, first.left);
            expect(first.width, lessThanOrEqualTo(960));
          } else {
            expect(first.top, second.top);
            expect(second.left, greaterThanOrEqualTo(first.right + 8));
            expect(first.width, lessThan(760));
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
        }
      },
    );
    for (final language in ['en', 'zh']) {
      for (final (scaleName, scaler) in [
        ('1', TextScaler.noScaling),
        ('1.3', const TextScaler.linear(1.3)),
        ('2', const TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          '$kind 4096 lazy cards preserve a reading ID before paint $language/$scaleName',
          (tester) async {
            final app = _GridApp()
              ..collection = ConfigCollection(
                entries: [for (var i = 0; i < 4096; i++) _config(i)],
                selectedId: 'entry-0',
              )
              ..overrides = [for (var i = 0; i < 4096; i++) _plugin(i)];
            try {
              await _show(
                tester,
                app,
                plugins,
                language: language,
                scaler: scaler,
              );
              final cards = find.byWidgetPredicate(
                (w) =>
                    w is Card &&
                    w.key is ValueKey<String> &&
                    (w.key as ValueKey<String>).value.startsWith(
                      plugins ? 'override-entry-' : 'config-entry-',
                    ),
              );
              final viewport = find.byType(CustomScrollView);
              final scroll = tester.state<ScrollableState>(
                find.byWidgetPredicate(
                  (w) =>
                      w is Scrollable && w.axisDirection == AxisDirection.down,
                ),
              );
              final position = scroll.position;
              final firstTargets = [
                cards.first,
                find.descendant(
                  of: cards.first,
                  matching: find.byIcon(Icons.more_vert),
                ),
                find.descendant(
                  of: cards.first,
                  matching: find.byIcon(Icons.edit_outlined),
                ),
              ];
              final firstRects = firstTargets.map(tester.getRect).toList();
              final firstElement = tester.element(cards.first);
              final readError = plugins
                  ? messages.overridesUnreadable
                  : messages.storageUnavailable;
              for (final (loaded, error) in [
                (false, null),
                (false, readError),
                (true, null),
              ]) {
                if (plugins) {
                  app.overridesLoaded = loaded;
                  app.overrideErrorMessage = error;
                } else {
                  app.configsLoaded = loaded;
                  app.configErrorMessage = error;
                }
                app.changed();
                for (final ms in [0, 16, 100]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(firstTargets.map(tester.getRect).toList(), firstRects);
                  expect(tester.element(cards.first), same(firstElement));
                  expect(scroll.position, same(position));
                  expect(
                    find.byKey(const ValueKey('override-read-state')),
                    findsNothing,
                  );
                  expect(
                    find.byKey(const ValueKey('config-state-entry-0')),
                    findsNothing,
                  );
                  expect(find.byType(AlertDialog), findsNothing);
                  expect(tester.takeException(), isNull);
                }
                if (error != null) {
                  await tester.pumpAndSettle();
                  final notice = find.byType(SnackBar);
                  expect(notice, findsOneWidget);
                  await tester.tap(
                    find.descendant(
                      of: notice,
                      matching: find.byIcon(Icons.close),
                    ),
                  );
                  for (final ms in [0, 16, 100, 200]) {
                    await tester.pump(Duration(milliseconds: ms));
                    expect(
                      firstTargets.map(tester.getRect).toList(),
                      firstRects,
                    );
                    expect(tester.element(cards.first), same(firstElement));
                    expect(scroll.position, same(position));
                    expect(tester.takeException(), isNull);
                  }
                  expect(notice, findsNothing);
                } else {
                  expect(find.byType(SnackBar), findsNothing);
                }
              }
              expect(cards.evaluate().length, lessThan(100));
              expect(
                find.byKey(
                  ValueKey('${plugins ? 'override' : 'config'}-entry-4095'),
                ),
                findsNothing,
              );
              position.jumpTo(2400);
              await tester.pumpAndSettle();
              (Key, double) reading({Set<Key> removed = const {}}) {
                final bounds = tester.getRect(viewport);
                final visible =
                    cards.evaluate().where((e) {
                      final rect = tester.getRect(find.byKey(e.widget.key!));
                      return !removed.contains(e.widget.key) &&
                          rect.top >= bounds.top &&
                          rect.top < bounds.bottom;
                    }).toList()..sort((a, b) {
                      final ar = tester.getRect(find.byKey(a.widget.key!));
                      final br = tester.getRect(find.byKey(b.widget.key!));
                      final y = ar.top.compareTo(br.top);
                      return y == 0 ? ar.left.compareTo(br.left) : y;
                    });
                expect(visible, isNotEmpty);
                final key = visible.first.widget.key!;
                return (key, tester.getTopLeft(find.byKey(key)).dy);
              }

              Future<void> stable((Key, double) anchor) async {
                for (final ms in [0, 16, 100]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(find.byKey(anchor.$1), findsOneWidget);
                  expect(
                    tester.getTopLeft(find.byKey(anchor.$1)).dy,
                    closeTo(anchor.$2, .01),
                    reason:
                        'width=${tester.view.physicalSize.width} ms=$ms '
                        'pixels=${position.pixels} '
                        'range=${position.minScrollExtent}..${position.maxScrollExtent}',
                  );
                  expect(scroll.position, same(position));
                  expect(cards.evaluate().length, lessThan(100));
                  expect(tester.takeException(), isNull);
                }
              }

              for (final width in [
                1599.0,
                1600.0,
                1601.0,
                1199.0,
                1200.0,
                1201.0,
                839.0,
                840.0,
                841.0,
                601.0,
                600.0,
                599.0,
                320.0,
                280.0,
                700.0,
                1704.0,
              ]) {
                final anchor = reading();
                tester.view.physicalSize = Size(width, 1136);
                await stable(anchor);
              }
              var anchor = reading();
              app.collection = ConfigCollection(
                entries: [
                  for (var i = -5; i < 0; i++) _config(i),
                  ...app.collection.entries,
                ],
                selectedId: 'entry-0',
              );
              app.overrides = [
                for (var i = -5; i < 0; i++) _plugin(i),
                ...app.overrides,
              ];
              app.changed();
              await stable(anchor);
              anchor = reading();
              app.collection = ConfigCollection(
                entries: app.collection.entries
                    .map(
                      (e) =>
                          e.renamed('${e.name} ${'长名称 natural content ' * 2}'),
                    )
                    .toList(),
                selectedId: 'entry-0',
              );
              app.overrides = app.overrides
                  .map(
                    (e) => e.changed(
                      name: '${e.name} ${'长名称 natural content ' * 2}',
                    ),
                  )
                  .toList();
              app.changed();
              await stable(anchor);
              anchor = reading();
              app.collection = ConfigCollection(
                entries: app.collection.entries.reversed.toList(),
                selectedId: 'entry-0',
              );
              app.overrides = app.overrides.reversed.toList();
              app.changed();
              await stable(anchor);
              final removed = reading().$1;
              final survivor = reading(removed: {removed});
              final removedId = (removed as ValueKey<String>).value.substring(
                plugins ? 'override-'.length : 'config-'.length,
              );
              app.collection = ConfigCollection(
                entries: app.collection.entries
                    .where((e) => e.id != removedId)
                    .toList(),
                selectedId: 'entry-0',
              );
              app.overrides = app.overrides
                  .where((e) => e.id != removedId)
                  .toList();
              app.changed();
              await stable(survivor);
              final index = plugins
                  ? app.overrides.indexWhere(
                      (e) =>
                          'override-${e.id}' ==
                          (survivor.$1 as ValueKey<String>).value,
                    )
                  : app.collection.entries.indexWhere(
                      (e) =>
                          'config-${e.id}' ==
                          (survivor.$1 as ValueKey<String>).value,
                    );
              expect(
                tester
                    .widget<IndexedSemantics>(
                      find
                          .ancestor(
                            of: find.byKey(survivor.$1),
                            matching: find.byType(IndexedSemantics),
                          )
                          .first,
                    )
                    .index,
                index,
              );
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              app.dispose();
            }
          },
        );
      }
    }
  }
}
