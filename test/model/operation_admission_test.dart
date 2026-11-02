import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final remaining in [0, 117000]) {
    test('snapshot 保留原 owner、受理时钟与剩余预算 $remaining ms', () {
      final message = messages.androidErrorOperationWaitTimeout.withDetail({
        'cause': {'message': '原始 deadline'},
        'future': [false, null],
      });
      final snapshot = AppSnapshot.fromMap({
        'writerBusy': true,
        'operationId': 'close-owner',
        'operationAdmittedAt': 100,
        'operationDeadline': 120100,
        'operationRemainingMs': remaining,
        'operation': message.toMap(),
      });
      for (final value in [snapshot, snapshot.asStale()]) {
        expect(value.writerBusy, isTrue);
        expect(value.operationId, 'close-owner');
        expect(value.operationAdmittedAt, 100);
        expect(value.operationDeadline, 120100);
        expect(value.operationRemainingMs, remaining);
        expect(value.operationMessage!.toMap(), message.toMap());
        expect(value.resultId, isNull);
      }
      expect(snapshot.stale, isFalse);
      expect(snapshot.asStale().stale, isTrue);
    });
  }

  test('没有 operation 的 snapshot 不创建 owner 或预算', () {
    final snapshot = AppSnapshot.fromMap({});
    expect(snapshot.operationId, isNull);
    expect(snapshot.operationAdmittedAt, isNull);
    expect(snapshot.operationDeadline, isNull);
    expect(snapshot.operationRemainingMs, isNull);
  });

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
