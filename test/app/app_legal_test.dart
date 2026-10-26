import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/app/app_legal.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(
    () => WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy,
  );

  test(
    'packaged application and native license texts are registered',
    () async {
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
        'Mozilla CA data (curl 2026-09-25)',
        'Public Suffix List (63cbc63d470d)',
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
        entries[3].paragraphs.map((p) => p.text).join('\n'),
        contains('com.google.guava:listenablefuture:1.0'),
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
    },
  );

  test(
    'every explicit legal asset is packaged byte-for-byte from its source',
    () async {
      const assets = [
        'LICENSE',
        'third_party/notices/mihomo.txt',
        'third_party/notices/go.txt',
        'third_party/notices/android.txt',
        'third_party/notices/material-icons.txt',
        'third_party/sources/re_editor/LICENSE',
        'third_party/data/certificates/NOTICE.txt',
        'third_party/data/certificates/MPL-2.0.txt',
        'third_party/notices/publicsuffix.txt',
        'third_party/data/geodata/NOTICE.txt',
        'third_party/data/geodata/CC-BY-SA-4.0.txt',
        'third_party/data/geodata/GeoSite-MIT.txt',
        'third_party/data/geodata/CC-BY-4.0.txt',
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
    },
  );

  test('YAML packages remain hosted with exact licenses and only the approved editor is a path exception', () {
    final lock =
        loadYaml(File('pubspec.lock').readAsStringSync())['packages'] as Map;
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config = jsonDecode(configFile.readAsStringSync()) as Map;
    for (final item in [
      (
        name: 'yaml',
        version: '3.1.4',
        copyright: 'Copyright (c) 2006, Kirill Simonov.',
      ),
      (
        name: 'yaml_edit',
        version: '2.2.4',
        copyright: 'Copyright 2020, the Dart project authors.',
      ),
    ]) {
      expect(lock[item.name]['source'], 'hosted');
      expect(lock[item.name]['version'], item.version);
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
        item.version,
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

  test('actual linked additions and separate PSL data rights stay in source notices', () {
    final text = File('third_party/notices/go.txt').readAsStringSync();
    final entries = RegExp(
      r'^={20,}\n(\S+) (v\S+)\n',
      multiLine: true,
    ).allMatches(text).toList();
    expect(entries.length, 121);
    expect(entries.map((entry) => entry[1]).toSet().length, 121);
    for (final entry in const {
      'github.com/fxamacker/cbor/v2': 'v2.9.0',
      'github.com/golang/groupcache': 'v0.0.0-20241129210726-2c02b8208cf8',
      'github.com/google/pprof': 'v0.0.0-20240727154555-813a5fbdbec8',
      'github.com/metacubex/gvisor': 'v0.0.0-20260922041103-e2cbcd6e7400',
      'github.com/metacubex/jsonv2': 'v0.0.0-20260721082349-16b4998c8f89',
      'github.com/metacubex/tailscale': 'v0.0.0-20260821153257-ff0ecd818181',
      'github.com/metacubex/tailscale-wireguard-go':
          'v0.0.0-20260725073821-e61ab99cede2',
      'github.com/pires/go-proxyproto': 'v0.8.0',
      'github.com/tailscale/peercred': 'v0.0.0-20250107143737-35a0c7bd7edc',
      'github.com/x448/float16': 'v0.8.4',
      'go4.org/mem': 'v0.0.0-20240501181205-ae6ca9944745',
      'golang.org/x/term': 'v0.29.0',
    }.entries) {
      expect(
        entries.any(
          (match) => match[1] == entry.key && match[2] == entry.value,
        ),
        isTrue,
        reason: entry.key,
      );
    }
    expect(text, contains('tempfork/goupnp/LICENSE'));
    expect(text, contains('third_party/svgpan/LICENSE'));
    expect(text, contains('Additional IP Rights Grant (Patents)'));
    final psl = File('third_party/notices/publicsuffix.txt').readAsStringSync();
    expect(psl, contains('63cbc63d470d7b52c35266aa96c4c98c96ec499c'));
    expect(
      psl,
      contains(
        '4dd388d5006a37c0748f17e1088ecd05c821da88eff36963bcc36297d7dea96e',
      ),
    );
    expect(psl, contains('Mozilla Public'));
    expect(psl, contains('MPL-2.0'));
    final geo = File('third_party/data/geodata/NOTICE.txt').readAsStringSync();
    for (final attribution in [
      'DB-IP',
      '2018-2019 V2Ray',
      'CC-BY-SA-4.0',
      'CC-BY-4.0',
    ]) {
      expect(geo, contains(attribution));
    }
  });

  testWidgets(
    'actual data and editor licenses are readable through the SDK page',
    (tester) async {
      LicenseRegistry.reset();
      registerAppLicenses();
      // Decode actual production assets outside the fake clock (large notices
      // use real IO/isolate work), then render those exact registry entries.
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
      for (final entry in const {
        're_editor': 'Copyright (c) 2024 Reqable',
        'Mozilla CA data (curl 2026-09-25)': 'cacert-2026-09-25.pem',
        'Public Suffix List (63cbc63d470d)': 'public_suffix_list.dat',
        'GeoIP.dat / GeoSite.dat / Country.mmdb / ASN.mmdb':
            'IP Geolocation by DB-IP',
      }.entries) {
        final row = find.text(entry.key);
        if (row.evaluate().isEmpty) {
          await tester.drag(
            find.byType(Scrollable).last,
            const Offset(0, 2000),
          );
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
    },
  );

  for (final dark in [false, true]) {
    testWidgets('legal notice and SDK license page are reachable dark=$dark', (
      tester,
    ) async {
      LicenseRegistry.reset();
      LicenseRegistry.addLicense(() async* {
        yield const LicenseEntryWithLineBreaks([
          'Clash Pseudo',
        ], 'GPL-3.0-only');
      });
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: dark ? AppTheme.dark : AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAppLegal(context),
                child: const Text('关于与许可'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('关于与许可'));
      await tester.pumpAndSettle();
      expect(find.textContaining('GPL-3.0-only'), findsOneWidget);
      await tester.tap(find.text('许可与第三方通知'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
