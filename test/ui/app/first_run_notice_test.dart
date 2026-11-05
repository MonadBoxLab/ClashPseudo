import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/app/first_run_notice.dart';
import 'package:clash_pseudo/src/ui/legal/app_legal.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _InstallationBridge extends AppBridge {
  bool shown = false;
  int reads = 0;
  int marks = 0;
  Object? readFailure;
  Object? writeFailure;
  Completer<bool>? readReply;
  Completer<void>? writeReply;

  @override
  Future<bool> privacyNoticeShown() async {
    reads++;
    if (readFailure case final failure?) throw failure;
    return readReply == null ? shown : await readReply!.future;
  }

  @override
  Future<void> markPrivacyNoticeShown() async {
    marks++;
    await writeReply?.future;
    if (writeFailure case final failure?) throw failure;
    shown = true;
  }
}

class _NoticeController extends AppController {
  _NoticeController(_InstallationBridge super.platform);

  bool visible = true;

  @override
  bool get interactive => visible;

  void visibility(bool value) {
    visible = value;
    notifyListeners();
  }
}

Widget _app(
  _NoticeController controller, {
  VoidCallback? stop,
  String language = 'en',
  ValueNotifier<bool>? reducedMotion,
}) => MaterialApp(
  navigatorObservers: [AppTaskNavigatorObserver()],
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: reducedMotion == null
      ? null
      : (context, child) => ValueListenableBuilder<bool>(
          valueListenable: reducedMotion,
          child: child,
          builder: (context, reduced, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
        ),
  home: FirstRunNotice(
    controller: controller,
    child: Scaffold(
      body: TextButton(onPressed: stop ?? () {}, child: const Text('Stop')),
    ),
  ),
);

Future<void> _paintPrompt(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  await tester.pump();
}

Future<void> _readPersistenceFailure(
  WidgetTester tester,
  String original, {
  VoidCallback? checkDetail,
}) async {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
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
  await tester.pumpAndSettle();
  final notice = find.byType(PrivacyNoticeDialog);
  final noticeElement = tester.element(notice);
  final noticeRoute = ModalRoute.of(noticeElement)!;
  final reader = find.descendant(
    of: notice,
    matching: find.byType(SelectionArea),
  );
  final readerState = tester.state<SelectionAreaState>(reader);
  final selectionState = readerState.selectableRegion;
  final scrollable = find
      .descendant(of: notice, matching: find.byType(Scrollable))
      .first;
  final scrollState = tester.state<ScrollableState>(scrollable);
  final position = scrollState.position;
  final strings = AppLocalizations.of(noticeElement);
  final details = find.descendant(
    of: find.byType(SnackBar),
    matching: find.widgetWithText(TextButton, strings.errorDetails),
  );
  expect(details.hitTestable(), findsOneWidget);
  expect(tester.getRect(details).height, greaterThanOrEqualTo(48));
  final offset = position.pixels;
  await tester.tap(details);
  await tester.pumpAndSettle();
  final result = find.ancestor(
    of: find.byKey(const ValueKey('operation-technical-details')),
    matching: find.byType(AlertDialog),
  );
  expect(result, findsOneWidget);
  expect(find.byType(AlertDialog), findsNWidgets(2));
  final resultRoute = ModalRoute.of(tester.element(result))!;
  expect(resultRoute, isNot(same(noticeRoute)));
  expect(find.text(original), findsNothing);
  await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
  await tester.pumpAndSettle();
  final technical = find.byKey(const ValueKey('operation-technical-text'));
  expect(tester.widget<SelectableText>(technical).data, original);
  checkDetail?.call();
  final copy = find.byKey(const ValueKey('operation-technical-copy'));
  await tester.ensureVisible(copy);
  await tester.tap(copy);
  await tester.pump();
  expect(copied, [original]);
  expect(ModalRoute.of(tester.element(result)), same(resultRoute));
  expect(resultRoute.isCurrent, isTrue);
  await tester.tap(find.text(strings.close));
  await tester.pumpAndSettle();
  expect(tester.element(notice), same(noticeElement));
  expect(ModalRoute.of(tester.element(notice)), same(noticeRoute));
  expect(noticeRoute.isCurrent, isTrue);
  expect(tester.state<SelectionAreaState>(reader), same(readerState));
  expect(readerState.selectableRegion, same(selectionState));
  expect(tester.state<ScrollableState>(scrollable), same(scrollState));
  expect(scrollState.position, same(position));
  expect(position.pixels, offset);
}

Future<void> _readSnackbarFailure(WidgetTester tester, String original) async {
  await tester.pumpAndSettle();
  final snack = find.byType(SnackBar);
  expect(snack, findsOneWidget);
  final strings = AppLocalizations.of(tester.element(snack));
  await tester.tap(
    find.descendant(
      of: snack,
      matching: find.widgetWithText(TextButton, strings.errorDetails),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
  await tester.pumpAndSettle();
  expect(
    tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('operation-technical-text')),
        )
        .data,
    contains(original),
  );
  await tester.tap(find.widgetWithText(TextButton, strings.close));
  await tester.pumpAndSettle();
}

void main() {
  final strings = lookupAppLocalizations(const Locale('en'));

  for (final language in ['zh', 'en']) {
    for (final startsReduced in [false, true]) {
      testWidgets(
        'painted marker failure preserves notice identity across reduce changes $language startsReduced=$startsReduced',
        (tester) async {
          final reducedMotion = ValueNotifier(startsReduced);
          addTearDown(reducedMotion.dispose);
          final bridge = _InstallationBridge()..writeReply = Completer<void>();
          final controller = _NoticeController(bridge)..visibility(false);
          addTearDown(controller.dispose);
          var stops = 0;
          await tester.pumpWidget(
            _app(
              controller,
              language: language,
              reducedMotion: reducedMotion,
              stop: () => stops++,
            ),
          );
          await _paintPrompt(tester);
          expect(find.byType(PrivacyNoticeDialog), findsNothing);
          expect(bridge.marks, 0);
          controller.visibility(true);
          await _paintPrompt(tester);
          expect(bridge.marks, 1);
          expect(bridge.shown, isFalse);
          final dialog = find.byType(PrivacyNoticeDialog);
          final noticeState = tester.state(find.byType(FirstRunNotice));
          final dialogElement = tester.element(dialog);
          final route = ModalRoute.of(dialogElement);
          final reader = find.descendant(
            of: dialog,
            matching: find.byType(SelectionArea),
          );
          final readerState = tester.state<SelectionAreaState>(reader);
          final selectionState = readerState.selectableRegion;
          final scrollable = find
              .descendant(of: dialog, matching: find.byType(Scrollable))
              .first;
          final scrollState = tester.state<ScrollableState>(scrollable);
          final scrollPosition = scrollState.position;
          readerState.selectableRegion.selectAll(
            SelectionChangedCause.keyboard,
          );
          final localized = lookupAppLocalizations(Locale(language));
          final introElement = tester.element(
            find.text(localized.privacyNoticeIntro),
          );

          void expectIdentity() {
            expect(
              tester.state(find.byType(FirstRunNotice)),
              same(noticeState),
            );
            expect(tester.element(dialog), same(dialogElement));
            expect(ModalRoute.of(tester.element(dialog)), same(route));
            expect(tester.state<SelectionAreaState>(reader), same(readerState));
            expect(readerState.selectableRegion, same(selectionState));
            expect(
              tester.state<ScrollableState>(scrollable),
              same(scrollState),
            );
            expect(scrollState.position, same(scrollPosition));
            expect(
              tester.element(find.text(localized.privacyNoticeIntro)),
              same(introElement),
            );
            expect(
              find.byKey(const ValueKey('privacy-notice-error-details')),
              findsNothing,
            );
            expect(bridge.reads, 1);
            expect(bridge.marks, 1);
            expect(tester.takeException(), isNull);
          }

          // Change the system setting both ways while the actual marker write
          // is still pending. Neither route nor reader is replaced.
          for (final reduced in [!startsReduced, startsReduced]) {
            reducedMotion.value = reduced;
            await tester.pump();
            expectIdentity();
          }
          final failure = PlatformFailure(
            code: 'privacyNoticeNotSaved',
            message: 'directory fsync failed',
            details: 'original fsync cause\nsuppressed directory close failure',
          );
          bridge.writeReply!.completeError(failure);
          await tester.pumpAndSettle();
          final expected = messages.privacyNoticeNotSaved
              .withDetail(failure)
              .summary(localized);
          final errorText = find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(expected),
          );
          expect(errorText, findsOneWidget);
          expect(tester.getSize(errorText).height, greaterThan(0));
          expectIdentity();
          for (final reduced in [
            !startsReduced,
            startsReduced,
            !startsReduced,
          ]) {
            reducedMotion.value = reduced;
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 16));
            expectIdentity();
            expect(errorText, findsOneWidget);
            expect(
              tester
                  .widget<TextButton>(
                    find.widgetWithText(
                      TextButton,
                      localized.privacyNoticeReadFull,
                    ),
                  )
                  .onPressed,
              isNotNull,
            );
            expect(
              tester
                  .widget<TextButton>(
                    find.widgetWithText(
                      TextButton,
                      localized.privacyNoticeUnderstood,
                    ),
                  )
                  .onPressed,
              isNotNull,
            );
          }
          await _readPersistenceFailure(tester, failure.toString());
          expectIdentity();
          expect(find.byType(SnackBar), findsNothing);
          expect(bridge.shown, isFalse);
          await tester.tap(find.text(localized.privacyNoticeUnderstood));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Stop'));
          expect(stops, 1);
          controller.visibility(controller.visible);
          await _paintPrompt(tester);
          expect(bridge.marks, 1);
          expect(find.byType(PrivacyNoticeDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('only a painted foreground prompt marks, before any button', (
    tester,
  ) async {
    final bridge = _InstallationBridge();
    final controller = _NoticeController(bridge)..visibility(false);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await _paintPrompt(tester);
    expect(bridge.reads, 1);
    expect(bridge.marks, 0);
    expect(find.byType(PrivacyNoticeDialog), findsNothing);

    controller.visibility(true);
    await _paintPrompt(tester);
    expect(find.text(strings.privacyNoticeIntro), findsOneWidget);
    expect(find.text(strings.privacyDataProcessingTitle), findsNothing);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).actions,
      hasLength(2),
    );
    expect(bridge.marks, 1);
    expect(bridge.shown, isTrue);
    final dialog = tester.element(find.byType(PrivacyNoticeDialog));
    final animation = ModalRoute.of(dialog)!.animation!;
    expect(animation.value, greaterThan(0));
    expect(animation.value, lessThan(1));

    // No Understood action: reconstruct the application with the same
    // installation-local storage (also the contract for a data-preserving update).
    await tester.pumpWidget(const SizedBox());
    final reopened = _NoticeController(bridge);
    addTearDown(reopened.dispose);
    await tester.pumpWidget(_app(reopened));
    await _paintPrompt(tester);
    expect(find.byType(PrivacyNoticeDialog), findsNothing);
    expect(bridge.marks, 1);
  });

  testWidgets('a fresh installation storage displays again, unlike a reopen', (
    tester,
  ) async {
    final oldInstallation = _InstallationBridge()..shown = true;
    final oldController = _NoticeController(oldInstallation);
    addTearDown(oldController.dispose);
    await tester.pumpWidget(_app(oldController));
    await _paintPrompt(tester);
    expect(find.byType(PrivacyNoticeDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final freshInstallation = _InstallationBridge();
    final freshController = _NoticeController(freshInstallation);
    addTearDown(freshController.dispose);
    await tester.pumpWidget(_app(freshController));
    await _paintPrompt(tester);
    expect(find.byType(PrivacyNoticeDialog), findsOneWidget);
    expect(freshInstallation.marks, 1);
    expect(oldInstallation.marks, 0);
  });

  testWidgets('background before the first visible frame never marks', (
    tester,
  ) async {
    final bridge = _InstallationBridge();
    final controller = _NoticeController(bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pump();
    controller.visibility(false);
    await _paintPrompt(tester);
    expect(bridge.marks, 0);
    await tester.pumpWidget(const SizedBox());
    expect(bridge.shown, isFalse);
  });

  testWidgets(
    'read failure stays unknown, retains original error, never writes',
    (tester) async {
      final bridge = _InstallationBridge()
        ..readFailure = PlatformFailure(
          code: 'privacyNoticeNotSaved',
          message: 'read failed',
          details: 'original read cause\nsuppressed close failure',
        );
      final controller = _NoticeController(bridge)..visibility(false);
      addTearDown(controller.dispose);
      var stops = 0;
      await tester.pumpWidget(_app(controller, stop: () => stops++));
      await _paintPrompt(tester);
      expect(find.byType(SnackBar), findsNothing);
      controller.visibility(true);
      await _paintPrompt(tester);
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyNoticeDialog), findsNothing);
      expect(find.text(strings.privacyNoticeReadFailed), findsOneWidget);
      expect(find.textContaining('original read cause'), findsNothing);
      await _readSnackbarFailure(
        tester,
        'original read cause\nsuppressed close failure',
      );
      await tester.tap(find.text('Stop'));
      expect(stops, 1);
      controller.visibility(controller.visible);
      await _paintPrompt(tester);
      expect(bridge.marks, 0);
    },
  );

  testWidgets('隐私标记读取失败按退避重试，成功后不再提示', (tester) async {
    final bridge = _InstallationBridge()
      ..shown = true
      ..readFailure = StateError('marker read failed');
    final controller = _NoticeController(bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await _paintPrompt(tester);
    expect(bridge.reads, 1);
    await tester.pump(const Duration(milliseconds: 900));
    expect(bridge.reads, 1);
    await tester.pump(const Duration(milliseconds: 101));
    expect(bridge.reads, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(bridge.reads, 3);
    bridge.readFailure = null;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(bridge.reads, 4);
    expect(bridge.marks, 0);
    expect(find.byType(PrivacyNoticeDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('读取超时后的重试等待真实读取结束', (tester) async {
    final first = Completer<bool>();
    final second = Completer<bool>();
    final bridge = _InstallationBridge()..readReply = first;
    final controller = _NoticeController(bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(bridge.reads, 1);
    final snack = find.byType(SnackBar);
    expect(snack, findsOneWidget);
    await tester.tap(
      find.descendant(
        of: snack,
        matching: find.widgetWithText(TextButton, strings.retry),
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.reads, 1);
    bridge.readReply = second;
    first.completeError(StateError('first read failed'));
    await tester.pump();
    expect(bridge.reads, 2);
    second.complete(true);
    await tester.pumpAndSettle();
    expect(bridge.marks, 0);
    expect(find.byType(PrivacyNoticeDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('隐私标记写入失败后仅在用户重试时再次写入', (tester) async {
    final bridge = _InstallationBridge()
      ..writeFailure = StateError('marker write failed');
    final controller = _NoticeController(bridge);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await _paintPrompt(tester);
    await tester.pumpAndSettle();
    expect(bridge.marks, 1);
    await tester.pump(const Duration(seconds: 20));
    expect(bridge.marks, 1);
    bridge.writeFailure = null;
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.retry),
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.marks, 2);
    expect(bridge.shown, isTrue);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(PrivacyNoticeDialog), findsOneWidget);
  });

  testWidgets('failed write remains unconfirmed with full error and no loop', (
    tester,
  ) async {
    final bridge = _InstallationBridge()
      ..writeFailure = PlatformFailure(
        code: 'privacyNoticeNotSaved',
        message: 'directory fsync failed',
        details: 'original fsync cause\nsuppressed directory close failure',
      );
    final controller = _NoticeController(bridge);
    addTearDown(controller.dispose);
    var stops = 0;
    await tester.pumpWidget(_app(controller, stop: () => stops++));
    await _paintPrompt(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining(strings.privacyNoticeNotSaved), findsOneWidget);
    await _readPersistenceFailure(
      tester,
      bridge.writeFailure.toString(),
      checkDetail: () {
        expect(
          find.textContaining(
            'original fsync cause\nsuppressed directory close failure',
          ),
          findsOneWidget,
        );
      },
    );
    expect(bridge.shown, isFalse);
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.privacyNoticeUnderstood));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    expect(stops, 1);
    controller.visibility(controller.visible);
    await _paintPrompt(tester);
    expect(bridge.marks, 1);
    expect(find.byType(PrivacyNoticeDialog), findsNothing);
  });

  testWidgets(
    'Escape releases UI immediately while the actual write continues',
    (tester) async {
      final bridge = _InstallationBridge()..writeReply = Completer<void>();
      final controller = _NoticeController(bridge);
      addTearDown(controller.dispose);
      var stops = 0;
      await tester.pumpWidget(_app(controller, stop: () => stops++));
      await _paintPrompt(tester);
      expect(bridge.marks, 1);
      await tester.pumpAndSettle();
      final oldOpenFull = tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, strings.privacyNoticeReadFull),
          )
          .onPressed!;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      oldOpenFull();
      expect(find.byType(PrivacyNoticePage), findsNothing);
      final gate = find
          .descendant(
            of: find.byType(PrivacyNoticeDialog, skipOffstage: false),
            matching: find.byType(ExcludeSemantics, skipOffstage: false),
          )
          .first;
      expect(tester.widget<ExcludeSemantics>(gate).excluding, isTrue);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stop'));
      expect(stops, 1);
      bridge.writeReply!.completeError(
        StateError('late original close failure'),
      );
      await _paintPrompt(tester);
      await _readSnackbarFailure(tester, 'late original close failure');
      expect(bridge.marks, 1);
      expect(find.byType(PrivacyNoticeDialog), findsNothing);
    },
  );

  testWidgets(
    'a write failure during reverse animation is not lost offscreen',
    (tester) async {
      final bridge = _InstallationBridge()..writeReply = Completer<void>();
      final controller = _NoticeController(bridge);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(controller));
      await _paintPrompt(tester);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(PrivacyNoticeDialog))).pop();
      bridge.writeReply!.completeError(
        StateError('failure during route reverse'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyNoticeDialog), findsNothing);
      await _readSnackbarFailure(tester, 'failure during route reverse');
      expect(bridge.marks, 1);
    },
  );

  testWidgets(
    'widget disposal does not revoke a real pending persistence write',
    (tester) async {
      final bridge = _InstallationBridge()..writeReply = Completer<void>();
      final controller = _NoticeController(bridge);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(controller));
      await _paintPrompt(tester);
      expect(bridge.marks, 1);
      await tester.pumpWidget(const SizedBox());
      bridge.writeReply!.complete();
      await tester.pump();
      expect(bridge.shown, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late absent read after disposal cannot open or mark a prompt',
    (tester) async {
      final bridge = _InstallationBridge()..readReply = Completer<bool>();
      final controller = _NoticeController(bridge);
      addTearDown(controller.dispose);
      var stops = 0;
      await tester.pumpWidget(_app(controller, stop: () => stops++));
      await tester.tap(find.text('Stop'));
      expect(stops, 1);
      await tester.pumpWidget(const SizedBox());
      bridge.readReply!.complete(false);
      await tester.pump();
      expect(bridge.marks, 0);
      expect(find.byType(PrivacyNoticeDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
