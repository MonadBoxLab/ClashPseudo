import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/legal/app_legal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(
    () => WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy,
  );

  test('application and native licenses are fully registered', () async {
    LicenseRegistry.reset();
    registerAppLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    expect(entries.map((entry) => entry.packages.single), [
      'Clash Pseudo (GPL-3.0-only)',
      'mihomo',
      'Go',
      'Android',
      'Material Icons',
      're_editor',
      'Mozilla CA data',
      'Public Suffix List',
      'GeoIP.dat / GeoSite.dat / Country.mmdb / ASN.mmdb',
    ]);
    expect(
      entries.first.paragraphs.map((p) => p.text).join('\n'),
      contains('Version 3, 29 June 2007'),
    );
    expect(
      entries[2].paragraphs.map((p) => p.text).join('\n'),
      contains('github.com/rasky/go-lzo'),
    );
    expect(
      entries[3].paragraphs.map((p) => p.text),
      LicenseEntryWithLineBreaks(
        ['Android'],
        File('third_party/notices/android.txt').readAsStringSync(),
      ).paragraphs.map((p) => p.text),
    );
    expect(
      entries[4].paragraphs.map((p) => p.text).join('\n'),
      contains('Copyright 2019 Google LLC.'),
    );
    final editorLicense = entries[5].paragraphs.map((p) => p.text).join('\n');
    expect(editorLicense, contains('Copyright (c) 2024 Reqable'));
    expect(editorLicense, isNot(contains('CodeEditorObservation')));
    expect(
      entries[4].paragraphs.map((p) => p.text).join('\n'),
      contains('Attribution 4.0 International'),
    );
  });

  test('each declared license asset matches its source bytes', () async {
    const assets = [
      'LICENSE',
      'third_party/notices/mihomo.txt',
      'third_party/notices/go.txt',
      'third_party/notices/android.txt',
      'third_party/notices/material-icons.txt',
      'third_party/sources/re_editor/LICENSE',
      'build/generated/bundled/legal/certificates/NOTICE.txt',
      'build/generated/bundled/legal/certificates/MPL-2.0.txt',
      'third_party/notices/publicsuffix.txt',
      'build/generated/bundled/legal/geodata/NOTICE.txt',
      'build/generated/bundled/legal/geodata/CC-BY-SA-4.0.txt',
      'build/generated/bundled/legal/geodata/GeoSite-MIT.txt',
      'build/generated/bundled/legal/geodata/CC-BY-4.0.txt',
    ];
    final declaration =
        loadYaml(File('pubspec.yaml').readAsStringSync())['flutter']['assets']
            as List;
    expect(
      declaration,
      isNot(contains('third_party/sources/re_editor/PATCHES.md')),
    );
    for (final asset in assets) {
      expect(declaration, contains(asset));
      final data = await rootBundle.load(asset);
      expect(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        File(asset).readAsBytesSync(),
        reason: asset,
      );
    }
  });

  test('YAML package uses the locked hosted version and original license; only the editor uses a path source', () {
    final lock =
        loadYaml(File('pubspec.lock').readAsStringSync())['packages'] as Map;
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config = jsonDecode(configFile.readAsStringSync()) as Map;
    for (final item in [
      (name: 'yaml', copyright: 'Copyright (c) 2006, Kirill Simonov.'),
      (
        name: 'yaml_edit',
        copyright: 'Copyright 2020, the Dart project authors.',
      ),
    ]) {
      expect(lock[item.name]['source'], 'hosted');
      final version = lock[item.name]['version'] as String;
      final package = (config['packages'] as List).singleWhere(
        (entry) => entry['name'] == item.name,
      ) as Map;
      final root = Directory.fromUri(
        configFile.uri.resolve(package['rootUri'] as String),
      ).uri;
      expect(
        loadYaml(
          File.fromUri(root.resolve('pubspec.yaml')).readAsStringSync(),
        )['version'],
        version,
      );
      expect(
        File.fromUri(root.resolve('LICENSE')).readAsStringSync(),
        contains(item.copyright),
      );
    }
    expect(
      lock.entries
          .where((entry) => (entry.value as Map)['source'] == 'path')
          .map((entry) => entry.key),
      ['re_editor'],
    );
    expect(
      lock['re_editor']['description']['path'],
      'third_party/sources/re_editor',
    );
    expect(
      File('third_party/sources/re_editor/LICENSE').readAsStringSync(),
      contains('Copyright (c) 2024 Reqable'),
    );
    expect(
      File('third_party/sources/re_editor/PATCHES.md').readAsStringSync(),
      contains(
        '66671c4774a6b4c5254c9a53ab35a083e7e7da9ae371c519bcf491c70a2a4e56',
      ),
    );
  });

  test('Geo notices retain data copyright and license', () {
    final geo = File('build/generated/bundled/legal/geodata/NOTICE.txt')
        .readAsStringSync();
    for (final attribution in [
      'DB-IP',
      '2018-2019 V2Ray',
      'CC-BY-SA-4.0',
      'CC-BY-4.0',
    ]) {
      expect(geo, contains(attribution));
    }
  });

  testWidgets('SDK page displays actual data and editor licenses', (
    tester,
  ) async {
    LicenseRegistry.reset();
    registerAppLicenses();
    // Large notice decoding uses actual I/O and isolates; load outside the fake clock
    // before displaying registered content.
    late List<LicenseEntry> actualEntries;
    await tester.runAsync(() async {
      actualEntries = await LicenseRegistry.licenses.toList();
    });
    LicenseRegistry.reset();
    LicenseRegistry.addLicense(
      () => Stream<LicenseEntry>.fromIterable(actualEntries),
    );
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const LicensePage(applicationName: 'Clash Pseudo'),
      ),
    );
    await tester.pumpAndSettle();
    final resources = jsonDecode(
      File('third_party/data/resources.json').readAsStringSync(),
    ) as Map;
    final ca = resources['resources']['ca'] as Map;
    for (final entry in {
      're_editor': 'Copyright (c) 2024 Reqable',
      'Mozilla CA data': Uri.parse(ca['sourceUrl'] as String).pathSegments.last,
      'Public Suffix List': 'public_suffix_list.dat',
      'GeoIP.dat / GeoSite.dat / Country.mmdb / ASN.mmdb':
          'IP Geolocation by DB-IP',
    }.entries) {
      final row = find.text(entry.key);
      if (row.evaluate().isEmpty) {
        await tester.drag(find.byType(Scrollable).last, const Offset(0, 2000));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          row,
          300,
          scrollable: find.byType(Scrollable).last,
        );
      }
      await Scrollable.ensureVisible(tester.element(row), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      final paragraph = find.textContaining(entry.value);
      await tester.scrollUntilVisible(
        paragraph,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(paragraph, findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });
}
