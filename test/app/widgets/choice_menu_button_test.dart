import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Finder surface() => find
    .ancestor(
      of: find.byType(MenuItemButton).first,
      matching: find.byWidgetPredicate(
        (widget) => widget is Material && widget.type == MaterialType.canvas,
      ),
    )
    .first;

void main() {
  for (final language in ['zh', 'en']) {
    for (final width in [280.0, 320.0, 700.0, 1704.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final left in [true, false]) {
          testWidgets(
            'right surface and long choices $language $width $scale left=$left',
            (tester) async {
              tester.view.physicalSize = Size(width, 900);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              String? selected;
              final long = language == 'zh'
                  ? '这是必须完整展示且不能缩小字号的很长的规则类型或策略组名称'
                  : 'A long rule type or strategy group name that must remain readable without shrinking';
              await tester.pumpWidget(
                MaterialApp(
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
                      child: Align(
                        alignment: left
                            ? Alignment.topLeft
                            : Alignment.topRight,
                        child: SizedBox(
                          width: left ? 144 : double.infinity,
                          child: ChoiceMenuButton<String>(
                            key: const ValueKey('choice'),
                            options: {'first': long, 'last': 'Last'},
                            maxHeight: 340,
                            onSelected: (value) => selected = value,
                            child: const InputDecorator(
                              decoration: InputDecoration(
                                border: OutlineInputBorder(),
                              ),
                              child: Text('Choice'),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              final trigger = find.byKey(const ValueKey('choice'));
              final before = tester.getRect(trigger);
              await tester.tap(trigger);
              for (final milliseconds in [0, 16, 40, 80, 200]) {
                await tester.pump(Duration(milliseconds: milliseconds));
                expect(
                  tester.getRect(surface()).right,
                  closeTo(before.right, .01),
                );
                expect(tester.getRect(trigger), before);
                expect(tester.takeException(), isNull);
              }
              final paragraph = tester.renderObject<RenderParagraph>(
                find.text(long),
              );
              expect(paragraph.didExceedMaxLines, isFalse);
              await tester.ensureVisible(
                find.widgetWithText(MenuItemButton, 'Last'),
              );
              await tester.tap(find.widgetWithText(MenuItemButton, 'Last'));
              await tester.pumpAndSettle();
              expect(selected, 'last');
              expect(tester.getRect(trigger), before);
              expect(FocusManager.instance.primaryFocus?.context, isNotNull);
              await tester.pumpWidget(const SizedBox());
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }

  testWidgets(
    'window resizing retires the old geometry before a deferred selection',
    (tester) async {
      tester.view.physicalSize = const Size(1704, 1136);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: 260,
                  child: ChoiceMenuButton<int>(
                    identity: 'same-source',
                    options: const {1: 'First', 2: 'Last'},
                    onSelected: selected.add,
                    child: const InputDecorator(
                      decoration: InputDecoration(border: OutlineInputBorder()),
                      child: Text('Choice'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final trigger = find.byType(ChoiceMenuButton<int>);
      for (final width in [700.0, 599.0, 1704.0]) {
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(surface()).right,
          closeTo(tester.getRect(trigger).right, .01),
        );
        final old = tester
            .widget<MenuItemButton>(find.byType(MenuItemButton).first)
            .onPressed!;
        tester.view.physicalSize = Size(width, 1136);
        await tester.pump();
        old();
        expect(selected, isEmpty);
        for (final ms in [16, 80, 200]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
      }
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Last'));
      await tester.pumpAndSettle();
      expect(selected, [2]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'keyboard insets reposition the real menu within the safe region',
    (tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        top: 24,
        left: 12,
        right: 20,
        bottom: 24,
      );
      addTearDown(tester.view.reset);
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: SizedBox(
                    width: 260,
                    child: ChoiceMenuButton<int>(
                      options: const {
                        1: 'A long readable first option',
                        2: 'Last',
                      },
                      maxHeight: 300,
                      onSelected: selected.add,
                      child: const InputDecorator(
                        decoration: InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        child: Text('Choice'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final trigger = find.byType(ChoiceMenuButton<int>);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      for (final inset in [380.0, 0.0, 460.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        final frames = <(int, Rect, Rect)>[];
        for (final ms in [0, 16, 80, 200]) {
          await tester.pump(Duration(milliseconds: ms));
          frames.add((ms, tester.getRect(surface()), tester.getRect(trigger)));
          expect(tester.takeException(), isNull);
        }
        for (final (ms, panel, anchor) in frames) {
          expect(panel.right, closeTo(anchor.right, .01));
          expect(
            panel.bottom,
            lessThanOrEqualTo(900 - inset),
            reason: 'inset=$inset ms=$ms frames=$frames',
          );
          expect(panel.top, greaterThanOrEqualTo(24));
        }
      }
      await tester.ensureVisible(find.widgetWithText(MenuItemButton, 'Last'));
      await tester.tap(find.widgetWithText(MenuItemButton, 'Last'));
      await tester.pumpAndSettle();
      expect(selected, [2]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('restore invalidates an open menu and its deferred selection', (
    tester,
  ) async {
    final epoch = ValueNotifier(1);
    addTearDown(epoch.dispose);
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: epoch,
            builder: (context, value, _) => Align(
              alignment: Alignment.topRight,
              child: ChoiceMenuButton<int>(
                identity: value,
                options: const {1: 'First', 2: 'Second'},
                onSelected: selected.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final old = tester.widget<MenuItemButton>(
      find.widgetWithText(MenuItemButton, 'Second'),
    );
    epoch.value = 2;
    await tester.pump();
    old.onPressed!();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Second'));
    await tester.pumpAndSettle();
    expect(selected, [2]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'outside cancellation consumes the tap and restores trigger focus',
    (tester) async {
      var behind = 0;
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: ChoiceMenuButton<int>(
                    options: const {1: 'First'},
                    onSelected: selected.add,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => behind++,
                  child: const Text('Behind'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Behind'));
      await tester.pumpAndSettle();
      expect(behind, 0);
      expect(selected, isEmpty);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(FocusManager.instance.primaryFocus?.context, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
