import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'configuration and plugin files retain error descriptions on read and copy',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pseudo-message-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final configs = ConfigStore(directory);
      final overrides = OverrideStore(directory);
      final error = messages.downloadHttpStatus('404');
      await configs.save(
        ConfigCollection(
          entries: [
            ConfigEntry(
              id: 'main',
              name: 'Main',
              source: 'https://fixture.test/main',
              revision: 1,
              body: 'rules: []',
              error: error,
            ),
          ],
          selectedId: 'main',
        ),
      );
      await overrides.save([
        OverrideEntry(
          id: 'part',
          name: 'Part',
          kind: ConfigKind.remote,
          source: 'https://fixture.test/part',
          revision: 1,
          body: '{}',
          error: error,
        ),
      ]);
      final config = (await configs.read()).selected!;
      final plugin = (await overrides.read()).single;
      final originalJson = jsonEncode([config.toJson(), plugin.toJson()]);
      expect(config.toJson()['error'], error.toMap());
      expect(plugin.toJson()['error'], error.toMap());
      expect(config.errorMessage, error);
      expect(plugin.errorMessage, error);
      expect(config.renamed('Renamed').errorMessage, error);
      expect(
        plugin.withUpdate(const UpdatePolicy(hours: 12)).errorMessage,
        error,
      );
      expect(jsonEncode([config.toJson(), plugin.toJson()]), originalJson);
    },
  );
}
