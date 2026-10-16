import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/features/strategies/strategy_choice.dart';
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
      expect(
        data.keys,
        unorderedEquals(['version', 'selectedId', 'mode', 'entries']),
      );
      expect(await directory.list().length, 1);
    },
  );

  test('strategy preferences are scoped to each configuration', () async {
    final first = entry
        .withChoice(
          '出口',
          const StrategyChoice(type: StrategyType.select, member: '节点🌐'),
        )
        .withChoice(
          '自动',
          const StrategyChoice(type: StrategyType.urlTest, member: null),
        );
    final second =
        ConfigEntry(
          id: 'two',
          name: '另一份',
          source: 'https://example.test/other',
          revision: 1,
          body: entry.body,
        ).withChoice(
          '出口',
          const StrategyChoice(type: StrategyType.select, member: 'DIRECT'),
        );
    await store.save(
      ConfigCollection(entries: [first, second], selectedId: 'one'),
    );
    final restored = await ConfigStore(directory).read();
    expect(restored.selected!.choices['出口']!.member, '节点🌐');
    expect(restored.find('two')!.choices['出口']!.member, 'DIRECT');
    expect(restored.selected!.choices.containsKey('自动'), isTrue);
    expect(restored.selected!.choices['自动']!.member, isNull);
    expect(first.revision, entry.revision);
    expect(first.body, entry.body);
    final invalidated = first.withContent(null, error: '更新未完成');
    expect(invalidated.choices['出口']!.member, '节点🌐');
    expect(invalidated.withContent('new body').choices['出口']!.member, '节点🌐');
    expect(entry.choices, isEmpty);
  });

  test('legacy entries default only absent strategy fields', () async {
    final file = File('${directory.path}/configurations.json');
    final legacy = entry.toJson()..remove('choices');
    Future<void> write(Map<String, Object?> record) => file.writeAsString(
      jsonEncode({
        'version': 1,
        'entries': [record],
        'selectedId': 'one',
      }),
    );
    await write(legacy);
    expect((await store.read()).selected!.choices, isEmpty);
    for (final invalid in <Object?>[
      null,
      [],
      {
        '': {'type': 'select', 'member': 'DIRECT'},
      },
      {
        'g': {'type': 'select'},
      },
      {
        'g': {'type': 'select', 'member': null},
      },
      {
        'g': {'type': 'load-balance', 'member': 'DIRECT'},
      },
      {
        'g': {'type': 'fallback', 'member': ''},
      },
      {
        'g': {'type': 'fallback', 'member': 1},
      },
    ]) {
      await write({...legacy, 'choices': invalid});
      final before = await file.readAsString();
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
      expect(await file.readAsString(), before);
    }
  });

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

  test('expired operation cannot publish a late staging write', () async {
    await store.save(ConfigCollection(entries: [entry], selectedId: entry.id));
    var checks = 0;
    final guarded = ConfigStore(
      directory,
      beforeWrite: () async {
        if (++checks == 2) throw StateError('expired');
      },
    );
    await expectLater(
      guarded.save(ConfigCollection(entries: [])),
      throwsStateError,
    );
    expect(checks, 2);
    expect((await store.read()).selectedId, entry.id);
    expect(
      await File('${directory.path}/configurations.json.tmp').exists(),
      isFalse,
    );
  });

  test('expired operation is rejected before staging', () async {
    final guarded = ConfigStore(
      directory,
      beforeWrite: () async {
        throw StateError('expired');
      },
    );
    await expectLater(
      guarded.save(ConfigCollection(entries: [])),
      throwsStateError,
    );
    expect(await directory.list().isEmpty, isTrue);
  });

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
