import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  testWidgets('mobile selection autoscroll ignores a disposed editor', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final selection = _selectionGesture(tester);
    final start =
        tester.getTopLeft(find.byType(CodeEditor)) + const Offset(12, 12);
    selection.onLongPressStart!(LongPressStartDetails(globalPosition: start));
    selection.onLongPressMoveUpdate!(
      LongPressMoveUpdateDetails(
        globalPosition: fixture.bottom,
        localOffsetFromOrigin: fixture.bottom - start,
      ),
    );
    await tester.pump(const Duration(milliseconds: 101));
    expect(fixture.scroll.verticalScroller.offset, greaterThan(0));
    expect(fixture.controller.selection.isCollapsed, isFalse);
    expect(tester.takeException(), isNull);

    // After the first auto-scroll, leave with the next 100ms callback pending. Invoke
    // accepted gesture callbacks directly to isolate delayed render access.
    await fixture.disposeEditor(tester);
  });

  for (final handle in [0, 1]) {
    testWidgets(
      'mobile handle $handle autoscroll ignores an unavailable field',
      (tester) async {
        final fixture = await _mount(tester);
        final selection = _selectionGesture(tester);
        final start =
            tester.getTopLeft(find.byType(CodeEditor)) + const Offset(12, 12);
        selection.onLongPressStart!(
          LongPressStartDetails(globalPosition: start),
        );
        selection.onLongPressEnd!(LongPressEndDetails(globalPosition: start));
        await tester.pump(const Duration(milliseconds: 101));
        expect(fixture.controller.selection.isCollapsed, isFalse);

        final handles = find.byWidgetPredicate(
          (widget) =>
              widget is RawGestureDetector &&
              widget.gestures.containsKey(PanGestureRecognizer),
        );
        expect(handles, findsNWidgets(2));
        final raw = tester.widget<RawGestureDetector>(handles.at(handle));
        final factory =
            raw.gestures[PanGestureRecognizer]!
                as GestureRecognizerFactory<PanGestureRecognizer>;
        final recognizer = factory.constructor();
        factory.initializer(recognizer);
        addTearDown(recognizer.dispose);
        // The real handle callback schedules the production autoscroll loop.
        // Keep the accepted drag active across field disposal, independently of
        // framework recognizer cancellation ordering.
        recognizer.onStart!(DragStartDetails(globalPosition: start));
        recognizer.onUpdate!(
          DragUpdateDetails(globalPosition: fixture.bottom, delta: Offset.zero),
        );
        await tester.pump(const Duration(milliseconds: 101));
        expect(fixture.scroll.verticalScroller.offset, greaterThan(0));
        expect(tester.takeException(), isNull);
        // Full CodeEditor.dispose resets both drag flags in 0.10.0 already.
        // Remove only the field through the public scrollbar builder, keeping
        // its overlay controller alive so that the render guard is exercised.
        fixture.fieldVisible.value = false;
        await tester.pump();
        expect(find.byType(CodeEditor), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 101));
        expect(tester.takeException(), isNull);
        await fixture.disposeEditor(tester);
      },
    );
  }
}

GestureDetector _selectionGesture(WidgetTester tester) =>
    tester.widget<GestureDetector>(
      find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector && widget.onLongPressStart != null,
      ),
    );

Future<_EditorFixture> _mount(WidgetTester tester) async {
  final fixture = _EditorFixture();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            height: 160,
            child: CodeEditor(
              controller: fixture.controller,
              focusNode: fixture.focus,
              scrollController: fixture.scroll,
              scrollbarBuilder: (context, child, details) =>
                  ValueListenableBuilder<bool>(
                    valueListenable: fixture.fieldVisible,
                    builder: (context, visible, _) =>
                        visible ? child : const SizedBox.shrink(),
                  ),
            ),
          ),
        ),
      ),
    ),
  );
  fixture.focus.requestFocus();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 101));
  expect(fixture.focus.hasFocus, isTrue);
  fixture.bottom =
      tester.getBottomLeft(find.byType(CodeEditor)) + const Offset(80, -2);
  return fixture;
}

class _EditorFixture {
  final controller = CodeLineEditingController.fromText(
    List.generate(100, (index) => 'line $index selection fixture').join('\n'),
  );
  final focus = FocusNode();
  final scroll = CodeScrollController();
  final fieldVisible = ValueNotifier(true);
  late Offset bottom;

  Future<void> disposeEditor(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
    scroll.dispose();
    scroll.verticalScroller.dispose();
    scroll.horizontalScroller.dispose();
    fieldVisible.dispose();
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.takeException(), isNull);
    // Verify the stopped loop stays stopped after its late callback.
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  }
}
