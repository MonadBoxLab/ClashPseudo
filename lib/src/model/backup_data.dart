import 'dart:convert';

import 'application_contract.dart';
import 'config_text.dart';

const maxBackupSummaryNameBytes = maxConfigNameBytes;

/// Confirmation metadata using the configuration name budget.
class BackupSummary {
  const BackupSummary({
    required this.configurations,
    required this.overrides,
    this.hasSelection = false,
    this.selectedName,
  });

  final int configurations;
  final int overrides;
  final bool hasSelection;
  final String? selectedName;

  factory BackupSummary.fromMap(Map<String, dynamic> value) {
    final configurations = value['configurations'];
    final overrides = value['overrides'];
    final hasSelection = value['hasSelection'];
    final selectedName = value['selectedName'];
    if (configurations is! int ||
        configurations < 0 ||
        configurations > ApplicationContract.backupCollectionEntries ||
        overrides is! int ||
        overrides < 0 ||
        overrides > ApplicationContract.backupCollectionEntries ||
        hasSelection is! bool ||
        (selectedName != null &&
            (selectedName is! String ||
                selectedName.length > maxBackupSummaryNameBytes ||
                utf8.encode(selectedName).length > maxBackupSummaryNameBytes ||
                selectedName.trim().isEmpty)) ||
        (hasSelection != (selectedName != null)) ||
        (configurations == 0 && hasSelection)) {
      throw const FormatException('Invalid backup summary');
    }
    return BackupSummary(
      configurations: configurations,
      overrides: overrides,
      hasSelection: hasSelection,
      selectedName: selectedName as String?,
    );
  }

  Map<String, Object?> toMap() => {
    'configurations': configurations,
    'overrides': overrides,
    'hasSelection': hasSelection,
    'selectedName': selectedName,
  };
}

/// The immutable candidate handed to the UI only after all three Store reads.
class BackupCandidate {
  const BackupCandidate({
    required this.token,
    required this.createdAtMillis,
    required this.summary,
  });

  final String token;
  final int createdAtMillis;
  final BackupSummary summary;

  factory BackupCandidate.fromMap(Map<String, dynamic> value) {
    final token = value['token'];
    final created = value['createdAtMillis'];
    if (!isBackupToken(token) ||
        created is! int ||
        created < 0 ||
        created > 8640000000000000 ||
        value['summary'] is! Map) {
      throw const FormatException('Invalid backup candidate');
    }
    return BackupCandidate(
      token: token as String,
      createdAtMillis: created,
      summary: BackupSummary.fromMap(
        Map<String, dynamic>.from(value['summary'] as Map),
      ),
    );
  }

  Map<String, Object?> toMap() => {
    'token': token,
    'createdAtMillis': createdAtMillis,
    'summary': summary.toMap(),
  };
}

bool isBackupToken(Object? value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);
