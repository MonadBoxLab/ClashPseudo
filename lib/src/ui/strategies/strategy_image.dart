import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart'
    as compiler;

import '../../platform/trust/trusted_http.dart';

const _bitmapLimit = 1024 * 1024;
const _svgLimit = 256 * 1024;

// Only successful compiled bytes reach the renderer. flutter_svg 2.3.0's
// SvgLoader cache retains failed pending futures, even after evict/clear.
Uint8List compileStrategySvg(Uint8List bytes) => compiler.encodeSvg(
  xml: utf8.decode(bytes),
  debugName: 'configuration icon',
  enableClippingOptimizer: false,
  enableMaskingOptimizer: false,
  enableOverdrawOptimizer: false,
);

Future<({Uint8List bytes, bool svg})> loadStrategyImage(
  String source,
  HttpClient client, {
  bool Function()? isCurrent,
}) async {
  void checkCurrent() {
    if (isCurrent?.call() == false) throw StateError('Icon request expired');
  }

  final uri = Uri.parse(source);
  checkCurrent();
  final request = await client.getUrl(uri);
  if (isCurrent?.call() == false) {
    request.abort();
    checkCurrent();
  }
  final response = await request.close();
  if (isCurrent?.call() == false) {
    await response.listen((_) {}).cancel();
    checkCurrent();
  }
  if (response.statusCode != HttpStatus.ok) {
    await response.listen((_) {}).cancel();
    throw HttpException(
      'HTTP ${response.statusCode} ${response.reasonPhrase}',
      uri: uri,
    );
  }
  final declaredSvg = response.headers.contentType?.mimeType == 'image/svg+xml';
  final limit = declaredSvg ? _svgLimit : _bitmapLimit;
  if (response.contentLength > limit) {
    await response.listen((_) {}).cancel();
    throw FormatException('Icon exceeds $limit bytes');
  }
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in response) {
    checkCurrent();
    if (buffer.length + chunk.length > limit) {
      throw FormatException('Icon exceeds $limit bytes');
    }
    buffer.add(chunk);
  }
  checkCurrent();
  final bytes = buffer.takeBytes();
  // Choose the renderer from the body, not the URL, MIME type or a bitmap
  // allowlist. The SDK decoder handles its supported raster formats; XML is
  // passed to the existing SVG compiler without an extra SVG validation gate.
  final svg = utf8
      .decode(bytes, allowMalformed: true)
      .trimLeft()
      .startsWith('<');
  if (!svg) return (bytes: bytes, svg: false);
  if (bytes.length > _svgLimit) {
    throw const FormatException('SVG exceeds $_svgLimit bytes');
  }
  return (bytes: await compute(compileStrategySvg, bytes), svg: true);
}

class StrategyImage extends StatefulWidget {
  const StrategyImage({
    super.key,
    required this.source,
    required this.fallback,
    this.createClient,
  });
  final String source;
  final Widget fallback;
  final FutureOr<HttpClient> Function()? createClient;

  @override
  State<StrategyImage> createState() => _StrategyImageState();
}

class _StrategyImageState extends State<StrategyImage> {
  HttpClient? _client;
  Completer<void>? _cancel;
  ({Uint8List bytes, bool svg})? _image;
  _CompiledIcon? _loader;
  Object? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StrategyImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.createClient != widget.createClient) {
      _load();
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    _cancel?.complete();
    _cancel = null;
    _client?.close(force: true);
    _client = null;
    _image = null;
    _loader = null;
    _error = null;
    final source = widget.source;
    final createClient = widget.createClient ?? createTrustedHttpClient;
    final cancel = _cancel = Completer<void>();
    const deadline = Duration(seconds: 8);
    var active = true;
    HttpClient? client;
    bool current() =>
        active && !cancel.isCompleted && mounted && request == _request;
    Future<({Uint8List bytes, bool svg})?> fetch() async {
      final created = await Future<HttpClient>.sync(createClient);
      if (!current()) {
        created.close(force: true);
        return null;
      }
      client = _client = created;
      created.connectionTimeout = deadline;
      return loadStrategyImage(source, created, isCurrent: current);
    }

    try {
      // Retire this request's deadline while preserving the shared root load for its
      // other consumers.
      final image = await Future.any<({Uint8List bytes, bool svg})?>([
        Future<({Uint8List bytes, bool svg})?>.microtask(fetch),
        cancel.future.then((_) => null),
      ]).timeout(deadline);
      if (image == null || !current()) return;
      setState(() {
        _image = image;
        _loader = image.svg ? _CompiledIcon(image.bytes) : null;
      });
    } catch (failure) {
      if (current()) setState(() => _error = failure);
    } finally {
      active = false;
      if (!cancel.isCompleted) cancel.complete();
      if (identical(_cancel, cancel)) _cancel = null;
      if (identical(_client, client)) {
        client?.close(force: true);
        _client = null;
      }
    }
  }

  Widget _fallback([Object? failure]) {
    final text = (failure ?? _error)?.toString();
    return text == null
        ? widget.fallback
        : Tooltip(message: text, child: widget.fallback);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return _fallback();
    if (image.svg) {
      return SvgPicture(
        _loader!,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        placeholderBuilder: (_) => _fallback(),
        errorBuilder: (_, failure, _) => _fallback(failure),
      );
    }
    return Image(
      image: ResizeImage(
        MemoryImage(image.bytes),
        width: 256,
        height: 256,
        policy: ResizeImagePolicy.fit,
      ),
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      errorBuilder: (_, failure, _) => _fallback(failure),
    );
  }

  @override
  void dispose() {
    _request++;
    _cancel?.complete();
    _cancel = null;
    _client?.close(force: true);
    _client = null;
    super.dispose();
  }
}

class _CompiledIcon extends BytesLoader {
  const _CompiledIcon(this.bytes);
  final Uint8List bytes;

  @override
  Future<ByteData> loadBytes(BuildContext? context) =>
      SynchronousFuture(ByteData.sublistView(bytes));
}
