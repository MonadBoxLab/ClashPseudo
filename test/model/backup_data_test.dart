import 'dart:convert';

import 'package:clash_pseudo/src/model/backup_data.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = '12345678-1234-1234-1234-123456789abc';

Map<String, dynamic> _summary() => {
  'configurations': 1,
  'overrides': 2,
  'hasSelection': true,
  'selectedName': 'Named configuration 配置 🌐',
};

void main() {
  test(
    'only an immutable token and bounded confirmation projection round-trip',
    () {
      final value = BackupCandidate.fromMap({
        'token': _token,
        'createdAtMillis': 1760000000123,
        'summary': _summary(),
        'paths': {'not': 'forwarded'},
        'body': 'not forwarded',
        'source': 'https://user:credential@fixture.invalid/',
      });
      expect(value.token, _token);
      expect(value.summary.configurations, 1);
      expect(value.summary.overrides, 2);
      expect(value.toMap(), {
        'token': _token,
        'createdAtMillis': 1760000000123,
        'summary': _summary(),
      });
      expect(
        BackupCandidate.fromMap(Map<String, dynamic>.from(value.toMap()))
            .toMap(),
        value.toMap(),
      );
      expect(jsonEncode(value.toMap()), isNot(contains('credential')));
    },
  );

  for (final bad in [
    null,
    '',
    '/private/candidate',
    '../token',
    'content://fixture',
    'A' * 36,
    '${_token}x',
  ]) {
    test('path-like or malformed token is rejected: $bad', () {
      expect(isBackupToken(bad), isFalse);
      expect(
        () => BackupCandidate.fromMap({
          'token': bad,
          'createdAtMillis': 0,
          'summary': _summary(),
        }),
        throwsFormatException,
      );
    });
  }

  for (final bad in [null, '1', -1, 8640000000000001, 1.5]) {
    test('invalid display timestamp is rejected: $bad', () {
      expect(
        () => BackupCandidate.fromMap({
          'token': _token,
          'createdAtMillis': bad,
          'summary': _summary(),
        }),
        throwsFormatException,
      );
    });
  }

  for (final field in ['configurations', 'overrides']) {
    for (final bad in [null, true, '1', -1, 4097]) {
      test('$field rejects invalid count $bad', () {
        expect(
          () => BackupSummary.fromMap({..._summary(), field: bad}),
          throwsFormatException,
        );
      });
    }
  }

  for (final value in [
    {..._summary(), 'hasSelection': null},
    {..._summary(), 'hasSelection': 'true'},
    {..._summary(), 'hasSelection': false},
    {..._summary(), 'selectedName': null},
    {..._summary(), 'selectedName': ''},
    {..._summary(), 'selectedName': '   '},
    {..._summary(), 'configurations': 0},
  ]) {
    test('inconsistent selection is rejected ${value.toString()}', () {
      expect(() => BackupSummary.fromMap(value), throwsFormatException);
    });
  }

  test('empty collections and a real absent selection remain explicit', () {
    final value = BackupSummary.fromMap({
      'configurations': 0,
      'overrides': 0,
      'hasSelection': false,
      'selectedName': null,
    });
    expect(value.hasSelection, isFalse);
    expect(value.selectedName, isNull);
    expect(value.toMap()['configurations'], 0);
    expect(value.toMap()['overrides'], 0);
  });

  for (final name in ['x' * 80, '🌐' * 20, '${'中' * 26}ab']) {
    test(
      'display name exact UTF-8 limit is admitted for ${name.runes.first}',
      () {
        expect(utf8.encode(name), hasLength(maxBackupSummaryNameBytes));
        expect(
          BackupSummary.fromMap({..._summary(), 'selectedName': name})
              .selectedName,
          name,
        );
        expect(
          () => BackupSummary.fromMap({
            ..._summary(),
            'selectedName': '${name}x',
          }),
          throwsFormatException,
        );
      },
    );
  }
}
