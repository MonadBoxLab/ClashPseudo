import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:clash_pseudo/src/features/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/diagnostics/runtime_fakes.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final brand in BrandColor.values) {
      for (final language in ['en', 'zh']) {
        for (final width in [320.0, 1704.0]) {
          testWidgets('SDK accessibility $brightness/$brand/$language/$width', (
            tester,
          ) async {
            tester.view.physicalSize = Size(width, 1136);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final app = TestApp(TestBridge())
              ..preferencesLoaded = true
              ..overridesLoaded = true
              ..preferences = AppPreferences(brand: brand);
            try {
              await tester.pumpWidget(
                MaterialApp(
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  theme: AppTheme.forBrightness(brightness, brand),
                  home: SettingsPage(app: app),
                ),
              );
              await tester.pumpAndSettle();
              for (final guideline in [
                androidTapTargetGuideline,
                labeledTapTargetGuideline,
                textContrastGuideline,
              ]) {
                await expectLater(tester, meetsGuideline(guideline));
              }
              await tester.tap(find.byType(ChoiceMenuButton<String>).first);
              await tester.pumpAndSettle();
              for (final guideline in [
                androidTapTargetGuideline,
                labeledTapTargetGuideline,
                textContrastGuideline,
              ]) {
                await expectLater(tester, meetsGuideline(guideline));
              }
              await tester.binding.handlePopRoute();
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(app.commands, isEmpty);
            } finally {
              await tester.pumpWidget(const SizedBox());
              app.dispose();
            }
          }, semanticsEnabled: true);
        }
      }
    }
  }
}
