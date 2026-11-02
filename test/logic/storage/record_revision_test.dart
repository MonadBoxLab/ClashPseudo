import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const lastRevision = 0x7fffffff;
  const config = ConfigEntry(
    id: 'config',
    name: 'Local',
    kind: ConfigKind.local,
    revision: lastRevision,
    body: 'rules: []',
  );
  const override = OverrideEntry(
    id: 'override',
    name: 'Plugin',
    kind: ConfigKind.local,
    revision: lastRevision,
    body: '{}',
  );

  test(
    'revision exhaustion cannot publish either store or alter old bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'record-revision-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final configs = ConfigStore(directory);
      final overrides = OverrideStore(directory);
      await configs.save(
        ConfigCollection(entries: [config], selectedId: config.id),
      );
      await overrides.save([override]);
      final configFile = File('${directory.path}/configurations.json');
      final overrideFile = File('${directory.path}/overrides.json');
      final beforeConfig = await configFile.readAsBytes();
      final beforeOverride = await overrideFile.readAsBytes();
      var publications = 0;
      final guardedConfigs = ConfigStore(
        directory,
        publish: (_) async {
          publications++;
        },
      );
      final guardedOverrides = OverrideStore(
        directory,
        publish: (_) async {
          publications++;
        },
      );
      await expectLater(
        guardedConfigs.save(
          ConfigCollection(
            entries: [config.withContent('rules: [MATCH,DIRECT]')],
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        guardedOverrides.save([override.withContent('rules: []')]),
        throwsFormatException,
      );
      expect(publications, 0);
      expect(await configFile.readAsBytes(), beforeConfig);
      expect(await overrideFile.readAsBytes(), beforeOverride);
      expect(await File('${configFile.path}.tmp').exists(), isFalse);
      expect(await File('${overrideFile.path}.tmp').exists(), isFalse);
    },
  );
}
