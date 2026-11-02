import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_downloader.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/platform/trust/trust_context.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';

class HeadersFake implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value.toString();
  }

  @override
  String? value(String name) => values[name];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ResponseFake extends Stream<List<int>> implements HttpClientResponse {
  ResponseFake(this.statusCode, {String? location}) {
    if (location != null) headers.set(HttpHeaders.locationHeader, location);
  }
  @override
  final int statusCode;
  @override
  final headers = HeadersFake();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode('rules: []')).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RequestFake implements HttpClientRequest {
  RequestFake(this.response);
  final ResponseFake response;
  @override
  final headers = HeadersFake();
  @override
  bool followRedirects = true;
  bool aborted = false;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborted = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ClientFake implements HttpClient {
  ClientFake(this.destination);
  final String destination;
  Object? failure;
  final uris = <Uri>[];
  final requests = <RequestFake>[];
  bool closed = false;
  int closeCalls = 0;
  Completer<void>? getGate;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
    if (getGate case final gate?) await gate.future;
    if (failure != null) throw failure!;
    final request = RequestFake(
      requests.isEmpty
          ? ResponseFake(302, location: destination)
          : ResponseFake(200),
    );
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closeCalls++;
    closed = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final synchronous in [true, false]) {
    test(
      'client/root loading failures retain the original error sync=$synchronous',
      () async {
        const raw =
            'https://user:password@source.test?token=private root diagnostic';
        final failure = PlatformException(code: 'trust', message: raw);
        final downloader = ConfigDownloader(
          createClient: () {
            if (synchronous) throw failure;
            return Future<HttpClient>.error(failure);
          },
        );
        addTearDown(() => setMessageLanguage(AppLanguage.system));
        try {
          await downloader.download('https://source.test/config?token=private');
          fail('Root loading must fail before creating a request');
        } on ConfigFailure catch (error) {
          expect(error.message.id, 'trustedRootsUnavailable');
          expect(error.message.args, isEmpty);
          expect(error.message.detail, failure.toString());
          final rendered = <String>[];
          for (final language in [AppLanguage.en, AppLanguage.zh]) {
            setMessageLanguage(language);
            final text = error.message.text;
            expect(text, endsWith('\n$failure'));
            expect(text, contains(raw));
            rendered.add(text);
          }
          expect(rendered.first, isNot(rendered.last));
        }
      },
    );
  }

  for (final (kind, material) in [
    ('PEM', 'not PEM'),
    ('DER', '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n'),
  ]) {
    test(
      'root $kind parsing errors are not mislabeled as response UTF-8 or TLS failures',
      () async {
        final trust = TrustContext(
          rootsLoader: () async => Uint8List.fromList(utf8.encode(material)),
        );
        await expectLater(
          ConfigDownloader(createClient: trust.createClient)
              .download('https://source.test/config'),
          throwsA(
            isA<ConfigFailure>().having(
              (error) => error.message.id,
              'message',
              'trustedRootsUnavailable',
            ),
          ),
        );
      },
    );
  }

  test('invalid sources do not load roots or create a client', () async {
    var creates = 0;
    await expectLater(
      ConfigDownloader(
        createClient: () {
          creates++;
          throw StateError('Should not create a client');
        },
      ).download('file:///private'),
      throwsA(
        isA<ConfigFailure>().having(
          (error) => error.message.id,
          'message',
          'urlRequired',
        ),
      ),
    );
    expect(creates, 0);
  });

  test('an expired operation leaves the client factory untouched', () async {
    var creates = 0;
    final downloader = ConfigDownloader(
      remaining: () async => Duration.zero,
      createClient: () {
        creates++;
        return ClientFake('/redirected');
      },
    );
    await expectLater(
      downloader.download('https://source.test/config'),
      throwsA(
        isA<ConfigFailure>().having(
          (error) => error.message.id,
          'message',
          'downloadTimeout',
        ),
      ),
    );
    await downloader.drained;
    expect(creates, 0);
  });

  for (final lateFactory in [true, false]) {
    testWidgets(
      'cancellation waits for actual drain, late factory: $lateFactory',
      (tester) async {
        final factory = Completer<HttpClient>();
        final transport = Completer<void>();
        final cancelled = Completer<void>();
        final client = ClientFake('/redirected')..getGate = transport;
        final downloader = ConfigDownloader(
          cancelled: cancelled.future,
          createClient: () => factory.future,
        );
        final result = downloader.download('https://source.test/config');
        final check = expectLater(
          result,
          throwsA(
            isA<ConfigFailure>().having(
              (error) => error.message.id,
              'message',
              'operationFinished',
            ),
          ),
        );
        if (!lateFactory) factory.complete(client);
        await tester.pump();
        expect(client.uris, hasLength(lateFactory ? 0 : 1));
        cancelled.complete();
        await tester.pump();
        await check;
        var drained = false;
        final drain = downloader.drained.then((_) => drained = true);
        await tester.pump();
        expect(drained, isFalse);
        expect(client.closed, !lateFactory);
        if (lateFactory) factory.complete(client);
        transport.complete();
        await tester.pump();
        await drain;
        expect(drained, isTrue);
        expect(client.closed, isTrue);
        expect(client.closeCalls, 1);
        if (lateFactory) {
          expect(client.uris, isEmpty);
        } else {
          expect(client.requests.single.aborted, isTrue);
          expect(client.uris, hasLength(1));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a client arriving after the total deadline is closed without I/O',
    (tester) async {
      final factory = Completer<HttpClient>();
      final client = ClientFake('/redirected');
      final result = ConfigDownloader(
        timeout: const Duration(seconds: 10),
        createClient: () => factory.future,
      ).download('https://source.test/config');
      final check = expectLater(
        result,
        throwsA(
          isA<ConfigFailure>().having(
            (error) => error.message.id,
            'message',
            'downloadTimeout',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await check;
      expect(client.closed, isFalse);
      factory.complete(client);
      await tester.pump();
      expect(client.closed, isTrue);
      expect(client.closeCalls, 1);
      expect(client.uris, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'factory time and transport time share one deadline, and late requests abort',
    (tester) async {
      final factory = Completer<HttpClient>();
      final transport = Completer<void>();
      final client = ClientFake('/redirected')..getGate = transport;
      final result = ConfigDownloader(
        remaining: () async => const Duration(seconds: 10),
        createClient: () => factory.future,
      ).download('https://source.test/config');
      final check = expectLater(
        result,
        throwsA(
          isA<ConfigFailure>().having(
            (error) => error.message.id,
            'message',
            'downloadTimeout',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      factory.complete(client);
      await tester.pump();
      expect(client.uris, hasLength(1));
      expect(client.closed, isFalse);
      await tester.pump(const Duration(seconds: 4));
      await check;
      expect(client.closed, isTrue);
      expect(client.closeCalls, 1);
      transport.complete();
      await tester.pump();
      expect(client.requests.single.aborted, isTrue);
      expect(client.uris, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late root failures after timeout are handled without an automatic retry',
    (tester) async {
      final factory = Completer<HttpClient>();
      var creates = 0;
      final result = ConfigDownloader(
        timeout: const Duration(seconds: 1),
        createClient: () {
          creates++;
          return factory.future;
        },
      ).download('https://source.test/config');
      final check = expectLater(
        result,
        throwsA(
          isA<ConfigFailure>().having(
            (error) => error.message.id,
            'message',
            'downloadTimeout',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await check;
      factory.completeError(PlatformException(code: 'trust'));
      await tester.pump();
      expect(creates, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final tls in [false, true]) {
    test('raw network diagnostics remain complete tls=$tls in both locales', () async {
      const raw =
          'https://user:password@source.test/config?token=private raw-diagnostic';
      final client = ClientFake('https://other.test/config')
        ..failure = tls
            ? const HandshakeException(raw)
            : const HttpException(raw);
      final expected = tls ? 'tlsFailed' : 'downloadFailed';
      addTearDown(() => setMessageLanguage(AppLanguage.system));
      try {
        await ConfigDownloader(createClient: () => client)
            .download(raw.split(' ').first);
        fail('The controlled transport error must fail the download');
      } on ConfigFailure catch (error) {
        expect(error.message.id, expected);
        expect(error.message.args, isEmpty);
        expect(error.message.detail, client.failure.toString());
        expect(error.toString(), '$expected: ${client.failure}');
        final rendered = <String>[];
        for (final language in [AppLanguage.en, AppLanguage.zh]) {
          setMessageLanguage(language);
          final text = error.message.text;
          expect(text, endsWith('\n${client.failure}'));
          expect(text, contains(raw));
          rendered.add(text);
        }
        expect(rendered.first, isNot(rendered.last));
      }
      expect(client.closed, isTrue);
    });
  }

  test('same-origin redirects retain original credentials only', () async {
    final client = ClientFake('/redirected');
    await ConfigDownloader(createClient: () => client)
        .download('https://user:secret@source.test/config');
    expect(client.uris.every((uri) => uri.userInfo.isEmpty), isTrue);
    for (final request in client.requests) {
      expect(
        request.headers.value(HttpHeaders.authorizationHeader),
        'Basic ${base64Encode(utf8.encode('user:secret'))}',
      );
    }
  });

  test(
    'HTTPS to HTTP redirect follows normally without forwarding credentials',
    () async {
      final client = ClientFake('http://redirect:injected@other.test/config');
      expect(
        await ConfigDownloader(createClient: () => client)
            .download('https://user:secret@source.test/config'),
        'rules: []',
      );
      expect(client.uris.map((u) => u.scheme), ['https', 'http']);
      expect(client.uris.every((u) => u.userInfo.isEmpty), isTrue);
      expect(
        client.requests.every((request) => !request.followRedirects),
        isTrue,
      );
      expect(
        client.requests.last.headers.value(HttpHeaders.authorizationHeader),
        isNull,
      );
      expect(client.closed, isTrue);
    },
  );

  test('credentials never follow a cross-origin redirect', () async {
    final client = ClientFake('https://other.test/config');
    await ConfigDownloader(createClient: () => client)
        .download('https://user:secret@source.test/config');
    expect(client.uris.every((u) => u.userInfo.isEmpty), true);
    expect(
      client.requests.first.headers.value(HttpHeaders.authorizationHeader),
      'Basic ${base64Encode(utf8.encode('user:secret'))}',
    );
    expect(
      client.requests.last.headers.value(HttpHeaders.authorizationHeader),
      isNull,
    );
    expect(client.closed, true);
  });
}
