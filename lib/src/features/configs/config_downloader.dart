import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config_entry.dart';
import 'config_text.dart';
import '../../l10n/messages.dart';
import '../../model/application_contract.dart';
import '../../platform/trusted_http.dart';

class ConfigDownloader {
  ConfigDownloader({
    this.maxBytes = maxConfigBytes,
    this.timeout = const Duration(
      milliseconds: ApplicationContract.operationOrdinaryTimeoutMs,
    ),
    this.remaining,
    this.cancelled,
    FutureOr<HttpClient> Function()? createClient,
  }) : _createClient = createClient ?? createTrustedHttpClient;

  final int maxBytes;
  final Duration timeout;
  final Future<Duration> Function()? remaining;
  final Future<void>? cancelled;
  final FutureOr<HttpClient> Function() _createClient;
  final _inflight = <Future<void>>{};
  Future<void> get drained async {
    await Future.wait(_inflight);
  }

  static const maxRedirects = 5;

  static Uri sourceUri(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw ConfigFailure(messages.urlRequired);
    }
    return uri.removeFragment();
  }

  Future<String> download(String source) async {
    final initial = sourceUri(source);
    HttpClient? client;
    var active = true;
    var budget = timeout;
    Future<String> fetch() async {
      final HttpClient created;
      try {
        created = await Future<HttpClient>.sync(_createClient);
      } catch (_) {
        throw ConfigFailure(messages.trustedRootsUnavailable);
      }
      if (!active) {
        created.close(force: true);
        throw TimeoutException('Download expired while creating its client');
      }
      client = created;
      created.connectionTimeout = budget;
      return _fetch(created, initial, () => active);
    }

    Future<String> perform() async {
      final remaining = await this.remaining?.call();
      if (!active) throw ConfigFailure(messages.operationFinished);
      if (remaining != null && remaining < budget) budget = remaining;
      if (budget <= Duration.zero) {
        throw ConfigFailure(messages.downloadTimeout);
      }
      try {
        // Register the deadline before invoking even a synchronous factory.
        final fetching = Future<String>.microtask(fetch);
        final draining = fetching.then<void>((_) {}, onError: (Object _) {});
        _inflight.add(draining);
        unawaited(draining.then((_) => _inflight.remove(draining)));
        return await fetching.timeout(budget);
      } on ConfigFailure {
        rethrow;
      } on TimeoutException {
        throw ConfigFailure(messages.downloadTimeout);
      } on HandshakeException {
        throw ConfigFailure(messages.tlsFailed);
      } on FormatException {
        throw ConfigFailure(messages.downloadNotUtf8);
      } catch (_) {
        // Network exceptions often embed the full URL, including subscription tokens.
        throw ConfigFailure(messages.downloadFailed);
      }
    }

    try {
      return await Future.any([
        perform(),
        if (cancelled case final cancelled?)
          cancelled.then<String>(
            (_) => throw ConfigFailure(messages.operationFinished),
          ),
      ]);
    } finally {
      active = false;
      client?.close(force: true);
    }
  }

  Future<String> _fetch(
    HttpClient client,
    Uri initial,
    bool Function() current,
  ) async {
    void checkCurrent() {
      if (!current()) throw TimeoutException('Download expired');
    }

    var uri = initial;
    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      checkCurrent();
      final request = await client.getUrl(uri.replace(userInfo: ''));
      if (!current()) {
        request.abort();
        checkCurrent();
      }
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/yaml, text/plain, */*',
      );
      if (_sameOrigin(initial, uri) && initial.userInfo.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Basic ${base64Encode(utf8.encode(Uri.decodeComponent(initial.userInfo)))}',
        );
      }
      final response = await request.close();
      if (!current()) {
        await response.listen((_) {}).cancel();
        checkCurrent();
      }
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null || redirects == maxRedirects) {
          throw ConfigFailure(messages.redirectInvalid);
        }
        uri = sourceUri(uri.resolve(location).toString());
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        final status = response.statusCode;
        await response.listen((_) {}).cancel();
        throw ConfigFailure(messages.downloadHttpStatus('$status'));
      }
      final builder = BytesBuilder(copy: false);
      await for (final bytes in response) {
        checkCurrent();
        if (builder.length + bytes.length > maxBytes) {
          throw ConfigFailure(messages.downloadTooLarge);
        }
        builder.add(bytes);
      }
      checkCurrent();
      return decodeConfigText(builder.takeBytes());
    }
    throw ConfigFailure(messages.redirectTooMany);
  }

  bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
}
