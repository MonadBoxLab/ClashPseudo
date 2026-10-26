import 'dart:ui' show SemanticsAction, Tristate;

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/configs_page.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/overrides_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/text_scalers.dart';

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
      home: plugins ? OverridesPage(app: app) : ConfigsPage(controller: app),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
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
              if (plugins) {
                final first = tester.getRect(cards.first);
                final status = find.byKey(
                  const ValueKey('override-read-state'),
                );
                final slot = tester.getRect(status);
                for (final (loaded, error) in [
                  (false, null),
                  (false, messages.overridesUnreadable),
                  (true, null),
                ]) {
                  app.overridesLoaded = loaded;
                  app.overrideErrorMessage = error;
                  app.changed();
                  for (final ms in [0, 16, 100]) {
                    await tester.pump(Duration(milliseconds: ms));
                    expect(tester.getRect(cards.first), first);
                    expect(tester.getRect(status), slot);
                    expect(tester.takeException(), isNull);
                  }
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
