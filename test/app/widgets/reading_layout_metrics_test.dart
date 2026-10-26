import 'dart:convert';

import 'package:clash_pseudo/src/app/widgets/reading_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _enabled = bool.fromEnvironment('validationLayoutMetrics');

void main() {
  testWidgets(
    'layout observation is opt-in, bounded and reports actual Flutter metrics',
    (tester) async {
      tester.view.physicalSize = const Size(3408, 2272);
      tester.view.devicePixelRatio = 2;
      tester.view.padding = const FakeViewPadding(top: 72, bottom: 64);
      tester.view.viewPadding = const FakeViewPadding(top: 72, bottom: 64);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetViewInsets);
      final tick = ValueNotifier(0);
      addTearDown(tick.dispose);
      final records = <Map<String, dynamic>>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message?.startsWith('CATEGORY_LAYOUT ') == true) {
          expect(message, isNot(contains('private sample text')));
          records.add(
            jsonDecode(message!.substring('CATEGORY_LAYOUT '.length))
                as Map<String, dynamic>,
          );
        } else {
          previous(message, wrapWidth: wrapWidth);
        }
      };
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 840),
                  child: ValueListenableBuilder<int>(
                    valueListenable: tick,
                    builder: (context, value, _) => ReadingList(
                      identity: 0,
                      header: Text('private sample text $value'),
                      items: const [],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        if (_enabled) {
          expect(records, isNotEmpty);
          final actual = records.last;
          expect(actual['window'], [1704.0, 1136.0]);
          expect(actual['inheritedSize'], [1704.0, 1136.0]);
          expect(actual['devicePixelRatio'], 2);
          expect(actual['viewPadding'], [0.0, 36.0, 0.0, 32.0]);
          expect((actual['parent'] as List)[1], 840);
          expect(actual['scaledText'], [14.0, 16.0, 28.0]);
        } else {
          expect(records, isEmpty);
        }
        tester.view.viewInsets = const FakeViewPadding(bottom: 600);
        await tester.pump();
        if (_enabled) {
          expect(records.last['viewInsets'], [0.0, 0.0, 0.0, 300.0]);
        }
        for (var i = 1; i <= 40; i++) {
          tick.value = i;
          await tester.pump();
        }
        expect(records.length, _enabled ? 16 : 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        debugPrint = previous;
      }
    },
  );
}
