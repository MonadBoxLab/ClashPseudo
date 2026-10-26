import 'dart:io';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/logic/preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late PreferencesStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-preferences-');
    store = PreferencesStore(directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test('absent settings use defaults without writing', () async {
    final preferences = await store.read();
    expect(preferences.appearance, AppAppearance.system);
    expect(preferences.brand, BrandColor.cinnabar);
    expect(preferences.language, AppLanguage.system);
    expect(preferences.access, ApplicationAccess.all);
    expect(preferences.reconnectOnRoutingChange, isFalse);
    expect(await directory.list().isEmpty, isTrue);
  });

  test('appearance changes preserve other settings and round trip', () async {
    const original = AppPreferences(
      access: ApplicationAccess.only,
      packages: ['io.example.app'],
    );
    final updated = original
        .withAppearance('brand', 'jade')
        .withAppearance('language', 'en')
        .withAppearance('appearance', 'dark');
    await store.save(updated);
    expect((await store.read()).toJson(), updated.toJson());
    expect((await store.read()).packages, original.packages);
  });

  test('routing reconnect persists and survives unrelated changes', () async {
    final updated = const AppPreferences()
        .withRoutingReconnect(true)
        .withAppearance('brand', 'jade')
        .withAccess(ApplicationAccess.only, ['fixture.app']);
    await store.save(updated);
    expect((await store.read()).reconnectOnRoutingChange, isTrue);
    await store.save(updated.withRoutingReconnect(false));
    expect((await store.read()).reconnectOnRoutingChange, isFalse);
  });

  test('invalid routing reconnect value is not accepted as false', () async {
    final file = File('${directory.path}/preferences.json');
    await file.writeAsString(
      '{"appearance":"system","brand":"cinnabar",'
      '"language":"system","access":"all","packages":[], '
      '"reconnectOnRoutingChange":"true"}',
    );
    await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
    expect(await file.readAsString(), contains('"true"'));
  });

  test('damaged settings are not replaced by defaults', () async {
    final file = File('${directory.path}/preferences.json');
    await file.writeAsString('{broken');
    await expectLater(store.read(), throwsA(isA<ConfigFailure>()));
    expect(await file.readAsString(), '{broken');
  });

  test('expired write cannot publish after temporary I/O', () async {
    await store.save(const AppPreferences());
    var checks = 0;
    final guarded = PreferencesStore(
      directory,
      beforeWrite: () async {
        if (++checks == 2) throw StateError('expired');
      },
    );
    await expectLater(
      guarded.save(const AppPreferences(brand: BrandColor.cobalt)),
      throwsStateError,
    );
    expect((await store.read()).brand, BrandColor.cinnabar);
    expect(
      await File('${directory.path}/preferences.json.tmp').exists(),
      isFalse,
    );
  });

  test('invalid enums, duplicates and empty only list are rejected', () {
    for (final value in [
      {...const AppPreferences().toJson(), 'appearance': 'unknown'},
      {...const AppPreferences().toJson(), 'access': 'only'},
      {
        ...const AppPreferences().toJson(),
        'packages': ['a', 'a'],
      },
      {
        ...const AppPreferences().toJson(),
        'packages': [''],
      },
    ]) {
      expect(
        () => AppPreferences.fromJson(value),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
      );
    }
    expect(
      () => const AppPreferences().withAppearance('access', 'only'),
      throwsFormatException,
    );
  });
}
