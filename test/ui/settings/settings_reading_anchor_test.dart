import 'dart:convert';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../diagnostics/configuration/runtime_fakes.dart';

void main() {
  for (final language in ['en', 'zh']) {
    for (final viewport in [const Size(320, 700), const Size(1704, 1136)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('settings retain bottom reading actions across insets '
            '$language/$viewport/$scale', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = viewport;
          tester.view.padding = const FakeViewPadding(bottom: 32);
          tester.view.viewPadding = const FakeViewPadding(bottom: 32);
          addTearDown(tester.view.reset);
          final app = TestApp(TestBridge())
            ..preferencesLoaded = true
            ..overridesLoaded = true;
          try {
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: AppTheme.light,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: SettingsPage(app: app),
              ),
            );
            await tester.pumpAndSettle();
            final scroll = tester.state<ScrollableState>(
              find.byType(Scrollable).first,
            );
            final position = scroll.position;
            position.jumpTo(position.maxScrollExtent);
            await tester.pumpAndSettle();
            final strings = lookupAppLocalizations(Locale(language));
            final controls = {
              'about': find.widgetWithText(ListTile, strings.about),
              'about-title': find.text(strings.about),
            };
            final actions = {
              for (final entry in controls.entries)
                entry.key: tester.getRect(entry.value),
            };
            for (final bottom in [20.0, 0.0, 32.0]) {
              tester.view.padding = FakeViewPadding(bottom: bottom);
              tester.view.viewPadding = FakeViewPadding(bottom: bottom);
              for (final ms in [0, 16, 100]) {
                await tester.pump(Duration(milliseconds: ms));
                final now = {
                  for (final entry in controls.entries)
                    entry.key: tester.getRect(entry.value),
                };
                debugPrint(
                  'SETTINGS_INSET_ANCHOR ${jsonEncode({
                    'sample': '$language/$viewport/$scale',
                    'bottom': bottom,
                    'frameMs': ms,
                    'beforeTop': [for (final rect in actions.values) rect.top],
                    'currentTop': [for (final rect in now.values) rect.top],
                  })}',
                );
                expect(scroll.position, same(position));
                expect(now, actions);
                expect(tester.takeException(), isNull);
              }
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            app.dispose();
          }
        });
      }
    }
  }
}
