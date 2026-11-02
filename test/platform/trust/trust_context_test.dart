import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/platform/trust/trust_context.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Uint8List roots;
  setUpAll(() async {
    roots = await File('test/fixtures/icon_tls/cert.pem').readAsBytes();
  });

  test(
    'loading is lazy and successful roots are cached, not clients',
    () async {
      var loads = 0;
      final trust = TrustContext(
        rootsLoader: () async {
          loads++;
          return Uint8List(0);
        },
      );
      expect(loads, 0);
      final first = await trust.createClient();
      first.close(force: true);
      final second = await trust.createClient();
      addTearDown(() => second.close(force: true));
      expect(identical(first, second), isFalse);
      expect(loads, 1);
    },
  );

  test(
    'successful context does not retain the initiating operation zone',
    () async {
      var retired = false;
      var loads = 0;
      final deferred = <void Function()>[];
      final initiatingZone = Zone.current.fork(
        specification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, callback) {
            if (retired) {
              deferred.add(callback);
            } else {
              parent.scheduleMicrotask(zone, callback);
            }
          },
        ),
      );
      final trust = TrustContext(
        rootsLoader: () async {
          loads++;
          return Uint8List(0);
        },
      );
      final first = await initiatingZone.run(trust.createClient);
      first.close(force: true);
      retired = true;
      final second = trust.createClient();
      try {
        await second.timeout(const Duration(milliseconds: 100));
        expect(deferred, isEmpty);
        expect(loads, 1);
      } finally {
        retired = false;
        final callbacks = List.of(deferred);
        deferred.clear();
        for (final callback in callbacks) {
          callback();
        }
        (await second).close(force: true);
      }
    },
  );

  test(
    'concurrent consumers share one pending load and get distinct clients',
    () async {
      var loads = 0;
      final gate = Completer<Uint8List>();
      final trust = TrustContext(
        rootsLoader: () {
          loads++;
          return gate.future;
        },
      );
      final pending = List.generate(4, (_) => trust.createClient());
      expect(loads, 1);
      gate.complete(roots);
      final clients = await Future.wait(pending);
      addTearDown(() {
        for (final client in clients) {
          client.close(force: true);
        }
      });
      expect(clients.toSet(), hasLength(4));
      expect(loads, 1);
    },
  );

  test(
    'all waiters see one failure and only an explicit call retries',
    () async {
      var loads = 0;
      final gate = Completer<Uint8List>();
      final failure = PlatformException(code: 'trustRoots');
      final trust = TrustContext(
        rootsLoader: () {
          loads++;
          return loads == 1 ? gate.future : Future.value(Uint8List(0));
        },
      );
      final waiting = List.generate(4, (_) => trust.createClient());
      final expectations = waiting
          .map((future) => expectLater(future, throwsA(same(failure))))
          .toList();
      expect(loads, 1);
      gate.completeError(failure);
      await Future.wait(expectations);
      await Future<void>.delayed(Duration.zero);
      expect(loads, 1);
      final retried = await trust.createClient();
      retried.close(force: true);
      expect(loads, 2);
      final cached = await trust.createClient();
      cached.close(force: true);
      expect(loads, 2);
    },
  );

  test('synchronous loader errors propagate and do not poison retry', () async {
    var loads = 0;
    final failure = StateError('platform root provider failed synchronously');
    final trust = TrustContext(
      rootsLoader: () {
        if (++loads == 1) throw failure;
        return Future.value(Uint8List(0));
      },
    );
    await expectLater(trust.createClient(), throwsA(same(failure)));
    final client = await trust.createClient();
    client.close(force: true);
    expect(loads, 2);
  });

  for (final name in [
    'garbage',
    'invalid certificate',
    'truncated certificate',
    'valid then invalid certificate',
    'invalid then valid certificate',
    'garbage before certificate',
    'garbage after certificate',
    'nested begin',
    'non-ASCII suffix',
  ]) {
    test('bad PEM fails closed: $name', () async {
      const bad =
          '-----BEGIN CERTIFICATE-----\nnot base64!\n-----END CERTIFICATE-----\n';
      final invalid = switch (name) {
        'garbage' => utf8.encode('not PEM'),
        'invalid certificate' => utf8.encode(bad),
        'truncated certificate' => roots.sublist(0, roots.length - 30),
        'valid then invalid certificate' => [...roots, ...utf8.encode(bad)],
        'invalid then valid certificate' => [...utf8.encode(bad), ...roots],
        'garbage before certificate' => [
          ...utf8.encode('unexpected prefix\n'),
          ...roots,
        ],
        'garbage after certificate' => [
          ...roots,
          ...utf8.encode('unexpected suffix'),
        ],
        'nested begin' => [
          ...utf8.encode('-----BEGIN CERTIFICATE-----\ninvalid prefix\n'),
          ...roots,
        ],
        'non-ASCII suffix' => [...roots, 255],
        _ => throw StateError('Unknown fixture'),
      };
      final trust = TrustContext(
        rootsLoader: () async => Uint8List.fromList(invalid),
      );
      await expectLater(
        trust.createClient().then((client) {
          client.close(force: true);
          return client;
        }),
        throwsA(anyOf(isA<TlsException>(), isA<FormatException>())),
      );
    });
  }

  test('valid PEM framing still requires SDK X.509 parsing', () async {
    final trust = TrustContext(
      rootsLoader: () async => Uint8List.fromList(
        ascii.encode(
          '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n',
        ),
      ),
    );
    await expectLater(
      trust.createClient().then((client) {
        client.close(force: true);
        return client;
      }),
      throwsA(isA<TlsException>()),
    );
  });

  test('bad roots can be retried with valid material without publishing a partial pool', () async {
    var loads = 0;
    final trust = TrustContext(
      rootsLoader: () async {
        loads++;
        return loads == 1
            ? Uint8List.fromList([
                ...roots,
                ...utf8.encode('unexpected suffix'),
              ])
            : roots;
      },
    );
    await expectLater(
      trust.createClient().then((client) {
        client.close(force: true);
        return client;
      }),
      throwsA(anyOf(isA<TlsException>(), isA<FormatException>())),
    );
    final server = await _TlsFixture.start(roots);
    addTearDown(server.close);
    final client = await trust.createClient();
    addTearDown(() => client.close(force: true));
    expect(await server.get(client), 'trusted response');
    expect(loads, 2);
  });

  test('the supplied root authenticates the controlled TLS peer', () async {
    final server = await _TlsFixture.start(roots);
    addTearDown(server.close);
    final trust = TrustContext(rootsLoader: () async => roots);
    final client = await trust.createClient();
    addTearDown(() => client.close(force: true));
    expect(await server.get(client), 'trusted response');
    expect(server.requests, 1);
  });

  test('successful empty roots reject an unknown TLS peer', () async {
    final server = await _TlsFixture.start(roots);
    addTearDown(server.close);
    final trust = TrustContext(rootsLoader: () async => Uint8List(0));
    final client = await trust.createClient();
    addTearDown(() => client.close(force: true));
    await expectLater(server.get(client), throwsA(isA<HandshakeException>()));
    expect(server.requests, 0);
  });

  test(
    'engine-owned snapshots do not share or fall back to another context',
    () async {
      final server = await _TlsFixture.start(roots);
      addTearDown(server.close);
      var firstLoads = 0;
      var secondLoads = 0;
      final first = TrustContext(
        rootsLoader: () async {
          firstLoads++;
          return roots;
        },
      );
      final second = TrustContext(
        rootsLoader: () async {
          secondLoads++;
          return Uint8List(0);
        },
      );
      final trusted = await first.createClient();
      addTearDown(() => trusted.close(force: true));
      expect(await server.get(trusted), 'trusted response');
      final empty = await second.createClient();
      addTearDown(() => empty.close(force: true));
      await expectLater(server.get(empty), throwsA(isA<HandshakeException>()));
      expect(firstLoads, 1);
      expect(secondLoads, 1);
    },
  );

  test('a trusted certificate still fails for the wrong hostname', () async {
    final wrongHostRoots = Uint8List.fromList(
      ascii.encode(_wrongHostCertificate),
    );
    final server = await _TlsFixture.start(wrongHostRoots);
    addTearDown(server.close);
    final trust = TrustContext(rootsLoader: () async => wrongHostRoots);
    final client = await trust.createClient();
    addTearDown(() => client.close(force: true));
    // The trusted certificate names wrong.example; exercise hostname rejection through
    // the real loopback TLS client.
    await expectLater(server.get(client), throwsA(isA<HandshakeException>()));
    expect(server.requests, 0);
  });

  test(
    'closing a client leaves the root snapshot usable by a new caller',
    () async {
      final server = await _TlsFixture.start(roots);
      addTearDown(server.close);
      var loads = 0;
      final trust = TrustContext(
        rootsLoader: () async {
          loads++;
          return roots;
        },
      );
      final first = await trust.createClient();
      expect(await server.get(first), 'trusted response');
      first.close(force: true);
      final second = await trust.createClient();
      addTearDown(() => second.close(force: true));
      expect(await server.get(second), 'trusted response');
      expect(loads, 1);
      expect(server.requests, 2);
    },
  );
}

