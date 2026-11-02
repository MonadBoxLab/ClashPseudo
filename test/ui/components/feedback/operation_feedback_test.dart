import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FeedbackApp extends AppController {
  _FeedbackApp() : super(AppBridge());

  void changed() => notifyListeners();
}

class _OnDeactivate extends StatefulWidget {
  const _OnDeactivate({required this.onDeactivate});

  final VoidCallback onDeactivate;

  @override
  State<_OnDeactivate> createState() => _OnDeactivateState();
}

class _OnDeactivateState extends State<_OnDeactivate> {
  @override
  void deactivate() {
    super.deactivate();
    widget.onDeactivate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _PushObserver extends NavigatorObserver {
  _PushObserver(this.onPush);

  final ValueChanged<Route<dynamic>> onPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      onPush(route);
}

Future<BuildContext> _host(
  WidgetTester tester,
  _FeedbackApp app, {
  bool Function()? taskActive,
  bool reduced = false,
  NavigatorObserver? observer,
}) async {
  late BuildContext origin;
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [AppTaskNavigatorObserver(), ?observer],
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: AppTaskScope(
        owner: app,
        task: AppTask.settings,
        open: (_) {},
        child: AppTaskActivity(
          active: true,
          isActiveNow: taskActive,
          isActiveWithPopup: (_) => taskActive?.call() ?? true,
          child: Scaffold(
            body: Builder(
              builder: (context) {
                origin = context;
                return const Text('origin');
              },
            ),
          ),
        ),
      ),
    ),
  );
  return origin;
}

VoidCallback _retainSemantics(WidgetTester tester) {
  final handle = tester.ensureSemantics();
  var released = false;
  void release() {
    if (released) return;
    released = true;
    handle.dispose();
  }

  addTearDown(release);
  return release;
}

Future<void> _expectNewTaskCanAct(
  WidgetTester tester,
  BuildContext origin,
) async {
  var actions = 0;
  final route = MaterialPageRoute<void>(
    builder: (_) => Scaffold(
      body: TextButton(
        onPressed: () => actions++,
        child: const Text('new task command'),
      ),
    ),
  );
  Navigator.of(origin).push(route);
  await tester.pumpAndSettle();
  final action = find.widgetWithText(TextButton, 'new task command');
  expect(route.isCurrent, isTrue);
  expect(action.hitTestable(), findsOneWidget);
  await tester.tap(action);
  expect(actions, 1);
}

Future<void> _expandTechnicalDetails(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
  await tester.pumpAndSettle();
}

