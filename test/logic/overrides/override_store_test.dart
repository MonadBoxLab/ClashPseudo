import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/config_text.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';

void main() {
  late Directory directory;
  late OverrideStore store;
  const local = OverrideEntry(
    id: 'local',
    name: '本地片段',
    kind: ConfigKind.local,
    revision: 1,
    body: '﻿dns:\r\n  enable: true\n',
    enabled: true,
  );
  const remote = OverrideEntry(
    id: 'remote',
    name: '远程片段',
    kind: ConfigKind.remote,
    source: 'https://example.test/part',
    revision: 2,
    body: '{}',
    mode: OverrideMode.replace,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('override-store-');
    store = OverrideStore(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test('missing store is empty without writing defaults', () async {
    expect(await store.read(), isEmpty);
    expect(await directory.list().toList(), isEmpty);
  });

  test(
    'round trip preserves order, original text and disabled entries',
    () async {
      await store.save([remote, local]);
      final entries = await store.read();
      expect(entries.map((entry) => entry.toJson()), [
        remote.toJson(),
        local.toJson(),
      ]);
      expect(() => entries.clear(), throwsUnsupportedError);
      expect(enabledOverrides(entries), [
        {'id': 'local', 'revision': 1, 'mode': 'prepend', 'body': local.body},
      ]);
    },
  );

  test(
    'local invalid YAML may be saved and empty mapping is not rewritten',
    () async {
      await store.save([local.withContent('dns: ['), remote]);
      final entries = await store.read();
      expect(entries.first.body, 'dns: [');
      expect(entries.last.body, '{}');
    },
  );

  test('metadata and failed download preserve body and revision', () {
    final failed = remote.changed(error: messages.downloadFailed);
    expect(failed.body, remote.body);
    expect(failed.revision, remote.revision);
    final changed = failed.changed(name: 'renamed', enabled: true);
    expect(changed.body, remote.body);
    expect(changed.revision, remote.revision);
    final content = failed.withContent('dns: {}');
    expect(content.revision, remote.revision + 1);
    expect(content.error, isNull);
    expect(content.withContent(content.body).revision, content.revision);
  });

  test('duplicates and malformed fields do not replace saved data', () async {
    await store.save([local]);
    for (final entries in [
      [local, local],
      [
        local,
        OverrideEntry.fromJson({
          ...local.toJson(),
          'id': 'other',
          'role': 'localCustom',
        }),
        OverrideEntry.fromJson({
          ...local.toJson(),
          'id': 'third',
          'role': 'localCustom',
        }),
      ],
    ]) {
      await expectLater(store.save(entries), throwsFormatException);
    }
    for (final values in [
      {...local.toJson(), 'id': ''},
      {...local.toJson(), 'body': null},
      {...local.toJson(), 'source': remote.source},
      {...local.toJson(), 'revision': 0},
      {...remote.toJson(), 'source': 'file:///private'},
    ]) {
      expect(() => OverrideEntry.fromJson(values), throwsFormatException);
    }
    expect((await store.read()).single.toJson(), local.toJson());
  });

  test('same remote source is retained for distinct identities', () async {
    final other = OverrideEntry.fromJson({...remote.toJson(), 'id': 'other'});
    await store.save([remote, other]);
    expect((await store.read()).map((entry) => entry.id), [
      remote.id,
      other.id,
    ]);
    expect((await store.read()).map((entry) => entry.source), [
      remote.source,
      remote.source,
    ]);
  });

  test(
    'rebuilt lists retain envelope fields and untouched entry JSON',
    () async {
      final file = File('${directory.path}/overrides.json');
      final record = <String, Object?>{
        ...local.toJson(),
        'update': null,
        'futureEntry': {'false': false, 'zero': 0, 'null': null, 'empty': []},
      };
      final original = <String, Object?>{
        'entries': [record],
        'futureEnvelope': {
          'false': false,
          'zero': 0,
          'null': null,
          'empty': {},
        },
      };
      await file.writeAsString(jsonEncode(original));
      final entries = await store.read();
      await OverrideStore(directory)
          .save([entries.single.changed(name: 'Renamed')]);
      expect(jsonDecode(await file.readAsString()), {
        ...original,
        'entries': [
          {...record, 'name': 'Renamed'},
        ],
      });
      expect((await store.read()).single.body, local.body);
    },
  );

  test('corrupt store is not silently replaced', () async {
    final file = File('${directory.path}/overrides.json');
    await file.writeAsString('{broken');
    await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
    expect(await file.readAsString(), '{broken');
  });

  test('owner expiry before rename preserves committed data', () async {
    await store.save([local]);
    var checks = 0;
    final guarded = OverrideStore(
      directory,
      beforeWrite: () async {
        if (++checks == 2) throw StateError('owner expired');
      },
    );
    await expectLater(guarded.save([remote]), throwsStateError);
    expect(checks, 2);
    expect((await store.read()).single.id, local.id);
    expect(
      await File('${directory.path}/overrides.json.tmp').exists(),
      isFalse,
    );
  });

  test('save captures entries before awaiting owner check', () async {
    final entries = [local];
    final guarded = OverrideStore(
      directory,
      beforeWrite: () async {
        entries.clear();
      },
    );
    await guarded.save(entries);
    expect((await store.read()).single.toJson(), local.toJson());
  });

  test('missing and null bodies reject even disabled remote records', () async {
    final file = File('${directory.path}/overrides.json');
    for (final entry in [local, remote]) {
      for (final missing in [false, true]) {
        final record = <String, Object?>{...entry.toJson(), 'body': null};
        if (missing) record.remove('body');
        final original = jsonEncode({
          'entries': [record],
        });
        await file.writeAsString(original);
        await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
        expect(await file.readAsString(), original);
      }
    }
  });

  test('empty enabled body is valid and retained', () async {
    await store.save([local.withContent('')]);
    expect(enabledOverrides(await store.read()).single['body'], '');
  });

  test('UTF-8 total budget applies only to enabled fragments', () {
    final full = local.withContent('a' * maxConfigBytes);
    expect(enabledOverrides([full]).single['body'], full.body);
    expect(enabledOverrides([full, remote]), hasLength(1));
    expect(
      () => enabledOverrides([full, remote.changed(enabled: true)]),
      throwsA(isA<ConfigFailure>()),
    );
    expect(
      () =>
          OverrideEntry.fromJson({...local.toJson(), 'body': '${full.body}中'}),
      throwsA(isA<ConfigFailure>()),
    );
  });
}
