import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/features/configs/config_downloader.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:flutter_test/flutter_test.dart';

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
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ClientFake implements HttpClient {
  ClientFake(this.destination);
  final String destination;
  final uris = <Uri>[];
  final requests = <RequestFake>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
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
    closed = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('HTTPS downgrade is stopped before any plaintext request', () async {
    final client = ClientFake('http://other.test/config');
    await expectLater(
      ConfigDownloader(createClient: () => client)
          .download('https://source.test/config', allowHttp: false),
      throwsA(
        isA<ConfigFailure>().having(
          (e) => e.needsHttpConfirmation,
          'requires confirmation',
          true,
        ),
      ),
    );
    expect(client.uris.map((u) => u.scheme), ['https']);
    expect(client.requests.single.followRedirects, false);
    expect(client.closed, true);
  });

  test('credentials never follow a cross-origin redirect', () async {
    final client = ClientFake('https://other.test/config');
    await ConfigDownloader(createClient: () => client)
        .download('https://user:secret@source.test/config', allowHttp: false);
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
