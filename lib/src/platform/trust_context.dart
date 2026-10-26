import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One lazy root snapshot per engine, shared by its HTTP consumers.
///
/// The owner supplies the platform loader and retains this instance. Clients
/// are independent resources and must be closed by their respective callers.
class TrustContext {
  TrustContext({required this.rootsLoader});

  final Future<Uint8List> Function() rootsLoader;
  SecurityContext? _context;
  Future<SecurityContext>? _loading;

  Future<HttpClient> createClient() async => HttpClient(context: await _load());

  Future<SecurityContext> _load() {
    final cached = _context;
    // Cache the loaded trust context and release the initiating operation's
    // Future/zone.
    if (cached != null) return Future.value(cached);
    return _loading ??= Future<Uint8List>.sync(rootsLoader)
        .then((roots) {
          final context = SecurityContext(withTrustedRoots: false);
          // The SDK accepts arbitrary non-PEM prefixes/suffixes. Android exports
          // certificate blocks only; reject other material rather than trusting
          // a valid subset. X.509 parsing remains the SDK's responsibility.
          final material = ascii.decode(roots).trim();
          final blocks = RegExp(
            r'-----BEGIN CERTIFICATE-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----',
          );
          var end = 0;
          for (final match in blocks.allMatches(material)) {
            if (material.substring(end, match.start).trim().isNotEmpty) {
              throw const FormatException('Invalid root PEM material');
            }
            context.setTrustedCertificatesBytes(ascii.encode(match.group(0)!));
            end = match.end;
          }
          // Empty/whitespace-only material deliberately leaves an empty pool.
          if (material.substring(end).trim().isNotEmpty) {
            throw const FormatException('Invalid root PEM material');
          }
          _context = context;
          _loading = null;
          return context;
        })
        .onError((Object error, StackTrace stack) {
          // An explicit later call starts a new load after failure. Future.sync also
          // captures synchronous loader failure.
          _loading = null;
          Error.throwWithStackTrace(error, stack);
        });
  }
}
