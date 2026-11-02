import 'dart:typed_data';

import 'package:clash_pseudo/src/ui/components/collections/exact_size_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

double _previousDouble(double value) {
  final bytes = ByteData(8)..setFloat64(0, value);
  bytes.setUint64(0, bytes.getUint64(0) - 1);
  return bytes.getFloat64(0);
}

void main() {
  for (final height in [148.0, 316.0, 306.0, 896.0]) {
    testWidgets('exact size noop retains box clip hits and semantics $height', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1200);
      addTearDown(tester.view.reset);
      final relayout = ValueNotifier(false);
      addTearDown(relayout.dispose);
      final semantics = tester.ensureSemantics();
      try {
        var taps = 0;
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 280,
                child: ValueListenableBuilder<bool>(
                  valueListenable: relayout,
                  builder: (_, shifted, _) => ExactSizeTransition(
                    child: Padding(
                      padding: EdgeInsets.only(left: shifted ? 1 : 0),
                      child: RepaintBoundary(
                        child: SizedBox(
                          height: height,
                          child: Semantics(
                            key: const ValueKey('exact-target'),
                            container: true,
                            label: 'Exact target',
                            button: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => taps++,
                              child: const ColoredBox(color: Colors.blue),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final animation = find.bySubtype<AnimatedSize>();
        final element = tester.element(animation);
        final box = tester.renderObject<RenderAnimatedSize>(animation);
        final target = find.byKey(const ValueKey('exact-target'));
        final targetElement = tester.element(target);
        final expected = Size(280, height);
        expect(box.size, expected);
        relayout.value = true;
        await tester.pump();
        var sawClip = false;
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.element(animation), same(element));
          expect(tester.element(target), same(targetElement));
          expect(box.size, expected);
          expect(box.getDryLayout(box.constraints), expected);
          expect(tester.getSemantics(target).rect.height, height);
          for (final clip in tester.layers.whereType<ClipRectLayer>()) {
            if (clip.clipRect?.width == 280) {
              sawClip = true;
              expect(clip.clipRect, Offset.zero & expected);
            }
          }
          // The exact representable predecessor, not a tolerance, exercises
          // the bottom edge that a one-ulp-short SDK box would reject.
          await tester.tapAt(Offset(100, _previousDouble(height)));
          expect(taps, frame + 1);
          expect(tester.takeException(), isNull);
        }
        expect(sawClip, isTrue);
        expect(box.isAnimating, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final rapid in [false, true]) {
    testWidgets(
      'exact size delegates real SDK resize and reverse rapid=$rapid',
      (tester) async {
        final height = ValueNotifier(148.0);
        addTearDown(height.dispose);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: ValueListenableBuilder<double>(
                valueListenable: height,
                builder: (_, value, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 280,
                      child: ExactSizeTransition(
                        child: SizedBox(height: value),
                      ),
                    ),
                    SizedBox(
                      width: 280,
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeInOutCubic,
                        alignment: Alignment.topCenter,
                        child: SizedBox(height: value),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final exact = tester.renderObject<RenderAnimatedSize>(
          find.byType(ExactSizeTransition),
        );
        final sdk = tester.renderObject<RenderAnimatedSize>(
          find.byType(AnimatedSize),
        );
        void sameSdk() {
          expect(exact.size, sdk.size);
          expect(exact.isAnimating, sdk.isAnimating);
          expect(
            exact.getDryLayout(exact.constraints),
            sdk.getDryLayout(sdk.constraints),
          );
          expect(tester.takeException(), isNull);
        }

        height.value = 316;
        await tester.pump();
        sameSdk();
        expect(exact.size.height, 148);
        if (rapid) {
          // A second target before the changed child stabilizes belongs to
          // the SDK's unstable-child handling, not a new local state machine.
          height.value = 306;
          await tester.pump(const Duration(milliseconds: 16));
          sameSdk();
          height.value = 220;
          await tester.pump(const Duration(milliseconds: 16));
          sameSdk();
        } else {
          await tester.pump(const Duration(milliseconds: 70));
          sameSdk();
          final middle = exact.size.height;
          expect(middle, greaterThan(148));
          expect(middle, lessThan(316));
          height.value = 148;
          await tester.pump();
          sameSdk();
          expect(exact.size.height, middle);
          await tester.pump(const Duration(milliseconds: 70));
          sameSdk();
          expect(exact.size.height, lessThan(middle));
        }
        await tester.pump(const Duration(milliseconds: 180));
        sameSdk();
        expect(exact.size.height, height.value);
        expect(exact.isAnimating, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('exact size reduced bypass restores fresh target and live IME', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    final height = ValueNotifier(148.0);
    final text = TextEditingController();
    final focus = FocusNode();
    final content = GlobalKey();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 280,
                child: ValueListenableBuilder<bool>(
                  valueListenable: reduced,
                  builder: (_, bypass, _) => ValueListenableBuilder<double>(
                    valueListenable: height,
                    builder: (_, value, _) {
                      final child = KeyedSubtree(
                        key: content,
                        child: SizedBox(
                          height: value,
                          child: TextField(controller: text, focusNode: focus),
                        ),
                      );
                      return bypass ? child : ExactSizeTransition(child: child);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      const draft = TextEditingValue(
        text: 'draft 文',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 6, end: 7),
      );
      tester.testTextInput.updateEditingValue(draft);
      await tester.pump();
      final field = tester.element(find.byType(TextField));
      final editor = tester.state<EditableTextState>(find.byType(EditableText));
      final original = tester.renderObject<RenderAnimatedSize>(
        find.byType(ExactSizeTransition),
      );
      height.value = 316;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(original.size.height, greaterThan(148));
      expect(original.size.height, lessThan(316));
      reduced.value = true;
      await tester.pump();
      expect(find.bySubtype<AnimatedSize>(), findsNothing);
      reduced.value = false;
      await tester.pump();
      final restored = tester.renderObject<RenderAnimatedSize>(
        find.byType(ExactSizeTransition),
      );
      expect(restored, isNot(same(original)));
      expect(restored.size, const Size(280, 316));
      expect(tester.element(find.byType(TextField)), same(field));
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editor),
      );
      expect(text.value, draft);
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      height.value = 148;
      await tester.pump();
      expect(restored.size.height, 316);
      await tester.pump(const Duration(milliseconds: 70));
      expect(restored.size.height, greaterThan(148));
      expect(restored.size.height, lessThan(316));
      expect(text.value, draft);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      reduced.dispose();
      height.dispose();
      text.dispose();
      focus.dispose();
    }
  });
}
