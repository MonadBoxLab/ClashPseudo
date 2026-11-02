import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(AppBridge.channel, null));

  test('trust material crosses the bridge as bytes without an owner', () async {
    final expected = Uint8List.fromList([0xef, 0xbb, 0xbf, 0x2d, 0x0a]);
    messenger.setMockMethodCallHandler(AppBridge.channel, (call) async {
      expect(call.method, 'trustRoots');
      expect(call.arguments, isEmpty);
      return expected;
    });

    expect(await AppBridge().trustRoots(), orderedEquals(expected));
  });

  test(
    'a successful empty trust pool is distinct from a missing reply',
    () async {
      messenger.setMockMethodCallHandler(
        AppBridge.channel,
        (_) async => Uint8List(0),
      );
      expect(await AppBridge().trustRoots(), isEmpty);

      messenger.setMockMethodCallHandler(AppBridge.channel, (_) async => null);
      await expectLater(
        AppBridge().trustRoots(),
        throwsA(
          isA<PlatformFailure>()
              .having((error) => error.code, 'code', 'trust')
              .having((error) => error.details, 'description', {
                'id': 'trustedRootsUnavailable',
                'args': <String, Object?>{},
              }),
        ),
      );
    },
  );

  test('platform trust failure is not converted into an empty pool', () async {
    const description = {
      'id': 'trustedRootsUnavailable',
      'args': <String, Object?>{},
    };
    messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
      throw PlatformException(code: 'trust', details: description);
    });

    await expectLater(
      AppBridge().trustRoots(),
      throwsA(
        isA<PlatformFailure>().having(
          (error) => error.details,
          'description',
          description,
        ),
      ),
    );
  });

  test('an expired operation does not request trust material', () async {
    var requests = 0;
    messenger.setMockMethodCallHandler(AppBridge.channel, (_) async {
      requests++;
      return Uint8List(0);
    });
    final bridge = AppBridge(operationId: 'expired')..cancel();

    await expectLater(
      bridge.trustRoots(),
      throwsA(isA<PlatformFailure>().having((e) => e.code, 'code', 'expired')),
    );
    expect(requests, 0);
  });
}
