import 'package:flutter_test/flutter_test.dart';

import 'fixtures/coverage_unimported.dart' deferred as uncalled;

void main() {
  test(
    'loading an otherwise unimported library does not execute its function',
    () async {
      await uncalled.loadLibrary();
      expect(uncalled.LoadingMarker, isA<Type>());
    },
  );
}
