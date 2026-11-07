import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _original =
    'https://user:pass@fixture.test/?token=原文🙂\n'
    'Authorization: Bearer fixture';
const previewCore = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'PREVIEW',
  configId: 'one',
  revision: 1,
  composition: '["one",1]',
);

Map<String, dynamic> _wire({
  CoreSnapshot source = previewCore,
  bool stale = false,
}) => {
  'generation': source.generation,
  'configId': source.configId,
  'revision': source.revision,
  'composition': source.composition,
  'purpose': source.purpose,
  'mode': 'rule',
  'globalReferenced': false,
  'stale': stale,
  'groups': [
    {
      'name': '出口',
      'type': 'select',
      'hidden': false,
      'now': _original,
      'currentIdentity': 'member-identity',
      'fixed': '',
      'icon': '',
      'members': [
        {
          'name': _original,
          'type': 'Socks5',
          'future': [false, null],
        },
      ],
      'future': {'Authorization': _original},
    },
  ],
  'unrestored': <Object?>[],
  'future': {
    'values': [false, null, _original],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('native response and platform errors', () {
    test('strategy bridge reads actual members and source identity', () async {
      final wire = _wire();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        AppBridge.channel,
        (_) async => jsonEncode(wire),
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppBridge.channel, null),
      );
      final actual = await AppBridge().strategies(previewCore);
      expect(actual.groups.single.currentIdentity, 'member-identity');
      expect(actual.groups.single.now, _original);
    });

    for (final malformed in [false, true]) {
      test(
        'strategy parsing retains errors without the full response: malformed=$malformed',
        () async {
          final wire = malformed
              ? _original
              : jsonEncode({
                  ..._wire(),
                  'groups': {'original': _original},
                });
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(
            AppBridge.channel,
            (_) async => wire,
          );
          addTearDown(
            () => messenger.setMockMethodCallHandler(AppBridge.channel, null),
          );
          Object? parseError;
          try {
            StrategySnapshot.fromMap(jsonDecode(wire) as Map<String, dynamic>);
          } catch (error) {
            parseError = error is FormatException
                ? FormatException(error.message, null, error.offset)
                : error;
          }
          expect(parseError, isNotNull);
          try {
            await AppBridge().strategies(previewCore);
            fail('Invalid typed response was accepted');
          } on PlatformFailure catch (error) {
            final detail = (error.details as Map)['detail'] as String;
            expect(detail, parseError.toString());
            expect(detail, isNot(contains(wire)));
          }
        },
      );
    }

    test('strategy bridge keeps actual platform errors', () async {
      final failure = PlatformException(
        code: 'fixture',
        message: _original,
        details: {'future': _original},
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        AppBridge.channel,
        (_) async => throw failure,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppBridge.channel, null),
      );
      await expectLater(
        AppBridge().strategies(previewCore),
        throwsA(
          isA<PlatformFailure>()
              .having((error) => error.code, 'code', failure.code)
              .having((error) => error.message, 'message', failure.message)
              .having((error) => error.details, 'details', failure.details),
        ),
      );
    });
  });
}
