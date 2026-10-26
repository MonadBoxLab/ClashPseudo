import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter/material.dart';

import 'package:clash_pseudo/src/features/configs/config_downloader.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:flutter_test/flutter_test.dart';

// Preserve the loopback fixture when the localized-feedback tests initialize
// the widget binding's default HTTP 400 stub.
class _LoopbackHttp extends HttpOverrides {}

HttpClient _loopbackClient() => _LoopbackHttp().createHttpClient(null);

class _FailingClient implements HttpClient {
  _FailingClient(this.failure);
  final Object failure;
  final opened = <Uri>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    opened.add(url);
    throw failure;
  }

  @override
  void close({bool force = false}) => closed = force;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ConfigFailure> _downloadFailure(Future<String> download) async {
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
    'HTTP status and size failures keep only their stable safe arguments',
    () async {
      for (final (path, id, args) in [
        ('missing', 'downloadHttpStatus', {'status': '404'}),
        ('large', 'downloadTooLarge', <String, Object?>{}),
      ]) {
        final failure = await _downloadFailure(
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
    'the whole-download deadline returns a stable argument-free timeout',
    () async {
      final failure = await _downloadFailure(
        ConfigDownloader(
          timeout: const Duration(milliseconds: 20),
          createClient: _loopbackClient,
        ).download('$source/slow?token=QueryCanary'),
      );
      expect(failure.message.toMap(), {'id': 'downloadTimeout', 'args': {}});
      for (final locale in [const Locale('en'), const Locale('zh')]) {
        final strings = lookupAppLocalizations(locale);
        expect(failure.message.resolve(strings), strings.downloadTimeout);
        expect(
          failure.message.resolve(strings),
          isNot(contains('QueryCanary')),
        );
      }
    },
  );

  const secretSource =
      'https://UserCanary:PasswordCanary@example.test/config?token=QueryCanary&sig=SignatureCanary';
  const detail = 'ErrorCanary request=$secretSource';
  for (final (kind, id, injected) in <(String, String, Object)>[
    ('socket', 'downloadFailed', const SocketException(detail)),
    (
      'http',
      'downloadFailed',
      HttpException(detail, uri: Uri.parse(secretSource)),
    ),
    ('tls', 'tlsFailed', const HandshakeException(detail)),
    ('format', 'downloadNotUtf8', const FormatException(detail, secretSource)),
    ('timeout', 'downloadTimeout', TimeoutException(detail)),
    ('client creation', 'trustedRootsUnavailable', StateError(detail)),
  ]) {
    testWidgets(
      'redacts credential-bearing $kind failures in logs and localized feedback',
      (tester) async {
        final logs = <String>[];
        final client = _FailingClient(injected);
        final previousPrint = debugPrint;
        late ConfigFailure failure;
        try {
          debugPrint = (message, {wrapWidth}) {
            if (message != null) logs.add(message);
          };
          failure = await runZoned(
            () => _downloadFailure(
              ConfigDownloader(
                createClient: () {
                  if (kind == 'client creation') throw injected;
                  return client;
                },
              ).download(secretSource),
            ),
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) => logs.add(line),
            ),
          );
        } finally {
          debugPrint = previousPrint;
        }
        expect(injected.toString(), contains(detail));
        expect(failure.message.toMap(), {'id': id, 'args': {}});
        if (kind == 'client creation') {
          expect(client.opened, isEmpty);
        } else {
          expect(client.opened, [
            Uri.parse(secretSource).replace(userInfo: ''),
          ]);
          expect(client.closed, isTrue);
        }
        final locale = ValueNotifier(const Locale('en'));
        addTearDown(locale.dispose);
        await tester.pumpWidget(
          ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (_, value, _) => MaterialApp(
              locale: value,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showAppMessage(context, failure.message),
                    child: const Text('Show failure'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Show failure'));
        await tester.pumpAndSettle();
        final dialog = tester.element(find.byType(AlertDialog));
        final rendered = <String>[];
        for (final language in ['en', 'zh']) {
          locale.value = Locale(language);
          await tester.pumpAndSettle();
          expect(tester.element(find.byType(AlertDialog)), same(dialog));
          final strings = AppLocalizations.of(dialog);
          final expected = switch (id) {
            'downloadFailed' => strings.downloadFailed,
            'tlsFailed' => strings.tlsFailed,
            'downloadNotUtf8' => strings.downloadNotUtf8,
            'downloadTimeout' => strings.downloadTimeout,
            'trustedRootsUnavailable' => strings.trustedRootsUnavailable,
            _ => throw StateError('Unexpected message ID'),
          };
          final content = tester.widget<SelectableText>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(SelectableText),
            ),
          );
          expect(content.data, expected);
          rendered.add(content.data!);
        }
        expect(rendered[0], isNot(rendered[1]));
        for (final secret in [
          'UserCanary',
          'PasswordCanary',
          'QueryCanary',
          'SignatureCanary',
          'ErrorCanary',
        ]) {
          for (final text in [
            ...logs,
            ...rendered,
            failure.toString(),
            jsonEncode(failure.message.toMap()),
          ]) {
            expect(
              text,
              isNot(contains(secret)),
              reason: '$kind must not expose $secret',
            );
          }
        }
        await tester.tap(find.text(AppLocalizations.of(dialog).close));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

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
