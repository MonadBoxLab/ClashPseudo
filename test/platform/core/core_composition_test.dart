import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/platform/core/core_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const main = ConfigEntry(
    id: 'main',
    name: 'Main',
    kind: ConfigKind.local,
    revision: 3,
    body: '﻿rules:\r\n - MATCH,DIRECT\r\n',
  );
  const first = OverrideEntry(
    id: 'first',
    name: 'First',
    kind: ConfigKind.local,
    revision: 1,
    body: 'dns: {}',
    enabled: true,
  );
  const second = OverrideEntry(
    id: 'second',
    name: 'Second',
    kind: ConfigKind.local,
    revision: 2,
    body: '{}',
    enabled: true,
    mode: OverrideMode.replace,
  );
  late Directory directory;
  late File file;
  late CoreInput input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('core-composition-');
    file = File('${directory.path}/input.json');
    input = CoreInput(file);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<Map<String, dynamic>> write(List<OverrideEntry> parts) async {
    await input.write(main, TunnelMode.rule, overrides: parts);
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  test('canonical composition preserves enabled order and stored modes', () {
    const disabled = OverrideEntry(
      id: 'disabled',
      name: 'Disabled',
      kind: ConfigKind.local,
      revision: 7,
      body: '{}',
      enabled: false,
    );
    expect(
      CoreInput.compositionOf(main.id, main.revision, [
        second,
        disabled,
        first,
      ]),
      '["main",3,["second",2,"replace"],["first",1,"prepend"]]',
    );
  });

  test(
    'input keeps original bodies and carries ordered enabled identities',
    () async {
      final value = await write([first, second]);
      expect(value['body'], main.body);
      expect(value['name'], main.name);
      final members = value['overrides'] as List;
      expect(members.map((part) => part['name']), [first.name, second.name]);
      expect(members.every((part) => part.containsKey('role')), isTrue);
      expect(members.map((part) => part['role']), [null, null]);
      expect(value['mode'], 'rule');
      expect(jsonDecode(value['composition'] as String), [
        'main',
        3,
        ['first', 1, 'prepend'],
        ['second', 2, 'replace'],
      ]);
      expect((value['overrides'] as List).map((part) => part['body']), [
        first.body,
        second.body,
      ]);
      await input.clear();
      expect(await file.exists(), isFalse);
    },
  );

  test('input snapshots names, roles and sources with bodies before the first I/O yield', () async {
    const remote = OverrideEntry(
      id: 'remote',
      name: 'Original remote',
      kind: ConfigKind.remote,
      source: 'https://fixture.test/original',
      revision: 4,
      body: 'rules: []',
      enabled: true,
    );
    const custom = OverrideEntry(
      id: 'custom',
      name: 'Original custom',
      kind: ConfigKind.local,
      role: OverrideRole.localCustom,
      revision: 5,
      body: 'dns: {}',
      enabled: true,
      mode: OverrideMode.replace,
    );
    final entries = [remote, custom];
    final pending = input.write(main, null, overrides: entries);
    entries
      ..clear()
      ..add(second.changed(name: 'Late name'));
    await pending;
    final value = jsonDecode(await file.readAsString()) as Map;
    expect(value['name'], main.name);
    final members = value['overrides'] as List;
    expect(members.map((part) => part['name']), [remote.name, custom.name]);
    expect(members.map((part) => part['role']), [null, 'localCustom']);
    expect(members.map((part) => part['source']), [remote.source, null]);
    expect(members.map((part) => part['body']), [remote.body, custom.body]);
    expect(jsonDecode(value['composition'] as String), [
      main.id,
      main.revision,
      [remote.id, remote.revision, 'prepend'],
      [custom.id, custom.revision, 'replace'],
    ]);
  });

  test(
    'a new explicit input publishes new names without changing body identity',
    () async {
      final before = await write([first, second]);
      await input.write(
        main.renamed('Renamed main'),
        TunnelMode.rule,
        overrides: [
          first.changed(name: 'Renamed first'),
          second,
        ],
      );
      final after = jsonDecode(await file.readAsString()) as Map;
      expect(after['name'], 'Renamed main');
      expect((after['overrides'] as List).first['name'], 'Renamed first');
      expect(after['composition'], before['composition']);
      expect(after['revision'], before['revision']);
      expect(after['body'], before['body']);
      expect((after['overrides'] as List).first['body'], first.body);
    },
  );

  test('missing loaded names reject before replacing prepared input', () async {
    await write([first]);
    final before = await file.readAsBytes();
    await expectLater(
      input.write(main.renamed(' '), null, overrides: [first]),
      throwsFormatException,
    );
    await expectLater(write([first.changed(name: '')]), throwsFormatException);
    expect(await file.readAsBytes(), before);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('nullable fallback and one-operation override remain separate from original YAML', () async {
    for (final fallback in <TunnelMode?>[null, TunnelMode.global]) {
      await input.write(main, fallback, overrides: [first, second]);
      final ordinary = jsonDecode(await file.readAsString()) as Map;
      expect(ordinary.containsKey('mode'), isTrue);
      expect(ordinary['mode'], fallback?.name);
      expect(ordinary['routingOverride'], isNull);
      expect(ordinary['body'], main.body);
      await input.write(
        main,
        fallback,
        routingOverride: TunnelMode.direct,
        overrides: [first, second],
      );
      final explicit = jsonDecode(await file.readAsString()) as Map;
      expect(explicit['mode'], fallback?.name);
      expect(explicit['routingOverride'], 'direct');
      expect(explicit['body'], ordinary['body']);
      expect(explicit['overrides'], ordinary['overrides']);
      expect(explicit['composition'], ordinary['composition']);
    }
  });

  test('identity reflects only effective ordered input, not labels or disabled edits', () async {
    final initial = (await write([first, second]))['composition'];
    expect(
      (await write([first.changed(name: 'Renamed'), second]))['composition'],
      initial,
    );
    for (final parts in [
      [second, first],
      [first.changed(enabled: false), second],
      [first.changed(mode: OverrideMode.replace), second],
      [first.withContent('dns: {enable: true}'), second],
    ]) {
      expect((await write(parts))['composition'], isNot(initial));
    }
    final disabled = first.changed(enabled: false);
    final before = (await write([disabled, second]))['composition'];
    expect(
      (await write([disabled.withContent('new'), second]))['composition'],
      before,
    );
  });

  test(
    'empty enabled fragment remains in composition and original input',
    () async {
      await write([first]);
      final original = await file.readAsBytes();
      const empty = OverrideEntry(
        id: 'empty',
        name: 'Empty',
        kind: ConfigKind.remote,
        source: 'https://example.test/part',
        revision: 1,
        body: '',
        enabled: true,
      );
      final value = await write([empty]);
      expect((value['overrides'] as List).single['body'], '');
      expect(jsonDecode(value['composition'] as String), [
        'main',
        3,
        ['empty', 1, 'prepend'],
      ]);
      expect(await file.readAsBytes(), isNot(original));
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );
}
