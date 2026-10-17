import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clash_pseudo/features/strategies/strategy_image.dart';
import 'package:clash_pseudo/features/strategies/strategy_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Network checks use the loopback fixture, not the widget binding's HTTP 400 stub.
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
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _PendingRequest(response);
  @override
  void close({bool force = false}) => closed = true;
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

void main() {
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
      () => compileStrategySvg(
        Uint8List.fromList(
          utf8.encode(
            '<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.test/private"/></svg>',
          ),
        ),
      ),
      throwsA(anything),
    );
  });

  test('HTTP icon loading bounds bytes, redirects and formats', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
      final path = request.uri.path;
      if (path == '/svg') {
        request.response.headers.contentType = ContentType('image', 'svg+xml');
        request.response.write(svg);
      } else if (path == '/large-svg') {
        request.response.headers.contentType = ContentType('image', 'svg+xml');
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
          File('tool/native_fixture/images/color.$extension').readAsBytesSync(),
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
    for (final path in [
      '/redirect/4',
      '/local',
      '/large-svg',
      '/large',
      '/missing',
    ]) {
      await expectLater(load(path), throwsFormatException);
    }
    final before = requests;
    final client = _LocalHttp().createHttpClient(null);
    try {
      for (final source in [
        'file:///tmp/icon.svg',
        'data:image/svg+xml,invalid',
        'http://user:secret@127.0.0.1:${server.port}/svg',
      ]) {
        await expectLater(
          loadStrategyImage(source, client),
          throwsFormatException,
        );
      }
    } finally {
      client.close(force: true);
    }
    expect(requests, before);
    expect((await load('/svg')).svg, isTrue);
  });

  test('HTTPS verifies certificates and rejects plaintext redirects', () async {
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
          'http://127.0.0.1:${server.port}/svg',
        );
      } else {
        request.response.headers.contentType = ContentType('image', 'svg+xml');
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
      await expectLater(
        loadStrategyImage(
          'https://127.0.0.1:${server.port}/downgrade',
          trusted,
        ),
        throwsFormatException,
      );
    } finally {
      trusted.close(force: true);
    }
  });

  testWidgets('successful old response cannot replace a newer image', (
    tester,
  ) async {
    final http = _PendingHttp();
    final webp = File('tool/native_fixture/images/color.webp')
        .readAsBytesSync();
    final jpeg = File('tool/native_fixture/images/color.jpg').readAsBytesSync();
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

  testWidgets('source replacement, timeout and disposal close owned requests', (
    tester,
  ) async {
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
  });

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
}
