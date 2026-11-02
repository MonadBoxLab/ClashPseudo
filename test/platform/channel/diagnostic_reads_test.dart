import 'dart:convert';

import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('diagnostic read decoding', () {
    testWidgets(
      'ordinary bridge decoding retains complete feedback and decode errors',
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
            try {
              await call.value();
              fail(
                'malformed ${call.key} feedback must retain its original error',
              );
            } on PlatformFailure catch (error) {
              expect(error.code, call.key);
              expect((error.details as Map)['detail'], endsWith(raw));
            }
          }
        }
      },
    );
  });
}
