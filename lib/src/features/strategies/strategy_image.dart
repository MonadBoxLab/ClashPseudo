import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics_compiler/vector_graphics_compiler.dart'
    as compiler;

import '../../platform/trusted_http.dart';

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
  HttpClient client, {
  bool Function()? isCurrent,
}) async {
  void checkCurrent() {
    if (isCurrent?.call() == false) throw StateError('Icon request expired');
  }

  var uri = Uri.parse(source);
  if (!_allowed(uri)) throw const FormatException('Unsupported icon source');
  for (var redirects = 0; ; redirects++) {
    checkCurrent();
    final request = await client.getUrl(uri);
    if (isCurrent?.call() == false) {
      request.abort();
      checkCurrent();
    }
    request.followRedirects = false;
    final response = await request.close();
    if (isCurrent?.call() == false) {
      await response.listen((_) {}).cancel();
      checkCurrent();
    }
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
      checkCurrent();
      if (buffer.length + chunk.length > limit) {
        throw const FormatException('Icon too large');
      }
      buffer.add(chunk);
    }
    checkCurrent();
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
    final source = widget.source;
    final uri = Uri.tryParse(source);
    if (uri == null || !_allowed(uri)) return;
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
    } catch (_) {
      // Trust loading, configuration URLs and decoder errors stay off the UI.
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
