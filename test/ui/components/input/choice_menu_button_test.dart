import 'dart:async';
import 'dart:ui'
    show
        DisplayFeature,
        DisplayFeatureState,
        DisplayFeatureType,
        PointerDeviceKind;

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder surface() => find
    .ancestor(
      of: find.byType(MenuItemButton).first,
      matching: find.byWidgetPredicate(
        (widget) => widget is Material && widget.type == MaterialType.canvas,
      ),
    )
    .first;

VoidCallback _retainSemantics(WidgetTester tester) {
  final handle = tester.ensureSemantics();
  var released = false;
  void release() {
    if (released) return;
    released = true;
    handle.dispose();
  }

  addTearDown(release);
  return release;
}

Future<
  ({
    BuildContext origin,
    FocusNode trigger,
    FocusNode external,
    ValueNotifier<bool> active,
    ValueNotifier<int> identity,
    List<int> selected,
  })
>
_focusHost(WidgetTester tester, {required bool reduced}) async {
  final active = ValueNotifier(true);
  final identity = ValueNotifier(1);
  final external = FocusNode();
  final selected = <int>[];
  addTearDown(active.dispose);
  addTearDown(identity.dispose);
  addTearDown(external.dispose);
  late BuildContext origin;
  late FocusNode trigger;
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [AppTaskNavigatorObserver()],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: ValueListenableBuilder(
        valueListenable: active,
        builder: (context, value, _) => AppTaskActivity(
          active: value,
          isActiveNow: () => active.value,
          child: Scaffold(
            body: Builder(
              builder: (context) {
                origin = context;
                return Column(
                  children: [
                    ValueListenableBuilder(
                      valueListenable: identity,
                      builder: (context, value, _) => ChoiceMenuButton<int>(
                        identity: value,
                        options: const {1: 'First', 2: 'Second'},
                        onSelected: selected.add,
                        buttonBuilder: (context, onPressed, focus) {
                          trigger = focus;
                          return TextButton(
                            focusNode: focus,
                            onPressed: onPressed,
                            child: const Text('Focus trigger'),
                          );
                        },
                      ),
                    ),
                    TextField(focusNode: external),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  return (
    origin: origin,
    trigger: trigger,
    external: external,
    active: active,
    identity: identity,
    selected: selected,
  );
}

FocusNode _menuItemFocus(WidgetTester tester, String label) => tester
    .widget<TextButton>(
      find.descendant(
        of: find.widgetWithText(MenuItemButton, label),
        matching: find.byType(TextButton),
      ),
    )
    .focusNode!;

Future<List<int>> _fieldHost(
  WidgetTester tester, {
  required ValueNotifier<TextDirection> direction,
  bool reduced = false,
  Map<int, String> options = const {1: 'First', 2: 'Second'},
  double? maxHeight,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(700, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final selected = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        scrollbarTheme: const ScrollbarThemeData(interactive: true),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: ValueListenableBuilder(
        valueListenable: direction,
        child: SizedBox(
          width: 240,
          child: ChoiceMenuButton<int>(
            key: const ValueKey('attachment-choice'),
            identity: 'field',
            value: 1,
            maxHeight: maxHeight,
            options: options,
            leadingIcon: (value) =>
                Icon(Icons.star_outline, key: ValueKey('leading:$value')),
            onSelected: selected.add,
            child: const InputDecorator(
              decoration: InputDecoration(border: OutlineInputBorder()),
              child: Row(
                children: [
                  Expanded(child: Text('Field')),
                  Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
          ),
        ),
        builder: (context, value, child) => Directionality(
          textDirection: value,
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.only(left: 60, top: 60),
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  return selected;
}

void main() {
  group('choice_menu_button', () {
    for (final reduced in [false, true]) {
      testWidgets(
        'real Tab leaves the open menu and Escape preserves the external field focus reduced=$reduced',
        (tester) async {
          final external = FocusNode();
          final input = TextEditingController(text: 'retained editor draft');
          addTearDown(external.dispose);
          addTearDown(input.dispose);
          final selected = <int>[];
          late FocusNode trigger;
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [AppTaskNavigatorObserver()],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => unawaited(
                      showDialog<void>(
                        context: context,
                        animationStyle: reduced
                            ? AnimationStyle.noAnimation
                            : null,
                        builder: (context) => Dialog(
                          child: SizedBox(
                            width: 360,
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Editor'),
                                  ChoiceMenuButton<int>(
                                    identity: 'original editor',
                                    options: const {1: 'First', 2: 'Second'},
                                    onSelected: selected.add,
                                    buttonBuilder: (context, onPressed, focus) {
                                      trigger = focus;
                                      return TextButton(
                                        focusNode: focus,
                                        onPressed: onPressed,
                                        child: const Text('Menu'),
                                      );
                                    },
                                  ),
                                  TextField(
                                    controller: input,
                                    focusNode: external,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    child: const Text('Open editor'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open editor'));
          await tester.pumpAndSettle();
          final editorRoute = ModalRoute.of(
            tester.element(find.text('Editor')),
          )!;
          final field = tester.state<EditableTextState>(
            find.byType(EditableText),
          );
          input.value = input.value.copyWith(
            selection: const TextSelection(baseOffset: 2, extentOffset: 8),
            composing: const TextRange(start: 2, end: 8),
          );
          await tester.tap(find.text('Menu'));
          await tester.pumpAndSettle();
          final menu = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
          final menuState = tester.state(find.byType(ChoiceMenuButton<int>));
          final cached = tester
              .widget<MenuItemButton>(
                find.widgetWithText(MenuItemButton, 'First'),
              )
              .onPressed!;
          expect(trigger.hasFocus, isTrue);
          expect(menu.controller!.isOpen, isTrue);
          expect(editorRoute.willHandlePopInternally, isTrue);

          // The real SDK Tab traversal moves from the menu's focused trigger to
          // the next field. No requestFocus substitutes for this original path.
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(external.hasPrimaryFocus, isTrue);
          expect(trigger.hasFocus, isFalse);
          expect(menu.controller!.isOpen, isTrue);
          expect(
            tester.state(find.byType(ChoiceMenuButton<int>)),
            same(menuState),
          );
          expect(tester.state(find.byType(EditableText)), same(field));
          final editing = input.value;

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.idle();
          expect(external.hasPrimaryFocus, isTrue);
          expect(trigger.hasFocus, isFalse);
          cached();
          expect(selected, isEmpty);
          for (final milliseconds in [0, 16, 100, 300]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(external.hasPrimaryFocus, isTrue);
            expect(trigger.hasFocus, isFalse);
            expect(input.value, editing);
            expect(tester.state(find.byType(EditableText)), same(field));
            expect(editorRoute.isActive, isTrue);
            expect(editorRoute.isCurrent, isTrue);
            expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
          }
          expect(find.byType(MenuItemButton), findsNothing);
          expect(editorRoute.willHandlePopInternally, isFalse);
          expect(selected, isEmpty);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.text('Editor'), findsNothing);
          expect(find.text('Open editor'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    for (final reduced in [false, true]) {
      testWidgets(
        'field attachment keeps live item direction and SDK identity reduced=$reduced',
        (tester) async {
          final direction = ValueNotifier(TextDirection.ltr);
          addTearDown(direction.dispose);
          final releaseSemantics = _retainSemantics(tester);
          try {
            final selected = await _fieldHost(
              tester,
              direction: direction,
              reduced: reduced,
            );
            final trigger = find.byKey(const ValueKey('attachment-choice'));
            final fieldState = tester.state(trigger);
            final anchorState = tester.state(find.byType(MenuAnchor));
            final triggerFocus = tester
                .widget<InkWell>(
                  find.descendant(of: trigger, matching: find.byType(InkWell)),
                )
                .focusNode!;
            final fieldRect = tester.getRect(trigger);
            final first = find.widgetWithText(MenuItemButton, 'First');
            Animation<double> opacity() => tester
                .widget<FadeTransition>(
                  find
                      .ancestor(
                        of: first,
                        matching: find.byType(FadeTransition),
                      )
                      .first,
                )
                .opacity;
            void expectDirection(TextDirection value) {
              expect(
                Directionality.of(tester.element(find.text('Field'))),
                value,
              );
              expect(Directionality.of(tester.element(first)), value);
              final semantics = find.ancestor(
                of: first,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics && widget.properties.selected == true,
                ),
              );
              expect(semantics, findsOneWidget);
              expect(Directionality.of(tester.element(semantics)), value);
              final leading = tester
                  .getCenter(find.byKey(const ValueKey('leading:1')))
                  .dx;
              final label = tester.getCenter(find.text('First')).dx;
              expect(find.byIcon(Icons.check), findsNothing);
              final arrow = tester
                  .getCenter(find.byIcon(Icons.arrow_drop_down))
                  .dx;
              final fieldLabel = tester.getCenter(find.text('Field')).dx;
              if (value == TextDirection.ltr) {
                expect(
                  tester.getRect(surface()).right,
                  closeTo(fieldRect.right, .01),
                );
                expect(leading, lessThan(label));
                expect(arrow, greaterThan(fieldLabel));
              } else {
                expect(
                  tester.getRect(surface()).left,
                  closeTo(fieldRect.left, .01),
                );
                expect(leading, greaterThan(label));
                expect(arrow, lessThan(fieldLabel));
              }
              expect(tester.getRect(trigger), fieldRect);
              expect(tester.state(trigger), same(fieldState));
              expect(tester.state(find.byType(MenuAnchor)), same(anchorState));
            }

            await tester.tap(trigger);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 40));
            expectDirection(TextDirection.ltr);
            final items = tester
                .widget<MenuAnchor>(find.byType(MenuAnchor))
                .menuChildren;
            final itemState = tester.state(first);
            final firstFocus = _menuItemFocus(tester, 'First');
            firstFocus.requestFocus();
            FocusManager.instance.applyFocusChangesIfNeeded();
            final animation = opacity();
            final beforeDirection = animation.value;
            if (!reduced) expect(beforeDirection, inExclusiveRange(0, 1));
            direction.value = TextDirection.rtl;
            await tester.pump();
            expectDirection(TextDirection.rtl);
            expect(opacity(), same(animation));
            expect(opacity().value, closeTo(beforeDirection, .001));
            expect(
              tester.widget<MenuAnchor>(find.byType(MenuAnchor)).menuChildren,
              same(items),
            );
            expect(tester.state(first), same(itemState));
            expect(_menuItemFocus(tester, 'First'), same(firstFocus));
            expect(firstFocus.hasFocus, isTrue);

            await tester.tap(trigger);
            await tester.pump();
            expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
            expect(
              tester.semantics.simulatedAccessibilityTraversal().map(
                (node) => node.getSemanticsData().label,
              ),
              isNot(contains('First')),
            );
            await tester.tap(trigger);
            await tester.pump();
            if (!reduced) {
              expect(opacity(), same(animation));
              expect(opacity().value, closeTo(beforeDirection, .001));
              expect(
                tester.widget<MenuAnchor>(find.byType(MenuAnchor)).menuChildren,
                same(items),
              );
            }
            await tester.pumpAndSettle();
            expectDirection(TextDirection.rtl);
            direction.value = TextDirection.ltr;
            await tester.pump();
            expectDirection(TextDirection.ltr);
            final cached = tester.widget<MenuItemButton>(first).onPressed!;
            _menuItemFocus(tester, 'First').requestFocus();
            FocusManager.instance.applyFocusChangesIfNeeded();
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.pump();
            expect(_menuItemFocus(tester, 'Second').hasFocus, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            expect(triggerFocus.hasFocus, isTrue);
            cached();
            expect(selected, isEmpty);
            await tester.pump();
            expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
            await tester.pumpAndSettle();
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(MenuItemButton, 'Second'));
            await tester.pump();
            expect(selected, [2]);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          } finally {
            releaseSemantics();
          }
        },
      );
    }

    testWidgets(
      'field panel keeps SDK scrollbar side inside safe IME and hinge bounds',
      (tester) async {
        final direction = ValueNotifier(TextDirection.ltr);
        addTearDown(direction.dispose);
        tester.view.padding = const FakeViewPadding(
          left: 12,
          right: 20,
          top: 24,
          bottom: 24,
        );
        tester.view.displayFeatures = const [
          DisplayFeature(
            bounds: Rect.fromLTWH(300, 0, 20, 900),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ];
        final selected = await _fieldHost(
          tester,
          direction: direction,
          options: {
            for (var i = 1; i <= 18; i++)
              i: 'Option ${i.toString().padLeft(2, '0')}',
          },
          maxHeight: 240,
          scale: 2,
        );
        await tester.tap(find.byKey(const ValueKey('attachment-choice')));
        await tester.pumpAndSettle();
        final scrollable = find.descendant(
          of: surface(),
          matching: find.byType(Scrollable),
        );
        final scroll = tester.state<ScrollableState>(scrollable);
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        final window = MediaQueryData.fromView(tester.view);
        final safe = window.padding.deflateRect(Offset.zero & window.size);
        final narrowHinge = window.displayFeatures.single.bounds;
        final originalPanel = tester.getRect(surface());
        final menu = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
        expect(safe.left, 12);
        expect(narrowHinge.left, 300);
        expect(originalPanel.width, greaterThan(narrowHinge.left - safe.left));
        // SDK preserves content wider than a sub-screen and places its left edge
        // at that screen's safe edge instead of squeezing it to the hinge.
        expect(originalPanel.left, safe.left);
        expect(originalPanel.right, greaterThan(narrowHinge.left));
        expect(originalPanel.right, lessThanOrEqualTo(safe.right));
        expect(originalPanel.top, greaterThanOrEqualTo(safe.top));
        expect(originalPanel.bottom, lessThanOrEqualTo(safe.bottom));
        tester.view.displayFeatures = const [
          DisplayFeature(
            bounds: Rect.fromLTWH(420, 0, 20, 900),
            type: DisplayFeatureType.hinge,
            state: DisplayFeatureState.postureFlat,
          ),
        ];
        await tester.pumpAndSettle();
        final fittingHinge = tester.view.displayFeatures.single.bounds;
        expect(originalPanel.width, lessThan(fittingHinge.left - safe.left));
        final movedMenu = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
        expect(movedMenu.controller, same(menu.controller));
        expect(movedMenu.controller!.isOpen, isTrue);
        expect(movedMenu.menuChildren, same(menu.menuChildren));
        expect(tester.state(scrollable), same(scroll));
        expect(tester.getRect(surface()).width, originalPanel.width);
        for (final value in [TextDirection.ltr, TextDirection.rtl]) {
          direction.value = value;
          await tester.pumpAndSettle();
          for (final inset in [380.0, 0.0]) {
            tester.view.viewInsets = FakeViewPadding(bottom: inset);
            for (final ms in [0, 40, 200]) {
              await tester.pump(Duration(milliseconds: ms));
              final panel = tester.getRect(surface());
              expect(panel.width, originalPanel.width);
              expect(panel.left, greaterThanOrEqualTo(safe.left));
              expect(panel.right, lessThanOrEqualTo(fittingHinge.left));
              expect(panel.right, lessThanOrEqualTo(safe.right));
              expect(panel.top, greaterThanOrEqualTo(24));
              expect(
                panel.bottom,
                lessThanOrEqualTo(900 - inset - (inset == 0 ? 24 : 0)),
              );
            }
          }
          final paint = find.descendant(
            of: surface(),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.foregroundPainter is ScrollbarPainter,
            ),
          );
          expect(paint, findsOneWidget);
          final painter =
              tester.widget<CustomPaint>(paint).foregroundPainter!
                  as ScrollbarPainter;
          final size = tester.getSize(paint);
          expect(painter.fadeoutOpacityAnimation.value, greaterThan(0));
          bool thumbInHalf(bool left) {
            final start = left ? 0.0 : size.width / 2;
            final end = left ? size.width / 2 : size.width;
            for (var x = start; x < end; x += 2) {
              for (var y = 0.0; y < size.height; y += 2) {
                if (painter.hitTestOnlyThumbInteractive(
                  Offset(x, y),
                  PointerDeviceKind.mouse,
                )) {
                  return true;
                }
              }
            }
            return false;
          }

          // The panel follows attachment direction; content remains in the real UI direction.
          expect(thumbInHalf(true), value == TextDirection.ltr);
          expect(thumbInHalf(false), value == TextDirection.rtl);
          expect(tester.state(scrollable), same(scroll));
          final before = scroll.position.pixels;
          await tester.drag(scrollable, const Offset(0, -80));
          await tester.pumpAndSettle();
          expect(scroll.position.pixels, greaterThan(before));
        }
        expect(selected, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final reduced in [false, true]) {
      for (final cancellation in [
        'Navigator.pop',
        'system Back',
        'Escape trigger',
        'Escape item',
      ]) {
        testWidgets(
          '$cancellation cancellation returns actual trigger focus immediately reduced=$reduced',
          (tester) async {
            final host = await _focusHost(tester, reduced: reduced);
            await tester.tap(find.text('Focus trigger'));
            await tester.pumpAndSettle();
            final cached = tester
                .widget<MenuItemButton>(
                  find.widgetWithText(MenuItemButton, 'First'),
                )
                .onPressed!;
            if (cancellation != 'Escape trigger') {
              final first = _menuItemFocus(tester, 'First');
              first.requestFocus();
              FocusManager.instance.applyFocusChangesIfNeeded();
              expect(first.hasFocus, isTrue);
            } else {
              expect(host.trigger.hasFocus, isTrue);
            }
            switch (cancellation) {
              case 'Navigator.pop':
                final route = ModalRoute.of(host.origin)!;
                final before = tester.binding.clock.now();
                Navigator.of(host.origin).pop();
                await tester.idle();
                expect(route.isActive, isTrue);
                expect(route.isCurrent, isTrue);
                expect(tester.binding.clock.now(), before);
              case 'system Back':
                await tester.binding.handlePopRoute();
              case 'Escape trigger':
                await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              case 'Escape item':
                await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
                await tester.pump();
                expect(_menuItemFocus(tester, 'Second').hasFocus, isTrue);
                await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            }
            // The trigger itself regains focus before any exit animation frame.
            expect(host.trigger.hasFocus, isTrue);
            cached();
            expect(host.selected, isEmpty);
            await tester.pump();
            expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
            if (!reduced) {
              expect(find.byType(MenuItemButton), findsNWidgets(2));
            }
            await tester.pumpAndSettle();
            expect(find.byType(MenuItemButton), findsNothing);
            expect(host.trigger.hasFocus, isTrue);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }

      testWidgets(
        'explicit cancellation cannot steal pending external focus reduced=$reduced',
        (tester) async {
          final host = await _focusHost(tester, reduced: reduced);
          await tester.tap(find.text('Focus trigger'));
          await tester.pumpAndSettle();
          _menuItemFocus(tester, 'First').requestFocus();
          FocusManager.instance.applyFocusChangesIfNeeded();
          // Do not apply the external request or rebuild before real cancellation.
          host.external.requestFocus();
          Navigator.of(host.origin).pop();
          expect(host.external.hasFocus, isTrue);
          expect(host.trigger.hasFocus, isFalse);
          await tester.pumpAndSettle();
          expect(host.external.hasFocus, isTrue);
          expect(host.trigger.hasFocus, isFalse);
          expect(find.byType(MenuItemButton), findsNothing);
          expect(host.selected, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );

      for (final retirement in ['task', 'identity', 'route']) {
        testWidgets(
          '$retirement retirement never returns trigger focus reduced=$reduced',
          (tester) async {
            final host = await _focusHost(tester, reduced: reduced);
            await tester.tap(find.text('Focus trigger'));
            await tester.pumpAndSettle();
            final cached = tester
                .widget<MenuItemButton>(
                  find.widgetWithText(MenuItemButton, 'First'),
                )
                .onPressed!;
            _menuItemFocus(tester, 'First').requestFocus();
            FocusManager.instance.applyFocusChangesIfNeeded();
            FocusNode? coverFocus;
            switch (retirement) {
              case 'task':
                host.active.value = false;
                // LocalHistory still exists; its explicit cancellation reads live
                // task qualification before any declarative update.
                Navigator.of(host.origin).pop();
                expect(host.trigger.hasFocus, isFalse);
              case 'identity':
                host.external.requestFocus();
                FocusManager.instance.applyFocusChangesIfNeeded();
                host.identity.value++;
              case 'route':
                final focus = FocusNode();
                coverFocus = focus;
                addTearDown(focus.dispose);
                Navigator.of(host.origin).push<void>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      body: TextField(focusNode: focus, autofocus: true),
                    ),
                  ),
                );
            }
            await tester.pump();
            cached();
            expect(host.selected, isEmpty);
            expect(host.trigger.hasFocus, isFalse);
            await tester.pumpAndSettle();
            expect(find.byType(MenuItemButton), findsNothing);
            expect(host.trigger.hasFocus, isFalse);
            if (retirement == 'identity') {
              expect(host.external.hasFocus, isTrue);
            }
            if (coverFocus != null) expect(coverFocus.hasFocus, isTrue);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }

    testWidgets('a closed trigger does not consume its parent dialog Escape', (
      tester,
    ) async {
      late BuildContext origin;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              origin = context;
              return const Scaffold();
            },
          ),
        ),
      );
      FocusNode? trigger;
      final result = showDialog<void>(
        context: origin,
        builder: (context) => Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                Navigator.of(context).pop();
                return null;
              },
            ),
          },
          child: AlertDialog(
            content: ChoiceMenuButton<int>(
              options: const {1: 'First'},
              onSelected: (_) => fail('closed menu selected an option'),
              buttonBuilder: (_, onPressed, focus) {
                trigger = focus;
                return TextButton(
                  focusNode: focus,
                  onPressed: onPressed,
                  child: const Text('Closed trigger'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      trigger!.requestFocus();
      FocusManager.instance.applyFocusChangesIfNeeded();
      expect(trigger!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await result;
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'cached menu actions lose live task qualification before rebuild',
      (tester) async {
        final active = ValueNotifier(true);
        addTearDown(active.dispose);
        final selected = <int>[];
        final releaseSemantics = _retainSemantics(tester);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: ValueListenableBuilder(
                valueListenable: active,
                builder: (context, value, _) => AppTaskActivity(
                  active: value,
                  isActiveNow: () => active.value,
                  child: Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: ChoiceMenuButton<int>(
                        options: const {1: 'Old task command'},
                        onSelected: selected.add,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byType(ChoiceMenuButton<int>));
          await tester.pumpAndSettle();
          final item = find.widgetWithText(MenuItemButton, 'Old task command');
          final cached = tester.widget<MenuItemButton>(item).onPressed!;
          active.value = false;
          cached();
          expect(selected, isEmpty);
          await tester.pump();
          expect(item.hitTestable(), findsNothing);
          expect(
            tester.semantics.simulatedAccessibilityTraversal().map(
              (node) => node.getSemanticsData().label,
            ),
            isNot(contains('Old task command')),
          );
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          releaseSemantics();
        }
      },
    );

    for (final language in ['en', 'zh']) {
      for (final width in [320.0, 700.0]) {
        testWidgets(
          'icon commands retain complete labels and no check slot $language/$width',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 700);
            addTearDown(tester.view.reset);
            final strings = lookupAppLocalizations(Locale(language));
            final labels = [strings.dnsClearCache, strings.dnsClearFakeIp];
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topRight,
                    child: Builder(
                      builder: (context) {
                        final colors = Theme.of(context).colorScheme;
                        return ChoiceMenuButton<bool>(
                          options: {false: labels[0], true: labels[1]},
                          onSelected: (_) {},
                          leadingIcon: (fakeIp) => Icon(
                            fakeIp
                                ? Icons.link_off
                                : Icons.cleaning_services_outlined,
                            color: fakeIp
                                ? colors.error
                                : colors.onSurfaceVariant,
                          ),
                          optionBuilder: (fakeIp, label) => Text(
                            label,
                            style: TextStyle(
                              color: fakeIp ? colors.error : colors.onSurface,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
            final trigger = find.byType(ChoiceMenuButton<bool>);
            expect(
              tester.getSize(trigger).shortestSide,
              greaterThanOrEqualTo(48),
            );
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            final panel = tester.getRect(surface());
            expect(panel.width, greaterThan(48));
            expect(panel.left, greaterThanOrEqualTo(0));
            expect(panel.right, lessThanOrEqualTo(width));
            for (final label in labels) {
              final item = find.widgetWithText(MenuItemButton, label);
              final button = tester.widget<MenuItemButton>(item);
              expect(button.leadingIcon, isNotNull);
              expect(button.trailingIcon, isNull);
              expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
              expect(tester.widget<Text>(find.text(label)).data, label);
              expect(
                tester
                    .renderObject<RenderParagraph>(find.text(label))
                    .didExceedMaxLines,
                isFalse,
              );
            }
            expect(find.byIcon(Icons.check), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }

    testWidgets(
      'SDK menu animation reverses in place and selections do not wait for exit',
      (tester) async {
        final selected = <int>[];
        final releaseSemantics = _retainSemantics(tester);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: ChoiceMenuButton<int>(
                    key: const ValueKey('animated-choice'),
                    options: const {1: 'First', 2: 'Second'},
                    onSelected: selected.add,
                  ),
                ),
              ),
            ),
          );
          final trigger = find.byKey(const ValueKey('animated-choice'));
          final state = tester.state(trigger);
          await tester.tap(trigger);
          await tester.pump();
          expect(
            tester.widget<MenuAnchor>(find.byType(MenuAnchor)).animated,
            isTrue,
          );
          Animation<double> opacity() => tester
              .widget<FadeTransition>(
                find
                    .ancestor(
                      of: find.text('First'),
                      matching: find.byType(FadeTransition),
                    )
                    .first,
              )
              .opacity;
          expect(opacity().value, 0);
          await tester.pump(const Duration(milliseconds: 40));
          final opening = opacity().value;
          expect(opening, inExclusiveRange(0, 1));
          await tester.tap(trigger);
          await tester.pump();
          expect(opacity().value, closeTo(opening, .001));
          expect(
            find.widgetWithText(MenuItemButton, 'First').hitTestable(),
            findsNothing,
          );
          expect(
            tester.semantics.simulatedAccessibilityTraversal().map(
              (node) => node.getSemanticsData().label,
            ),
            isNot(contains('First')),
          );
          await tester.tap(trigger);
          await tester.pump();
          expect(opacity().value, closeTo(opening, .001));
          expect(tester.state(trigger), same(state));
          await tester.pumpAndSettle();
          expect(opacity().value, 1);
          expect(
            tester.semantics.simulatedAccessibilityTraversal().map(
              (node) => node.getSemanticsData().label,
            ),
            contains('First'),
          );
          final second = find.widgetWithText(MenuItemButton, 'Second');
          final cachedSelection = tester
              .widget<MenuItemButton>(second)
              .onPressed!;
          await tester.tap(second);
          expect(selected, isEmpty);
          // MenuItemButton dispatches onPressed after this frame has rendered.
          await tester.pump();
          expect(selected, [2]);
          expect(opacity().status, AnimationStatus.reverse);
          cachedSelection();
          expect(selected, [2]);
          // Render the first closing frame without advancing animation time.
          await tester.pump();
          expect(opacity().status, AnimationStatus.reverse);
          expect(opacity().value, 1);
          expect(find.byType(MenuItemButton), findsNWidgets(2));
          expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
          expect(
            tester.semantics.simulatedAccessibilityTraversal().map(
              (node) => node.getSemanticsData().label,
            ),
            isNot(anyOf(contains('First'), contains('Second'))),
          );
          expect(
            tester
                .widgetList<ExcludeFocus>(
                  find.ancestor(
                    of: second,
                    matching: find.byType(ExcludeFocus),
                  ),
                )
                .any((widget) => widget.excluding),
            isTrue,
          );
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          expect(FocusManager.instance.primaryFocus?.context, isNotNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          releaseSemantics();
        }
      },
    );

    testWidgets(
      'reduced motion is immediate and selection uses background and semantics',
      (tester) async {
        final reduced = ValueNotifier(true);
        addTearDown(reduced.dispose);
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: ValueListenableBuilder(
              valueListenable: reduced,
              builder: (context, value, _) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: value),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: ChoiceMenuButton<int>(
                      key: const ValueKey('reduced-choice'),
                      value: 2,
                      options: const {1: 'First', 2: 'Second'},
                      onSelected: selected.add,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final trigger = find.byKey(const ValueKey('reduced-choice'));
        final state = tester.state(trigger);
        await tester.tap(trigger);
        await tester.pump();
        expect(
          tester.widget<MenuAnchor>(find.byType(MenuAnchor)).animated,
          isFalse,
        );
        final buttons = tester
            .widgetList<MenuItemButton>(find.byType(MenuItemButton))
            .toList();
        expect(
          buttons.map((button) => button.trailingIcon),
          everyElement(isNull),
        );
        final colors = Theme.of(tester.element(trigger)).colorScheme;
        for (final button in buttons) {
          final selectedItem = button.key == const ValueKey(2);
          expect(
            button.style!.backgroundColor!.resolve({}),
            selectedItem ? colors.surfaceContainerHighest : Colors.transparent,
          );
          expect(
            button.style!.textStyle!.resolve({})!.fontWeight,
            selectedItem ? FontWeight.w700 : FontWeight.w400,
          );
          final semantics = find.ancestor(
            of: find.byWidget(button),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.selected != null,
            ),
          );
          expect(
            tester.widget<Semantics>(semantics.first).properties.selected,
            selectedItem,
          );
        }
        expect(find.byIcon(Icons.check), findsNothing);
        reduced.value = false;
        await tester.pump();
        expect(
          tester.widget<MenuAnchor>(find.byType(MenuAnchor)).animated,
          isTrue,
        );
        expect(tester.state(trigger), same(state));
        reduced.value = true;
        await tester.pump();
        final animation = tester
            .widget<FadeTransition>(
              find
                  .ancestor(
                    of: find.text('First'),
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity;
        await tester.tap(find.widgetWithText(MenuItemButton, 'First'));
        expect(selected, isEmpty);
        // Selection and the zero-duration close are accepted post-frame.
        await tester.pump();
        expect(selected, [1]);
        expect(animation.status, AnimationStatus.dismissed);
        // Apply the SDK overlay removal, still without advancing the clock.
        await tester.pump();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final language in ['zh', 'en']) {
      for (final width in [280.0, 320.0, 700.0, 1704.0]) {
        for (final scale in [1.0, 1.3, 2.0]) {
          for (final left in [true, false]) {
            testWidgets(
              'content-sized surface and long choices $language $width $scale left=$left',
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
                  // Content may extend on either side of a small trigger. The
                  // SDK positions the complete menu inside the workspace.
                  final panel = tester.getRect(surface());
                  expect(panel.left, greaterThanOrEqualTo(0));
                  expect(panel.right, lessThanOrEqualTo(width));
                  expect(panel.width, greaterThan(144));
                  expect(panel.top, greaterThanOrEqualTo(0));
                  expect(panel.bottom, lessThanOrEqualTo(900));
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
        final trigger = find.byType(ChoiceMenuButton<int>);
        for (final width in [700.0, 599.0, 1704.0]) {
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          final panel = tester.getRect(surface());
          expect(panel.left, greaterThanOrEqualTo(0));
          expect(
            panel.right,
            lessThanOrEqualTo(tester.view.physicalSize.width),
          );
          expect(panel.top, greaterThanOrEqualTo(0));
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
            frames.add((
              ms,
              tester.getRect(surface()),
              tester.getRect(trigger),
            ));
            expect(tester.takeException(), isNull);
          }
          for (final (ms, panel, anchor) in frames) {
            expect(panel.left, greaterThanOrEqualTo(12));
            expect(panel.right, lessThanOrEqualTo(680));
            expect(tester.getRect(trigger), anchor);
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
  });
  group('choice_menu_lifecycle', () {
    testWidgets('root menu registers Android Back before it can be invoked', (
      tester,
    ) async {
      final handlesBack = <bool>[];
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
            handlesBack.add(call.arguments as bool);
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('Root')),
            body: ChoiceMenuButton<int>(
              options: const {1: 'First'},
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(handlesBack.last, isFalse);
      for (final select in [false, true]) {
        await tester.tap(find.byIcon(Icons.arrow_drop_down));
        await tester.pumpAndSettle();
        expect(handlesBack.last, isTrue);
        expect(find.byType(BackButton), findsNothing);
        if (select) {
          await tester.tap(find.byType(MenuItemButton));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(find.text('Root'), findsOneWidget);
        expect(handlesBack.last, isFalse);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'system Back dismisses the menu without moving the AppBar or popping the page',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              appBar: AppBar(title: const Text('Page')),
              body: Align(
                alignment: Alignment.topRight,
                child: ChoiceMenuButton<int>(
                  options: const {1: 'First'},
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        );
        final title = tester.getRect(find.text('Page'));
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        expect(find.byType(BackButton), findsNothing);
        expect(tester.getRect(find.text('Page')), title);
        await tester.binding.handlePopRoute();
        for (final milliseconds in [0, 16, 100, 300]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          expect(tester.getRect(find.text('Page')), title);
          expect(find.byType(BackButton), findsNothing);
        }
        expect(find.byType(MenuItemButton), findsNothing);
        expect(navigator.currentState!.canPop(), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a retired callback cannot borrow a newly opened menu identity',
      (tester) async {
        final epoch = ValueNotifier(1);
        addTearDown(epoch.dispose);
        final saved = <(int, int)>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: epoch,
                builder: (context, identity, _) => Align(
                  alignment: Alignment.topRight,
                  child: ChoiceMenuButton<int>(
                    identity: identity,
                    options: const {1: 'First'},
                    onSelected: (value) => saved.add((identity, value)),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        final retired = tester.widget<MenuItemButton>(
          find.byType(MenuItemButton),
        );
        epoch.value = 2;
        await tester.pumpAndSettle();
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        retired.onPressed!();
        expect(saved, isEmpty);
        await tester.tap(find.byType(MenuItemButton));
        await tester.pumpAndSettle();
        expect(saved, [(2, 1)]);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final animations in [false, true]) {
      testWidgets(
        'cancelled selection cannot target a reopened same-identity menu animations=$animations',
        (tester) async {
          final selected = <int>[];
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: !animations),
                child: child!,
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topRight,
                  child: ChoiceMenuButton<int>(
                    identity: 'same-source',
                    options: const {1: 'First'},
                    onSelected: selected.add,
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byType(IconButton));
          await tester.pumpAndSettle();
          final retired = tester
              .widget<MenuItemButton>(find.byType(MenuItemButton))
              .onPressed!;
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          retired();
          expect(selected, isEmpty);
          await tester.tap(find.byType(IconButton));
          await tester.pumpAndSettle();
          retired();
          expect(selected, isEmpty);
          await tester.tap(find.byType(MenuItemButton));
          await tester.pumpAndSettle();
          expect(selected, [1]);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets(
      'a covering route dismisses the menu and rejects its old callback',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        var selected = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: ChoiceMenuButton<int>(
                  options: const {1: 'First'},
                  onSelected: (_) => selected++,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        final old = tester.widget<MenuItemButton>(find.byType(MenuItemButton));
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Cover')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        old.onPressed!();
        expect(selected, 0);
        expect(find.byType(MenuItemButton), findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(navigator.currentState!.canPop(), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('selecting retires Back history before the operation starts', (
      tester,
    ) async {
      final pending = Completer<void>();
      var started = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Operation page')),
                      body: ChoiceMenuButton<int>(
                        options: const {1: 'Start'},
                        onSelected: (_) async {
                          started = true;
                          await pending.future;
                        },
                      ),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Start'));
      await tester.pump();
      expect(started, isTrue);
      final route = ModalRoute.of(tester.element(find.text('Operation page')))!;
      expect(route.willHandlePopInternally, isFalse);
      // SDK activation ran after the preceding frame. Draw the first closing
      // frame without advancing time before sending Back through its hit targets.
      final beforeExitFrame = tester.binding.clock.now();
      await tester.pump();
      expect(tester.binding.clock.now(), beforeExitFrame);
      expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Operation page'), findsNothing);
      pending.complete();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('backgrounding retires an open menu before any resumed frame', (
      tester,
    ) async {
      final selected = <int>[];
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: ChoiceMenuButton<int>(
                  identity: 'unchanged',
                  options: const {1: 'First'},
                  onSelected: selected.add,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        final old = tester
            .widget<MenuItemButton>(find.byType(MenuItemButton))
            .onPressed!;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        old();
        expect(selected, isEmpty);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        old();
        expect(selected, isEmpty);
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(MenuItemButton));
        await tester.pumpAndSettle();
        expect(selected, [1]);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    });

    testWidgets('temporary disable cannot revive a closing selection', (
      tester,
    ) async {
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: enabled,
              builder: (context, value, _) => ChoiceMenuButton<int>(
                identity: 'same-source',
                enabled: value,
                options: const {1: 'First'},
                onSelected: selected.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      final old = tester
          .widget<MenuItemButton>(find.byType(MenuItemButton))
          .onPressed!;
      expect(find.semantics.byLabel('First'), findsOne);
      enabled.value = false;
      await tester.pump();
      expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
      expect(find.semantics.byLabel('First'), findsNothing);
      enabled.value = true;
      await tester.pump();
      old();
      for (final item in tester.widgetList<MenuItemButton>(
        find.byType(MenuItemButton),
      )) {
        item.onPressed?.call();
      }
      expect(selected, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      old();
      expect(selected, isEmpty);
      await tester.tap(find.byType(MenuItemButton));
      await tester.pumpAndSettle();
      expect(selected, [1]);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    }, semanticsEnabled: true);

    testWidgets('returning to the opening size cannot revive a closing menu', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: ChoiceMenuButton<int>(
                identity: 'same-source',
                options: const {1: 'First'},
                onSelected: selected.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      final old = tester
          .widget<MenuItemButton>(find.byType(MenuItemButton))
          .onPressed!;
      tester.view.physicalSize = const Size(599, 900);
      await tester.pump();
      tester.view.physicalSize = const Size(700, 900);
      await tester.pump();
      old();
      expect(selected, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      old();
      expect(selected, isEmpty);
      await tester.tap(find.byType(MenuItemButton));
      await tester.pumpAndSettle();
      expect(selected, [1]);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'disabled options stay disabled and availability changes retire the opening',
      (tester) async {
        final disabled = ValueNotifier<Set<int>>({2});
        addTearDown(disabled.dispose);
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder(
                valueListenable: disabled,
                builder: (context, value, _) => ChoiceMenuButton<int>(
                  identity: 'same-source',
                  options: const {1: 'First', 2: 'Unavailable'},
                  disabledOptions: value,
                  onSelected: selected.add,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        final blocked = find.widgetWithText(MenuItemButton, 'Unavailable');
        expect(tester.widget<MenuItemButton>(blocked).onPressed, isNull);
        await tester.tap(blocked);
        await tester.pump();
        expect(selected, isEmpty);
        final old = tester
            .widget<MenuItemButton>(
              find.widgetWithText(MenuItemButton, 'First'),
            )
            .onPressed!;
        disabled.value = {};
        await tester.pump();
        disabled.value = {2};
        await tester.pump();
        old();
        expect(selected, isEmpty);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        expect(tester.widget<MenuItemButton>(blocked).onPressed, isNull);
        await tester.tap(find.widgetWithText(MenuItemButton, 'First'));
        await tester.pumpAndSettle();
        expect(selected, [1]);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('disposing during opening retires local history and focus', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChoiceMenuButton<int>(
              options: const {1: 'First'},
              onSelected: (_) => fail('Disposed menu selected'),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
