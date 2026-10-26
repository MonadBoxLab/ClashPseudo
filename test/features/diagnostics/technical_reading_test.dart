import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/technical_reading_pane.dart';
import 'package:clash_pseudo/src/features/diagnostics/logs_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/runtime_config_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_fakes.dart';

void main() {
  for (final logs in [false, true]) {
    for (final language in ['en', 'zh']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'technical reading bounds retain task and draft $logs/$language/$scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = const Size(4000, 900);
            addTearDown(tester.view.reset);
            final app = TestApp(TestBridge())
              ..state = const AppSnapshot(phase: 'STOPPED');
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: AppTheme.dark,
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: logs
                      ? CoreLogsPage(app: app)
                      : RuntimeConfigPage(app: app),
                ),
              );
              await tester.pump();
              final page = find.byType(logs ? CoreLogsPage : RuntimeConfigPage);
              final state = tester.state(page);
              final search = find.byType(TextField);
              final controller = tester.widget<TextField>(search).controller!;
              await tester.enterText(search, 'literal query');
              controller.selection = const TextSelection.collapsed(offset: 3);
              final draft = controller.value;
              final column = find
                  .descendant(
                    of: find.byType(TechnicalReadingPane),
                    matching: find.byType(ConstrainedBox),
                  )
                  .first;
              final wide = tester.getRect(column);
              expect(wide.width, lessThan(tester.view.physicalSize.width));
              expect(wide.center.dx, closeTo(2000, .01));
              for (final width in [320.0, 700.0, 4000.0]) {
                tester.view.physicalSize = Size(width, 900);
                await tester.pump();
                expect(tester.state(page), same(state));
                expect(
                  tester.widget<TextField>(search).controller,
                  same(controller),
                );
                expect(controller.value, draft);
                final current = tester.getRect(column);
                expect(current.width, lessThanOrEqualTo(width));
                expect(current.center.dx, closeTo(width / 2, .01));
                if (width == 4000) expect(current, wide);
                expect(app.commands, isEmpty);
                expect(tester.takeException(), isNull);
              }
            } finally {
              await tester.pumpWidget(const SizedBox());
              app.dispose();
            }
          },
        );
      }
    }
  }
}
