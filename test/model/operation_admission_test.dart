import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final milliseconds in [0, 1, 117000, 300000]) {
    test('admission preserves the actual remaining $milliseconds ms', () {
      final admission = OperationAdmission.fromMap({
        'operationId': 'accepted-operation',
        'remainingMs': milliseconds,
      });
      expect(admission.operationId, 'accepted-operation');
      expect(admission.remaining, Duration(milliseconds: milliseconds));
    });
  }

  for (final invalid in <Map<Object?, Object?>>[
    {},
    {'operationId': '', 'remainingMs': 120000},
    {'operationId': 7, 'remainingMs': 120000},
    {'operationId': 'accepted-operation'},
    {'operationId': 'accepted-operation', 'remainingMs': -1},
    {'operationId': 'accepted-operation', 'remainingMs': 300001},
    {'operationId': 'accepted-operation', 'remainingMs': 120000.0},
    {'operationId': 'accepted-operation', 'remainingMs': '120000'},
  ]) {
    test('invalid admission is rejected: $invalid', () {
      expect(() => OperationAdmission.fromMap(invalid), throwsFormatException);
    });
  }
}
