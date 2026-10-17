import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart'
    as compiler;

const _bitmapLimit = 1024 * 1024;
const _svgLimit = 256 * 1024;

bool _allowed(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

// Only successful compiled bytes reach the renderer. flutter_svg 2.3.0's
// SvgLoader cache retains failed pending futures, even after evict/clear.
Uint8List compileStrategySvg(Uint8List bytes) => compiler.encodeSvg(
  xml: utf8.decode(bytes),
  debugName: 'configuration icon',
  warningsAsErrors: true,
  enableClippingOptimizer: false,
  enableMaskingOptimizer: false,
  enableOverdrawOptimizer: false,
);

Future<({Uint8List bytes, bool svg})> loadStrategyImage(
  String source,
  HttpClient client,
) async {
  var uri = Uri.parse(source);
  if (!_allowed(uri)) throw const FormatException('Unsupported icon source');
  for (var redirects = 0; ; redirects++) {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    final response = await request.close();
    if (response.isRedirect) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (redirects >= 3 || location == null) {
        throw const FormatException('Icon redirect limit');
      }
      final next = uri.resolve(location);
      if (!_allowed(next) ||
          (uri.scheme == 'https' && next.scheme != 'https')) {
        throw const FormatException('Unsupported icon redirect');
      }
      await response.listen((_) {}).cancel();
      uri = next;
      continue;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw const FormatException('Icon request failed');
    }
    final declaredSvg =
        response.headers.contentType?.mimeType == 'image/svg+xml';
    final limit = declaredSvg ? _svgLimit : _bitmapLimit;
    if (response.contentLength > limit) {
      throw const FormatException('Icon too large');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (buffer.length + chunk.length > limit) {
        throw const FormatException('Icon too large');
      }
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    bool prefix(List<int> signature) =>
        bytes.length >= signature.length &&
        signature.indexed.every((entry) => bytes[entry.$1] == entry.$2);
    final bitmap =
        prefix([137, 80, 78, 71, 13, 10, 26, 10]) ||
        prefix([255, 216, 255]) ||
        (prefix([82, 73, 70, 70]) &&
            bytes.length >= 12 &&
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP');
    if (bitmap && !declaredSvg) return (bytes: bytes, svg: false);
    if (bytes.length > _svgLimit) throw const FormatException('SVG too large');
    return (bytes: await compute(compileStrategySvg, bytes), svg: true);
  }
}

class StrategyImage extends StatefulWidget {
  const StrategyImage({
    super.key,
    required this.source,
    required this.fallback,
  });
  final String source;
  final Widget fallback;

  @override
  State<StrategyImage> createState() => _StrategyImageState();
}

class _StrategyImageState extends State<StrategyImage> {
  HttpClient? _client;
  ({Uint8List bytes, bool svg})? _image;
  _CompiledIcon? _loader;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StrategyImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    _client?.close(force: true);
    _image = null;
    _loader = null;
    final uri = Uri.tryParse(widget.source);
    if (uri == null || !_allowed(uri)) return;
    final client = _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final image = await loadStrategyImage(
        widget.source,
        client,
      ).timeout(const Duration(seconds: 8));
      if (!mounted || request != _request) return;
      setState(() {
        _image = image;
        _loader = image.svg ? _CompiledIcon(image.bytes) : null;
      });
    } catch (_) {
      // Configuration URLs and decoder errors may contain credentials.
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return widget.fallback;
    if (image.svg) {
      return SvgPicture(
        _loader!,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        placeholderBuilder: (_) => widget.fallback,
        errorBuilder: (_, _, _) => widget.fallback,
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
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }

  @override
  void dispose() {
    _request++;
    _client?.close(force: true);
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
