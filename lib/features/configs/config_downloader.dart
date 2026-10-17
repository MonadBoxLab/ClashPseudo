import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config_entry.dart';
import 'config_text.dart';

class ConfigDownloader {
  ConfigDownloader({
    this.maxBytes = maxConfigBytes,
    this.timeout = const Duration(seconds: 30),
    HttpClient Function()? createClient,
  }) : _createClient = createClient ?? HttpClient.new;

  // Bound memory and wait time for a foreground import, including redirects.
  final int maxBytes;
  final Duration timeout;
  final HttpClient Function() _createClient;
  static const maxRedirects = 5;

  static Uri sourceUri(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const ConfigFailure('请输入完整的 HTTP 或 HTTPS 配置 URL。');
    }
    return uri.removeFragment();
  }

  Future<String> download(String source, {required bool allowHttp}) async {
    final client = _createClient();
    client.connectionTimeout = timeout;
    try {
      return await _fetch(
        client,
        sourceUri(source),
        allowHttp,
      ).timeout(timeout);
    } on ConfigFailure {
      rethrow;
    } on TimeoutException {
      throw const ConfigFailure('下载超时，请检查网络后重试。');
    } on HandshakeException {
      throw const ConfigFailure('HTTPS 证书或安全连接验证失败，未绕过验证。');
    } on FormatException {
      throw const ConfigFailure('下载内容不是有效的 UTF-8 文本。');
    } catch (_) {
      // Network exceptions often embed the full URL, including subscription tokens.
      throw const ConfigFailure('无法下载配置，请检查来源和当前网络。');
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _fetch(HttpClient client, Uri initial, bool allowHttp) async {
    var uri = initial;
    for (var redirects = 0; redirects <= maxRedirects; redirects++) {
      if (uri.scheme == 'http' && !allowHttp) {
        throw const ConfigFailure(
          '此来源或其重定向使用 HTTP，配置和凭据将以明文传输。',
          needsHttpConfirmation: true,
        );
      }
      final request = await client.getUrl(uri.replace(userInfo: ''));
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
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null || redirects == maxRedirects) {
          throw const ConfigFailure('配置来源的重定向无效或次数过多。');
        }
        uri = sourceUri(uri.resolve(location).toString());
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        final status = response.statusCode;
        await response.listen((_) {}).cancel();
        throw ConfigFailure('配置下载失败（HTTP $status）。');
      }
      final builder = BytesBuilder(copy: false);
      await for (final bytes in response) {
        if (builder.length + bytes.length > maxBytes) {
          throw const ConfigFailure('配置正文过大，未保存。');
        }
        builder.add(bytes);
      }
      return decodeConfigText(builder.takeBytes());
    }
    throw const ConfigFailure('配置来源的重定向次数过多。');
  }

  bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
}
