import 'dart:convert';

import 'package:clash_pseudo/src/ui/legal/app_legal.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(
  String language, {
  bool reducedMotion = false,
  AppMessage? failure,
}) => MaterialApp(
  navigatorObservers: [AppTaskNavigatorObserver()],
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: const TextScaler.linear(2),
      disableAnimations: reducedMotion,
    ),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          animationStyle: reducedMotion ? AnimationStyle.noAnimation : null,
          builder: (_) => PrivacyNoticeDialog(persistenceFailure: failure),
        ),
        child: const Text('notice'),
      ),
    ),
  ),
);

String _spaces(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

void main() {
  for (final language in ['zh', 'en']) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'short-height large-text prompt has ungated actions $language reduced=$reducedMotion',
        (tester) async {
          tester.view.physicalSize = const Size(320, 300);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            _host(language, reducedMotion: reducedMotion),
          );
          await tester.tap(find.text('notice'));
          await tester.pump();
          final route = ModalRoute.of(
            tester.element(find.byType(PrivacyNoticeDialog)),
          )!;
          if (reducedMotion) {
            expect(route.animation!.value, 1);
          } else {
            await tester.pump(const Duration(milliseconds: 32));
            expect(route.animation!.value, inExclusiveRange(0, 1));
          }
          await tester.pumpAndSettle();
          final strings = lookupAppLocalizations(Locale(language));
          expect(find.byType(Checkbox), findsNothing);
          final understood = find.widgetWithText(
            TextButton,
            strings.privacyNoticeUnderstood,
          );
          expect(tester.getRect(understood).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(understood).bottom, lessThanOrEqualTo(300));
          // No scroll-to-bottom or acceptance gate is required.
          await tester.tap(understood);
          await tester.pumpAndSettle();
          expect(find.byType(PrivacyNoticeDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'complete sectioned text and URL select/copy across resize $language',
      (tester) async {
        String? copiedText;
        var clipboardWrites = 0;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboardWrites++;
              copiedText = (call.arguments as Map)['text'] as String;
            case 'Clipboard.getData':
              return copiedText == null ? null : {'text': copiedText};
            case 'Clipboard.hasStrings':
              return {'value': copiedText?.isNotEmpty ?? false};
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        tester.view.physicalSize = const Size(320, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = lookupAppLocalizations(Locale(language));
        await tester.pumpWidget(_host(language));
        await tester.tap(find.text('notice'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.privacyNoticeReadFull));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));
        final page = tester.element(find.byType(PrivacyNoticePage));
        final route = ModalRoute.of(page)!;
        expect(route.animation!.value, inExclusiveRange(0, 1));
        await tester.pumpAndSettle();
        final selectionFinder = find.descendant(
          of: find.byType(PrivacyNoticePage),
          matching: find.byType(SelectionArea),
        );
        final selection = tester.state<SelectionAreaState>(selectionFinder);
        for (final title in [
          strings.privacyDataProcessingTitle,
          strings.privacyNetworkCommunicationTitle,
          strings.privacyPermissionPurposesTitle,
          strings.privacyFilesAndBackupsTitle,
          strings.privacyRecordsAndLogsTitle,
          strings.privacyDeletingDataTitle,
          strings.privacyProjectRepositoryTitle,
        ]) {
          expect(find.text(title), findsOneWidget);
          final semantics = tester.widget<Semantics>(
            find
                .ancestor(
                  of: find.text(title),
                  matching: find.byType(Semantics),
                )
                .first,
          );
          expect(semantics.properties.header, isTrue);
        }
        expect(find.text(strings.projectRepositoryUrl), findsOneWidget);
        selection.selectableRegion.selectAll(SelectionChangedCause.keyboard);
        await tester.pump();
        Actions.invoke(
          tester.element(find.text(strings.privacyNoticeIntro).last),
          CopySelectionTextIntent.copy,
        );
        await tester.pump();
        expect(clipboardWrites, 1);
        expect(copiedText, isNotNull);
        expect(_spaces(copiedText!), _spaces(strings.privacyNoticeBody));
        final clipboard = await tester.runAsync(
          () => Clipboard.getData(Clipboard.kTextPlain),
        );
        expect(_spaces(clipboard!.text!), _spaces(strings.privacyNoticeBody));

        tester.view.physicalSize = const Size(700, 300);
        await tester.pump();
        expect(
          tester.state<SelectionAreaState>(selectionFinder),
          same(selection),
        );
        expect(
          ModalRoute.of(tester.element(find.byType(PrivacyNoticePage))),
          same(route),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'both GPL entries read the complete bundled LICENSE $language',
      (tester) async {
        rootBundle.evict('LICENSE');
        addTearDown(() => rootBundle.evict('LICENSE'));
        final localLicense = await tester.runAsync(() async {
          final data = await rootBundle.load('LICENSE');
          return utf8.decode(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        });
        expect(localLicense, contains('END OF TERMS AND CONDITIONS'));
        tester.view.physicalSize = const Size(400, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = lookupAppLocalizations(Locale(language));
        await tester.pumpWidget(_host(language));
        await tester.tap(find.text('notice'));
        await tester.pumpAndSettle();
        final link = find.widgetWithText(
          TextButton,
          strings.privacyNoticeLicenseNotice,
        );
        await tester.ensureVisible(link);
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(find.text(strings.privacyNoticeLicenseName), findsOneWidget);
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          localLicense,
        );
        expect(find.byType(LicensePage), findsNothing);
        if (language == 'zh') {
          await tester.tap(find.byType(BackButton));
        } else {
          await tester.pageBack();
        }
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.privacyNoticeReadFull));
        await tester.pumpAndSettle();
        await tester.ensureVisible(link);
        await tester.pumpAndSettle();
        expect(tester.getRect(link).height, greaterThanOrEqualTo(48));
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(
          tester.widget<SelectableText>(find.byType(SelectableText)).data,
          localLicense,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'full notice loses semantics and pointer/focus eligibility on pop',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(_host('en'));
        await tester.tap(find.text('notice'));
        await tester.pumpAndSettle();
        final strings = lookupAppLocalizations(const Locale('en'));
        await tester.tap(find.text(strings.privacyNoticeReadFull));
        await tester.pumpAndSettle();
        Set<SemanticsNode> actualSemantics() {
          final root = View.pipelineOwnerOf(
            tester.element(find.byType(PrivacyNoticePage)),
          ).semanticsOwner?.rootSemanticsNode;
          expect(root, isNotNull);
          expect(root!.attached, isTrue);
          expect(root.parent, isNull);
          final nodes = Set<SemanticsNode>.identity();
          void collect(SemanticsNode node) {
            if (!nodes.add(node)) return;
            node.visitChildren((child) {
              collect(child);
              return true;
            });
          }

          collect(root);
          return nodes;
        }

        final departingTitleNodes = actualSemantics()
            .where((node) => node.label == strings.privacyDataProcessingTitle)
            .toList();
        expect(departingTitleNodes, isNotEmpty);
        final context = tester.element(find.byType(PrivacyNoticePage));
        Navigator.of(context).pop();
        await tester.pump();
        final page = find.byType(PrivacyNoticePage, skipOffstage: false);
        expect(page, findsOneWidget); // SDK exit is still animating.
        final gate = find
            .descendant(
              of: page,
              matching: find.byType(IgnorePointer, skipOffstage: false),
            )
            .first;
        expect(tester.widget<IgnorePointer>(gate).ignoring, isTrue);
        final focusGate = find
            .descendant(
              of: page,
              matching: find.byType(ExcludeFocus, skipOffstage: false),
            )
            .first;
        expect(tester.widget<ExcludeFocus>(focusGate).excluding, isTrue);
        final reachableNodes = actualSemantics();
        expect(
          reachableNodes.where(
            (node) => node.label == strings.privacyDataProcessingTitle,
          ),
          isEmpty,
        );
        expect(departingTitleNodes.where(reachableNodes.contains), isEmpty);
        await tester.pumpAndSettle();
        expect(find.byType(PrivacyNoticePage), findsNothing);
        expect(find.byType(PrivacyNoticeDialog), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'notice persistence failure has a task summary and copyable original details',
    (tester) async {
      const original = 'notice record write failed 原文🙂\nfsync: fixture';
      const failure = AppMessage('privacyNoticeNotSaved', detail: original);
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
      await tester.pumpWidget(_host('en', failure: failure));
      await tester.tap(find.text('notice'));
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      final notice = tester.state(find.byType(PrivacyNoticeDialog));
      final selection = tester.state(
        find.descendant(
          of: find.byType(PrivacyNoticeDialog),
          matching: find.byType(SelectionArea),
        ),
      );
      expect(find.text(strings.privacyNoticeNotSaved), findsOneWidget);
      expect(find.text(original), findsNothing);
      final details = find.byKey(
        const ValueKey('privacy-notice-error-details'),
      );
      await tester.ensureVisible(details);
      expect(tester.getRect(details).height, greaterThanOrEqualTo(48));
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text(strings.privacyNoticeNotSaved), findsNWidgets(2));
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('operation-technical-text')),
            )
            .data,
        original,
      );
      final copy = find.byKey(const ValueKey('operation-technical-copy'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, original);
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(PrivacyNoticeDialog)), same(notice));
      expect(
        tester.state(
          find.descendant(
            of: find.byType(PrivacyNoticeDialog),
            matching: find.byType(SelectionArea),
          ),
        ),
        same(selection),
      );
      final fullNotice = find.widgetWithText(
        TextButton,
        strings.privacyNoticeReadFull,
      );
      await tester.ensureVisible(fullNotice);
      await tester.tap(fullNotice);
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyNoticePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
