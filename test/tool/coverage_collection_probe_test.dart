import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/coverage_probe.dart' as probe;

void main() {
  var bodyRan = false;
  tearDownAll(() {
    expect(bodyRan, isTrue);
    expect(probe.suiteTeardown(), 17);
  });
  test(
    'known functions and both outcomes execute before coverage collection',
    () {
      bodyRan = true;
      expect(probe.exercised(true), 1);
      expect(probe.exercised(false), 2);
      expect(probe.firstSameLine(), 1);
      final rows = <Map<String, Object?>>[];
      for (final (first, second, result, secondCalls) in [
        (false, false, 2, 0),
        (false, true, 2, 0),
        (true, false, 2, 1),
        (true, true, 1, 1),
      ]) {
        var callsA = 0;
        var callsB = 0;
        final actual = probe.composite(
          () {
            callsA++;
            return first;
          },
          () {
            callsB++;
            return second;
          },
        );
        expect(actual, result);
        expect(callsA, 1);
        expect(callsB, secondCalls);
        rows.add({
          'first': first,
          'second': second,
          'firstCalls': callsA,
          'secondCalls': callsB,
          'result': actual,
        });
      }
      // Record explicit operand observations alongside VM branch-source positions.
      stdout.writeln('COVERAGE_COMPOUND_EVIDENCE:${jsonEncode(rows)}');
    },
  );
}
