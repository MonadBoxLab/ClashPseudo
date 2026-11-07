import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_image.dart';
import 'package:clash_pseudo/src/platform/trust/trusted_http.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Downloads explicitly inject the UI factory; the delegate performs actual loopback
// HTTPS validation.
class _RawHttp extends HttpOverrides {}

class _RecordingHttp extends HttpOverrides {
  final contexts = <SecurityContext?>[];
  final clients = <_TrackedClient>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    contexts.add(context);
    final client = _TrackedClient(_RawHttp().createHttpClient(context));
    clients.add(client);
    return client;
  }
}

class _TrackedClient implements HttpClient {
  _TrackedClient(this.delegate);
  final HttpClient delegate;
  var closeCalls = 0;

  @override
  Duration? get connectionTimeout => delegate.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) => delegate.getUrl(url);
  @override
  void close({bool force = false}) {
    closeCalls++;
    delegate.close(force: force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'default downloads and images share one owner-free engine trust snapshot',
    (tester) async {
      final roots = File('test/fixtures/icon_tls/cert.pem').readAsBytesSync();
      final image = File('tool/network/native_fixture/images/color.webp')
          .readAsBytesSync();
      final serverContext = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(roots)
        ..usePrivateKey('test/fixtures/icon_tls/key.pem');
      final server = (await tester.runAsync(
        () => HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          serverContext,
        ),
      ))!;
      final requests = <String>[];
      final errors = <Object>[];
      late final StreamSubscription<HttpRequest> subscription;
      await tester.runAsync(() async {
        subscription = server.listen((request) async {
          requests.add(request.uri.path);
          try {
            if (request.uri.path == '/config') {
              request.response.write('rules:\n  - MATCH,DIRECT\n');
            } else {
              request.response.headers.contentType = ContentType(
                'image',
                'webp',
              );
              request.response.add(image);
            }
            await request.response.close();
          } catch (error) {
            errors.add(error);
          }
        }, onError: (Object error) => errors.add(error));
      });
      addTearDown(
        () => tester.runAsync(() async {
          await server.close(force: true);
          await subscription.cancel();
          expect(errors, isEmpty);
        }),
      );
      var rootLoads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppBridge.channel, (call) async {
            expect(call.method, 'trustRoots');
            expect((call.arguments as Map).containsKey('owner'), isFalse);
            rootLoads++;
            if (rootLoads == 1) {
              throw PlatformException(
                code: 'trust',
                message: 'private root diagnostic',
              );
            }
            return roots;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AppBridge.channel, null),
      );
      final http = _RecordingHttp();
      await HttpOverrides.runWithHttpOverrides(() async {
        await tester.runAsync(() async {
          await expectLater(
            ConfigDownloader(createClient: createTrustedHttpClient)
                .download('https://127.0.0.1:${server.port}/config'),
            throwsA(
              isA<ConfigFailure>().having(
                (failure) => failure.message.id,
                'message',
                'trustedRootsUnavailable',
              ),
            ),
          );
          expect(requests, isEmpty);
          expect(http.clients, isEmpty);
          expect(rootLoads, 1);
          expect(
            await ConfigDownloader(createClient: createTrustedHttpClient)
                .download('https://127.0.0.1:${server.port}/config'),
            'rules:\n  - MATCH,DIRECT\n',
          );
        });
        expect(rootLoads, 2);
        expect(http.clients.single.closeCalls, 1);
        expect(http.contexts.single, isNotNull);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: StrategyImage(
                  source: 'https://127.0.0.1:${server.port}/icon',
                  fallback: const Icon(Icons.dns),
                ),
              ),
            ),
          ),
        );
        final slot = tester.getRect(find.byType(StrategyImage));
        for (
          var frame = 0;
          frame < 100 && find.byType(Image).evaluate().isEmpty;
          frame++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(find.byType(StrategyImage)), slot);
        }
        expect(find.byType(Image), findsOneWidget);
        final provider =
            tester.widget<Image>(find.byType(Image)).image as ResizeImage;
        expect((provider.imageProvider as MemoryImage).bytes, image);
        expect(requests, ['/config', '/icon']);
        expect(rootLoads, 2);
        expect(http.contexts, hasLength(2));
        expect(identical(http.contexts.first, http.contexts.last), isTrue);
        expect(http.clients.every((client) => client.closeCalls == 1), isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      }, http);
    },
  );
}
