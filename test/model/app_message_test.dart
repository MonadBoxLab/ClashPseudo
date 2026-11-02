import 'dart:convert';
import 'dart:isolate';

import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'invalid messages are rejected rather than treated as old display text',
    () {
      for (final value in <Object?>[
        null,
        'Settings saved.',
        <String, Object?>{},
        {'id': '', 'args': <String, Object?>{}},
        {'id': 1, 'args': <String, Object?>{}},
        {'id': 'settingsSaved'},
        {'id': 'settingsSaved', 'args': null},
        {
          'id': 'settingsSaved',
          'args': <int, String>{1: 'invalid'},
        },
        {
          'id': 'settingsSaved',
          'args': {'value': null},
        },
        {
          'id': 'settingsSaved',
          'args': {'value': 1.5},
        },
        {
          'id': 'settingsSaved',
          'args': {'value': <String>[]},
        },
        {
          'id': 'settingsSaved',
          'args': {
            'value': {'raw': 'diagnostic'},
          },
        },
      ]) {
        expect(() => AppMessage.fromMap(value), throwsFormatException);
      }
      Object nested = messages.settingsSaved.toMap();
      for (var depth = 0; depth < 4; depth++) {
        nested = {
          'id': 'androidErrorStageFailed',
          'args': {'stage': nested},
        };
      }
      expect(AppMessage.fromMap(nested), isA<AppMessage>());
      nested = {
        'id': 'androidErrorStageFailed',
        'args': {'stage': nested},
      };
      expect(() => AppMessage.fromMap(nested), throwsFormatException);
    },
  );

  test('nested descriptions and original details round trip as pure JSON', () {
    final original = AppMessage.withArgs('operationAndCleanupFailed', {
      'operation': messages.operationFailed.withDetail('original operation'),
      'cleanup': messages.androidErrorReleaseUnconfirmed.withDetail(
        'original cleanup\nSuppressed: repeated\nSuppressed: repeated',
      ),
    }, detail: 'outer detail');
    final restored = AppMessage.fromMap(
      jsonDecode(jsonEncode(original.toMap())),
    );
    expect(restored, original);
    expect(restored.hashCode, original.hashCode);
    expect(restored.toMap(), original.toMap());
    expect(
      encodeAppMessages({
        'results': [original, null],
      }),
      {
        'results': [original.toMap(), null],
      },
    );
  });

  test(
    'fresh isolates construct descriptions without a Flutter binding',
    () async {
      final value = await Isolate.run(() => messages.settingsSaved.toMap());
      expect(value, const {'id': 'settingsSaved', 'args': <String, Object?>{}});
    },
  );
}
