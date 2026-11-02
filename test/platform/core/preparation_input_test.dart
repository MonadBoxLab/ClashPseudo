import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/platform/core/core_input.dart';
import 'package:flutter_test/flutter_test.dart';

const _entry = ConfigEntry(
  id: 'main',
  name: 'Controlled source',
  kind: ConfigKind.local,
  revision: 7,
  body: 'rules: [MATCH,DIRECT]',
);

void main() {
  late Directory directory;
  late File file;
  late CoreInput input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('preparation-input-');
    file = File('${directory.path}/owned.input');
    input = CoreInput(file);
  });
  tearDown(() => directory.delete(recursive: true));

  test('complete composition remains JSON beyond 64 KiB, including escaped source metadata', () async {
    final parts = List.generate(
      4096,
      (index) => OverrideEntry(
        id: 'plugin-$index-${'identity' * 8}',
        name: 'Plugin $index',
        kind: ConfigKind.local,
        revision: index + 1,
        enabled: true,
        body: '{}',
      ),
    );
    final name =
        'quoted " ${String.fromCharCode(92)} ${String.fromCharCode(0)}\n配置 🌐';
    await input.write(_entry.renamed(name), null, overrides: parts);
    final value = jsonDecode(await file.readAsString()) as Map;
    final composition = value['composition'] as String;
    expect(utf8.encode(composition).length, greaterThan(64 * 1024));
    final identity = jsonDecode(composition) as List;
    expect(identity, hasLength(4098));
    expect(
      identity.sublist(2).map((part) => (part as List).first),
      parts.map((part) => part.id),
    );
    expect(value['name'], name);
    expect(value['body'], _entry.body);
    expect(value['overrides'], hasLength(4096));
  });

  test(
    'static preparation JSON overflow fails before replacing any input file',
    () async {
      await file.writeAsString('owned previous bytes');
      final escapedId =
          String.fromCharCode(0) * (maxPreparationOptionsBytes ~/ 7 + 1);
      final part = OverrideEntry(
        id: escapedId,
        name: 'Controlled',
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
        enabled: true,
      );
      await expectLater(
        input.write(_entry, null, overrides: [part]),
        throwsA(
          isA<ConfigFailure>().having(
            (failure) => failure.message.id,
            'message',
            'preparationOptionsTooLarge',
          ),
        ),
      );
      expect(await file.readAsString(), 'owned previous bytes');
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );

  test('encoded fragment JSON has its own 128 MiB budget, not the 16 MiB options quota', () async {
    final name = 'x' * (2 * 1024 * 1024);
    final parts = List.generate(
      65,
      (index) => OverrideEntry(
        id: 'plugin-$index',
        name: name,
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
        enabled: true,
      ),
    );
    await expectLater(
      input.write(_entry, null, overrides: parts),
      throwsA(
        isA<ConfigFailure>().having(
          (failure) => failure.message.id,
          'message',
          'preparationFragmentsTooLarge',
        ),
      ),
    );
    expect(await file.exists(), isFalse);
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test('sixteen mebibyte body is not charged for JSON escaping against the options budget', () async {
    final body = String.fromCharCode(92) * (16 * 1024 * 1024);
    await input.write(_entry.withContent(body), null);
    expect(await file.length(), greaterThan(32 * 1024 * 1024));
    final value = jsonDecode(await file.readAsString()) as Map;
    expect(value['body'], body);
    expect(value['composition'], '["main",8]');
  });

  for (final field in ['main id', 'main name', 'part id', 'part name']) {
    test(
      'unpaired UTF-16 metadata cannot be silently replaced across the wire: $field',
      () async {
        final invalid = String.fromCharCode(0xd800);
        final entry = ConfigEntry(
          id: field == 'main id' ? invalid : _entry.id,
          name: field == 'main name' ? invalid : _entry.name,
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        );
        final part = OverrideEntry(
          id: field == 'part id' ? invalid : 'plugin',
          name: field == 'part name' ? invalid : 'Controlled',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
          enabled: true,
        );
        await expectLater(
          input.write(entry, null, overrides: [part]),
          throwsA(
            isA<ConfigFailure>().having(
              (failure) => failure.message.id,
              'message',
              'preparationMetadataInvalid',
            ),
          ),
        );
        expect(await file.exists(), isFalse);
      },
    );
  }

  test(
    'disabled fragments do not consume an active input wire budget',
    () async {
      final invalid = String.fromCharCode(0xd800);
      await input.write(
        _entry,
        null,
        overrides: [
          OverrideEntry(
            id: invalid,
            name: invalid,
            kind: ConfigKind.local,
            revision: 1,
            body: '{}',
            enabled: false,
          ),
        ],
      );
      final value = jsonDecode(await file.readAsString()) as Map;
      expect(value['overrides'], isEmpty);
      expect(value['composition'], '["main",7]');
    },
  );
}
