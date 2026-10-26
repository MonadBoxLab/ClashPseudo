import 'dart:io';

import 'app_bridge.dart';
import 'trust_context.dart';

// Each Flutter isolate lazily owns a read-only process-root snapshot independent of
// command lifetimes.
final _trust = TrustContext(rootsLoader: AppBridge().trustRoots);

Future<HttpClient> createTrustedHttpClient() => _trust.createClient();
