import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/diagnostics/dns/dns_tool.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/config_field_dialog.dart';
import 'package:clash_pseudo/src/ui/overrides/overrides_page.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../diagnostics/dns/dns_fakes.dart';

import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    DnsTestApp app, {
    String language = 'en',
    double scale = 1,
    Size size = const Size(320, 900),
    ValueNotifier<(String, double, bool)>? presentation,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final observer = AppTaskNavigatorObserver();
    Widget application((String, double, bool) value) => MaterialApp(
      navigatorObservers: [observer],
      theme: AppTheme.light,
      locale: Locale(value.$1),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(value.$2),
          disableAnimations: value.$3,
        ),
        child: child!,
      ),
      home: SettingsPage(app: app),
    );
    await tester.pumpWidget(
      presentation == null
          ? application((language, scale, false))
          : ValueListenableBuilder(
              valueListenable: presentation,
              builder: (_, value, _) => application(value),
            ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, String text) async {
    await tester.scrollUntilVisible(
      find.text(text),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'settings supplies task activity to plugins without treating their own dialog as exit',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 900);
      addTearDown(tester.view.reset);
      final app = DnsTestApp(DnsTestBridge())..overridesLoaded = true;
      addTearDown(app.dispose);
      final task = ValueNotifier(AppTask.settings);
      addTearDown(task.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          theme: AppTheme.light,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => ValueListenableBuilder(
            valueListenable: task,
            child: child,
            builder: (context, selected, child) => AppTaskScope(
              owner: app,
              task: selected,
              open: (value) => task.value = value,
              child: child!,
            ),
          ),
          home: Builder(
            // Reproduce the shell's root-current snapshot becoming false when a
            // Settings child page is pushed. It is not the child's task activity.
            builder: (context) => SettingsPage(
              app: app,
              active: ModalRoute.isCurrentOf(context) ?? true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      await reveal(tester, strings.overridePlugins);
      await tester.tap(find.widgetWithText(ListTile, strings.overridePlugins));
      await tester.pumpAndSettle();
      final page = find.byType(OverridesPage);
      expect(tester.widget<OverridesPage>(page).active, isTrue);
      final state = tester.state(page);
      await tester.tap(find.byTooltip(strings.addOverride));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(MenuItemButton, strings.newOverride),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfigFieldDialog), findsOneWidget);
      expect(tester.widget<OverridesPage>(page).active, isTrue);
      expect(tester.state(page), same(state));
      app.publish();
      await tester.pumpAndSettle();
      expect(tester.widget<OverridesPage>(page).active, isTrue);
      task.value = AppTask.overview;
      await tester.pump();
      expect(tester.widget<OverridesPage>(page).active, isFalse);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cached settings entries cannot navigate or open DNS for an exiting task',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final semantics = tester.ensureSemantics();
      var released = false;
      void releaseSemantics() {
        if (released) return;
        released = true;
        semantics.dispose();
      }

      addTearDown(releaseSemantics);
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            theme: AppTheme.light,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ValueListenableBuilder(
              valueListenable: active,
              builder: (context, value, _) => AppTaskActivity(
                active: value,
                isActiveNow: () => active.value,
                child: SettingsPage(app: app),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final strings = lookupAppLocalizations(const Locale('en'));
        await reveal(tester, strings.overridePlugins);
        final openPage = tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, strings.overridePlugins),
            )
            .onTap!;
        await reveal(tester, strings.dnsTools);
        final openDns = tester
            .widget<ListTile>(find.widgetWithText(ListTile, strings.dnsTools))
            .onTap!;
        active.value = false;
        openPage();
        openDns();
        await tester.pumpAndSettle();
        expect(find.byType(OverridesPage), findsNothing);
        expect(find.byType(DnsTool), findsNothing);
        expect(find.byType(SettingsPage).hitTestable(), findsNothing);
        expect(
          tester.semantics.simulatedAccessibilityTraversal().map(
            (node) => node.getSemanticsData().label,
          ),
          isNot(contains(strings.dnsTools)),
        );
        expect(app.commands, isEmpty);
        expect(bridge.queries, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        releaseSemantics();
      }
    },
  );

  testWidgets(
    'settings keeps grouped identities through continuous layout reversals and reduced motion',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final presentation = ValueNotifier(('en', 1.0, false));
      addTearDown(presentation.dispose);
      await show(
        tester,
        app,
        size: const Size(1200, 900),
        presentation: presentation,
      );
      Finder section(int index) =>
          find.byKey(ValueKey('settings-section:$index'));
      Rect rect(int index) => tester.getRect(section(index));
      double height(int index) => tester
          .getSize(
            find
                .ancestor(
                  of: section(index),
                  matching: find.byType(IndexedSemantics),
                )
                .first,
          )
          .height;
      final settings = tester.state(find.byType(SettingsPage));
      final language = find.ancestor(
        of: find.byIcon(Icons.translate_rounded),
        matching: find.byType(ChoiceMenuButton<String>),
      );
      final choice = tester.state(language);
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final pixels = scroll.position.pixels;
      final wide = [rect(0), rect(1)];
      expect(wide[1].left, greaterThan(wide[0].right));
      expect(wide[1].top, wide[0].top);
      tester.view.physicalSize = const Size(700, 900);
      await tester.pump();
      expect(rect(0).width, closeTo(wide[0].width, .01));
      expect((rect(1).topLeft - wide[1].topLeft).distance, lessThan(.01));
      await tester.pump(const Duration(milliseconds: 60));
      final middle = [rect(0), rect(1)];
      expect(middle[0].width, inExclusiveRange(wide[0].width, 700));
      expect(middle[1].left, inExclusiveRange(0, wide[1].left));
      expect(
        find
            .byKey(const ValueKey('settings-mode'))
            .hitTestable(at: const Alignment(-.8, 0)),
        findsNothing,
      );
      expect(language.hitTestable(), findsNothing);
      tester.view.physicalSize = const Size(1200, 900);
      await tester.pump();
      expect(rect(0).width, closeTo(middle[0].width, .01));
      expect((rect(1).topLeft - middle[1].topLeft).distance, lessThan(.01));
      await tester.pump(const Duration(milliseconds: 40));
      expect(rect(0).width, lessThan(middle[0].width));
      tester.view.physicalSize = const Size(700, 900);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(rect(0).width, 700);
      expect(rect(1).left, rect(0).left);
      expect(rect(1).top, greaterThanOrEqualTo(rect(0).bottom));
      final beforeText = height(0);
      presentation.value = ('zh', 2.0, false);
      await tester.pump();
      expect(height(0), closeTo(beforeText, .01));
      await tester.pump(const Duration(milliseconds: 60));
      final middleHeight = height(0);
      expect(middleHeight, greaterThan(beforeText));
      await tester.pumpAndSettle();
      expect(height(0), greaterThan(middleHeight));
      presentation.value = ('en', 1.0, true);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.padding = const FakeViewPadding(left: 12, right: 20);
      await tester.pump();
      expect(rect(0).width, 572);
      expect(rect(1).left, greaterThan(rect(0).right));
      expect(height(0), closeTo(wide[0].height, .01));
      expect(tester.state(find.byType(SettingsPage)), same(settings));
      expect(tester.state(language), same(choice));
      expect(language.hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-mode')).hitTestable(),
        findsOneWidget,
      );
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller,
        same(controller),
      );
      expect(scroll.position.pixels, pixels);
      expect(find.byType(CollectionWorkspace), findsNothing);
      expect(app.commands, isEmpty);
      expect(bridge.queries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('settings scrolling stays direct while groups are relocating', (
    tester,
  ) async {
    final app = DnsTestApp(DnsTestBridge());
    addTearDown(app.dispose);
    await show(tester, app, size: const Size(900, 479));
    tester.view.physicalSize = const Size(700, 479);
    await tester.pump();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final before = scroll.position.pixels;
    final gesture = await tester.startGesture(const Offset(8, 280));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 10));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 10));
    expect(scroll.position.pixels, greaterThan(before));
    expect(
      find.byKey(const ValueKey('settings-mode')).hitTestable(),
      findsNothing,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final scene in [
    (const Size(320, 900), 'en', 2.0),
    (const Size(700, 479), 'zh', 2.0),
    (const Size(1704, 1136), 'en', 1.0),
    (const Size(900, 900), 'zh', 1.0),
  ]) {
    testWidgets('DNS dialog leaves settings groups unchanged $scene', (
      tester,
    ) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final strings = lookupAppLocalizations(Locale(scene.$2));
      await show(
        tester,
        app,
        size: scene.$1,
        language: scene.$2,
        scale: scene.$3,
      );
      await reveal(tester, strings.dnsTools);
      final groups = {
        for (var i = 0; i < 7; i++)
          if (find.byKey(ValueKey('settings-section:$i')).evaluate().isNotEmpty)
            i: tester.getRect(find.byKey(ValueKey('settings-section:$i'))),
      };
      expect(groups, contains(4));
      final page = tester.state(find.byType(SettingsPage));
      void unchanged() {
        for (final group in groups.entries) {
          expect(
            tester.getRect(
              find.byKey(ValueKey('settings-section:${group.key}')),
            ),
            group.value,
          );
        }
        expect(tester.state(find.byType(SettingsPage)), same(page));
        expect(find.byType(CollectionWorkspace), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(app.commands, isEmpty);
        expect(bridge.queries, isEmpty);
        expect(tester.takeException(), isNull);
      }

      await tester.tap(find.text(strings.dnsTools));
      for (final ms in [0, 40, 80, 200]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(find.byType(DnsTool), findsOneWidget);
        expect(find.byType(Dialog), findsOneWidget);
        unchanged();
      }
      await tester.binding.handlePopRoute();
      for (final ms in [0, 40, 80, 200]) {
        await tester.pump(Duration(milliseconds: ms));
        unchanged();
      }
      expect(find.byType(DnsTool), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'settings opens no core and retains DNS session input across visits',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      await show(tester, app);
      expect(app.commands, isEmpty);
      expect(bridge.queries, isEmpty);
      await reveal(tester, 'DNS tools');
      await tester.tap(find.text('DNS tools'));
      await tester.pumpAndSettle();
      expect(find.byType(DnsTool), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'session.example.test',
      );
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await reveal(tester, 'DNS tools');
      await tester.tap(find.text('DNS tools'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'session.example.test',
      );
      expect(bridge.queries, isEmpty);
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'settings groups configuration, routing and tools without redundant system-add actions $language $scale',
        (tester) async {
          final bridge = DnsTestBridge();
          final app = DnsTestApp(bridge);
          addTearDown(app.dispose);
          final strings = lookupAppLocalizations(Locale(language));
          await show(tester, app, language: language, scale: scale);
          final expected = [
            strings.appearanceAndLanguage,
            strings.appearance,
            strings.brandColor,
            strings.language,
            strings.connectionBehavior,
            strings.modeTitle,
            strings.reconnectOnRoutingChange,
            strings.configurationsAndData,
            strings.configurations,
            strings.overridePlugins,
            strings.runtimeConfiguration,
            strings.storageData,
            strings.routingAndResources,
            strings.proxyNodes,
            strings.allStrategyGroups,
            strings.rules,
            strings.externalResources,
            strings.diagnosticTools,
            strings.recentConnections,
            strings.coreLogs,
            strings.dnsTools,
            strings.androidSection,
            strings.applicationAccess,
            strings.alwaysOnTitle,
            strings.about,
          ];
          final labels = <String>[];
          final seenText = <String>{};
          var previousY = double.negativeInfinity;
          for (final label in expected) {
            await reveal(tester, label);
            final text = find.text(label);
            final position = tester
                .state<ScrollableState>(find.byType(Scrollable).first)
                .position;
            final rect = tester.getRect(text);
            expect(
              rect.overlaps(tester.getRect(find.byType(Scrollable).first)),
              isTrue,
            );
            final y = rect.top + position.pixels;
            expect(y, greaterThan(previousY));
            previousY = y;
            labels.add(tester.widget<Text>(text).data!);
            seenText.addAll(
              tester
                  .widgetList<Text>(
                    find.descendant(
                      of: find.byType(SettingsPage),
                      matching: find.byType(Text),
                    ),
                  )
                  .map((text) => text.data)
                  .whereType<String>(),
            );
          }
          expect(labels, expected);
          for (final obsolete in const [
            'Add Quick Settings tile',
            'Add home-screen widget',
            '添加快捷设置磁贴',
            '添加桌面小组件',
          ]) {
            expect(seenText, isNot(contains(obsolete)));
          }
          await reveal(tester, strings.about);
          expect(tester.takeException(), isNull);
          expect(app.commands, isEmpty);
          expect(bridge.queries, isEmpty);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
