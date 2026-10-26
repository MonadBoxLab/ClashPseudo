import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/overrides/proxy_form_type_page.dart';
import 'package:clash_pseudo/src/features/settings/about_page.dart';
import 'package:clash_pseudo/src/features/settings/always_on_page.dart';
import 'package:clash_pseudo/src/features/settings/applications_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/text_scalers.dart';

import '../features/settings/application_fakes.dart';
import '../support/application_info.dart';

class _InfoBridge extends AccessBridge {
  _InfoBridge(this.info);

  final Map<String, dynamic> info;

  @override
  Future<Map<String, dynamic>> applicationInfo() async => Map.of(info);
}

void main() {
  const applicationInfo = applicationInfoFixture;
  for (final name in ['about', 'always-on', 'applications', 'types']) {
    for (final language in ['en', 'zh']) {
      for (final (scaleName, scaler) in [
        ('1', TextScaler.noScaling),
        ('1.3', const TextScaler.linear(1.3)),
        ('2', const TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          '$name keeps a bounded reading column and its state through window changes $language/$scaleName',
          (tester) async {
            const initialSize = Size(1704, 1136);
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = initialSize;
            tester.view.padding = const FakeViewPadding(
              left: 8,
              right: 8,
              bottom: 20,
            );
            addTearDown(tester.view.reset);
            final bridge = _InfoBridge(applicationInfo);
            final app = AccessApp(bridge);
            final page = switch (name) {
              'about' => AboutPage(platform: bridge),
              'always-on' => AlwaysOnPage(app: app),
              'applications' => ApplicationsPage(app: app),
              _ => const ProxyFormTypePage(selectedType: 'http'),
            };
            try {
              await tester.pumpWidget(
                MaterialApp(
                  locale: Locale(language),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  theme: AppTheme.light,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(textScaler: scaler),
                    child: child!,
                  ),
                  home: page,
                ),
              );
              await tester.pumpAndSettle();
              final vertical = find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable &&
                    widget.axisDirection == AxisDirection.down,
              );
              final viewport = name == 'applications'
                  ? find
                        .descendant(
                          of: find.byType(CustomScrollView),
                          matching: vertical,
                        )
                        .first
                  : vertical.first;
              final scroll = tester.state<ScrollableState>(viewport);
              final position = scroll.position;
              EditableText? draft;
              if (name == 'applications') {
                await tester.enterText(find.byType(TextField), 'controlled');
                await tester.pump();
                draft = tester.widget<EditableText>(find.byType(EditableText));
                draft.controller.selection = const TextSelection(
                  baseOffset: 1,
                  extentOffset: 5,
                );
                await tester.pump();
              }
              for (final (width, wideAccessScene) in [
                (initialSize.width, true),
                (1601.0, true),
                (1600.0, true),
                (1599.0, true),
                (1201.0, true),
                (1200.0, true),
                (1199.0, true),
                (841.0, false),
                (840.0, false),
                (839.0, false),
                (700.0, false),
                (601.0, false),
                (600.0, false),
                (599.0, false),
                (320.0, false),
                (280.0, false),
                (initialSize.width, true),
              ]) {
                tester.view.physicalSize = Size(width, initialSize.height);
                for (final ms in [0, 16]) {
                  await tester.pump(Duration(milliseconds: ms));
                  final rect = tester.getRect(viewport);
                  final window = MediaQueryData.fromView(tester.view);
                  final available = (window.padding + window.viewInsets)
                      .deflateRect(Offset.zero & window.size);
                  if (name == 'applications' && wideAccessScene) {
                    final controls = find
                        .ancestor(
                          of: find.byType(TextField),
                          matching: find.byType(SingleChildScrollView),
                        )
                        .last;
                    final control = tester.getRect(controls);
                    final workspace = control.expandToInclude(rect);
                    expect(control.width, inInclusiveRange(320, 480));
                    expect(rect.width, greaterThanOrEqualTo(360));
                    expect(rect.left, closeTo(control.right, .01));
                    expect(
                      workspace.width,
                      closeTo(available.width.clamp(0, 1440), .01),
                    );
                    expect(
                      workspace.center.dx,
                      closeTo(available.center.dx, .01),
                    );
                  } else {
                    expect(rect.width, lessThanOrEqualTo(840));
                    expect(
                      rect.width,
                      closeTo(available.width.clamp(0, 840), .01),
                    );
                    expect(rect.center.dx, closeTo(available.center.dx, .01));
                  }
                  expect(scroll.position, same(position));
                  if (draft != null) {
                    final actual = tester.widget<EditableText>(
                      find.byType(EditableText),
                    );
                    expect(actual.controller, same(draft.controller));
                    expect(actual.controller.text, 'controlled');
                    expect(
                      actual.controller.selection,
                      const TextSelection(baseOffset: 1, extentOffset: 5),
                    );
                    expect(actual.focusNode, same(draft.focusNode));
                    expect(actual.focusNode.hasFocus, isTrue);
                  }
                  expect(
                    tester.takeException(),
                    isNull,
                    reason: '$name/$width/$ms',
                  );
                }
              }
              expect(app.commands, isEmpty);
            } finally {
              await tester.pumpWidget(const SizedBox.shrink());
              app.dispose();
            }
          },
        );
      }
    }
  }
}
