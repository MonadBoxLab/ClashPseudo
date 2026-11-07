import 'dart:convert';

import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diagnostic read decoding', () {
    testWidgets(
      'diagnostic reads retain parsing errors without the full response',
      (tester) async {
        final bridge = AppBridge();
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            AppBridge.channel,
            null,
          ),
        );
        const source = CoreSnapshot(
          phase: 'READY',
          generation: 1,
          configId: 'config',
          revision: 1,
          composition: 'composition',
          purpose: 'RUNNING',
          logWindow: 'window',
        );
        final calls = <String, Future<Map<String, dynamic>> Function()>{
          'runtimeConfig': () => bridge.runtimeConfiguration(source),
          'resources': () => bridge.resources(source),
          'nodes': () => bridge.nodes(source, {'search': '  original  '}),
          'rules': () => bridge.rules(source, {'search': '  original  '}),
          'logs': () => bridge.logs(source, {'after': 3}),
        };
        final original = {
          'unknown': [false, 0, null, <Object?>[], <String, Object?>{}],
          'body': '${'x' * 20000}tail',
        };
        for (final call in calls.entries) {
          String? wire = jsonEncode(original);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            AppBridge.channel,
            (method) async {
              expect(method.method, call.key);
              if (call.key == 'logs') {
                expect(
                  (method.arguments as Map)['query']['window'],
                  source.logWindow,
                );
              }
              return wire;
            },
          );
          expect(await call.value(), original);
          for (final raw in [
            'not-json:${'x' * 20000}tail',
            jsonEncode([original]),
          ]) {
            wire = raw;
            Object? parseError;
            try {
              jsonDecode(raw) as Map<String, dynamic>;
            } catch (error) {
              parseError = error is FormatException
                  ? FormatException(error.message, null, error.offset)
                  : error;
            }
            expect(parseError, isNotNull);
            try {
              await call.value();
              fail('Diagnostic read accepted an invalid response: ${call.key}');
            } on PlatformFailure catch (error) {
              expect(error.code, call.key);
              final detail = (error.details as Map)['detail'] as String;
              expect(detail, parseError.toString());
              expect(detail, isNot(contains(raw)));
            }
          }
        }
      },
    );
  });
}
