import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late ConfigStore store;
  const entry = ConfigEntry(
    id: 'one',
    name: '测试🌐',
    source: 'https://example.test/config?token=private',
    revision: 1,
    body: 'rules:\n  - MATCH,DIRECT\n',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-store-');
    store = ConfigStore(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'restores only saved configuration and selection, not runtime state',
    () async {
      expect((await store.read()).entries, isEmpty);
      await store.save(
        ConfigCollection(entries: [entry], selectedId: entry.id),
      );
      final restored = await ConfigStore(directory).read();
      expect(restored.selected!.body, entry.body);
      expect(restored.selected!.name, '测试🌐');
      expect(restored.selected!.source, contains('token=private'));
      expect(restored.selected!.displaySource, isNot(contains('private')));
      final data = jsonDecode(
        await File('${directory.path}/configurations.json').readAsString(),
      ) as Map;
      expect(data.keys, unorderedEquals(['version', 'selectedId', 'entries']));
      expect(await directory.list().length, 1);
    },
  );

  test('invalidated content stays unavailable after reopening', () async {
    await store.save(
      ConfigCollection(
        entries: [entry.withContent(null, error: '更新未完成')],
        selectedId: entry.id,
      ),
    );
    final restored = await ConfigStore(directory).read();
    expect(restored.selected!.body, isNull);
    expect(restored.selected!.source, entry.source);
  });

  test(
    'damaged store is reported without replacing it with an empty list',
    () async {
      final file = File('${directory.path}/configurations.json');
      await file.writeAsString('{broken');
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
      expect(await file.readAsString(), '{broken');
    },
  );

  test(
    'failed staging write preserves the previously committed file',
    () async {
      await store.save(
        ConfigCollection(entries: [entry], selectedId: entry.id),
      );
      await Directory('${directory.path}/configurations.json.tmp').create();
      await expectLater(
        store.save(ConfigCollection(entries: [])),
        throwsA(isA<ConfigFailure>()),
      );
      expect((await store.read()).selectedId, entry.id);
    },
  );

  test(
    'inconsistent restored selection is not accepted as a clean store',
    () async {
      await File('${directory.path}/configurations.json').writeAsString(
        jsonEncode({
          'version': 1,
          'entries': [entry.toJson()],
          'selectedId': 'missing',
        }),
      );
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
    },
  );
}
