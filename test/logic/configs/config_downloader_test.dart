import 'dart:ui';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:io';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';

import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';

// Use real loopback HTTP clients independently of test binding overrides.
class _LoopbackHttp extends HttpOverrides {}

HttpClient _loopbackClient() => _LoopbackHttp().createHttpClient(null);

Future<ConfigFailure> downloadFailure(Future<String> download) async {
  try {
    await download;
  } on ConfigFailure catch (failure) {
    return failure;
  }
  fail('The controlled download must fail');
}

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

  test('HTTP downloads normally without a separate consent protocol', () async {
    expect(
      await ConfigDownloader(createClient: _loopbackClient)
          .download('$source/config'),
      'rules:\n  - MATCH,DIRECT\n',
    );
    expect(requests, hasLength(1));
  });

  test(
    'downloads UTF-8 configuration and follows a relative redirect',
    () async {
      final body = await ConfigDownloader(createClient: _loopbackClient)
          .download('$source/redirect');
      expect(body, 'rules:\n  - MATCH,DIRECT\n');
      expect(requests.map((r) => r.uri.path), ['/redirect', '/config']);
    },
  );

  test('caps redirect count', () async {
    await expectLater(
      ConfigDownloader(createClient: _loopbackClient).download('$source/loop'),
      throwsA(isA<ConfigFailure>()),
    );
    expect(requests.length, ConfigDownloader.maxRedirects + 1);
  });

  test('accepts empty content without YAML validation', () async {
    expect(
      await ConfigDownloader(createClient: _loopbackClient)
          .download('$source/empty'),
      '',
    );
  });

  test(
    'HTTP status and size failures report the actual status or capacity',
    () async {
      for (final (path, id, args) in [
        ('missing', 'downloadHttpStatus', {'status': '404'}),
        ('large', 'downloadTooLarge', <String, Object?>{}),
      ]) {
        final failure = await downloadFailure(
          ConfigDownloader(
            maxBytes: 32,
            createClient: _loopbackClient,
          ).download('$source/$path?token=QueryCanary'),
        );
        expect(failure.message.id, id);
        expect(failure.message.args, args);
        for (final locale in [const Locale('en'), const Locale('zh')]) {
          final strings = lookupAppLocalizations(locale);
          expect(
            failure.message.resolve(strings),
            path == 'missing'
                ? strings.downloadHttpStatus('404')
                : strings.downloadTooLarge,
          );
          expect(
            failure.message.resolve(strings),
            isNot(contains('QueryCanary')),
          );
        }
      }
    },
  );

  test(
    'the whole-download deadline reports timeout and its original diagnostic',
    () async {
      final failure = await downloadFailure(
        ConfigDownloader(
          timeout: const Duration(milliseconds: 20),
          createClient: _loopbackClient,
        ).download('$source/slow?token=QueryCanary'),
      );
      expect(failure.message.id, 'downloadTimeout');
      expect(failure.message.args, isEmpty);
      expect(failure.message.detail, contains('TimeoutException'));
      for (final locale in [const Locale('en'), const Locale('zh')]) {
        final strings = lookupAppLocalizations(locale);
        expect(
          failure.message.resolve(strings),
          '${strings.downloadTimeout}\n${failure.message.detail}',
        );
      }
    },
  );

  test('HTTP factory 错误经过 ConfigFailure 后保留完整 cause、stack 与未知字段', () async {
    const original = PlatformFailure(
      code: 'trustedRootsUnavailable',
      message: '原始 HTTP client 错误',
      stacktrace: '原始 platform stack',
      details: {
        'cause': {
          'message': '原始 cause',
          'future': [false, null],
        },
        'suppressed': [
          {'message': '原始 close 错误', 'stack': 'close stack'},
        ],
        'cancelError': {'message': '原始 cancel 错误'},
        'unknown': {'enabled': false, 'value': null},
      },
    );
    final originalStack = StackTrace.fromString('HTTP factory Dart stack');
    final failure = await downloadFailure(
      ConfigDownloader(
        createClient: () => Error.throwWithStackTrace(original, originalStack),
      ).download('$source/config'),
    );
    expect(failure.message.id, 'trustedRootsUnavailable');
    expect(failure.cause, same(original));
    expect(failure.stackTrace.toString(), originalStack.toString());
    final value = failureValue(failure, StackTrace.fromString('业务边界 stack'));
    expect(value, {
      'type': 'ConfigFailure',
      'message': failure.message.toMap(),
      'cause': {...original.toMap(), 'dartStack': originalStack.toString()},
      'stack': '业务边界 stack',
    });
    expect(jsonDecode(jsonEncode(value)), value);
    const codec = StandardMessageCodec();
    expect(codec.decodeMessage(codec.encodeMessage(value)), value);
    expect(requests, isEmpty);
  });

  test(
    'source parsing retains query tokens and fragments without trimming',
    () {
      expect(
        ConfigDownloader.sourceUri(
          'https://example.test/config?token=one#section',
        ).toString(),
        'https://example.test/config?token=one#section',
      );
      expect(
        () => ConfigDownloader.sourceUri(' https://example.test/config'),
        throwsA(isA<ConfigFailure>()),
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
