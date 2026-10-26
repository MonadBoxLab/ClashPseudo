import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/diagnostics/dns_tool.dart';
import 'package:clash_pseudo/src/features/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../diagnostics/dns_fakes.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    DnsTestApp app, {
    String language = 'en',
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: SettingsPage(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'settings opens no core and retains DNS session input across visits',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      await show(tester, app);
      expect(app.commands, isEmpty);
      expect(bridge.queries, isEmpty);
      await reveal(tester, 'DNS tools');
      await tester.tap(find.text('DNS tools'));
      await tester.pumpAndSettle();
      expect(find.byType(DnsTool), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'session.example.test',
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await reveal(tester, 'DNS tools');
      await tester.tap(find.text('DNS tools'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'session.example.test',
      );
      expect(bridge.queries, isEmpty);
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'settings groups configuration, routing and tools without redundant system-add actions $language $scale',
        (tester) async {
          final bridge = DnsTestBridge();
          final app = DnsTestApp(bridge);
          addTearDown(app.dispose);
          final strings = lookupAppLocalizations(Locale(language));
          await show(tester, app, language: language, scale: scale);
          final expected = [
            strings.appearanceAndLanguage,
            strings.appearance,
            strings.brandColor,
            strings.language,
            strings.connectionBehavior,
            strings.modeTitle,
            strings.reconnectOnRoutingChange,
            strings.configurationsAndPlugins,
            strings.configurations,
            strings.overridePlugins,
            strings.runtimeConfiguration,
            strings.routingAndResources,
            strings.proxyNodes,
            strings.allStrategyGroups,
            strings.rules,
            strings.externalResources,
            strings.diagnosticTools,
            strings.recentConnections,
            strings.dnsTools,
            strings.coreLogs,
            strings.backupImport,
            strings.backupExport,
            strings.androidSection,
            strings.applicationAccess,
            strings.alwaysOnTitle,
            strings.about,
          ];
          final labels = <String>[];
          final seenText = <String>{};
          var previousY = double.negativeInfinity;
          for (final label in expected) {
            await reveal(tester, label);
            final text = find.text(label);
            final position = tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position;
            final rect = tester.getRect(text);
            expect(
              rect.overlaps(tester.getRect(find.byType(Scrollable).first)),
              isTrue,
            );
            final y = rect.top + position.pixels;
            expect(y, greaterThan(previousY));
            previousY = y;
            labels.add(tester.widget<Text>(text).data!);
            seenText.addAll(
              tester
                  .widgetList<Text>(
                    find.descendant(
                      of: find.byType(SettingsPage),
                      matching: find.byType(Text),
                    ),
                  )
                  .map((text) => text.data)
                  .whereType<String>(),
            );
          }
          expect(labels, expected);
          for (final obsolete in const [
            'Add Quick Settings tile',
            'Add home-screen widget',
            '添加快捷设置磁贴',
            '添加桌面小组件',
          ]) {
            expect(seenText, isNot(contains(obsolete)));
          }
          await reveal(tester, strings.about);
          expect(tester.takeException(), isNull);
          expect(app.commands, isEmpty);
          expect(bridge.queries, isEmpty);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
