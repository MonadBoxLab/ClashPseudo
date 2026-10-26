import 'package:clash_pseudo/src/features/overrides/local_custom_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wait for actual compute completion through isolate messaging independently of row
/// visibility.
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
