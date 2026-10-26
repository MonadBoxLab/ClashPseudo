import 'dart:async';

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/settings/about_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/application_info.dart';

class InfoBridge extends AppBridge {
  final replies = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> applicationInfo() {
    final reply = Completer<Map<String, dynamic>>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  const applicationInfo = applicationInfoFixture;
  final longVersion = '${applicationInfo['version']}-${'long-version-' * 8}';
  for (final language in ['zh', 'en']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'about retries only failures without shifting $language $scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final bridge = InfoBridge();
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
              home: AboutPage(platform: bridge),
            ),
          );
          final strings = AppLocalizations.of(
            tester.element(find.byType(AboutPage)),
          );
          expect(find.textContaining('mihomo'), findsOneWidget);
          final divider = tester.getRect(find.byType(Divider));
          expect(find.text(strings.retry), findsNothing);
          bridge.replies.first.completeError(StateError('fixture read failed'));
          await tester.pump();
          expect(find.text(strings.versionUnavailable), findsOneWidget);
          expect(tester.getRect(find.byType(Divider)), divider);
          await tester.tap(
            find.byTooltip('${strings.versionUnavailable} ${strings.retry}'),
          );
          await tester.pump();
          expect(bridge.replies, hasLength(2));
          expect(tester.getRect(find.byType(Divider)), divider);
          bridge.replies.last.complete({
            ...applicationInfo,
            'version': longVersion,
          });
          for (final ms in [0, 16, 100, 300]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(tester.getRect(find.byType(Divider)), divider);
          }
          expect(find.byIcon(Icons.refresh), findsNothing);
          expect(find.text(strings.versionUnavailable), findsNothing);
          expect(
            find.text(applicationInfo['coreVersion'] as String),
            findsOneWidget,
          );
          expect(find.text(longVersion), findsOneWidget);
          await tester.scrollUntilVisible(
            find.byIcon(Icons.description_outlined),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          final palette = const SettingsPalette(false);
          expect(
            tester.widget<Icon>(find.byIcon(Icons.description_outlined)).color,
            palette.configuration,
          );
          expect(
            tester.widget<Icon>(find.byIcon(Icons.chevron_right)).color,
            palette.configuration,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
