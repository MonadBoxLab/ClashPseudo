import 'dart:io';

import 'package:clash_pseudo/features/configs/config_downloader.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late String source;
  late List<HttpRequest> requests;
  setUp(() async {
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    source = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      requests.add(request);
      try {
        switch (request.uri.path) {
          case '/redirect':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(HttpHeaders.locationHeader, '/config');
          case '/loop':
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(HttpHeaders.locationHeader, '/loop');
          case '/missing':
            request.response.statusCode = HttpStatus.notFound;
          case '/empty':
            break;
          case '/large':
            request.response.write('x' * 100);
          case '/slow':
            await Future<void>.delayed(const Duration(milliseconds: 100));
            request.response.write('late');
          default:
            request.response.write('rules:\n  - MATCH,DIRECT\n');
        }
        await request.response.close();
      } catch (_) {
        /* Client cancellation is expected for limit/timeout cases. */
      }
    });
  });
  tearDown(() => server.close(force: true));

  test('HTTP requires consent before opening a connection', () async {
    await expectLater(
      ConfigDownloader().download('$source/config', allowHttp: false),
      throwsA(
        isA<ConfigFailure>().having(
          (e) => e.needsHttpConfirmation,
          'confirmation',
          true,
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test(
    'downloads UTF-8 configuration and follows a relative redirect',
    () async {
      final body = await ConfigDownloader().download(
        '$source/redirect',
        allowHttp: true,
      );
      expect(body, 'rules:\n  - MATCH,DIRECT\n');
      expect(requests.map((r) => r.uri.path), ['/redirect', '/config']);
    },
  );

  test('caps redirect count', () async {
    await expectLater(
      ConfigDownloader().download('$source/loop', allowHttp: true),
      throwsA(isA<ConfigFailure>()),
    );
    expect(requests.length, ConfigDownloader.maxRedirects + 1);
  });

  test('rejects empty, HTTP failures and oversize responses', () async {
    for (final path in ['empty', 'missing', 'large']) {
      await expectLater(
        ConfigDownloader(maxBytes: 32)
            .download('$source/$path', allowHttp: true),
        throwsA(isA<ConfigFailure>()),
      );
    }
  });

  test(
    'bounds the whole download and hides token-bearing network exceptions',
    () async {
      await expectLater(
        ConfigDownloader(timeout: const Duration(milliseconds: 20))
            .download('$source/slow?token=private', allowHttp: true),
        throwsA(
          isA<ConfigFailure>().having(
            (e) => e.message,
            'message',
            isNot(contains('private')),
          ),
        ),
      );
    },
  );

  test(
    'source identity preserves query tokens and excludes only fragments',
    () {
      expect(
        ConfigDownloader.sourceUri(
          ' https://example.test/config?token=one#section ',
        ).toString(),
        'https://example.test/config?token=one',
      );
      expect(
        ConfigDownloader.sourceUri('https://example.test/config?token=one'),
        isNot(
          ConfigDownloader.sourceUri('https://example.test/config?token=two'),
        ),
      );
      expect(
        () => ConfigDownloader.sourceUri('file:///private'),
        throwsA(isA<ConfigFailure>()),
      );
    },
  );
}
