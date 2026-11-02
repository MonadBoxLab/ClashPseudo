import 'package:clash_pseudo/src/ui/overrides/definitions/local_custom_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用户从 SnackBar 打开完整错误；确认 Dialog 不经过此入口。
Future<void> openNoticeDetails(WidgetTester tester) async {
  if (find.byType(AlertDialog).evaluate().isNotEmpty) return;
  await settleLocalDefinitions(tester);
  final details = find
      .descendant(of: find.byType(SnackBar), matching: find.byType(TextButton))
      .first;
  expect(details, findsOneWidget);
  await tester.tap(details);
  await settleLocalDefinitions(tester);
}

Future<void> dismissNotice(WidgetTester tester) async {
  await settleLocalDefinitions(tester);
  final close = find.descendant(
    of: find.byType(SnackBar),
    matching: find.byIcon(Icons.close),
  );
  if (close.evaluate().isEmpty) return;
  await tester.tap(close);
  await settleLocalDefinitions(tester);
}

/// 等待实际 compute 解析及分类动画结束。
Future<void> settleLocalDefinitions(WidgetTester tester) async {
  bool parsing() =>
      tester.stateList<State>(find.byType(LocalDefinitions)).any((state) {
        final properties = DiagnosticPropertiesBuilder();
        state.debugFillProperties(properties);
        return properties.properties.any(
          (property) => property.name == 'parsing' && property.value == true,
        );
      });

  await tester.pump();
  for (var attempt = 0; attempt < 1000; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (parsing()) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    } else if (!tester.binding.hasScheduledFrame) {
      return;
    }
  }
  expect(
    parsing(),
    isFalse,
    reason: 'The real local-definition parse must finish',
  );
  expect(
    tester.binding.hasScheduledFrame,
    isFalse,
    reason: 'Category animations must settle after the real parse',
  );
}