void main() {
  for (final reduced in [false, true]) {
    for (final notify in [false, true]) {
      testWidgets(
        'ownerless result retires from ${notify ? 'qualification notification' : 'cached copy'} reduced=$reduced',
        (tester) async {
          final eligibility = ValueNotifier(true);
          addTearDown(eligibility.dispose);
          var copies = 0;
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') copies++;
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          late BuildContext origin;
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [AppTaskNavigatorObserver()],
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: child!,
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    origin = context;
                    return const Text('ownerless origin');
                  },
                ),
              ),
            ),
          );
          expect(find.byType(AppTaskScope), findsNothing);
          final originElement = tester.element(find.text('ownerless origin'));
          final originRoute = ModalRoute.of(origin)!;
          final result = showLocalizedOperationMessage(
            origin,
            (_) => 'The source is no longer current.',
            technicalDetail: (_) => 'complete ownerless original',
            isCurrent: () => eligibility.value,
            isCurrentWithPopup: (_) => eligibility.value,
            eligibilityChanges: notify ? eligibility : null,
          );
          await tester.pumpAndSettle();
          await _expandTechnicalDetails(tester);
          final resultRoute = ModalRoute.of(
            tester.element(find.byType(AlertDialog)),
          )!;
          final cachedCopy = tester
              .widget<TextButton>(
                find.byKey(const ValueKey('operation-technical-copy')),
              )
              .onPressed!;
          eligibility.value = false;
          if (!notify) cachedCopy();
          eligibility.value = true;
          cachedCopy();
          await tester.idle();
          expect(copies, 0);
          await tester.pumpAndSettle();
          await result;
          expect(resultRoute.isActive, isFalse);
          expect(find.byType(AlertDialog), findsNothing);
          expect(originRoute.isCurrent, isTrue);
          expect(
            tester.element(find.text('ownerless origin')),
            same(originElement),
          );
          expect(copies, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('multiline summary is not inferred to contain technical detail', (
    tester,
  ) async {
    final app = _FeedbackApp();
    addTearDown(app.dispose);
    final origin = await _host(tester, app);
    const summary =
        'Not saved\nThe draft remains. Correct the fields and retry.';
    final result = showLocalizedOperationMessage(origin, (_) => summary);
    await tester.pumpAndSettle();
    expect(find.text(summary), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(
      find.byKey(const ValueKey('operation-technical-copy')),
      findsNothing,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await result;
    expect(find.text('origin'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'explicit technical detail expands and copies the complete original',
    (tester) async {
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
      final app = _FeedbackApp();
      addTearDown(app.dispose);
      final origin = await _host(tester, app);
      const summary = 'Saved; applying failed. Retry the application.';
      const original =
          '﻿cause\r\nunknown-field: 原文\nsuppressed: close failed\n';
      final result = showLocalizedOperationMessage(
        origin,
        (_) => summary,
        technicalDetail: (_) => original,
      );
      await tester.pumpAndSettle();
      final dialogRoute = ModalRoute.of(
        tester.element(find.byType(AlertDialog)),
      )!;
      expect(find.text(summary), findsOneWidget);
      expect(find.text(original), findsNothing);
      expect(find.text('Technical details'), findsOneWidget);
      await _expandTechnicalDetails(tester);
      expect(find.text(summary), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('operation-technical-text')),
            )
            .data,
        original,
      );
      await tester.tap(find.byKey(const ValueKey('operation-technical-copy')));
      await tester.pump();
      expect(copied, [original]);
      expect(dialogRoute.isCurrent, isTrue);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await result;
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('复制失败提示与主动详情保留原技术正文和复制内容', (tester) async {
    final failure = PlatformException(
      code: 'syntheticClipboardFailure',
      message: 'copy 原始错误\r\nsuppressed: synthetic failure',
    );
    final copies = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copies.add((call.arguments as Map)['text'] as String);
          if (copies.length == 1) throw failure;
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
    final app = _FeedbackApp();
    addTearDown(app.dispose);
    final origin = await _host(tester, app);
    final sourceRoute = ModalRoute.of(origin)!;
    final routes = <ModalRoute<dynamic>?>[];
    const original = '﻿original operation error\r\n第二行\r尾部\n';
    final result = showAppMessage(
      origin,
      messages.operationFailed.withDetail(original),
      isCurrentWithPopup: (popup) =>
          AppTaskActivity.routeIsActive(sourceRoute, ownedPopup: popup),
      onRoute: routes.add,
    );
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final owned = ModalRoute.of(tester.element(dialog))!;
    await _expandTechnicalDetails(tester);
    final originalText = find.byKey(const ValueKey('operation-technical-text'));
    final copy = find.byKey(const ValueKey('operation-technical-copy'));
    final close = find.widgetWithText(TextButton, 'Close');
    final targets = [dialog, originalText, copy, close];
    final rectangles = targets.map(tester.getRect).toList();
    final originalElement = tester.element(originalText);
    final cachedCopy = tester.widget<TextButton>(copy).onPressed!;
    await tester.tap(copy);
    for (final milliseconds in [0, 16, 100, 200]) {
      await tester.pump(Duration(milliseconds: milliseconds));
      expect(targets.map(tester.getRect).toList(), rectangles);
      expect(tester.element(originalText), same(originalElement));
      expect(tester.widget<SelectableText>(originalText).data, original);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(owned.isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpAndSettle();
    final notice = find.byType(SnackBar);
    expect(notice, findsOneWidget);
    expect(tester.widget<SnackBar>(notice).behavior, SnackBarBehavior.floating);
    expect(find.textContaining('syntheticClipboardFailure'), findsNothing);
    expect(find.textContaining('copy 原始错误'), findsNothing);
    final details = find.descendant(
      of: notice,
      matching: find.text('Error details'),
    );
    final cachedDetails = tester
        .widget<TextButton>(
          find.ancestor(of: details, matching: find.byType(TextButton)),
        )
        .onPressed!;
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNWidgets(2));
    final failureDialog = find.byType(AlertDialog).last;
    final failureRoute = ModalRoute.of(tester.element(failureDialog))!;
    expect(routes, [owned, failureRoute]);
    expect(owned.isActive, isTrue);
    expect(owned.isCurrent, isFalse);
    cachedCopy();
    await tester.pump();
    expect(copies, [original]);
    await tester.tap(
      find.descendant(
        of: failureDialog,
        matching: find.byKey(const ValueKey('operation-technical-details')),
      ),
    );
    await tester.pumpAndSettle();
    final failureText = find.descendant(
      of: failureDialog,
      matching: find.byKey(const ValueKey('operation-technical-text')),
    );
    expect(tester.widget<SelectableText>(failureText).data, failure.toString());
    expect(find.textContaining('copy 原始错误'), findsOneWidget);
    expect(
      find.textContaining('suppressed: synthetic failure'),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: failureDialog,
        matching: find.byKey(const ValueKey('operation-technical-copy')),
      ),
    );
    await tester.pumpAndSettle();
    expect(copies, [original, failure.toString()]);
    await tester.tap(
      find.descendant(
        of: failureDialog,
        matching: find.widgetWithText(TextButton, 'Close'),
      ),
    );
    await tester.pumpAndSettle();
    expect(routes, [owned, failureRoute, owned]);
    expect(owned.isCurrent, isTrue);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(targets.map(tester.getRect).toList(), rectangles);
    expect(tester.element(originalText), same(originalElement));
    expect(tester.widget<SelectableText>(originalText).data, original);
    cachedDetails();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copies, [original, failure.toString(), original]);
    await tester.tap(close);
    await tester.pumpAndSettle();
    await result;
    expect(routes, [owned, failureRoute, owned, null]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'cached technical copy cannot act for a retired owner reduced=$reduced',
      (tester) async {
        var copies = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') copies++;
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final app = _FeedbackApp();
        addTearDown(app.dispose);
        var source = true;
        final origin = await _host(tester, app, reduced: reduced);
        final result = showAppMessage(
          origin,
          messages.operationFailed.withDetail('retired original'),
          isCurrent: () => source,
          isCurrentWithPopup: (_) => source,
        );
        await tester.pumpAndSettle();
        await _expandTechnicalDetails(tester);
        final cachedCopy = tester
            .widget<TextButton>(
              find.byKey(const ValueKey('operation-technical-copy')),
            )
            .onPressed!;
        source = false;
        cachedCopy();
        await tester.idle();
        expect(copies, 0);
        app.changed();
        await tester.pumpAndSettle();
        await result;
        expect(find.byType(AlertDialog), findsNothing);
        expect(copies, 0);
        expect(find.text('origin'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'removed root retires its owned result without ancestor lookup reduced=$reduced',
      (tester) async {
        final app = _FeedbackApp();
        addTearDown(app.dispose);
        final visible = ValueNotifier(true);
        addTearDown(visible.dispose);
        var task = true;
        var deactivations = 0;
        var newActions = 0;
        late BuildContext origin;
        late ModalRoute<dynamic> originRoute;
        late VoidCallback cachedClose;
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!,
            ),
            home: ValueListenableBuilder(
              valueListenable: visible,
              builder: (context, shown, _) => shown
                  ? AppTaskScope(
                      owner: app,
                      task: AppTask.settings,
                      open: (_) {},
                      child: AppTaskActivity(
                        active: true,
                        isActiveNow: () => task,
                        isActiveWithPopup: (_) => task,
                        child: Scaffold(
                          body: Column(
                            children: [
                              Builder(
                                builder: (context) {
                                  origin = context;
                                  return const Text('old root');
                                },
                              ),
                              _OnDeactivate(
                                onDeactivate: () {
                                  deactivations++;
                                  expect(origin.mounted, isTrue);
                                  expect(
                                    (origin as Element).debugIsActive,
                                    isFalse,
                                  );
                                  expect(originRoute.isActive, isTrue);
                                  // Invoke the actual cached dialog action while
                                  // its origin is inactive, not yet unmounted.
                                  cachedClose();
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : Scaffold(
                      body: TextButton(
                        onPressed: () => newActions++,
                        child: const Text('new root action'),
                      ),
                    ),
            ),
          ),
        );
        originRoute = ModalRoute.of(origin)!;
        final rootBarriers = find.byType(ModalBarrier).evaluate().length;
        final result = showAppMessage(origin, messages.operationFailed);
        await tester.pumpAndSettle();
        final owned = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
        final entries = List<OverlayEntry>.of(owned.overlayEntries);
        cachedClose = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
            .onPressed!;
        task = false;
        visible.value = false;
        await tester.pump();
        expect(deactivations, 1);
        await tester.pump();
        expect(find.byType(AlertDialog).hitTestable(), findsNothing);
        await tester.pumpAndSettle();
        await result;
        expect(owned.isActive, isFalse);
        expect(entries.every((entry) => !entry.mounted), isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(ModalBarrier), findsNWidgets(rootBarriers));
        expect(find.byType(AnimatedModalBarrier), findsNothing);
        expect(originRoute.isCurrent, isTrue);
        cachedClose();
        final action = find.widgetWithText(TextButton, 'new root action');
        expect(action.hitTestable(), findsOneWidget);
        await tester.tap(action);
        expect(newActions, 1);
        expect(originRoute.isCurrent, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'explicit qualification retires during synchronous push notification reduced=$reduced',
      (tester) async {
        final app = _FeedbackApp();
        final eligibility = ValueNotifier(true);
        addTearDown(app.dispose);
        addTearDown(eligibility.dispose);
        final bindings = <ModalRoute<dynamic>?>[];
        final pushed = Completer<void>();
        ModalRoute<dynamic>? feedback;
        var watchingPush = false;
        var qualificationChecks = 0;
        final origin = await _host(
          tester,
          app,
          reduced: reduced,
          observer: _PushObserver((route) {
            if (!watchingPush) return;
            expect(feedback, same(route));
            eligibility.value = false;
            eligibility.value = true;
            pushed.complete();
          }),
        );
        final originRoute = ModalRoute.of(origin)!;
        watchingPush = true;
        final result = showLocalizedOperationMessage(
          origin,
          (_) => 'The source retired during push.',
          technicalDetail: (_) => 'complete synchronous original',
          eligibilityChanges: eligibility,
          isCurrent: () => eligibility.value,
          isCurrentWithPopup: (popup) {
            qualificationChecks++;
            expect(feedback, same(popup));
            return eligibility.value;
          },
          onRoute: (route) {
            feedback = route;
            bindings.add(route);
            if (route != null) expect(route.navigator, isNull);
          },
        );
        await pushed.future;
        final actual = feedback!;
        expect(qualificationChecks, 2);
        expect(actual.isCurrent, isTrue);
        expect(eligibility.value, isTrue);
        await tester.pumpAndSettle();
        await result;
        expect(bindings, [actual, null]);
        expect(actual.isActive, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        expect(originRoute.isCurrent, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'owned route is bound before synchronous push notification reduced=$reduced',
      (tester) async {
        final app = _FeedbackApp();
        addTearDown(app.dispose);
        final bindings = <ModalRoute<dynamic>?>[];
        final pushed = Completer<void>();
        ModalRoute<dynamic>? feedback;
        var watchingPush = false;
        var builderChecks = 0;
        var ownerNotifications = 0;
        var retired = false;
        final origin = await _host(
          tester,
          app,
          reduced: reduced,
          observer: _PushObserver((route) {
            if (!watchingPush) return;
            expect(builderChecks, 0);
            expect(feedback, same(route));
            app.changed();
            pushed.complete();
          }),
        );
        late BuildContext ownerContext;
        final popupTheme = Theme.of(origin).copyWith(
          dialogTheme: const DialogThemeData(barrierColor: Color(0x66334455)),
        );
        final ownerRoute = DialogRoute<void>(
          context: origin,
          builder: (_) => Theme(
            data: popupTheme,
            child: AppTaskScope(
              owner: app,
              task: AppTask.settings,
              open: (_) {},
              child: Builder(
                builder: (context) {
                  ownerContext = context;
                  return const AlertDialog(content: Text('owner popup'));
                },
              ),
            ),
          ),
        );
        Navigator.of(origin).push(ownerRoute);
        await tester.pumpAndSettle();
        void ownerChanged() {
          ownerNotifications++;
          if (!AppTaskActivity.routeIsActive(
            ownerRoute,
            ownedPopup: feedback,
          )) {
            retired = true;
          }
        }

        app.addListener(ownerChanged);
        addTearDown(() => app.removeListener(ownerChanged));
        watchingPush = true;
        final result = showAppMessage(
          ownerContext,
          messages.operationFailed.withDetail('synchronous owner result'),
          isCurrent: () => !retired && ownerRoute.isCurrent,
          isCurrentWithPopup: (popup) {
            builderChecks++;
            expect(feedback, same(popup));
            return !retired &&
                AppTaskActivity.routeIsActive(ownerRoute, ownedPopup: popup);
          },
          onRoute: (route) {
            feedback = route;
            bindings.add(route);
            if (route != null) expect(route.navigator, isNull);
          },
        );
        // Await only the synchronous push notification, before any frame builds.
        await pushed.future;
        final actual = feedback!;
        expect(builderChecks, 0);
        expect(ownerNotifications, 1);
        expect(retired, isFalse);
        expect(actual, isA<DialogRoute<void>>());
        expect(actual.isCurrent, isTrue);
        expect(ownerRoute.isActive, isTrue);
        expect(ownerRoute.isCurrent, isFalse);
        expect(
          actual.navigator,
          same(Navigator.of(origin, rootNavigator: true)),
        );
        expect(actual.barrierColor, popupTheme.dialogTheme.barrierColor);
        expect(actual.barrierDismissible, isTrue);
        expect(actual.traversalEdgeBehavior, TraversalEdgeBehavior.closedLoop);
        expect(
          actual.transitionDuration.inMicroseconds,
          reduced ? 0 : greaterThan(0),
        );
        await tester.pumpAndSettle();
        expect(builderChecks, greaterThan(0));
        expect(retired, isFalse);
        expect(find.text('owner popup'), findsOneWidget);
        expect(find.textContaining('synchronous owner result'), findsNothing);
        await _expandTechnicalDetails(tester);
        expect(find.textContaining('synchronous owner result'), findsOneWidget);
        final close = find.widgetWithText(TextButton, 'Close');
        expect(close.hitTestable(), findsOneWidget);
        expect(
          Theme.of(tester.element(close)).dialogTheme.barrierColor,
          popupTheme.dialogTheme.barrierColor,
        );
        watchingPush = false;
        await tester.tap(close);
        await tester.pumpAndSettle();
        await result;
        expect(bindings, [same(actual), isNull]);
        expect(feedback, isNull);
        expect(ownerRoute.isCurrent, isTrue);
        expect(find.text('owner popup'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('a retired source cannot wait and later open a result', (
    tester,
  ) async {
    final app = _FeedbackApp()..setInteractive(false);
    addTearDown(app.dispose);
    final origin = await _host(tester, app);
    await showAppMessage(
      origin,
      messages.operationFailed.withDetail('retired result'),
      isCurrent: () => false,
    );
    app.setInteractive(true);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final invalidation in ['source', 'task', 'route']) {
    testWidgets('interactive wait rechecks live $invalidation before a frame', (
      tester,
    ) async {
      final app = _FeedbackApp()..setInteractive(false);
      addTearDown(app.dispose);
      var source = true;
      var task = true;
      final origin = await _host(tester, app, taskActive: () => task);
      final result = showAppMessage(
        origin,
        messages.operationFailed.withDetail('late result'),
        isCurrent: () => source,
      );
      switch (invalidation) {
        case 'source':
          source = false;
        case 'task':
          task = false;
        case 'route':
          Navigator.of(origin).push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('cover')),
            ),
          );
          expect(ModalRoute.of(origin)!.isActive, isTrue);
          expect(ModalRoute.of(origin)!.isCurrent, isFalse);
      }
      app.setInteractive(true);
      await result;
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final invalidation in ['source', 'task', 'interactive']) {
    testWidgets(
      'an owned result loses actions, focus and semantics on $invalidation exit',
      (tester) async {
        final app = _FeedbackApp();
        addTearDown(app.dispose);
        final releaseSemantics = _retainSemantics(tester);
        try {
          var source = true;
          var task = true;
          final origin = await _host(tester, app, taskActive: () => task);
          final originRoute = ModalRoute.of(origin)!;
          // PageRoute retains its own transparent barrier under its contents.
          final rootBarriers = find.byType(ModalBarrier).evaluate().length;
          final rootAnimatedBarriers = find
              .byType(AnimatedModalBarrier)
              .evaluate()
              .length;
          ModalRoute<dynamic>? owned;
          final result = showAppMessage(
            origin,
            messages.operationFailed.withDetail('cause and suppressed: 原始错误'),
            isCurrent: () => source && originRoute.isCurrent,
            isCurrentWithPopup: (popup) {
              owned = popup;
              return source &&
                  AppTaskActivity.routeIsActive(originRoute, ownedPopup: popup);
            },
          );
          await tester.pumpAndSettle();
          final close = find.widgetWithText(TextButton, 'Close');
          expect(close.hitTestable(), findsOneWidget);
          expect(owned, isNotNull);
          expect(owned!.isCurrent, isTrue);
          final ownedEntries = List<OverlayEntry>.of(owned!.overlayEntries);
          expect(ownedEntries, isNotEmpty);
          expect(
            find.byType(AnimatedModalBarrier),
            findsNWidgets(rootAnimatedBarriers + 1),
          );
          expect(originRoute.isCurrent, isFalse);
          expect(
            find.textContaining('cause and suppressed: 原始错误'),
            findsNothing,
          );
          await _expandTechnicalDetails(tester);
          expect(
            find.textContaining('cause and suppressed: 原始错误'),
            findsOneWidget,
          );
          final cachedClose = tester.widget<TextButton>(close).onPressed!;
          switch (invalidation) {
            case 'source':
              source = false;
              app.changed();
            case 'task':
              task = false;
              app.changed();
            case 'interactive':
              app.setInteractive(false);
          }
          // A cached callback reads the live owner before any rebuild.
          cachedClose();
          expect(owned!.isCurrent, isTrue);
          await tester.pump();
          expect(close.hitTestable(), findsNothing);
          expect(
            tester.semantics.simulatedAccessibilityTraversal().map(
              (node) => node.getSemanticsData().label,
            ),
            isNot(contains('Close')),
          );
          expect(
            tester
                .widgetList<ExcludeFocus>(
                  find.ancestor(of: close, matching: find.byType(ExcludeFocus)),
                )
                .any((widget) => widget.excluding),
            isTrue,
          );
          await tester.pumpAndSettle();
          await result;
          expect(find.byType(AlertDialog), findsNothing);
          expect(owned!.isActive, isFalse);
          expect(ownedEntries.every((entry) => !entry.mounted), isTrue);
          expect(find.byType(ModalBarrier), findsNWidgets(rootBarriers));
          expect(
            find.byType(AnimatedModalBarrier),
            findsNWidgets(rootAnimatedBarriers),
          );
          expect(originRoute.isCurrent, isTrue);
          expect(find.text('origin'), findsOneWidget);
          app.setInteractive(true);
          await _expectNewTaskCanAct(tester, origin);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          releaseSemantics();
        }
      },
    );
  }

  testWidgets(
    'restored qualification cannot revive a retired result before its deferred removal',
    (tester) async {
      final app = _FeedbackApp();
      addTearDown(app.dispose);
      final origin = await _host(tester, app);
      final originRoute = ModalRoute.of(origin)!;
      final rootBarriers = find.byType(ModalBarrier).evaluate().length;
      final rootAnimatedBarriers = find
          .byType(AnimatedModalBarrier)
          .evaluate()
          .length;
      var source = true;
      final result = showAppMessage(
        origin,
        messages.operationFailed,
        isCurrent: () => source,
        isCurrentWithPopup: (_) => source,
      );
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final route = ModalRoute.of(tester.element(dialog))!;
      final ownedEntries = List<OverlayEntry>.of(route.overlayEntries);
      expect(ownedEntries, isNotEmpty);
      expect(
        find.byType(AnimatedModalBarrier),
        findsNWidgets(rootAnimatedBarriers + 1),
      );
      final cachedClose = tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
          .onPressed!;
      source = false;
      cachedClose();
      source = true;
      cachedClose();
      // No resumed action may close it synchronously or rescue it from retirement.
      expect(route.isCurrent, isTrue);
      await tester.pumpAndSettle();
      await result;
      expect(dialog, findsNothing);
      expect(route.isActive, isFalse);
      expect(ownedEntries.every((entry) => !entry.mounted), isTrue);
      expect(find.byType(ModalBarrier), findsNWidgets(rootBarriers));
      expect(
        find.byType(AnimatedModalBarrier),
        findsNWidgets(rootAnimatedBarriers),
      );
      expect(originRoute.isCurrent, isTrue);
      expect(find.text('origin'), findsOneWidget);
      await _expectNewTaskCanAct(tester, origin);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('retiring an obscured result removes only its own barrier', (
    tester,
  ) async {
    final app = _FeedbackApp();
    addTearDown(app.dispose);
    final origin = await _host(tester, app);
    final result = showAppMessage(origin, messages.operationFailed);
    await tester.pumpAndSettle();
    final owned = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
    final ownedEntries = List<OverlayEntry>.of(owned.overlayEntries);
    expect(ownedEntries, isNotEmpty);
    final cachedClose = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Close'))
        .onPressed!;
    var actions = 0;
    final cover = MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: TextButton(
          onPressed: () => actions++,
          child: const Text('new page'),
        ),
      ),
    );
    Navigator.of(origin).push(cover);
    cachedClose();
    expect(cover.isCurrent, isTrue);
    await tester.pumpAndSettle();
    await result;
    expect(cover.isCurrent, isTrue);
    expect(find.text('new page'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(owned.isActive, isFalse);
    expect(ownedEntries.every((entry) => !entry.mounted), isTrue);
    final action = find.widgetWithText(TextButton, 'new page');
    expect(action.hitTestable(), findsOneWidget);
    await tester.tap(action);
    expect(actions, 1);
    expect(cover.isCurrent, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'SDK result transition preserves original error and retires on reverse reduced=$reduced',
      (tester) async {
        final app = _FeedbackApp();
        addTearDown(app.dispose);
        final releaseSemantics = _retainSemantics(tester);
        try {
          final origin = await _host(tester, app, reduced: reduced);
          final result = showAppMessage(
            origin,
            messages.operationFailed.withDetail('cause\nsuppressed 原文'),
          );
          await tester.pump();
          final dialog = find.byType(AlertDialog);
          final route = ModalRoute.of(tester.element(dialog))!;
          final animation = route.animation!;
          if (reduced) {
            expect(animation.value, 1);
          } else {
            await tester.pump(const Duration(milliseconds: 40));
            expect(animation.value, inExclusiveRange(0, 1));
            await tester.pumpAndSettle();
          }
          expect(find.textContaining('cause\nsuppressed 原文'), findsNothing);
          await _expandTechnicalDetails(tester);
          expect(find.textContaining('cause\nsuppressed 原文'), findsOneWidget);
          final close = find.widgetWithText(TextButton, 'Close');
          final cachedClose = tester.widget<TextButton>(close).onPressed!;
          Navigator.of(tester.element(dialog)).pop();
          cachedClose();
          await tester.pump();
          if (!reduced) {
            expect(dialog, findsOneWidget);
            expect(dialog.hitTestable(), findsNothing);
            expect(animation.status, AnimationStatus.reverse);
            expect(
              tester.semantics.simulatedAccessibilityTraversal().map(
                (node) => node.getSemanticsData().label,
              ),
              isNot(contains('Close')),
            );
          }
          await tester.pumpAndSettle();
          await result;
          expect(find.text('origin'), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          releaseSemantics();
        }
      },
    );
  }
}
