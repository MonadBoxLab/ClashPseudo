import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  testWidgets('mobile editor disposal cancels pending cursor callbacks', (
    tester,
  ) async {
    final controller = CodeLineEditingController.fromText('fixture');
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeEditor(controller: controller, focusNode: focus),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    controller.selectAll();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping blink cancels delayed cursor visibility', (
    tester,
  ) async {
    final controller = CodeLineEditingController.fromText('fixture');
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeEditor(
            controller: controller,
            focusNode: focus,
            autofocus: false,
          ),
        ),
      ),
    );
    final cursor = _cursorVisibility(tester);
    focus.requestFocus();
    await tester.pump();
    expect(cursor.value, isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    focus.unfocus();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.pump(const Duration(milliseconds: 51));
    expect(cursor.value, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('restarting blink replaces the delayed visibility callback', (
    tester,
  ) async {
    final controller = CodeLineEditingController.fromText('fixture');
    final focus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeEditor(
            controller: controller,
            focusNode: focus,
            autofocus: false,
          ),
        ),
      ),
    );
    final cursor = _cursorVisibility(tester);
    focus.requestFocus();
    await tester.pump();
    expect(cursor.value, isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    controller.selection = const CodeLineSelection.collapsed(
      index: 0,
      offset: 1,
    );
    await tester.pump();
    // Advance past the old blink deadline while the replacement deadline remains
    // pending.
    await tester.pump(const Duration(milliseconds: 51));
    expect(cursor.value, isFalse);
    await tester.pump(const Duration(milliseconds: 49));
    expect(cursor.value, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    focus.dispose();
    await tester.pump(const Duration(milliseconds: 101));
    expect(tester.takeException(), isNull);
  });
}

ValueNotifier<bool> _cursorVisibility(WidgetTester tester) {
  // Observe the notifier consumed by the actual field render.
  final dynamic field = tester.renderObject(
    find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_CodeField',
    ),
  );
  return field.showCursorNotifier as ValueNotifier<bool>;
}