// Self-signed public test certificate for wrong.example, made with the existing
// test/fixtures/icon_tls/key.pem fixture key. Valid 2026-10-18 to 2126-09-24.
const _wrongHostCertificate = '''
-----BEGIN CERTIFICATE-----
MIIDGjCCAgKgAwIBAgIBAjANBgkqhkiG9w0BAQsFADAYMRYwFAYDVQQDDA13cm9u
Zy5leGFtcGxlMCAXDTI2MTAxODE1MzYxNVoYDzIxMjYwOTI0MTUzNjE1WjAYMRYw
FAYDVQQDDA13cm9uZy5leGFtcGxlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIB
CgKCAQEAtnPRe4oyK9qGtET7effTTSEFy0FKnCAsBFUS7BG1y43DPHwvOsSGWNm3
kpJxmnsjHd09Q8m/0J5UPCl8FZO5+UFbUfd1ux6h7oT6xe6WJLkmA5bvBPC4WToN
i/MYbHy35A1jxORSfW33E5YCHmVYrGpjqPFQvSAH0tFAcwsBrICWNjSm4pP610Z3
XP6yqKx8paxutxk3Q2g9tI/Zd5b2PuIH9AgdWAo7tkAguhi1LT7KBrfzGqfRJVxM
J1ITDMYVqLFDYpI4aQGtTYAHSyu6b3o2rlMxm1RrSktpMS/xM7dN+Wy/AbI1/Dwd
I5zoHOfusDvUD4fmM8TXpB0J+621dQIDAQABo20wazAdBgNVHQ4EFgQUO5bSFEGs
rqg14v8LLLottGfTfOUwHwYDVR0jBBgwFoAUO5bSFEGsrqg14v8LLLottGfTfOUw
DwYDVR0TAQH/BAUwAwEB/zAYBgNVHREEETAPgg13cm9uZy5leGFtcGxlMA0GCSqG
SIb3DQEBCwUAA4IBAQCb/v03QNI6noalvzW0Z8Zw/qFiW4quYzb94eG1Z9zpQP+Q
Uy0MA/SaqdFP5s4TeyRj5sadUDc2L2qrMuLCIsRQLBWLlmY+vzgoDxuyZfqjBibV
aAtE6uc1thTqTagbThVRffPbxW1zNu7/xFqx6CmBqegj3Srs1pK9vKSGViWGyh7i
gTAQbWQMLjXVsEOadsa+KKem0V0aI4nZqQoMdEHBQhC2zbyWdmk3ZEDwKhhhIKIe
UnY6/+tLRkLKtwkzVJQyu9nC3veBQnCAiKSitt+xGJu6PGd4CU3/ANKkeE8bS4ow
jCcfupf/V1hL4peTzo5Gicn3eG6VFYnEQUInLFrk
-----END CERTIFICATE-----
''';

class _TlsFixture {
  _TlsFixture(this._server) {
    _subscription = _server.listen((request) async {
      requests++;
      request.response.write('trusted response');
      await request.response.close();
    }, onError: (Object error) => _serverErrors.add(error));
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final _serverErrors = <Object>[];
  var requests = 0;
  int get port => _server.port;

  static Future<_TlsFixture> start(Uint8List roots) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(roots)
      ..usePrivateKey('test/fixtures/icon_tls/key.pem');
    return _TlsFixture(
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context),
    );
  }

  Future<String> get(HttpClient client) async {
    client.findProxy = (_) => 'DIRECT';
    final request = await client
        .getUrl(
          Uri(scheme: 'https', host: '127.0.0.1', port: port, path: '/trust'),
        )
        .timeout(const Duration(seconds: 5));
    final response = await request.close().timeout(const Duration(seconds: 5));
    expect(response.statusCode, HttpStatus.ok);
    return utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _subscription.cancel();
    // Accept expected rejected-client handshake errors and report other server
    // failures.
    expect(_serverErrors.where((error) => error is! TlsException), isEmpty);
  }
}
