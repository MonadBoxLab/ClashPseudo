import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/diagnostics/configuration/runtime_config_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/logs/logs_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_page.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/ui/settings/about_page.dart';
import 'package:clash_pseudo/src/ui/settings/always_on_page.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../diagnostics/configuration/runtime_fakes.dart' show TestApp;

class _FailedReads extends AppBridge {
  Future<Map<String, dynamic>> _fail() async => throw StateError('Read failed');
  @override
  Future<Map<String, dynamic>> nodes(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) => _fail();
  @override
  Future<Map<String, dynamic>> rules(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) => _fail();
  @override
  Future<Map<String, dynamic>> resources(CoreSnapshot core) => _fail();
  @override
  Future<Map<String, dynamic>> logs(
    CoreSnapshot core,
    Map<String, Object?> query,
  ) => _fail();
  @override
  Future<Map<String, dynamic>> runtimeConfiguration(CoreSnapshot core) =>
      _fail();
  @override
  Future<Map<String, dynamic>> vpnStatus() => _fail();
  @override
  Future<Map<String, dynamic>> applicationInfo() => _fail();
}

Color renderedIcon(WidgetTester tester, Finder icon) => tester
    .widget<RichText>(
      find.descendant(of: icon, matching: find.byType(RichText)),
    )
    .text
    .style!
    .color!;

Widget host(Widget page, ThemeData theme) => MaterialApp(
  theme: theme,
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: page,
);

void main() {
  final pages = <String, Widget Function(TestApp)>{
    'nodes': (app) => NodesPage(app: app),
    'rules': (app) => RulesPage(app: app),
    'resources': (app) => ResourcesPage(app: app),
    'logs': (app) => CoreLogsPage(app: app),
    'runtime': (app) => RuntimeConfigPage(app: app),
    'always-on': (app) => AlwaysOnPage(app: app),
    'about': (app) => AboutPage(platform: app.platform),
  };
  for (final brightness in Brightness.values) {
    for (final brand in BrandColor.values) {
      final theme = AppTheme.forBrightness(brightness, brand);
      final palette = theme.extension<HomePalette>()!;
      for (final page in pages.entries) {
        testWidgets(
          'refresh keeps its action color ${page.key} $brightness $brand',
          (tester) async {
            final app = TestApp(_FailedReads())
              ..overridesLoaded = true
              ..preferencesLoaded = true;
            try {
              await tester.pumpWidget(host(page.value(app), theme));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 240));
              final refresh = find.byIcon(Icons.refresh);
              expect(refresh, findsOneWidget);
              final button = find.ancestor(
                of: refresh,
                matching: find.byType(IconButton),
              );
              expect(tester.widget<IconButton>(button).onPressed, isNotNull);
              expect(renderedIcon(tester, refresh), palette.syncAction);
              final rect = tester.getRect(button);
              app.setForeground(false);
              for (final milliseconds in [0, 16, 80, 180]) {
                await tester.pump(Duration(milliseconds: milliseconds));
                expect(tester.getRect(button), rect);
                if (milliseconds == 180 &&
                    tester.widget<IconButton>(button).onPressed == null) {
                  expect(
                    renderedIcon(tester, refresh),
                    theme.colorScheme.onSurface.withAlpha(97),
                  );
                }
                expect(tester.takeException(), isNull);
              }
            } finally {
              await tester.pumpWidget(const SizedBox());
              app.dispose();
            }
          },
        );
      }
      testWidgets(
        'GUI edit and removal roles survive disabling $brightness $brand',
        (tester) async {
          for (final enabled in [true, false, true]) {
            await tester.pumpWidget(
              host(
                Scaffold(
                  body: DefinitionRowActions(
                    id: 'row',
                    label: 'row',
                    index: 1,
                    onUp: enabled ? () {} : null,
                    onDown: enabled ? () {} : null,
                    onRemove: enabled ? () {} : null,
                  ),
                ),
                theme,
              ),
            );
            await tester.pump(const Duration(milliseconds: 240));
            for (final (icon, color) in [
              (Icons.arrow_upward, palette.editAction),
              (Icons.arrow_downward, palette.editAction),
              (Icons.remove_circle_outline, theme.colorScheme.error),
            ]) {
              expect(
                renderedIcon(tester, find.byIcon(icon)),
                enabled ? color : theme.colorScheme.onSurface.withAlpha(97),
              );
            }
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }
}
