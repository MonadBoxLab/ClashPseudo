import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import 'readonly_override_store.dart';

void main() {
  const entry = OverrideEntry(
    id: 'fixture',
    name: 'Fixture',
    kind: ConfigKind.local,
    revision: 1,
    body: '{}',
  );

  test(
    'read-only override stub rejects saves instead of falling through to disk',
    () async {
      final store = ReadOnlyOverrideStore()..entries = [entry];
      await expectLater(store.save([]), throwsUnsupportedError);
      expect(await store.read(), [entry]);
      expect(store.entries, [entry]);
    },
  );

  test(
    'read-only override stub rejects clear before any disk access',
    () async {
      final store = ReadOnlyOverrideStore()..entries = [entry];
      var diskAttempts = 0;
      await IOOverrides.runZoned(
        () async {
          await expectLater(store.clear(), throwsUnsupportedError);
          expect(await store.read(), [entry]);
          expect(store.entries, [entry]);
        },
        createFile: (_) {
          diskAttempts++;
          throw StateError('read-only stub attempted file access');
        },
        createDirectory: (_) {
          diskAttempts++;
          throw StateError('read-only stub attempted directory access');
        },
      );
      expect(diskAttempts, 0);
    },
  );

  test(
    'read-only override stub returns an immutable independent snapshot',
    () async {
      final store = ReadOnlyOverrideStore()..entries = [entry];
      final snapshot = await store.read();
      expect(() => snapshot.clear(), throwsUnsupportedError);
      store.entries.clear();
      expect(snapshot, [entry]);
      expect(await store.read(), isEmpty);
    },
  );
}
