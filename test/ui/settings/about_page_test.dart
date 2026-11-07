import 'dart:async';

import 'package:clash_pseudo/src/ui/legal/app_legal.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/settings/about_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
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
    testWidgets(
      'about retains the complete repository and full notice entry $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = InfoBridge();
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AboutPage(platform: bridge),
          ),
        );
        bridge.replies.single.complete(applicationInfo);
        await tester.pumpAndSettle();
        final strings = lookupAppLocalizations(Locale(language));
        final aboutSliver = find.descendant(
          of: find.byType(AboutPage),
          matching: find.byType(SliverList),
        );
        expect(aboutSliver, findsOneWidget);
        final aboutScrollable = find.ancestor(
          of: aboutSliver,
          matching: find.byType(Scrollable),
        );
        expect(aboutScrollable, findsOneWidget);
        expect(
          tester.widget<Scrollable>(aboutScrollable).axisDirection,
          AxisDirection.down,
        );
        final repository = find.widgetWithText(
          SelectableText,
          strings.projectRepositoryUrl,
        );
        await tester.scrollUntilVisible(
          repository,
          160,
          scrollable: aboutScrollable,
        );
        expect(
          tester.widget<SelectableText>(repository).data,
          'https://github.com/MonadBoxLab/ClashPseudo',
        );
        expect(find.text(strings.sourceDistributionNotice), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text(strings.privacyNoticeTitle),
          -160,
          scrollable: aboutScrollable,
        );
        await tester.tap(find.text(strings.privacyNoticeTitle));
        await tester.pumpAndSettle();
        expect(find.byType(PrivacyNoticePage), findsOneWidget);
        expect(find.byType(PrivacyNoticeDialog), findsNothing);
        if (language == 'zh') {
          final backButton = find.descendant(
            of: find.byType(PrivacyNoticePage),
            matching: find.byType(BackButton),
          );
          expect(backButton, findsOneWidget);
          await tester.tap(backButton);
        } else {
          await tester.pageBack();
        }
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(strings.licenses),
          160,
          scrollable: aboutScrollable,
        );
        await tester.pump();
        expect(find.text(strings.licenses).hitTestable(), findsOneWidget);
        await tester.tap(find.text(strings.licenses));
        await tester.pumpAndSettle();
        expect(find.byType(LicensePage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final succeeds in [true, false]) {
    testWidgets(
      'About timeout retry waits for the actual read to finish success=$succeeds',
      (tester) async {
        final bridge = InfoBridge();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AboutPage(platform: bridge),
          ),
        );
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        final strings = lookupAppLocalizations(const Locale('en'));
        expect(find.byType(SnackBar), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, strings.retry),
          ),
        );
        await tester.pumpAndSettle();
        expect(bridge.replies, hasLength(1));
        if (succeeds) {
          bridge.replies.first.complete(applicationInfo);
        } else {
          bridge.replies.first.completeError(
            StateError('previous read failed'),
          );
          await tester.pump();
          expect(bridge.replies, hasLength(2));
          bridge.replies.last.complete(applicationInfo);
        }
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(
          find.text(applicationInfo['coreVersion'] as String),
          findsOneWidget,
        );
        expect(bridge.replies, hasLength(succeeds ? 1 : 2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('healthy About state does not retain an error details area', (
    tester,
  ) async {
    final bridge = InfoBridge();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AboutPage(platform: bridge),
      ),
    );
    bridge.replies.single.complete(applicationInfo);
    await tester.pumpAndSettle();
    final strings = AppLocalizations.of(tester.element(find.byType(AboutPage)));
    final version = find.widgetWithText(ListTile, strings.coreVersion);
    final privacy = find.widgetWithText(ListTile, strings.privacyNoticeTitle);
    expect(
      tester.getRect(privacy).top - tester.getRect(version).bottom,
      closeTo(24, 0.1),
    );
    expect(
      find.byKey(const ValueKey('about-version-error-details')),
      findsNothing,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('about retry cannot act during its SDK exit animation', (
    tester,
  ) async {
    final bridge = InfoBridge();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => AboutPage(platform: bridge)),
              ),
              child: const Text('about'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('about'));
    await tester.pumpAndSettle();
    bridge.replies.single.completeError(StateError('fixture read failed'));
    await tester.pumpAndSettle();
    final retry = tester
        .widget<TextButton>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, 'Retry'),
          ),
        )
        .onPressed!;
    Navigator.of(tester.element(find.byType(AboutPage))).pop();
    await tester.pump();
    retry();
    expect(bridge.replies, hasLength(1));
    expect(find.byType(AboutPage), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsNothing);
  });

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
          await tester.pumpAndSettle();
          expect(find.text(strings.versionUnavailable), findsOneWidget);
          expect(find.byType(SnackBar), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.getRect(find.byType(Divider)), divider);
          expect(find.byIcon(Icons.refresh), findsNothing);
          await tester.tap(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.text(strings.retry),
            ),
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
            tester
                .widget<Icon>(
                  find.descendant(
                    of: find.widgetWithText(ListTile, strings.licenses),
                    matching: find.byIcon(Icons.chevron_right),
                  ),
                )
                .color,
            palette.configuration,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'version failure exposes an explicit copyable detail without replacing the About reader',
    (tester) async {
      final bridge = InfoBridge();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AboutPage(platform: bridge),
        ),
      );
      final state = tester.state(find.byType(AboutPage));
      final divider = tester.getRect(find.byType(Divider));
      bridge.replies.single.completeError(
        StateError('version read failed 原文🙂'),
      );
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      expect(find.text(strings.versionUnavailable), findsOneWidget);
      expect(find.text('Bad state: version read failed 原文🙂'), findsNothing);
      expect(
        find.byKey(const ValueKey('about-version-error-details')),
        findsNothing,
      );
      expect(find.byType(AlertDialog), findsNothing);
      final details = find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.errorDetails),
      );
      expect(details.hitTestable(), findsOneWidget);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text(strings.coreVersion), findsNWidgets(2));
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      final original = tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('operation-technical-text')),
          )
          .data;
      expect(original, 'Bad state: version read failed 原文🙂');
      final copy = find.byKey(const ValueKey('operation-technical-copy'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, original);
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(AboutPage)), same(state));
      expect(tester.getRect(find.byType(Divider)), divider);
      expect(bridge.replies, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
