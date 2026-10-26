import 'dart:convert';

import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(AppBridge.channel, null));

  for (final action in ['saveLocalDefinition', 'deleteLocalDefinition']) {
    test(
      '$action preserves nested BOM strings through the actual channel codec',
      () async {
        final payload = <String, Object?>{
          'id': '\u{feff}saved-id',
          'revision': 2,
          'name': '\u{feff}Local',
          'section': 'proxies',
          'definition': {
            'name': 'Proxy',
            'type': 'http',
            'password': '\u{feff}\u{feff}secret🌐',
            'headers': {'\u{feff}X-Name': '\u{feff}header-value'},
          },
          'path': ['proxies', 0],
          'value': '\u{feff}Proxy',
          'replacement': {
            'path': ['proxies', 0],
            'value': '\u{feff}Previous',
          },
        };
        messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
          expect(call.method, 'submit');
          final args = call.arguments as Map;
          final restored = args['definitionPayload'] is Uint8List
              ? jsonDecode(utf8.decode(args['definitionPayload'] as Uint8List))
              : (Map.of(args)
                  ..remove('action')
                  ..remove('storageEpoch'));
          expect(restored, payload);
          expect(
            args.keys,
            unorderedEquals(['action', 'storageEpoch', 'definitionPayload']),
          );
          expect(args['action'], action);
          expect(args['storageEpoch'], 7);
          expect(args['definitionPayload'], isA<Uint8List>());
          expect(
            jsonDecode(utf8.decode(args['definitionPayload'] as Uint8List)),
            payload,
          );
          return {'operationId': 'operation', 'remainingMs': 117000};
        });
        final admission = await AppBridge().submit({
          'action': action,
          'storageEpoch': 7,
          ...payload,
        });
        expect(admission?.operationId, 'operation');
        expect(admission?.remaining, const Duration(seconds: 117));
      },
    );
  }
}
