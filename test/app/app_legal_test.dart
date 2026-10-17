import 'package:clash_pseudo/app/app_legal.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'packaged application and native license texts are registered',
    () async {
      LicenseRegistry.reset();
      registerAppLicenses();
      final entries = await LicenseRegistry.licenses.toList();
      expect(entries.map((entry) => entry.packages.single), [
        'Clash Pseudo (GPL-3.0-only)',
        'mihomo v1.19.32',
        'Go 原生运行依赖',
        'Android 运行依赖',
        'Material Icons 字体',
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
      expect(
        entries[4].paragraphs.map((p) => p.text).join('\n'),
        contains('Attribution 4.0 International'),
      );
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
