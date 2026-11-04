import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/feedback/confirm_action.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final departure in ['task', 'page', 'origin']) {
    testWidgets(
      'confirmation cached buttons cannot dismiss after structural departure $departure',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        var active = true;
        var sourceCurrent = true;
        bool? answer;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [AppTaskNavigatorObserver()],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) => AppTaskActivity(
              active: true,
              isActiveNow: () => active,
              isActiveWithPopup: (_) => active,
              child: child!,
            ),
            home: const Scaffold(body: Text('Root')),
          ),
        );
        final owner = FocusedPageRoute<void>(
          builder: (_) => Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  answer = await confirmAction(
                    context,
                    title: (strings) => strings.deleteConfigTitle,
                    message: (strings) => strings.deleteLocalBody,
                    confirmLabel: (strings) => strings.delete,
                    isCurrent: () => sourceCurrent,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        );
        navigator.currentState!.push(owner);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        final popup = ModalRoute.of(tester.element(dialog))!;
        final confirm = tester
            .widget<FilledButton>(
              find.descendant(of: dialog, matching: find.byType(FilledButton)),
            )
            .onPressed!;
        final cancel = tester
            .widget<TextButton>(
              find.descendant(of: dialog, matching: find.byType(TextButton)),
            )
            .onPressed!;
        final replacement = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Replacement')),
        );
        sourceCurrent = false;
        if (departure == 'task') {
          active = false;
        } else if (departure == 'page') {
          navigator.currentState!.push(replacement);
        } else {
          navigator.currentState!.removeRoute(owner);
        }
        for (final frame in [Duration.zero, const Duration(milliseconds: 16)]) {
          confirm();
          cancel();
          expect(popup.isActive, isTrue);
          expect(answer, isNull);
          expect(owner.isActive, departure != 'origin');
          if (departure == 'page') {
            expect(replacement.isActive, isTrue);
            expect(replacement.isCurrent, isTrue);
          } else {
            expect(popup.isCurrent, isTrue);
          }
          await tester.pump(frame);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'confirmation publishes its route once across dependency and popped reverse rebuilds',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final observer = AppTaskNavigatorObserver();
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(locale.dispose);
      final published = <ModalRoute<dynamic>?>[];
      ModalRoute<dynamic>? ownedPopup;
      var builds = 0;
      bool? answer;
      await tester.pumpWidget(
        ValueListenableBuilder<Locale>(
          valueListenable: locale,
          builder: (_, language, _) => MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [observer],
            locale: language,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    answer = await confirmAction(
                      context,
                      title: (strings) {
                        builds++;
                        return strings.deleteConfigTitle;
                      },
                      message: (strings) => strings.deleteLocalBody,
                      confirmLabel: (strings) => strings.delete,
                      onRoute: (route) {
                        ownedPopup = route;
                        published.add(route);
                      },
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      final owner = ModalRoute.of(tester.element(find.text('Open')))!;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final popup = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
      expect(published, [same(popup)]);
      final beforeLocale = builds;
      locale.value = const Locale('zh');
      await tester.pumpAndSettle();
      expect(builds, greaterThan(beforeLocale));
      expect(published, [same(popup)]);
      navigator.currentState!.pop(false);
      await tester.pump();
      expect(answer, isFalse);
      expect(popup.animation!.status, AnimationStatus.reverse);
      expect(published, [same(popup), isNull]);
      expect(ownedPopup, isNull);
      expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
      final beforeReverse = builds;
      locale.value = const Locale('en');
      await tester.pump(const Duration(milliseconds: 16));
      expect(builds, greaterThan(beforeReverse));
      expect(popup.animation!.status, AnimationStatus.reverse);
      expect(published, [same(popup), isNull]);
      expect(ownedPopup, isNull);
      expect(
        AppTaskActivity.routeIsActive(owner, ownedPopup: ownedPopup),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(published, [same(popup), isNull]);
      expect(ownedPopup, isNull);
      expect(owner.isCurrent, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final accept in [false, true]) {
    testWidgets(
      'owned confirmation permits itself but retires cached callbacks accept=$accept',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        ModalRoute<dynamic>? popup;
        bool? answer;
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            navigatorKey: navigator,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Text('Root')),
          ),
        );
        navigator.currentState!.push<void>(
          FocusedPageRoute(
            builder: (_) => Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    answer = await confirmAction(
                      context,
                      title: (strings) => strings.deleteConfigTitle,
                      message: (strings) => strings.deleteLocalBody,
                      confirmLabel: (strings) => strings.delete,
                      onRoute: (route) => popup = route,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final owner = ModalRoute.of(tester.element(find.text('Open')))!;
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(owner.isCurrent, isFalse);
        expect(popup!.isCurrent, isTrue);
        final cached = tester
            .widget<FilledButton>(find.byType(FilledButton))
            .onPressed!;
        final cachedCancel = tester
            .widget<TextButton>(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(TextButton),
              ),
            )
            .onPressed!;
        if (accept) {
          cached();
        } else {
          navigator.currentState!.pop(false);
        }
        // Before the next frame the old closures have already lost their Route.
        cached();
        cachedCancel();
        expect(owner.isActive, isTrue);
        expect(owner.isCurrent, isTrue);
        await tester.pump(const Duration(milliseconds: 16));
        cached();
        cachedCancel();
        expect(owner.isActive, isTrue);
        expect(owner.isCurrent, isTrue);
        final dialog = find.byType(AlertDialog, skipOffstage: false);
        if (dialog.evaluate().isNotEmpty) {
          expect(
            tester
                .widgetList<IgnorePointer>(
                  find.ancestor(
                    of: dialog,
                    matching: find.byType(IgnorePointer),
                  ),
                )
                .any((widget) => widget.ignoring),
            isTrue,
          );
          expect(
            tester
                .widgetList<ExcludeFocus>(
                  find.ancestor(
                    of: dialog,
                    matching: find.byType(ExcludeFocus),
                  ),
                )
                .any((widget) => widget.excluding),
            isTrue,
          );
          expect(
            tester
                .widgetList<ExcludeSemantics>(
                  find.ancestor(
                    of: dialog,
                    matching: find.byType(ExcludeSemantics),
                  ),
                )
                .any((widget) => widget.excluding),
            isTrue,
          );
        }
        await tester.pumpAndSettle();
        expect(answer, accept);
        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Root'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('confirmation long object scrolls dark=$dark scale=$scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final subject = '长配置名称与English🌐' * 12;
        bool? accepted;
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            theme: dark ? AppTheme.dark : AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: const EdgeInsets.only(bottom: 100),
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    accepted = await confirmAction(
                      context,
                      title: (strings) => strings.deleteConfigTitle,
                      subject: subject,
                      message: (strings) => strings.deleteLocalBody,
                      confirmLabel: (strings) => strings.delete,
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
        expect((dialog.title! as Text).data, '删除配置？');
        expect(find.text(subject), findsOneWidget);
        expect(tester.takeException(), isNull);
        final button = find.widgetWithText(FilledButton, '删除');
        final rect = tester.getRect(button);
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -1200),
        );
        for (var i = 0; i < 14; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.getRect(button), rect);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(accepted, isTrue);
      });
    }
  }
}
