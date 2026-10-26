import 'application_contract.dart';

class OperationAdmission {
  const OperationAdmission({
    required this.operationId,
    required this.remaining,
  });

  final String operationId;
  final Duration remaining;

  factory OperationAdmission.fromMap(Map<Object?, Object?> value) {
    final id = value['operationId'];
    final remaining = value['remainingMs'];
    if (id is! String ||
        id.isEmpty ||
        remaining is! int ||
        remaining < 0 ||
        remaining > ApplicationContract.operationBackupTimeoutMs) {
      throw const FormatException('Invalid operation admission');
    }
    return OperationAdmission(
      operationId: id,
      remaining: Duration(milliseconds: remaining),
    );
  }
}
