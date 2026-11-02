import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_image.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_icon.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';

import 'package:flutter_svg/flutter_svg.dart';

// Exercise HTTP through the controlled loopback server.
class _LocalHttp extends HttpOverrides {}

class _PendingHttp extends HttpOverrides {
  final clients = <_PendingClient>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = _PendingClient();
    clients.add(client);
    return client;
  }
}

class _PendingClient implements HttpClient {
  final response = Completer<HttpClientResponse>();
  bool closed = false;
  int closeCalls = 0;
  final uris = <Uri>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
    return _PendingRequest(response);
  }

  @override
  void close({bool force = false}) {
    closed = true;
    closeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _PendingRequest implements HttpClientRequest {
  _PendingRequest(this.response);
  final Completer<HttpClientResponse> response;
  @override
  Future<HttpClientResponse> close() => response.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _EmptyResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.notFound;
  @override
  bool get isRedirect => false;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageHeaders implements HttpHeaders {
  @override
  ContentType? get contentType => ContentType('image', 'webp');
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageResponse extends _EmptyResponse {
  _ImageResponse(this.bytes);
  final Uint8List bytes;
  @override
  int get statusCode => HttpStatus.ok;
  @override
  int get contentLength => bytes.length;
  @override
  HttpHeaders get headers => _ImageHeaders();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}

class _Headers implements HttpHeaders {
  _Headers(this.contentType);

  @override
  final ContentType? contentType;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this.body, {
    this.statusCode = HttpStatus.ok,
    this.contentLength = -1,
    ContentType? contentType,
  }) : headers = _Headers(contentType);

  final Stream<List<int>> body;

  @override
  final int statusCode;

  @override
  final int contentLength;

  @override
  final HttpHeaders headers;

  @override
  String get reasonPhrase => 'Fixture status';

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.response);

  final Future<HttpClientResponse> response;

  @override
  Future<HttpClientResponse> close() => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Client implements HttpClient {
  final response = Completer<HttpClientResponse>();
  final sources = <Uri>[];
  bool closed = false;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    sources.add(uri);
    return _Request(response.future);
  }

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Uint8List _gif() =>
    base64Decode('R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAkQBADs=');

Uint8List _bmp() {
  final bytes = Uint8List(58);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x42;
  bytes[1] = 0x4d;
  data.setUint32(2, bytes.length, Endian.little);
  data.setUint32(10, 54, Endian.little);
  data.setUint32(14, 40, Endian.little);
  data.setInt32(18, 1, Endian.little);
  data.setInt32(22, 1, Endian.little);
  data.setUint16(26, 1, Endian.little);
  data.setUint16(28, 24, Endian.little);
  data.setUint32(34, 4, Endian.little);
  bytes.setRange(54, 57, [0x64, 0x7a, 0x1a]);
  return bytes;
}

Future<({Uint8List bytes, bool svg})> _load(
  Uint8List bytes, {
  ContentType? contentType,
  String source = 'https://fixture.test/icon',
}) {
  final client = _Client();
  client.response.complete(
    _Response(
      Stream.value(bytes),
      contentType: contentType,
      contentLength: bytes.length,
    ),
  );
  return loadStrategyImage(source, client);
}

void main() {
  group('trusted transport and renderer', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppBridge.channel, (call) async {
            if (call.method == 'trustRoots') return Uint8List(0);
            throw MissingPluginException('Unexpected platform method');
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppBridge.channel, null),
    );

    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10" fill="#1a7a64"/></svg>';
    test('invalid SVG does not poison later compilation', () {
      for (var i = 0; i < 3; i++) {
        expect(
          () => compileStrategySvg(Uint8List.fromList(utf8.encode('<svg'))),
          throwsA(anything),
        );
        expect(
          compileStrategySvg(Uint8List.fromList(utf8.encode(svg))),
          isNotEmpty,
        );
      }
      expect(
        compileStrategySvg(
          Uint8List.fromList(
            utf8.encode(
              '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><image href="https://example.test/private"/></svg>',
            ),
          ),
        ),
        isNotEmpty,
      );
    });

    test('HTTP icon loading bounds bytes, redirects and formats', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          request.uri.path == '/auth' ? 'Basic dXNlcjpzZWNyZXQ=' : isNull,
        );
        expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
        final path = request.uri.path;
        if (path == '/svg' || path == '/auth') {
          request.response.headers.contentType = ContentType(
            'image',
            'svg+xml',
          );
          request.response.write(svg);
        } else if (path == '/large-svg') {
          request.response.headers.contentType = ContentType(
            'image',
            'svg+xml',
          );
          request.response.add(Uint8List(256 * 1024 + 1));
        } else if (path == '/large') {
          request.response.add(Uint8List(1024 * 1024 + 1));
        } else if (path.startsWith('/redirect/')) {
          final remaining = int.parse(path.split('/').last);
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            remaining == 1 ? '/svg' : '/redirect/${remaining - 1}',
          );
        } else if (path == '/local') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'file:///tmp/icon.svg',
          );
        } else if (path == '/jpeg' || path == '/webp') {
          final extension = path == '/jpeg' ? 'jpg' : 'webp';
          request.response.add(
            File('tool/network/native_fixture/images/color.$extension')
                .readAsBytesSync(),
          );
        } else if (path == '/png') {
          request.response.add(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aQ5kAAAAASUVORK5CYII=',
            ),
          );
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      addTearDown(subscription.cancel);
      Future<({Uint8List bytes, bool svg})> load(String path) async {
        final client = _LocalHttp().createHttpClient(null);
        try {
          return await loadStrategyImage(
            'http://127.0.0.1:${server.port}$path',
            client,
          );
        } finally {
          client.close(force: true);
        }
      }

      expect((await load('/svg')).svg, isTrue);
      expect((await load('/png')).svg, isFalse);
      for (final path in ['/jpeg', '/webp']) {
        final image = await load(path);
        expect(image.svg, isFalse);
        final codec = await ui.instantiateImageCodec(image.bytes);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 32);
        expect(frame.image.height, 24);
        frame.image.dispose();
        codec.dispose();
      }
      expect((await load('/redirect/3')).svg, isTrue);
      expect((await load('/redirect/4')).svg, isTrue);
      await expectLater(load('/redirect/6'), throwsA(isA<RedirectException>()));
      await expectLater(load('/local'), throwsArgumentError);
      for (final path in ['/large-svg', '/large']) {
        await expectLater(load(path), throwsFormatException);
      }
      await expectLater(
        load('/missing'),
        throwsA(
          isA<HttpException>().having(
            (error) => error.message,
            'status',
            contains('404'),
          ),
        ),
      );
      final before = requests;
      final client = _LocalHttp().createHttpClient(null);
      try {
        for (final source in [
          'file:///tmp/icon.svg',
          'data:image/svg+xml,invalid',
        ]) {
          await expectLater(
            loadStrategyImage(source, client),
            throwsArgumentError,
          );
        }
        expect(requests, before);
        expect(
          (await loadStrategyImage(
            'http://user:secret@127.0.0.1:${server.port}/auth',
            client,
          )).svg,
          isTrue,
        );
      } finally {
        client.close(force: true);
      }
      expect(requests, before + 1);
      expect((await load('/svg')).svg, isTrue);
    });

    test('HTTPS verifies certificates and follows SDK redirects', () async {
      final plaintext = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plaintext.close(force: true));
      final plainSubscription = plaintext.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'svg+xml');
        request.response.write(svg);
        await request.response.close();
      });
      addTearDown(plainSubscription.cancel);
      final serverContext = SecurityContext()
        ..useCertificateChain('test/fixtures/icon_tls/cert.pem')
        ..usePrivateKey('test/fixtures/icon_tls/key.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        serverContext,
      );
      addTearDown(() => server.close(force: true));
      final subscription = server.listen((request) async {
        if (request.uri.path == '/downgrade') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${plaintext.port}/svg',
          );
        } else {
          request.response.headers.contentType = ContentType(
            'image',
            'svg+xml',
          );
          request.response.write(svg);
        }
        await request.response.close();
      }, onError: (Object _) {});
      addTearDown(subscription.cancel);
      final untrusted = _LocalHttp().createHttpClient(null);
      try {
        await expectLater(
          loadStrategyImage('https://127.0.0.1:${server.port}/svg', untrusted),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        untrusted.close(force: true);
      }
      final trusted = _LocalHttp().createHttpClient(
        SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificates('test/fixtures/icon_tls/cert.pem'),
      );
      try {
        expect(
          (await loadStrategyImage(
            'https://127.0.0.1:${server.port}/svg',
            trusted,
          )).svg,
          isTrue,
        );
        expect(
          (await loadStrategyImage(
            'https://127.0.0.1:${server.port}/downgrade',
            trusted,
          )).svg,
          isTrue,
        );
      } finally {
        trusted.close(force: true);
      }
    });

    testWidgets('successful old response cannot replace a newer image', (
      tester,
    ) async {
      final http = _PendingHttp();
      final webp = File('tool/network/native_fixture/images/color.webp')
          .readAsBytesSync();
      final jpeg = File('tool/network/native_fixture/images/color.jpg')
          .readAsBytesSync();
      await HttpOverrides.runWithHttpOverrides(() async {
        Future<void> show(String name) => tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: StrategyIcon(
                type: 'select',
                source: 'https://fixture.test/$name',
              ),
            ),
          ),
        );
        await show('old');
        await show('new');
        http.clients.last.response.complete(_ImageResponse(webp));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getSize(find.byType(StrategyIcon)), const Size(30, 30));
        }
        expect(find.byType(Image), findsOneWidget);
        final provider =
            tester.widget<Image>(find.byType(Image)).image as ResizeImage;
        expect((provider.imageProvider as MemoryImage).bytes, webp);
        http.clients.first.response.complete(_ImageResponse(jpeg));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getSize(find.byType(StrategyIcon)), const Size(30, 30));
        }
        final retained =
            tester.widget<Image>(find.byType(Image)).image as ResizeImage;
        expect((retained.imageProvider as MemoryImage).bytes, webp);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      }, http);
    });

    testWidgets(
      'source replacement, timeout and disposal close owned requests',
      (tester) async {
        final http = _PendingHttp();
        await HttpOverrides.runWithHttpOverrides(() async {
          Future<void> show(String source) => tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: StrategyIcon(type: 'select', source: source),
              ),
            ),
          );
          await show('https://fixture.test/first');
          expect(http.clients, hasLength(1));
          expect(tester.getSize(find.byType(StrategyIcon)), const Size(30, 30));
          await show('https://fixture.test/second');
          expect(http.clients, hasLength(2));
          expect(http.clients.first.closed, isTrue);
          http.clients.first.response.complete(_EmptyResponse());
          await tester.pump();
          expect(http.clients.last.closed, isFalse);
          expect(tester.getSize(find.byType(StrategyIcon)), const Size(30, 30));
          await tester.pump(const Duration(seconds: 8));
          expect(http.clients.last.closed, isTrue);
          expect(find.byType(Icon), findsWidgets);
          await tester.pump(const Duration(seconds: 20));
          expect(http.clients, hasLength(2));
          http.clients.last.response.complete(_EmptyResponse());
          await tester.pump();
          await show('https://fixture.test/third');
          expect(http.clients, hasLength(3));
          await tester.pumpWidget(const SizedBox());
          expect(http.clients.last.closed, isTrue);
          http.clients.last.response.complete(_EmptyResponse());
          await tester.pump();
          expect(tester.takeException(), isNull);
        }, http);
      },
    );

    testWidgets(
      'source changes close late-created clients before they can request an image',
      (tester) async {
        final gates = <Completer<HttpClient>>[];
        Future<HttpClient> create() {
          final gate = Completer<HttpClient>();
          gates.add(gate);
          return gate.future;
        }

        Future<void> show(String source) => tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: StrategyImage(
                  source: source,
                  createClient: create,
                  fallback: const Icon(Icons.dns),
                ),
              ),
            ),
          ),
        );
        await show('https://fixture.test/old');
        final slot = tester.getRect(find.byType(StrategyImage));
        await show('https://fixture.test/new');
        expect(gates, hasLength(2));
        final old = _PendingClient();
        gates.first.complete(old);
        await tester.pump();
        expect(old.closed, isTrue);
        expect(old.closeCalls, 1);
        expect(old.uris, isEmpty);
        expect(tester.getRect(find.byType(StrategyImage)), slot);
        final current = _PendingClient();
        final webp = File('tool/network/native_fixture/images/color.webp')
            .readAsBytesSync();
        current.response.complete(_ImageResponse(webp));
        gates.last.complete(current);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(find.byType(StrategyImage)), slot);
        }
        expect(current.uris.single.path, '/new');
        expect(current.closeCalls, 1);
        expect(find.byType(Image), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'image deadline includes the factory and closes a late client without retry',
      (tester) async {
        final gate = Completer<HttpClient>();
        var creates = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: StrategyImage(
                  source: 'https://fixture.test/icon',
                  fallback: const Icon(Icons.dns),
                  createClient: () {
                    creates++;
                    return gate.future;
                  },
                ),
              ),
            ),
          ),
        );
        final slot = tester.getRect(find.byType(StrategyImage));
        await tester.pump(const Duration(seconds: 8));
        expect(find.byType(Image), findsNothing);
        final late = _PendingClient();
        gate.complete(late);
        await tester.pump();
        expect(late.closeCalls, 1);
        expect(late.uris, isEmpty);
        await tester.pump(const Duration(seconds: 20));
        expect(creates, 1);
        expect(tester.getRect(find.byType(StrategyImage)), slot);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'factory and image transport share the same eight-second budget',
      (tester) async {
        final gate = Completer<HttpClient>();
        final client = _PendingClient();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: StrategyImage(
                  source: 'https://fixture.test/icon',
                  fallback: const Icon(Icons.dns),
                  createClient: () => gate.future,
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 5));
        gate.complete(client);
        await tester.pump();
        expect(client.uris, hasLength(1));
        expect(client.closed, isFalse);
        await tester.pump(const Duration(seconds: 3));
        expect(client.closeCalls, 1);
        client.response.complete(
          _ImageResponse(
            File('tool/network/native_fixture/images/color.webp')
                .readAsBytesSync(),
          ),
        );
        await tester.pump();
        expect(find.byType(Image), findsNothing);
        await tester.pumpWidget(const SizedBox());
        expect(client.closeCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'disposing while the factory waits closes its late client without I/O',
      (tester) async {
        final gate = Completer<HttpClient>();
        await tester.pumpWidget(
          MaterialApp(
            home: StrategyImage(
              source: 'https://fixture.test/icon',
              fallback: const Icon(Icons.dns),
              createClient: () => gate.future,
            ),
          ),
        );
        await tester.pumpWidget(const SizedBox());
        final client = _PendingClient();
        gate.complete(client);
        await tester.pump();
        expect(client.closeCalls, 1);
        expect(client.uris, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'root errors stay on the fixed fallback and do not retry on rebuild',
      (tester) async {
        var creates = 0;
        Future<HttpClient> create() {
          creates++;
          return Future.error(
            PlatformFailure(code: 'trust', message: 'private root diagnostic'),
          );
        }

        Future<void> show() => tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 30,
                height: 30,
                child: StrategyImage(
                  source: 'https://fixture.test/icon',
                  fallback: const Icon(Icons.dns),
                  createClient: create,
                ),
              ),
            ),
          ),
        );
        await show();
        final slot = tester.getRect(find.byType(StrategyImage));
        await tester.pump();
        await show();
        await tester.pump(const Duration(seconds: 20));
        expect(creates, 1);
        expect(find.byType(Image), findsNothing);
        expect(find.byType(Icon), findsOneWidget);
        expect(
          find.byTooltip(
            PlatformFailure(
              code: 'trust',
              message: 'private root diagnostic',
            ).toString(),
          ),
          findsOneWidget,
        );
        await tester.longPress(find.byType(Icon));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.textContaining('private root diagnostic'), findsOneWidget);
        expect(tester.getRect(find.byType(StrategyImage)), slot);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'disposal retires its deadline while shared root loading is still pending',
      (tester) async {
        final gate = Completer<HttpClient>();
        await tester.pumpWidget(
          MaterialApp(
            home: StrategyImage(
              source: 'https://fixture.test/icon',
              fallback: const Icon(Icons.dns),
              createClient: () => gate.future,
            ),
          ),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        // Leave the shared load pending and verify disposal retires this widget's
        // deadline independently.
        expect(tester.takeException(), isNull);
      },
    );

    for (final dark in [false, true]) {
      testWidgets(
        'protocol and unavailable image fallbacks retain category color dark=$dark',
        (tester) async {
          for (final source in ['', 'file:///tmp/icon.svg']) {
            await tester.pumpWidget(
              MaterialApp(
                theme: dark ? AppTheme.dark : AppTheme.light,
                home: Center(
                  child: StrategyIcon(type: 'Socks5', source: source),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.widget<Icon>(find.byIcon(Icons.alt_route_rounded)).color,
              HomePalette(dark).cobalt,
            );
            expect(
              tester.getSize(find.byType(StrategyIcon)),
              const Size(30, 30),
            );
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets(
      'bitmap cache evicts decoded entries after source replacement',
      (tester) async {
        final cache = PaintingBinding.instance.imageCache;
        final maximum = cache.maximumSize;
        final http = _PendingHttp();
        final webp = File('tool/network/native_fixture/images/color.webp')
            .readAsBytesSync();
        final jpeg = File('tool/network/native_fixture/images/color.jpg')
            .readAsBytesSync();
        cache.clear();
        cache.maximumSize = 1;
        try {
          await HttpOverrides.runWithHttpOverrides(() async {
            Future<Object> load(String name, Uint8List bytes) async {
              await tester.pumpWidget(
                MaterialApp(
                  home: Center(
                    child: StrategyIcon(
                      type: 'select',
                      source: 'https://fixture.test/$name',
                    ),
                  ),
                ),
              );
              http.clients.last.response.complete(_ImageResponse(bytes));
              for (var frame = 0; frame < 4; frame++) {
                await tester.pump(const Duration(milliseconds: 16));
                expect(
                  tester.getSize(find.byType(StrategyIcon)),
                  const Size(30, 30),
                );
              }
              final image = tester.widget<Image>(find.byType(Image));
              Object? decodeError;
              await tester.runAsync(
                () => precacheImage(
                  image.image,
                  tester.element(find.byType(Image)),
                  onError: (error, stack) => decodeError = error,
                ),
              );
              await tester.pump();
              expect(decodeError, isNull);
              expect(tester.takeException(), isNull);
              return image.image.obtainKey(ImageConfiguration.empty);
            }

            final first = await load('first', webp);
            expect(cache.statusForKey(first).keepAlive, isTrue);
            expect(cache.currentSize, 1);
            final second = await load('second', jpeg);
            expect(cache.statusForKey(first).keepAlive, isFalse);
            expect(cache.statusForKey(first).live, isFalse);
            expect(cache.statusForKey(second).keepAlive, isTrue);
            expect(cache.currentSize, 1);
            expect(http.clients.first.closeCalls, 1);
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            expect(cache.liveImageCount, 0);
            expect(http.clients.last.closeCalls, 1);
          }, http);
        } finally {
          await tester.pumpWidget(const SizedBox());
          cache.clear();
          cache.maximumSize = maximum;
        }
      },
    );

    testWidgets('built-in icons and rejected sources retain their fixed slot', (
      tester,
    ) async {
      for (final type in [
        'select',
        'url-test',
        'fallback',
        'load-balance',
        'Direct',
        'Reject',
        '',
      ]) {
        for (final source in ['', 'file:///tmp/icon.svg']) {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: StrategyIcon(type: type, source: source),
              ),
            ),
          );
          await tester.pump();
          expect(tester.getSize(find.byType(StrategyIcon)), const Size(30, 30));
          expect(find.byType(Icon), findsWidgets);
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('formats and in-flight images', () {
    test(
      'SDK raster formats are not restricted to PNG, JPEG and WebP',
      () async {
        for (final bytes in [_gif(), _bmp()]) {
          for (final contentType in [
            null,
            ContentType('image', 'svg+xml'),
            ContentType('application', 'octet-stream'),
          ]) {
            final image = await _load(
              bytes,
              contentType: contentType,
              source: 'https://fixture.test/misleading.svg?format=svg#original',
            );
            expect(image.svg, isFalse);
            expect(image.bytes, orderedEquals(bytes));
            final codec = await ui.instantiateImageCodec(image.bytes);
            try {
              final frame = await codec.getNextFrame();
              try {
                expect(frame.image.width, 1);
                expect(frame.image.height, 1);
              } finally {
                frame.image.dispose();
              }
            } finally {
              codec.dispose();
            }
          }
        }
      },
    );

    test(
      'SVG body reaches the compiler regardless of MIME or suffix',
      () async {
        final bytes = Uint8List.fromList(
          utf8.encode(
            '${String.fromCharCode(0xfeff)}<?xml version="1.0"?>\n'
            '<!-- original source -->\n'
            '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">'
            '<rect width="20" height="10" fill="#1a7a64"/></svg>',
          ),
        );
        final image = await _load(
          bytes,
          contentType: ContentType('image', 'png'),
          source: 'https://fixture.test/misleading.png?format=png#original',
        );
        expect(image.svg, isTrue);
        expect(image.bytes, orderedEquals(compileStrategySvg(bytes)));
        expect(image.bytes, isNotEmpty);
      },
    );

    test(
      'original source is passed to the transport without another URL gate',
      () async {
        const source =
            'fixture+image://user:fixture@fixture.test/icon%2Fname'
            '?value=%E4%B8%AD&empty=&value=second#original';
        final client = _Client();
        final bytes = _gif();
        client.response.complete(_Response(Stream.value(bytes)));
        final image = await loadStrategyImage(source, client);
        expect(client.sources, [Uri.parse(source)]);
        expect(client.sources.single.toString(), source);
        expect(image.svg, isFalse);
        expect(image.bytes, orderedEquals(bytes));
      },
    );

    test(
      'transport and response body failures retain their original objects',
      () async {
        final cause = StateError('original cause');
        final suppressed = ArgumentError('original cleanup failure');
        final details = <String, Object>{
          'cause': cause,
          'suppressed': [suppressed],
        };
        final failure = PlatformFailure(
          code: 'original',
          message: 'original response failure',
          details: details,
        );
        for (final bodyFailure in [false, true]) {
          final client = _Client();
          final load = loadStrategyImage(
            'https://fixture.test/failure',
            client,
          );
          final result = expectLater(load, throwsA(same(failure)));
          if (bodyFailure) {
            client.response.complete(_Response(Stream.error(failure)));
          } else {
            client.response.completeError(failure, StackTrace.current);
          }
          await result;
          expect(failure.details, same(details));
          expect(details['cause'], same(cause));
          expect(
            (details['suppressed'] as List<Object>).single,
            same(suppressed),
          );
        }
      },
    );

    test(
      'status failure awaits response cancellation and retains its source',
      () async {
        final cancelStarted = Completer<void>();
        final canceled = Completer<void>();
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelStarted.complete();
            return canceled.future;
          },
        );
        final client = _Client();
        const source = 'https://fixture.test/original%2Ficon?version=2#source';
        client.response.complete(
          _Response(body.stream, statusCode: HttpStatus.gone),
        );
        var settled = false;
        final load = loadStrategyImage(source, client);
        final result = expectLater(
          load.whenComplete(() => settled = true),
          throwsA(
            isA<HttpException>()
                .having((failure) => failure.uri, 'source', Uri.parse(source))
                .having(
                  (failure) => failure.message,
                  'original status',
                  'HTTP 410 Fixture status',
                ),
          ),
        );
        await cancelStarted.future;
        expect(settled, isFalse);
        canceled.complete();
        await result;
        expect(settled, isTrue);
        await body.close();
      },
    );

    test('malformed XML retains the SVG compiler diagnostic', () async {
      final bytes = Uint8List.fromList(utf8.encode('<svg'));
      Object? original;
      try {
        compileStrategySvg(bytes);
      } catch (failure) {
        original = failure;
      }
      expect(original, isNotNull);
      await expectLater(
        _load(bytes),
        throwsA(
          predicate<Object>(
            (failure) => failure.toString() == original.toString(),
            'the original SVG compiler diagnostic',
          ),
        ),
      );
    });

    testWidgets('invalid raster data exposes the actual decoder diagnostic', (
      tester,
    ) async {
      final client = _Client();
      client.response.complete(
        _Response(
          Stream.value([0, 1, 2, 3]),
          contentType: ContentType('image', 'png'),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 30,
              child: StrategyImage(
                source: 'https://fixture.test/broken.png',
                createClient: () => client,
                fallback: const Icon(Icons.dns),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final image = tester.widget<Image>(find.byType(Image));
      Object? decoderFailure;
      await tester.runAsync(
        () => precacheImage(
          image.image,
          tester.element(find.byType(Image)),
          onError: (failure, stack) => decoderFailure = failure,
        ),
      );
      await tester.pump();
      expect(decoderFailure, isNotNull);
      expect(find.byTooltip(decoderFailure.toString()), findsOneWidget);
      expect(find.byIcon(Icons.dns), findsOneWidget);
      expect(tester.getSize(find.byType(StrategyImage)), const Size(30, 30));
      expect(client.closed, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'valid GIF uses the image widget rather than the SVG compiler',
      (tester) async {
        final client = _Client();
        final bytes = _gif();
        client.response.complete(_Response(Stream.value(bytes)));
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox.square(
                dimension: 30,
                child: StrategyImage(
                  source: 'https://fixture.test/icon',
                  createClient: () => client,
                  fallback: const Icon(Icons.dns),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final image = tester.widget<Image>(find.byType(Image));
        final provider = image.image as ResizeImage;
        expect(
          (provider.imageProvider as MemoryImage).bytes,
          orderedEquals(bytes),
        );
        Object? decodeError;
        await tester.runAsync(
          () => precacheImage(
            image.image,
            tester.element(find.byType(Image)),
            onError: (error, stack) => decodeError = error,
          ),
        );
        await tester.pump();
        expect(decodeError, isNull);
        expect(find.byType(Tooltip), findsNothing);
        expect(tester.getSize(find.byType(StrategyImage)), const Size(30, 30));
        expect(client.closed, isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'source fragments keep distinct request and failure identities',
      (tester) async {
        final clients = <_Client>[];
        HttpClient create() {
          final client = _Client();
          clients.add(client);
          return client;
        }

        Future<void> show(String source) => tester.pumpWidget(
          MaterialApp(
            home: SizedBox.square(
              dimension: 30,
              child: StrategyImage(
                source: source,
                createClient: create,
                fallback: const Icon(Icons.dns),
              ),
            ),
          ),
        );
        const oldSource = 'https://fixture.test/icon?v=1#old';
        const newSource = 'https://fixture.test/icon?v=1#new';
        await show(oldSource);
        await show(newSource);
        expect(clients, hasLength(2));
        expect(clients.first.sources.single, Uri.parse(oldSource));
        expect(clients.last.sources.single, Uri.parse(newSource));
        expect(clients.first.closed, isTrue);
        final failure = StateError('new source original failure');
        clients.last.response.completeError(failure);
        await tester.idle();
        await tester.pump();
        expect(find.byTooltip(failure.toString()), findsOneWidget);
        clients.first.response.completeError(StateError('old source failure'));
        await tester.pump();
        expect(find.byTooltip(failure.toString()), findsOneWidget);
        expect(find.byTooltip('Bad state: old source failure'), findsNothing);
        expect(find.byType(Image), findsNothing);
        expect(clients.last.closed, isTrue);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('upstream SVG cache behavior', () {
    test(
      'flutter_svg 2.3.0 retains failed pending entries after evict',
      () async {
        final cache = Cache();
        final done = Completer<void>();
        final detachedErrors = <Object>[];
        var loads = 0;
        runZonedGuarded(() async {
          Future<ByteData> load() async {
            loads++;
            throw const FormatException('invalid SVG fixture');
          }

          for (var i = 0; i < 3; i++) {
            await expectLater(
              cache.putIfAbsent('fixture', load),
              throwsFormatException,
            );
            cache.evict('fixture');
            cache.clear();
          }
          await Future<void>.delayed(Duration.zero);
          done.complete();
        }, (error, stack) => detachedErrors.add(error));
        await done.future;
        expect(loads, 1);
        expect(detachedErrors, hasLength(1));
      },
    );
  });
}
