import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

const _unknown = <String, Object?>{
  'false': false,
  'zero': 0,
  'null': null,
  'list': <Object?>[],
  'map': <String, Object?>{},
};

void main() {
  const config = ConfigEntry(
    id: 'config',
    name: 'Original',
    kind: ConfigKind.local,
    revision: 1,
    body: '﻿# exact\r\nrules: []\n',
  );
  const override = OverrideEntry(
    id: 'override',
    name: 'Original',
    kind: ConfigKind.local,
    revision: 1,
    body: '﻿# exact\r\nrules: []\n',
  );

  test(
    'configuration keeps unknown and explicit values through every copy',
    () {
      final original = <String, dynamic>{
        ...config.toJson(),
        'future': _unknown,
        'updatedAt': 0,
        'update': null,
        'choices': {
          'automatic': {'type': 'url-test', 'member': null, 'future': _unknown},
        },
        'error': {
          'id': 'downloadFailed',
          'args': <String, Object?>{},
          'future': _unknown,
        },
      };
      final entry = ConfigEntry.fromJson(original);
      expect(entry.toJson(), original);
      expect(entry.renamed('Renamed').toJson(), {
        ...original,
        'name': 'Renamed',
      });
      expect(entry.withSource('https://fixture.invalid/config').toJson(), {
        ...original,
        'source': 'https://fixture.invalid/config',
      });
      final chosen = entry.withChoice(
        'automatic',
        const StrategyChoice(type: StrategyType.urlTest, member: 'New member'),
      );
      expect(chosen.toJson(), {
        ...original,
        'choices': {
          'automatic': {
            'type': 'url-test',
            'member': 'New member',
            'future': _unknown,
          },
        },
      });
      final content = entry.withContent('rules: [MATCH,DIRECT]\r\n');
      expect(content.toJson(), {
        ...original,
        'body': content.body,
        'revision': 2,
        'updatedAt': content.updatedAt!.millisecondsSinceEpoch,
        'error': null,
      });
      expect(ConfigEntry.fromJson(chosen.toJson()).toJson(), chosen.toJson());
    },
  );

  test(
    'absent optional configuration fields are not materialized by rename',
    () {
      final original = <String, dynamic>{...config.toJson(), 'future': _unknown}
        ..remove('source')
        ..remove('updatedAt')
        ..remove('update')
        ..remove('error');
      final entry = ConfigEntry.fromJson(original);
      expect(entry.toJson(), original);
      expect(entry.renamed('Renamed').toJson(), {
        ...original,
        'name': 'Renamed',
      });
    },
  );

  test('update policy edits retain unknown and absent result metadata', () {
    final original = <String, dynamic>{
      'enabled': false,
      'hours': 24,
      'lastAttempt': 0,
      'future': _unknown,
    };
    final policy = UpdatePolicy.fromJson(original);
    expect(policy.toJson(), original);
    expect(policy.changed().toJson(), original);
    expect(policy.changed(enabled: true, hours: 6).toJson(), {
      ...original,
      'enabled': true,
      'hours': 6,
    });
    final entry = ConfigEntry.fromJson({
      ...config.toJson(),
      'update': original,
    });
    expect(
      (entry.withUpdate(const UpdatePolicy(enabled: true)).toJson()['update']
          as Map)['future'],
      _unknown,
    );
  });

  test(
    'strategy choice standalone round trip keeps null and future fields',
    () {
      final original = <String, dynamic>{
        'type': 'fallback',
        'member': null,
        'future': _unknown,
      };
      expect(StrategyChoice.fromJson(original).toJson(), original);
    },
  );

  test(
    'override edits only supplied metadata and preserves untouched error',
    () {
      final original = <String, dynamic>{
        ...override.toJson(),
        'future': _unknown,
        'updatedAt': 0,
        'enabled': false,
        'addNoResolve': false,
        'proxyName': '',
        'update': null,
        'error': {
          'id': 'downloadFailed',
          'args': <String, Object?>{},
          'future': _unknown,
        },
      };
      final entry = OverrideEntry.fromJson(original);
      expect(entry.toJson(), original);
      expect(entry.changed().toJson(), original);
      expect(entry.changed(name: 'Renamed', enabled: false).toJson(), {
        ...original,
        'name': 'Renamed',
      });
      expect(entry.changed(error: null).toJson(), {...original, 'error': null});
      final updated = entry.withContent('');
      expect(updated.toJson(), {
        ...original,
        'body': '',
        'revision': 2,
        'updatedAt': updated.updatedAt!.millisecondsSinceEpoch,
        'error': null,
      });
    },
  );

  test('override optional fields stay absent until explicitly edited', () {
    final original = <String, dynamic>{...override.toJson(), 'future': _unknown}
      ..remove('source')
      ..remove('role')
      ..remove('proxyName')
      ..remove('addNoResolve')
      ..remove('updatedAt')
      ..remove('update')
      ..remove('error');
    final entry = OverrideEntry.fromJson(original);
    expect(entry.changed(name: 'Renamed').toJson(), {
      ...original,
      'name': 'Renamed',
    });
    expect(entry.changed(proxyName: '', addNoResolve: false).toJson(), {
      ...original,
      'proxyName': '',
      'addNoResolve': false,
    });
    final withPolicy = OverrideEntry.fromJson({
      ...original,
      'update': {'enabled': false, 'hours': 24, 'future': _unknown},
    }).withUpdate(const UpdatePolicy(enabled: true));
    expect((withPolicy.toJson()['update'] as Map)['future'], _unknown);
  });

  for (final representation in ['absent', 'null', 'false']) {
    test(
      'preferences preserve $representation reconnect and unknown fields',
      () {
        final original = <String, dynamic>{
          ...const AppPreferences().toJson(),
          'future': _unknown,
        };
        if (representation == 'absent') {
          original.remove('reconnectOnRoutingChange');
        } else {
          original['reconnectOnRoutingChange'] = representation == 'false'
              ? false
              : null;
        }
        final preferences = AppPreferences.fromJson(original);
        expect(preferences.toJson(), original);
        expect(preferences.reconnectOnRoutingChange, isFalse);
        expect(preferences.withAppearance('brand', 'jade').toJson(), {
          ...original,
          'brand': 'jade',
        });
        expect(preferences.withAccess(ApplicationAccess.except, []).toJson(), {
          ...original,
          'access': 'except',
          'packages': <String>[],
        });
        expect(preferences.withRoutingReconnect(false).toJson(), {
          ...original,
          'reconnectOnRoutingChange': false,
        });
      },
    );
  }
}
