import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import 'strategy_fakes.dart';

StrategySnapshot _snapshot(List<String> names) => StrategySnapshot(
  generation: previewCore.generation,
  configId: previewCore.configId!,
  revision: previewCore.revision!,
  purpose: previewCore.purpose!,
  composition: previewCore.composition,
  globalReferenced: false,
  unrestored: const {},
  groups: [
    for (final name in names)
      StrategyGroup(
        name: name,
        rawType: 'select',
        hidden: false,
        now: 'DIRECT',
        fixed: '',
        members: const [StrategyMember(name: 'DIRECT', type: 'Direct')],
      ),
  ],
);

void main() {
  for (final language in ['en', 'zh']) {
    for (final all in [false, true]) {
      for (final (scaleName, scaler) in [
        ('1', TextScaler.noScaling),
        ('1.3', const TextScaler.linear(1.3)),
        ('2', const TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          '4096 lazy cards retain reading IDs across columns and updates $language/$all/$scaleName',
          (tester) async {
            tester.view.physicalSize = const Size(1704, 1136);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final names = [
              for (var i = 0; i < 4096; i++) 'Group $i — 可读长名称 🌐',
            ];
            final bridge = StrategyBridgeFake()..data = _snapshot(names);
            final app = StrategyAppFake(bridge);
            final controller = StrategyController(app, allGroups: all);
            addTearDown(controller.dispose);
            addTearDown(app.dispose);
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: AppTheme.light,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: scaler, disableAnimations: true),
                  child: child!,
                ),
                home: StrategiesPage(controller: controller, active: true),
              ),
            );
            await tester.pumpAndSettle();
            final cards = find.byWidgetPredicate(
              (widget) =>
                  widget is SizedBox &&
                  widget.key is ValueKey<String> &&
                  ((widget.key as ValueKey<String>).value.startsWith(
                    'strategy-card-',
                  )),
            );
            final scroll = tester.state<ScrollableState>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              ),
            );
            final position = scroll.position;
            expect(cards.evaluate().length, lessThan(100));
            expect(
              find.byKey(ValueKey('strategy-card-${names.last}')),
              findsNothing,
            );
            position.jumpTo(2400);
            await tester.pumpAndSettle();

            (Key, double) reading({Set<String> removed = const {}}) {
              final viewport = tester.getRect(find.byType(CustomScrollView));
              final visible =
                  cards.evaluate().where((element) {
                    final key = element.widget.key! as ValueKey<String>;
                    final rect = tester.getRect(find.byKey(key));
                    return !removed.contains(
                          key.value.substring('strategy-card-'.length),
                        ) &&
                        rect.top >= viewport.top &&
                        rect.top < viewport.bottom;
                  }).toList()..sort((a, b) {
                    final ar = tester.getRect(find.byKey(a.widget.key!));
                    final br = tester.getRect(find.byKey(b.widget.key!));
                    final vertical = ar.top.compareTo(br.top);
                    return vertical == 0
                        ? ar.left.compareTo(br.left)
                        : vertical;
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
            for (final updated in [
              ['New 1', 'New 2', ...names],
              names.reversed.toList(),
            ]) {
              final anchor = reading();
              bridge.data = _snapshot(updated);
              await controller.retry();
              await stable(anchor);
            }
            final removed = (reading().$1 as ValueKey<String>).value.substring(
              'strategy-card-'.length,
            );
            final survivor = reading(removed: {removed});
            bridge.data = _snapshot(
              names.reversed.where((name) => name != removed).toList(),
            );
            await controller.retry();
            await stable(survivor);
            position.jumpTo(position.minScrollExtent);
            await tester.pumpAndSettle();
            expect(find.text(strategyEntry.name), findsOneWidget);
            expect(tester.takeException(), isNull);
            controller.setVisible(false);
            final reads = bridge.reads;
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(seconds: 6));
            expect(bridge.reads, reads);
          },
        );
      }
    }
  }
}
