import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'flutter_svg 2.3.0 retains failed pending entries after evict',
    () async {
      final cache = Cache();
      final done = Completer<void>();
      final detachedErrors = <Object>[];
      var loads = 0;
      runZonedGuarded(() async {
        Future<ByteData> load() async {
          loads++;
          throw const FormatException('invalid SVG fixture');
        }

        for (var i = 0; i < 3; i++) {
          await expectLater(
            cache.putIfAbsent('fixture', load),
            throwsFormatException,
          );
          cache.evict('fixture');
          cache.clear();
        }
        await Future<void>.delayed(Duration.zero);
        done.complete();
      }, (error, stack) => detachedErrors.add(error));
      await done.future;
      expect(loads, 1);
      expect(detachedErrors, hasLength(1));
    },
  );
}
