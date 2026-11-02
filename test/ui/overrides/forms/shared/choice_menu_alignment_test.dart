import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final language in ['zh', 'en']) {
    for (final width in [320.0, 700.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'choice menu follows the right arrow $language $width $scale',
          (tester) async {
            tester.view.physicalSize = Size(width, 1000);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            String? selected;
            await tester.pumpWidget(
              MaterialApp(
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 60, 16, 0),
                    child: DefinitionChoiceField(
                      id: 'alignment',
                      label: 'hidden',
                      options: const {'on': 'On', 'off': 'Off'},
                      onChanged: (value) => selected = value,
                    ),
                  ),
                ),
              ),
            );
            final trigger = find.byKey(
              const ValueKey('definition-menu:alignment'),
            );
            final before = tester.getRect(trigger);
            await tester.tap(trigger);
            for (final duration in [16, 40, 80, 200]) {
              await tester.pump(Duration(milliseconds: duration));
              final item = find.byType(MenuItemButton).last;
              final surface = find
                  .ancestor(
                    of: item,
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is Material &&
                          widget.type == MaterialType.canvas,
                    ),
                  )
                  .first;
              expect(
                tester.getRect(surface).right,
                closeTo(before.right, .01),
                reason: 'The popup must share the right edge of the field containing the arrow.',
              );
              expect(tester.getRect(trigger), before);
            }
            await tester.tap(find.widgetWithText(MenuItemButton, 'On'));
            for (final duration in [0, 16, 100, 300]) {
              await tester.pump(Duration(milliseconds: duration));
              expect(tester.getRect(trigger), before);
            }
            expect(selected, 'on');
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
