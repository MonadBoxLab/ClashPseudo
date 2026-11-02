import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';

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
      expect(restored.selected!.displaySource, entry.source);
      final data = jsonDecode(
        await File('${directory.path}/configurations.json').readAsString(),
      ) as Map;
      expect(data.keys, unorderedEquals(['selectedId', 'mode', 'entries']));
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
    final invalidated = first.withContent(
      first.body,
      error: messages.downloadFailed,
    );
    expect(invalidated.choices['出口']!.member, '节点🌐');
    expect(invalidated.withContent('new body').choices['出口']!.member, '节点🌐');
    expect(entry.choices, isEmpty);
  });

  test('current entries require valid strategy fields', () async {
    final file = File('${directory.path}/configurations.json');
    final incomplete = entry.toJson()..remove('choices');
    Future<void> write(Map<String, Object?> record) => file.writeAsString(
      jsonEncode({
        'mode': 'rule',
        'entries': [record],
        'selectedId': 'one',
      }),
    );
    await write(incomplete);
    await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
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
      await write({...incomplete, 'choices': invalid});
      final before = await file.readAsString();
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
      expect(await file.readAsString(), before);
    }
  });

  test('invalid current records are rejected without rewriting', () async {
    final file = File('${directory.path}/configurations.json');
    final missingKind = entry.toJson()..remove('kind');
    for (final record in [
      missingKind,
      {...entry.toJson(), 'kind': 'unknown'},
      {...entry.toJson(), 'kind': 'local'},
      {...entry.toJson(), 'source': null},
      {...entry.toJson(), 'revision': 0},
    ]) {
      final original = jsonEncode({
        'mode': 'rule',
        'entries': [record],
        'selectedId': 'one',
      });
      await file.writeAsString(original);
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
      expect(await file.readAsString(), original);
    }
  });

  test(
    'invalid modes and duplicate identities cannot become empty data',
    () async {
      final file = File('${directory.path}/configurations.json');
      for (final data in [
        {
          'entries': [entry.toJson()],
        },
        {
          'mode': 'invalid',
          'entries': [entry.toJson()],
        },
        {
          'mode': 'rule',
          'entries': [entry.toJson(), entry.toJson()],
        },
      ]) {
        final original = jsonEncode(data);
        await file.writeAsString(original);
        await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
        expect(await file.readAsString(), original);
      }
    },
  );

  test('different identities retain the same complete remote source', () async {
    final other = ConfigEntry.fromJson({...entry.toJson(), 'id': 'two'});
    await store.save(
      ConfigCollection(entries: [entry, other], selectedId: other.id),
    );
    final restored = await store.read();
    expect(restored.entries.map((value) => value.id), [entry.id, other.id]);
    expect(restored.entries.map((value) => value.source), [
      entry.source,
      entry.source,
    ]);
    expect(restored.selectedId, other.id);
  });

  test(
    'local names and null sources may repeat, preserving order and time',
    () async {
      final time = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final locals = [
        for (final id in ['a', 'b'])
          ConfigEntry(
            id: id,
            name: 'Local',
            kind: ConfigKind.local,
            revision: 1,
            body: '',
            updatedAt: time,
          ),
      ];
      await store.save(
        ConfigCollection(entries: [entry, ...locals], selectedId: 'b'),
      );
      final restored = await store.read();
      expect(restored.entries.map((e) => e.id), ['one', 'a', 'b']);
      expect(restored.selected!.updatedAt, time);
      expect(restored.selected!.body, '');
      expect(restored.selected!.displaySource, localizedMessages.localConfig);
    },
  );

  test(
    'missing and null bodies are corruption for local and remote entries',
    () async {
      final file = File('${directory.path}/configurations.json');
      for (final kind in ConfigKind.values) {
        for (final missing in [false, true]) {
          final record = <String, Object?>{
            ...entry.toJson(),
            'kind': kind.name,
            'source': kind == ConfigKind.local ? null : entry.source,
            'body': null,
          };
          if (missing) record.remove('body');
          final original = jsonEncode({
            'mode': 'rule',
            'entries': [record],
            'selectedId': entry.id,
          });
          await file.writeAsString(original);
          await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
          expect(await file.readAsString(), original);
        }
      }
    },
  );

  test(
    'rebuilt collections retain the disk JSON envelope and entry fields',
    () async {
      final file = File('${directory.path}/configurations.json');
      final record = <String, Object?>{
        ...entry.toJson(),
        'update': null,
        'futureEntry': {'false': false, 'zero': 0, 'null': null, 'empty': []},
      };
      final original = <String, Object?>{
        'mode': null,
        'entries': [record],
        'futureEnvelope': {
          'false': false,
          'zero': 0,
          'null': null,
          'empty': {},
        },
      };
      await file.writeAsString(jsonEncode(original));
      final read = await store.read();
      // Reproduce callers constructing a new collection and a fresh Store.
      await ConfigStore(directory).save(
        ConfigCollection(entries: [read.entries.single.renamed('Renamed')]),
      );
      expect(jsonDecode(await file.readAsString()), {
        ...original,
        'entries': [
          {...record, 'name': 'Renamed'},
        ],
      });
      expect(read.entries.single.body, entry.body);
      expect(
        read.replace(read.entries.single).originalJson['futureEnvelope'],
        original['futureEnvelope'],
      );
    },
  );

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
          'mode': 'rule',
          'entries': [entry.toJson()],
          'selectedId': 'missing',
        }),
      );
      await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
    },
  );
}
