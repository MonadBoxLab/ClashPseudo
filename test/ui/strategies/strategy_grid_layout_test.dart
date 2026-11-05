import 'dart:async';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import '../../support/strategy_fakes.dart';

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
  for (final all in [false, true]) {
    for (final initiallyReduced in [false, true]) {
      testWidgets(
        'loading and empty headers keep their subtree across dynamic reduce all=$all initial=$initiallyReduced',
        (tester) async {
          tester.view.physicalSize = const Size(900, 1136);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final pending = Completer<StrategySnapshot>();
          final bridge = StrategyBridgeFake()..pendingRead = pending;
          final app = StrategyAppFake(bridge);
          final controller = StrategyController(app, allGroups: all);
          final reduce = ValueNotifier(initiallyReduced);
          addTearDown(controller.dispose);
          addTearDown(app.dispose);
          addTearDown(reduce.dispose);
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.light,
              builder: (context, child) => ValueListenableBuilder<bool>(
                valueListenable: reduce,
                builder: (_, value, _) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: value),
                  child: child!,
                ),
              ),
              home: StrategiesPage(controller: controller, active: true),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          final strings = lookupAppLocalizations(const Locale('en'));
          final page = tester.state(find.byType(StrategiesPage));
          final headerColumn = find
              .descendant(
                of: find.byType(SliverToBoxAdapter).first,
                matching: find.byType(Column),
              )
              .first;
          final header = find.byKey(
            tester.widget<Column>(headerColumn).key!,
            skipOffstage: false,
          );
          final headerElement = tester.element(header);
          final search = find.byTooltip(strings.searchStrategies);
          final searchRect = tester.getRect(search);
          expect(find.byTooltip(strings.refresh), findsNothing);
          final reader = find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          );
          final scroll = tester.state<ScrollableState>(reader);
          final position = scroll.position;
          void stable() {
            expect(tester.state(find.byType(StrategiesPage)), same(page));
            expect(
              tester
                  .widget<StrategiesPage>(find.byType(StrategiesPage))
                  .controller,
              same(controller),
            );
            expect(tester.element(header), same(headerElement));
            expect(tester.getRect(search), searchRect);
            expect(
              find.descendant(of: header, matching: find.byType(Scrollable)),
              findsNothing,
            );
            expect(tester.state<ScrollableState>(reader), same(scroll));
            expect(scroll.position, same(position));
            expect(
              find.ancestor(
                of: header,
                matching: find.byType(AnimatedSize, skipOffstage: false),
              ),
              reduce.value ? findsNothing : findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          }

          expect(controller.loading, isTrue);
          expect(controller.data, isNull);
          expect(bridge.reads, 1);
          expect(find.text(strings.coreReadLoading), findsOneWidget);
          for (final value in [!initiallyReduced, initiallyReduced, true]) {
            reduce.value = value;
            await tester.pump();
            stable();
            expect(controller.loading, isTrue);
            expect(bridge.reads, 1);
          }
          final loadingHeight = tester.getSize(header).height;
          final loadingContentHeight =
              tester.getSize(find.text(strings.coreReadLoading)).height + 12;
          final loaded = _snapshot([for (var i = 0; i < 64; i++) 'Group $i']);
          pending.complete(loaded);
          await tester.idle();
          expect(controller.loading, isFalse);
          expect(controller.data, same(loaded));
          expect(tester.binding.hasScheduledFrame, isTrue);
          await tester.pump();
          stable();
          expect(controller.loading, isFalse);
          expect(controller.data, same(loaded));
          expect(
            tester.getSize(header).height,
            closeTo(loadingHeight - loadingContentHeight, .01),
          );
          expect(find.text(strings.coreReadLoading), findsNothing);
          final card = find.byKey(const ValueKey('strategy-group-Group 1'));
          final cardElement = tester.element(card);
          controller.setShowHidden(true);
          position.jumpTo(32);
          await tester.pump();
          final offset = position.pixels;
          for (final value in [false, true, false, true]) {
            reduce.value = value;
            await tester.pump();
            stable();
            expect(position.pixels, offset);
            expect(tester.element(card), same(cardElement));
            expect(controller.data, same(loaded));
            expect(controller.data!.find('Group 1')!.now, 'DIRECT');
            expect(controller.showHidden, isTrue);
          }
          final populatedHeight = tester.getSize(header).height;
          bridge.pendingRead = null;
          bridge.data = _snapshot([]);
          await controller.retry();
          await tester.pump();
          stable();
          expect(
            find.text(all ? strings.noStrategyGroups : strings.noVisibleGroups),
            findsOneWidget,
          );
          final emptyHeight = tester.getSize(header).height;
          expect(emptyHeight, greaterThan(populatedHeight));
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getSize(header).height, emptyHeight);
          stable();
          for (final value in [false, true, false, true]) {
            reduce.value = value;
            await tester.pump();
            stable();
          }
          bridge.data = loaded;
          await controller.retry();
          await tester.pump();
          stable();
          expect(tester.getSize(header).height, populatedHeight);
          expect(
            find.text(all ? strings.noStrategyGroups : strings.noVisibleGroups),
            findsNothing,
          );
          expect(bridge.reads, 3);
          expect(bridge.events, isEmpty);
          expect(app.commands, isEmpty);
          controller.setVisible(false);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'filter empty header animates, reverses and reduces without replacing search or reader',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1136);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = StrategyBridgeFake()
        ..data = _snapshot([for (var i = 0; i < 64; i++) 'Group $i']);
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app);
      final reduce = ValueNotifier(false);
      addTearDown(controller.dispose);
      addTearDown(app.dispose);
      addTearDown(reduce.dispose);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: reduce,
            builder: (_, value, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: value),
              child: child!,
            ),
          ),
          home: StrategiesPage(controller: controller, active: true),
        ),
      );
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.byTooltip(strings.searchStrategies));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      final search = tester.state(field);
      final text = tester.widget<TextField>(field).controller!;
      final focus = tester.widget<TextField>(field).focusNode!;
      final page = tester.state(find.byType(StrategiesPage));
      final reader = find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      );
      final scroll = tester.state<ScrollableState>(reader);
      final position = scroll.position;
      final header = find
          .ancestor(
            of: find.text(strategyEntry.name),
            matching: find.byType(Column),
          )
          .first;
      final headerElement = tester.element(header);
      final animated = find.ancestor(
        of: header,
        matching: find.byType(AnimatedSize),
      );
      final originalHeight = tester.getSize(animated).height;
      void stable() {
        expect(tester.state(find.byType(StrategiesPage)), same(page));
        expect(
          tester.widget<StrategiesPage>(find.byType(StrategiesPage)).controller,
          same(controller),
        );
        expect(tester.state(field), same(search));
        expect(tester.widget<TextField>(field).controller, same(text));
        expect(tester.widget<TextField>(field).focusNode, same(focus));
        expect(focus.hasFocus, isTrue);
        expect(tester.element(header), same(headerElement));
        expect(tester.state<ScrollableState>(reader), same(scroll));
        expect(scroll.position, same(position));
        expect(controller.data, same(bridge.data));
        expect(bridge.reads, 1);
        expect(tester.takeException(), isNull);
      }

      await tester.enterText(field, 'no matching group');
      await tester.pump();
      final emptyHeight = tester
          .getSize(find.byWidget(tester.widget<AnimatedSize>(animated).child!))
          .height;
      expect(tester.getSize(animated).height, originalHeight);
      await tester.pump(const Duration(milliseconds: 60));
      final middle = tester.getSize(animated).height;
      expect(middle, greaterThan(originalHeight));
      expect(middle, lessThan(emptyHeight));
      stable();
      await tester.enterText(field, 'Group 1');
      await tester.pump();
      expect(tester.getSize(animated).height, closeTo(middle, .01));
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getSize(animated).height, lessThan(middle));
      stable();
      await tester.pumpAndSettle();
      expect(tester.getSize(animated).height, originalHeight);
      stable();
      await tester.enterText(field, 'no matching group');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      reduce.value = true;
      await tester.pump();
      stable();
      expect(animated, findsNothing);
      expect(find.text(strings.noMatchingStrategies), findsOneWidget);
      final immediate = tester.getSize(header).height;
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getSize(header).height, immediate);
      text.selection = const TextSelection(baseOffset: 3, extentOffset: 8);
      final selection = text.selection;
      for (final value in [false, true, false, true]) {
        reduce.value = value;
        tester.view.physicalSize = Size(value ? 700 : 900, 1136);
        await tester.pump();
        stable();
        expect(text.text, 'no matching group');
        expect(text.selection, selection);
      }
      await tester.enterText(field, 'Group 1');
      await tester.pump();
      stable();
      expect(find.text(strings.noMatchingStrategies), findsNothing);
      expect(
        find.byKey(const ValueKey('strategy-group-Group 1')),
        findsOneWidget,
      );
      final card = tester.element(
        find.byKey(const ValueKey('strategy-group-Group 1')),
      );
      for (final value in [false, true]) {
        reduce.value = value;
        await tester.pump();
        stable();
        expect(
          tester.element(find.byKey(const ValueKey('strategy-group-Group 1'))),
          same(card),
        );
        expect(text.text, 'Group 1');
      }
      expect(app.commands, isEmpty);
      expect(bridge.events, isEmpty);
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final all in [false, true]) {
    testWidgets(
      'mounted grid cards retarget visual geometry without replacing the reader all=$all',
      (tester) async {
        tester.view.physicalSize = const Size(900, 1136);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = StrategyBridgeFake()
          ..data = _snapshot([for (var i = 0; i < 4096; i++) 'Group $i']);
        final app = StrategyAppFake(bridge);
        final controller = StrategyController(app, allGroups: all);
        addTearDown(controller.dispose);
        addTearDown(app.dispose);
        final reduce = ValueNotifier(false);
        final opened = <String>[];
        addTearDown(reduce.dispose);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: AppTheme.light,
            builder: (context, child) => ValueListenableBuilder<bool>(
              valueListenable: reduce,
              builder: (_, value, _) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: value),
                child: child!,
              ),
            ),
            home: StrategiesPage(
              controller: controller,
              active: true,
              onOpenGroup: (group) => opened.add(group.name),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('strategy-group-Group 1'));
        final identity = tester.element(card);
        Rect visual() {
          final box = tester.renderObject<RenderBox>(card);
          return MatrixUtils.transformRect(
            box.getTransformTo(null),
            Offset.zero & box.size,
          );
        }

        const identityTransform = <double>[
          1,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          1,
        ];
        List<double> childTransform() {
          final motion = tester.renderObject<RenderProxyBox>(
            find.byKey(const ValueKey('strategy-motion-Group 1')),
          );
          return motion.child!.getTransformTo(motion).storage;
        }

        void sameRect(Rect actual, Rect expected) {
          expect(actual.left, closeTo(expected.left, .01));
          expect(actual.top, closeTo(expected.top, .01));
          expect(actual.width, closeTo(expected.width, .01));
          expect(actual.height, closeTo(expected.height, .01));
        }

        final scroll = tester.state<ScrollableState>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        );
        final position = scroll.position;
        final original = visual();
        expect(childTransform(), orderedEquals(identityTransform));
        tester.view.physicalSize = const Size(700, 1136);
        await tester.pump();
        sameRect(visual(), original);
        final target = tester.getRect(
          find.byKey(const ValueKey('strategy-card-Group 1')),
        );
        expect(target, isNot(original));
        await tester.pump(const Duration(milliseconds: 60));
        final middle = visual();
        expect(middle, isNot(original));
        expect(middle, isNot(target));
        expect(childTransform(), isNot(orderedEquals(identityTransform)));
        final expected = Rect.lerp(
          original,
          target,
          Curves.easeOutCubic.transform(1 / 3),
        )!;
        expect(middle.left, closeTo(expected.left, .01));
        expect(middle.top, closeTo(expected.top, .01));
        expect(middle.width, closeTo(expected.width, .01));
        expect(middle.height, closeTo(expected.height, .01));
        await tester.tapAt(middle.center);
        expect(opened, isEmpty);
        expect(
          find.byKey(const ValueKey('strategy-popup-title')),
          findsNothing,
        );
        // Reverse from the actually painted position, not the previous endpoint.
        tester.view.physicalSize = const Size(900, 1136);
        await tester.pump();
        sameRect(visual(), middle);
        await tester.pumpAndSettle();
        sameRect(visual(), original);
        expect(childTransform(), orderedEquals(identityTransform));
        for (final width in [880.0, 860.0, 840.0, 820.0, 800.0]) {
          tester.view.physicalSize = Size(width, 1136);
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.element(card), same(identity));
          expect(scroll.position, same(position));
          expect(tester.takeException(), isNull);
        }
        reduce.value = true;
        await tester.pump();
        expect(childTransform(), orderedEquals(identityTransform));
        final immediate = visual();
        await tester.pump(const Duration(milliseconds: 16));
        expect(visual(), immediate);
        expect(
          tester.widget<StrategiesPage>(find.byType(StrategiesPage)).controller,
          same(controller),
        );
        expect(
          find.byKey(const ValueKey('strategy-group-Group 4095')),
          findsNothing,
        );
        expect(bridge.reads, 1);
        await tester.tap(card);
        await tester.pump();
        if (all) {
          expect(opened, ['Group 1']);
        } else {
          expect(
            find.byKey(const ValueKey('strategy-popup-title')),
            findsOneWidget,
          );
        }
        controller.setVisible(false);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
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
            expect(
              find.text(
                all
                    ? lookupAppLocalizations(Locale(language)).allStrategyGroups
                    : strategyEntry.name,
              ),
              findsOneWidget,
            );
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
