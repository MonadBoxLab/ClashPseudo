import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';

import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/import_dialog.dart';
import 'package:re_editor/re_editor.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/overrides/overrides_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_test/flutter_test.dart';

Finder _noticeText(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Future<void> _dismissNotice(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final notice = find.byType(SnackBar);
  expect(notice, findsOneWidget);
  await tester.tap(
    find.descendant(of: notice, matching: find.byIcon(Icons.close)),
  );
  await tester.pumpAndSettle();
}

class _FormReceiptBridge extends AppBridge {
  late OverridePageApp app;

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    app.commands.add(command);
    final current = app;
    if (current is _EpochPageApp && command['storageEpoch'] != current.epoch) {
      throw PlatformFailure(
        code: 'storage',
        details: messages.storageContextChanged.toMap(),
      );
    }
    if (current is _EpochPageApp) current.accepted++;
    if (!app.submitStarted.isCompleted) app.submitStarted.complete();
    final pending = app.pendingSubmit;
    final id = pending == null ? 'operation' : await pending.future;
    return id == null
        ? null
        : OperationAdmission(
            operationId: id,
            remaining: const Duration(seconds: 120),
          );
  }
}

class OverridePageApp extends AppController {
  OverridePageApp() : super(_FormReceiptBridge()) {
    (platform as _FormReceiptBridge).app = this;
    loading = false;
    configsLoaded = true;
    overridesLoaded = true;
    state = const AppSnapshot(phase: 'STOPPED');
  }

  final commands = <Map<String, Object?>>[];
  final saveResults = <AppSnapshot>[];
  Completer<String?>? pendingSubmit;
  final submitStarted = Completer<void>();
  int refreshCalls = 0;
  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  void changed() => notifyListeners();
  bool editable = true;
  @override
  bool get canEdit => editable;

  @override
  Future<AppSnapshot?> saveOverride(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    commands.add({'action': 'saveOverride', ...command});
    if (saveResults.isNotEmpty) return saveResults.removeAt(0);
    return const AppSnapshot(
      phase: 'STOPPED',
      resultId: 'operation',
      resultSuccess: true,
      overrideStatus: 'saved',
      targetId: 'imported',
      savedRevision: 1,
    );
  }

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(command);
    if (!submitStarted.isCompleted) submitStarted.complete();
    final pending = pendingSubmit;
    if (pending != null) return pending.future;
    return 'operation';
  }
}

class _EpochPageApp extends OverridePageApp {
  _EpochPageApp() {
    state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 41);
  }

  int epoch = 41;
  int accepted = 0;
  @override
  int get storageEpoch => epoch;
  @override
  bool get overridesCurrent =>
      overridesLoaded &&
      state.storageReady &&
      !state.storageRestoring &&
      state.storageEpoch == epoch &&
      overrideErrorMessage == null;

  void restoreSameIdentity(String body) {
    overrides = [
      for (final entry in overrides)
        OverrideEntry.fromJson({...entry.toJson(), 'body': body}),
    ];
    epoch++;
    state = AppSnapshot(phase: 'STOPPED', storageEpoch: epoch);
    changed();
  }

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    final submitted = Map<String, Object?>.of(command);
    commands.add(submitted);
    lastCommand = submitted;
    lastCommandAutomatic = automatic;
    if (command['storageEpoch'] != epoch) {
      commandErrorMessage = messages.storageContextChanged;
      changed();
      return null;
    }
    accepted++;
    commandErrorMessage = null;
    changed();
    if (!submitStarted.isCompleted) submitStarted.complete();
    final pending = pendingSubmit;
    if (pending != null) return pending.future;
    return 'accepted-receipt';
  }

  @override
  Future<AppSnapshot?> saveOverride(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    if (command['storageEpoch'] != epoch) {
      commands.add({'action': 'saveOverride', ...command});
      commandErrorMessage = messages.storageContextChanged;
      return null;
    }
    final result = await super.saveOverride(
      command,
      feedbackOwner: feedbackOwner,
    );
    if (result?.targetId != null &&
        result?.savedRevision != null &&
        const [
          'saved',
          'applied',
          'applyFailed',
        ].contains(result?.overrideStatus)) {
      accepted++;
      final old = overrides
          .where((entry) => entry.id == result!.targetId)
          .firstOrNull;
      final saved = OverrideEntry(
        id: result!.targetId!,
        name: old?.name ?? command['name'] as String,
        kind: old?.kind ?? ConfigKind.local,
        source: old?.source,
        revision: result.savedRevision!,
        body: command['body'] as String,
        role: old?.role,
        enabled: old?.enabled ?? true,
        mode: old?.mode ?? OverrideMode.prepend,
      );
      overrides = old == null
          ? [...overrides, saved]
          : [
              for (final entry in overrides)
                entry.id == saved.id ? saved : entry,
            ];
    }
    return result;
  }
}

class _ReceiptPageApp extends _EpochPageApp {
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    dispatching = true;
    changed();
    try {
      return await super.submit(command, automatic: automatic);
    } finally {
      dispatching = false;
      changed();
    }
  }
}

Widget _receiptFeedbackHost(OverridePageApp app) => MaterialApp(
  navigatorObservers: [AppTaskNavigatorObserver()],
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => AppTaskActivity(active: true, child: child!),
  home: AppTaskScope(
    open: (_) {},
    task: AppTask.configurations,
    owner: app,
    child: OperationNoticeHost(
      child: OperationFeedback(
        controller: app,
        child: Navigator(
          observers: [AppTaskNavigatorObserver()],
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => OverridesPage(app: app)),
        ),
      ),
    ),
  ),
);

Widget pluginHost(
  OverridePageApp app, {
  Future<XFile?> Function()? selectFile,
  bool feedback = false,
  bool Function()? isActiveNow,
  ValueNotifier<bool>? reducedMotion,
}) => MaterialApp(
  navigatorObservers: [AppTaskNavigatorObserver()],
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) {
    final content = AppTaskActivity(
      active: true,
      isActiveNow: isActiveNow,
      child: child!,
    );
    return reducedMotion == null
        ? content
        : ValueListenableBuilder<bool>(
            valueListenable: reducedMotion,
            builder: (_, reduced, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: content,
            ),
          );
  },
  home: OperationNoticeHost(
    child: feedback
        ? OperationFeedback(
            controller: app,
            child: OverridesPage(
              app: app,
              selectFile: selectFile ?? () async => null,
            ),
          )
        : OverridesPage(app: app, selectFile: selectFile ?? () async => null),
  ),
);

void main() {
  group('plugin error and child actions', () {
    for (final language in ['en', 'zh']) {
      for (final editable in [false, true]) {
        testWidgets(
          'error remains readable without editing $language/$editable',
          (tester) async {
            final raw = 'provider: unknown\noriginal parser error\n' * 40;
            final error = const AppMessage('overrideSavedReconnectIncomplete')
                .withDetail(raw);
            final entry = OverrideEntry(
              id: 'one',
              name: 'Failed plugin 插件',
              kind: ConfigKind.local,
              enabled: true,
              revision: 3,
              body: '{}',
              error: error,
            );
            final app = OverridePageApp()
              ..editable = editable
              ..overrides = [entry];
            addTearDown(app.dispose);
            await tester.pumpWidget(
              MaterialApp(
                navigatorObservers: [AppTaskNavigatorObserver()],
                locale: Locale(language),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: OperationNoticeHost(child: OverridesPage(app: app)),
              ),
            );
            await tester.pumpAndSettle();
            final strings = lookupAppLocalizations(Locale(language));
            expect(
              find.byKey(const ValueKey('override-error-one')),
              findsNothing,
            );
            final card = find.byKey(const ValueKey('override-one'));
            final more = find.byTooltip(strings.moreLabel);
            await tester.ensureVisible(more);
            await tester.pumpAndSettle();
            final cardRect = tester.getRect(card);
            final moreRect = tester.getRect(more);
            final action = find.descendant(
              of: find.byType(SnackBar),
              matching: find.widgetWithText(TextButton, strings.errorDetails),
            );
            expect(action, findsOneWidget);
            final cached = tester.widget<TextButton>(action).onPressed!;
            await tester.tap(action);
            await tester.pumpAndSettle();
            expect(tester.getRect(card), cardRect);
            expect(tester.getRect(more), moreRect);
            expect(find.text(strings.overrideActionFailed), findsWidgets);
            expect(find.text(error.summary(strings)), findsNothing);
            expect(find.text(error.resolve(strings)), findsNothing);
            expect(find.byType(ConfigTextPage), findsNothing);
            expect(app.commands, isEmpty);
            expect(app.overrides.single.enabled, isTrue);
            expect(
              find.byKey(const ValueKey('operation-technical-text')),
              findsNothing,
            );
            await tester.tap(find.text(strings.technicalDetails));
            await tester.pumpAndSettle();
            final detail = tester
                .widget<SelectableText>(
                  find.byKey(const ValueKey('operation-technical-text')),
                )
                .data!;
            expect(detail, contains(entry.name));
            expect(detail, contains(error.summary(strings)));
            expect(detail, contains(raw));
            await tester.tap(find.text(strings.close));
            await tester.pumpAndSettle();
            if (editable) {
              await tester.tap(find.byType(Switch));
              await tester.pumpAndSettle();
              expect(app.commands, hasLength(1));
              expect(app.commands.single['action'], 'changeOverride');
              expect(app.commands.single['enabled'], isFalse);
              expect(find.byType(ConfigTextPage), findsNothing);
            }
            final commands = app.commands.length;
            if (editable) {
              await tester.tap(find.byTooltip(strings.moreLabel));
              await tester.pumpAndSettle();
              expect(
                find.widgetWithText(MenuItemButton, strings.viewOverrideError),
                findsNothing,
              );
              await tester.binding.handlePopRoute();
              await tester.pumpAndSettle();
            }
            expect(find.byType(ConfigTextPage), findsNothing);
            expect(app.commands, hasLength(commands));
            app.setForeground(false);
            cached();
            app.setForeground(true);
            cached();
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
            expect(app.commands, hasLength(commands));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  testWidgets(
    'plugin empty header bypasses size animation without retiring the list',
    (tester) async {
      final app = OverridePageApp();
      addTearDown(app.dispose);
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      const entry = OverrideEntry(
        id: 'local',
        name: 'Local',
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
      );
      await tester.pumpWidget(pluginHost(app, reducedMotion: reduced));
      final page = find.byType(OverridesPage);
      final pageState = tester.state(page);
      final viewport = tester.element(find.byType(CustomScrollView));
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller;
      final strings = lookupAppLocalizations(const Locale('en'));
      final sizes = find.descendant(
        of: page,
        matching: find.bySubtype<AnimatedSize>(),
      );
      Finder headerColumn() => find
          .descendant(
            of: find.byType(SliverToBoxAdapter),
            matching: find.byType(Column),
          )
          .first;
      Future<void> pumpClean([int milliseconds = 0]) async {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(tester.takeException(), isNull);
      }

      Future<void> publish(List<OverrideEntry> entries) async {
        app.overrides = entries;
        app.changed();
        await pumpClean();
      }

      await pumpClean();
      expect(find.text(strings.overrideEmpty), findsOneWidget);
      expect(sizes, findsNothing);
      final emptyHeight = tester.getSize(headerColumn()).height;
      await publish([entry]);
      expect(find.text(strings.overrideEmpty), findsNothing);
      expect(sizes, findsNothing);
      final nonemptyHeight = tester.getSize(headerColumn()).height;
      final card = find.byKey(const ValueKey('override-local'));
      final reducedCard = tester.element(card);
      reduced.value = false;
      await pumpClean();
      expect(tester.element(card), same(reducedCard));
      expect(sizes, findsNWidgets(2));
      expect(
        tester
            .widgetList<AnimatedSize>(sizes)
            .every((size) => size.duration > Duration.zero),
        isTrue,
      );

      await publish([]);
      await pumpClean(60);
      final expanding = tester.getSize(sizes.first).height;
      expect(expanding, greaterThan(nonemptyHeight));
      expect(expanding, lessThan(emptyHeight));
      await publish([entry]);
      expect(tester.getSize(sizes.first).height, closeTo(expanding, .01));
      await pumpClean(60);
      expect(tester.getSize(sizes.first).height, lessThan(expanding));
      final returningCard = tester.element(card);
      final toggle = tester.element(
        find.descendant(of: card, matching: find.byType(Switch)),
      );
      final cardScroll = tester.state<ScrollableState>(
        find.descendant(of: card, matching: find.byType(Scrollable)),
      );
      reduced.value = true;
      await pumpClean();
      expect(sizes, findsNothing);
      expect(
        tester.getSize(headerColumn()).height,
        closeTo(nonemptyHeight, .01),
      );
      expect(tester.element(card), same(returningCard));
      expect(
        tester.element(
          find.descendant(of: card, matching: find.byType(Switch)),
        ),
        same(toggle),
      );
      expect(
        tester.state<ScrollableState>(
          find.descendant(of: card, matching: find.byType(Scrollable)),
        ),
        same(cardScroll),
      );
      await publish([]);
      expect(find.text(strings.overrideEmpty), findsOneWidget);
      expect(sizes, findsNothing);
      reduced.value = false;
      await pumpClean();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.state(page), same(pageState));
      expect(tester.element(find.byType(CustomScrollView)), same(viewport));
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller,
        same(scroll),
      );
      expect(tester.widget<OverridesPage>(page).app, same(app));
      expect(app.commands, isEmpty);
    },
  );

  testWidgets(
    'plugin card height keeps content state through reverse and dynamic reduce',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final app = OverridePageApp();
      addTearDown(app.dispose);
      const entry = OverrideEntry(
        id: 'local',
        name: 'Local',
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
      );
      app.overrides = [entry];
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await tester.pumpWidget(pluginHost(app, reducedMotion: reduced));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('override-local'));
      final element = tester.element(card);
      final titleElement = tester.element(find.text(entry.name));
      final toggle = tester.element(
        find.descendant(of: card, matching: find.byType(Switch)),
      );
      final cardScroll = tester.state<ScrollableState>(
        find.descendant(of: card, matching: find.byType(Scrollable)),
      );
      final pageState = tester.state(find.byType(OverridesPage));
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller;
      Finder sizeTween() => find
          .ancestor(of: card, matching: find.bySubtype<AnimatedSize>())
          .first;
      Future<void> pumpClean([int milliseconds = 0]) async {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(tester.takeException(), isNull);
      }

      Future<void> rename(String name) async {
        app.overrides = [entry.changed(name: name)];
        app.changed();
        await pumpClean();
      }

      final originalHeight = tester.getSize(sizeTween()).height;
      final longName = 'Long wrapped plugin title ' * 12;
      await rename(longName);
      final expandedHeight = tester.getSize(card).height;
      expect(expandedHeight, greaterThan(originalHeight));
      expect(tester.getSize(sizeTween()).height, closeTo(originalHeight, .01));
      await pumpClean(70);
      final middle = tester.getSize(sizeTween()).height;
      expect(middle, greaterThan(originalHeight));
      expect(middle, lessThan(expandedHeight));
      await rename(entry.name);
      expect(tester.getSize(sizeTween()).height, closeTo(middle, .01));
      await pumpClean(70);
      expect(tester.getSize(sizeTween()).height, lessThan(middle));
      reduced.value = true;
      await pumpClean();
      expect(
        find.ancestor(of: card, matching: find.bySubtype<AnimatedSize>()),
        findsNothing,
      );
      expect(tester.getSize(card).height, closeTo(originalHeight, .01));
      await rename(longName);
      expect(tester.getSize(card).height, closeTo(expandedHeight, .01));
      reduced.value = false;
      await pumpClean();
      expect(tester.getSize(sizeTween()).height, closeTo(expandedHeight, .01));
      await rename(entry.name);
      await pumpClean(60);
      reduced.value = true;
      await pumpClean();
      expect(tester.getSize(card).height, closeTo(originalHeight, .01));
      expect(tester.element(card), same(element));
      expect(tester.element(find.text(entry.name)), same(titleElement));
      expect(
        tester.element(
          find.descendant(of: card, matching: find.byType(Switch)),
        ),
        same(toggle),
      );
      expect(
        tester.state<ScrollableState>(
          find.descendant(of: card, matching: find.byType(Scrollable)),
        ),
        same(cardScroll),
      );
      expect(tester.state(find.byType(OverridesPage)), same(pageState));
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller,
        same(scroll),
      );
      expect(app.commands, isEmpty);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached plugin toggle and edit lose task authority before rebuild',
    (tester) async {
      final app = OverridePageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'local',
          name: 'Local',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
      ];
      var active = true;
      await tester.pumpWidget(pluginHost(app, isActiveNow: () => active));
      await tester.pumpAndSettle();
      final toggle = tester.widget<Switch>(find.byType(Switch)).onChanged!;
      final strings = lookupAppLocalizations(const Locale('en'));
      final edit = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is IconButton && widget.tooltip == strings.editConfig,
            ),
          )
          .onPressed!;
      active = false;
      toggle(true);
      edit();
      expect(app.commands, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(ConfigTextPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plugin more actions retire across background and resume', (
    tester,
  ) async {
    final app = OverridePageApp();
    addTearDown(app.dispose);
    app.overrides = const [
      OverrideEntry(
        id: 'local',
        name: 'Local',
        kind: ConfigKind.local,
        revision: 1,
        body: '{}',
      ),
    ];
    try {
      await tester.pumpWidget(pluginHost(app));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Rename').hitTestable(), findsOneWidget);
      final old = tester
          .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Rename'))
          .onPressed!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(tester.binding.framesEnabled, isFalse);
      old();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Rename').hitTestable(), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(app.commands, isEmpty);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Rename').hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
    }
  });

  for (final dark in [false, true]) {
    for (final brand in BrandColor.values) {
      for (final language in ['zh', 'en']) {
        for (final width in [320.0, 760.0]) {
          for (final scale in [1.0, 1.3, 2.0]) {
            testWidgets(
              'plugin card roles and stable frames $dark/$brand/$language/$width/$scale',
              (tester) async {
                tester.view.physicalSize = Size(width, 1100);
                tester.view.devicePixelRatio = 1;
                addTearDown(tester.view.resetPhysicalSize);
                addTearDown(tester.view.resetDevicePixelRatio);
                final app = OverridePageApp();
                addTearDown(app.dispose);
                const remote = OverrideEntry(
                  id: 'remote',
                  name: 'Remote',
                  kind: ConfigKind.remote,
                  revision: 1,
                  body: '{}',
                  source:
                      'https://user:password@fixture.test/plugin?token=private',
                );
                final local = OverrideEntry(
                  id: 'local',
                  name: '插件 Long name 🌐 ' * 3,
                  kind: ConfigKind.local,
                  revision: 1,
                  body: '{}',
                );
                app.overrides = [remote, local];
                await tester.pumpWidget(
                  MaterialApp(
                    navigatorObservers: [AppTaskNavigatorObserver()],
                    theme: AppTheme.forBrightness(
                      dark ? Brightness.dark : Brightness.light,
                      brand,
                    ),
                    locale: Locale(language),
                    localizationsDelegates:
                        AppLocalizations.localizationsDelegates,
                    supportedLocales: AppLocalizations.supportedLocales,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: OperationNoticeHost(child: OverridesPage(app: app)),
                  ),
                );
                await tester.pumpAndSettle();
                final strings = lookupAppLocalizations(Locale(language));
                final palette = HomePalette(dark, brand: brand);
                final card = find.byKey(const ValueKey('override-local'));
                final remoteCard = find.byKey(
                  const ValueKey('override-remote'),
                );
                Finder inside(Finder root, Finder child) =>
                    find.descendant(of: root, matching: child);
                final appBar = find.byType(AppBar);
                final pageTitle = inside(
                  appBar,
                  find.text(strings.overridePlugins),
                );
                final titleParagraph = tester.renderObject<RenderParagraph>(
                  pageTitle,
                );
                expect(titleParagraph.didExceedMaxLines, isFalse);
                expect(
                  tester.getRect(pageTitle).top,
                  greaterThanOrEqualTo(tester.getRect(appBar).top),
                );
                expect(
                  tester.getRect(pageTitle).bottom,
                  lessThanOrEqualTo(tester.getRect(appBar).bottom),
                );
                expect(
                  tester.widget<AppBar>(appBar).titleTextStyle!.fontWeight,
                  FontWeight.w600,
                );
                final pageState = tester.state(find.byType(OverridesPage));
                final list = find.byType(CustomScrollView);
                final verticalScroll = inside(
                  list,
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is Scrollable &&
                        widget.axisDirection == AxisDirection.down,
                  ),
                );
                final position = tester
                    .state<ScrollableState>(verticalScroll)
                    .position;
                final source = inside(
                  card,
                  find.text(
                    '${strings.overrideLocal} · ${strings.overridePrepend}',
                  ),
                );
                final targets = [
                  card,
                  inside(card, find.text(local.name)),
                  source,
                  inside(card, find.byType(SingleChildScrollView)),
                  inside(card, find.byType(Switch)),
                  inside(card, find.byTooltip(strings.editConfig)),
                  inside(card, find.byTooltip(strings.moreLabel)),
                ];
                Future<void> expectStableFrames(
                  List<Finder> readingTargets,
                ) async {
                  for (final target in readingTargets) {
                    expect(target, findsOneWidget);
                  }
                  final rectangles = readingTargets
                      .map(tester.getRect)
                      .toList();
                  final readingElement = tester.element(readingTargets.first);
                  final offset = position.pixels;
                  for (final (enabled, editable, error, loaded, readError) in [
                    (true, true, null, true, null),
                    (false, false, messages.downloadFailed, true, null),
                    (
                      false,
                      false,
                      messages.downloadFailed,
                      false,
                      messages.overridesUnreadable,
                    ),
                    (true, true, null, true, null),
                  ]) {
                    app.editable = editable;
                    app.overridesLoaded = loaded;
                    app.overrideErrorMessage = readError;
                    app.overrides = [
                      remote,
                      OverrideEntry.fromJson({
                        ...local.toJson(),
                        'enabled': enabled,
                        'updatedAt': 1234567890000,
                        'error': error?.toMap(),
                      }),
                    ];
                    app.changed();
                    for (var frame = 0; frame < 8; frame++) {
                      await tester.pump(const Duration(milliseconds: 16));
                      expect(
                        readingTargets.map(tester.getRect).toList(),
                        rectangles,
                      );
                      expect(
                        tester.element(readingTargets.first),
                        same(readingElement),
                      );
                      expect(
                        tester.state(find.byType(OverridesPage)),
                        same(pageState),
                      );
                      expect(
                        tester.state<ScrollableState>(verticalScroll).position,
                        same(position),
                      );
                      expect(position.pixels, offset);
                      expect(
                        find.byKey(const ValueKey('override-read-state')),
                        findsNothing,
                      );
                      expect(
                        find.byKey(const ValueKey('override-error-local')),
                        findsNothing,
                      );
                      expect(find.byType(AlertDialog), findsNothing);
                      expect(tester.takeException(), isNull);
                    }
                    await tester.pumpAndSettle();
                    if (readError != null || error != null) {
                      expect(find.byType(SnackBar), findsOneWidget);
                      await _dismissNotice(tester);
                      if (find.byType(SnackBar).evaluate().isNotEmpty) {
                        await _dismissNotice(tester);
                      }
                    } else {
                      expect(find.byType(SnackBar), findsNothing);
                    }
                    expect(
                      readingTargets.map(tester.getRect).toList(),
                      rectangles,
                    );
                    expect(
                      tester.element(readingTargets.first),
                      same(readingElement),
                    );
                    expect(
                      tester.state<ScrollableState>(verticalScroll).position,
                      same(position),
                    );
                    expect(position.pixels, offset);
                  }
                }

                // Check visible card state and complete remote sources; offscreen cards
                // build lazily.
                expect(remoteCard, findsOneWidget);
                expect(
                  tester
                      .widget<Icon>(
                        inside(remoteCard, find.byIcon(Icons.cloud_outlined)),
                      )
                      .color,
                  palette.remoteSource,
                );
                expect(
                  IconTheme.of(
                    tester.element(
                      inside(remoteCard, find.byIcon(Icons.refresh)),
                    ),
                  ).color,
                  palette.syncAction,
                );
                final visibleText = tester
                    .widgetList<Text>(find.byType(Text))
                    .map((text) => text.data ?? '')
                    .join('\n');
                final remoteSummary =
                    '${remote.source} · ${strings.overridePrepend}';
                expect(visibleText, contains(remoteSummary));
                expect(
                  inside(remoteCard, find.text(remoteSummary)),
                  findsOneWidget,
                );
                expect(
                  inside(remoteCard, find.byTooltip(remoteSummary)),
                  findsOneWidget,
                );
                await expectStableFrames([
                  remoteCard,
                  inside(remoteCard, find.text(remote.name)),
                  inside(remoteCard, find.byType(Switch)),
                  inside(remoteCard, find.byIcon(Icons.refresh)),
                  inside(remoteCard, find.byIcon(Icons.more_vert)),
                ]);

                // Restore unknown local update time to check layout when the actual
                // time first appears.
                app.overrides = [remote, local];
                app.changed();
                await tester.pumpAndSettle();
                // After scrolling to the local entry, remeasure positions and sizes of
                // all seven card elements.
                await tester.scrollUntilVisible(
                  card,
                  200,
                  scrollable: verticalScroll,
                );
                await tester.pumpAndSettle();
                expect(card, findsOneWidget);
                expect(
                  tester
                      .widget<Text>(inside(card, find.text(local.name)))
                      .maxLines,
                  isNull,
                );
                expect(
                  tester.getTopLeft(targets[1]).dx,
                  tester.getTopLeft(source).dx,
                );
                expect(
                  tester.getTopLeft(source).dx,
                  tester.getTopLeft(targets[3]).dx,
                );
                expect(
                  tester
                      .widget<Icon>(
                        inside(card, find.byIcon(Icons.description_outlined)),
                      )
                      .color,
                  palette.localSource,
                );
                expect(
                  IconTheme.of(
                    tester.element(
                      inside(card, find.byIcon(Icons.edit_outlined)),
                    ),
                  ).color,
                  palette.editAction,
                );
                expect(
                  IconTheme.of(
                    tester.element(inside(card, find.byIcon(Icons.more_vert))),
                  ).color,
                  palette.moreAction,
                );
                await expectStableFrames(targets.take(7).toList());
                expect(app.commands, isEmpty);
                await tester.pumpWidget(const SizedBox.shrink());
              },
            );
          }
        }
      }
    }
  }

  testWidgets('plugin error summaries resolve at the current UI locale', (
    tester,
  ) async {
    final app = OverridePageApp();
    addTearDown(app.dispose);
    const error = AppMessage('downloadFailed');
    app.overrides = const [
      OverrideEntry(
        id: 'one',
        name: 'Saved plugin',
        kind: ConfigKind.local,
        revision: 1,
        body: '',
        error: error,
      ),
    ];
    final locale = ValueNotifier(const Locale('en'));
    final routes = AppTaskNavigatorObserver();
    addTearDown(locale.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: locale,
        builder: (_, value, _) => MaterialApp(
          navigatorObservers: [routes],
          locale: value,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OperationNoticeHost(child: OverridesPage(app: app)),
        ),
      ),
    );
    for (final language in ['en', 'zh', 'en']) {
      locale.value = Locale(language);
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(Locale(language));
      expect(
        find.byTooltip('${strings.overrideLocal} · ${strings.overridePrepend}'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('override-error-one')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(strings.overrideActionFailed),
        ),
        findsOneWidget,
      );
      expect(identical(app.overrides.single.errorMessage, error), isTrue);
    }
    final strings = lookupAppLocalizations(const Locale('en'));
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(strings.errorDetails),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.technicalDetails));
    await tester.pumpAndSettle();
    expect(find.textContaining(strings.downloadFailed), findsOneWidget);
    await tester.tap(find.text(strings.close).hitTestable());
    await tester.pumpAndSettle();
    expect(app.commands, isEmpty);
  });

  for (final language in ['en', 'zh']) {
    testWidgets('plugin deletion retains the real confirmation $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = OverridePageApp();
      addTearDown(app.dispose);
      final name = 'Long plugin name 插件 🌐 ' * 8;
      app.overrides = [
        OverrideEntry(
          id: 'one',
          name: name,
          kind: ConfigKind.local,
          revision: 1,
          body: '',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: OperationNoticeHost(child: OverridesPage(app: app)),
        ),
      );
      final strings = lookupAppLocalizations(Locale(language));
      final row = find.byKey(const ValueKey('override-one'));
      final more = find.byTooltip(strings.moreLabel);
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      final rect = tester.getRect(row);
      for (final confirm in [false, true]) {
        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.overrideDelete));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(
          find.descendant(of: dialog, matching: find.text(name)),
          findsOneWidget,
        );
        expect(find.text(strings.overrideDeleteMessage), findsOneWidget);
        expect(
          find.descendant(of: dialog, matching: find.byType(SelectableText)),
          findsNWidgets(2),
        );
        expect(app.commands, isEmpty);
        expect(tester.getRect(row), rect);
        final action = confirm
            ? find.widgetWithText(FilledButton, strings.overrideDelete)
            : find.widgetWithText(TextButton, strings.cancel);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(tester.getRect(row), rect);
        expect(tester.takeException(), isNull);
        if (confirm) {
          expect(app.commands.single, {
            'storageEpoch': 0,
            'action': 'deleteOverride',
            'id': 'one',
            'revision': 1,
            'expectedName': name,
            'expectedSource': null,
            'expectedProxyName': '',
            'expectedAddNoResolve': false,
          });
        } else {
          expect(app.commands, isEmpty);
        }
      }
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('plugin read states retain row anchors at scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = OverridePageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'one',
          name: 'Saved plugin with a long readable name',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: OperationNoticeHost(child: OverridesPage(app: app)),
        ),
      );
      final row = find.byKey(const ValueKey('override-one'));
      final strings = lookupAppLocalizations(const Locale('en'));
      final targets = [
        row,
        find.text(app.overrides.single.name),
        find.descendant(of: row, matching: find.byType(Switch)),
        find.descendant(of: row, matching: find.byIcon(Icons.edit_outlined)),
        find.descendant(of: row, matching: find.byIcon(Icons.more_vert)),
        find.byTooltip(strings.addOverride),
      ];
      final rectangles = targets.map(tester.getRect).toList();
      final rowElement = tester.element(row);
      final pageState = tester.state(find.byType(OverridesPage));
      final scroll = tester.state<ScrollableState>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      final position = scroll.position;
      for (final (loaded, error) in [
        (false, null),
        (false, messages.overridesUnreadable),
        (true, null),
      ]) {
        app.overridesLoaded = loaded;
        app.overrideErrorMessage = error;
        app.changed();
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(targets.map(tester.getRect).toList(), rectangles);
          expect(tester.element(row), same(rowElement));
          expect(tester.state(find.byType(OverridesPage)), same(pageState));
          expect(scroll.position, same(position));
          expect(
            find.byKey(const ValueKey('override-read-state')),
            findsNothing,
          );
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.text('No plugins added yet.'), findsNothing);
          expect(tester.takeException(), isNull);
        }
        if (error != null) {
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsOneWidget);
          await _dismissNotice(tester);
          expect(targets.map(tester.getRect).toList(), rectangles);
          expect(scroll.position, same(position));
        } else {
          expect(find.byType(SnackBar), findsNothing);
        }
      }
      app.overrideErrorMessage = messages.overridesUnreadable;
      app.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_noticeText(strings.overridesUnreadable), findsOneWidget);
      expect(targets.map(tester.getRect).toList(), rectangles);
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(strings.errorDetails),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.widgetWithText(SelectableText, strings.overridesUnreadable),
        findsOneWidget,
      );
      await tester.tap(find.text(strings.close).hitTestable());
      await tester.pumpAndSettle();
      expect(targets.map(tester.getRect).toList(), rectangles);
      expect(tester.element(row), same(rowElement));
      expect(scroll.position, same(position));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('unreadable plugins are not displayed as an empty collection', (
    tester,
  ) async {
    final app = OverridePageApp()..overridesLoaded = false;
    addTearDown(app.dispose);
    await tester.pumpWidget(pluginHost(app));
    final strings = lookupAppLocalizations(const Locale('en'));
    expect(find.text(strings.overrideEmpty), findsNothing);
    app.overrideErrorMessage = messages.overridesUnreadable;
    app.changed();
    await tester.pump();
    expect(find.text(strings.overrideEmpty), findsNothing);
    app.overrideErrorMessage = null;
    app.overridesLoaded = true;
    app.changed();
    await tester.pump();
    expect(find.text(strings.overrideEmpty), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'plugin management has no global apply and edits names and sources',
    (tester) async {
      final app = OverridePageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'one',
          name: 'Fixture',
          kind: ConfigKind.remote,
          revision: 1,
          body: '{}',
          source: 'https://fixture.test/old.yaml',
          enabled: true,
        ),
      ];
      await tester.pumpWidget(pluginHost(app));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      expect(find.byKey(const ValueKey('override-apply')), findsNothing);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      await tester.tap(find.byTooltip(strings.moreLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.rename));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Renamed');
      await tester.tap(find.text(strings.save));
      await tester.pumpAndSettle();
      expect(app.commands.single, {
        'storageEpoch': 0,
        'action': 'changeOverride',
        'id': 'one',
        'revision': 1,
        'expectedSource': 'https://fixture.test/old.yaml',
        'expectedName': 'Fixture',
        'expectedProxyName': '',
        'expectedAddNoResolve': false,
        'name': 'Renamed',
      });
      app.commands.clear();
      await tester.tap(find.byTooltip(strings.moreLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.changeSource));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('import-source')))
            .obscureText,
        isTrue,
      );
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'http://fixture.test/new.yaml',
      );
      await tester.tap(find.text(strings.saveAndUpdate));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.commands.single, {
        'storageEpoch': 0,
        'action': 'changeOverrideSource',
        'id': 'one',
        'revision': 1,
        'expectedSource': 'https://fixture.test/old.yaml',
        'expectedName': 'Fixture',
        'expectedProxyName': '',
        'expectedAddNoResolve': false,
        'source': 'http://fixture.test/new.yaml',
        'proxyName': '',
        'addNoResolve': false,
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'remote plugin source form persists both options and redownloads same URL',
    (tester) async {
      final app = OverridePageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'remote',
          name: 'Remote',
          kind: ConfigKind.remote,
          revision: 7,
          body: '{}',
          source: 'https://fixture.invalid/same',
          proxyName: 'Previous proxy',
          addNoResolve: true,
        ),
      ];
      await tester.pumpWidget(pluginHost(app));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.byTooltip(strings.moreLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.changeSource));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('loon-proxy-name')))
            .controller!
            .text,
        'Previous proxy',
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('loon-no-resolve')),
            )
            .value,
        isTrue,
      );
      expect(find.text(strings.nameOptional), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('loon-proxy-name')),
        'Chosen proxy',
      );
      await tester.tap(find.byKey(const ValueKey('loon-no-resolve')));
      await tester.tap(find.text(strings.saveAndUpdate));
      await tester.pumpAndSettle();
      expect(app.commands.single, {
        'storageEpoch': 0,
        'action': 'changeOverrideSource',
        'id': 'remote',
        'revision': 7,
        'expectedSource': 'https://fixture.invalid/same',
        'expectedName': 'Remote',
        'expectedProxyName': 'Previous proxy',
        'expectedAddNoResolve': true,
        'source': 'https://fixture.invalid/same',
        'proxyName': 'Chosen proxy',
        'addNoResolve': false,
      });
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'remote import sends explicitly chosen options without a target lookup',
    (tester) async {
      final app = OverridePageApp();
      addTearDown(app.dispose);
      await tester.pumpWidget(pluginHost(app));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.byTooltip(strings.addOverride));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.remoteOverride));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('loon-proxy-name')))
            .controller!
            .text,
        '',
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('loon-no-resolve')),
            )
            .value,
        isFalse,
      );
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'http://fixture.invalid/anything',
      );
      await tester.enterText(
        find.byKey(const ValueKey('loon-proxy-name')),
        'Does not exist yet 🧭',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('loon-no-resolve')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('loon-no-resolve')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.downloadAndSave));
      await tester.pumpAndSettle();
      expect(app.commands.single, {
        'storageEpoch': 0,
        'action': 'importOverride',
        'name': '',
        'source': 'http://fixture.invalid/anything',
        'proxyName': 'Does not exist yet 🧭',
        'addNoResolve': true,
      });
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final existing in [true, false]) {
    testWidgets(
      '${existing ? 'existing' : 'new'} plugin editor reuses saved identity after apply failure',
      (tester) async {
        final app = OverridePageApp();
        addTearDown(app.dispose);
        final id = existing ? 'existing' : 'created';
        final savedRevision = existing ? 2 : 1;
        app.saveResults.addAll([
          AppSnapshot(
            phase: 'STOPPED',
            resultId: 'first',
            resultSuccess: false,
            overrideStatus: 'applyFailed',
            targetId: id,
            savedRevision: savedRevision,
            resultMessage: messages.overrideSavedReconnectIncomplete,
          ),
          AppSnapshot(
            phase: 'STOPPED',
            resultId: 'second',
            resultSuccess: true,
            overrideStatus: 'saved',
            targetId: id,
            savedRevision: savedRevision + 1,
          ),
        ]);
        if (existing) {
          app.overrides = const [
            OverrideEntry(
              id: 'existing',
              name: 'Existing',
              kind: ConfigKind.local,
              revision: 1,
              body: '{}',
            ),
          ];
        }
        await tester.pumpWidget(pluginHost(app));
        final strings = AppLocalizations.of(
          tester.element(find.byType(OverridesPage)),
        );
        if (existing) {
          await tester.tap(find.text('Existing'));
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.byTooltip(strings.addOverride));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.newOverride));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'New plugin');
          await tester.tap(find.text(strings.continueLabel));
          await tester.pumpAndSettle();
        }
        expect(find.byType(ConfigTextPage), findsOneWidget);
        final editor = tester
            .widget<CodeEditor>(find.byType(CodeEditor))
            .controller!;
        editor.text = 'rules: ["DOMAIN,first.test,DIRECT"]';
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.save));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          _noticeText(
            messages.overrideSavedReconnectIncomplete.summary(strings),
          ),
          findsOneWidget,
        );
        expect(find.text(strings.savedApplyFailed), findsNothing);
        expect(find.byType(ConfigTextPage), findsOneWidget);
        expect(app.commands.single['id'], existing ? id : null);
        expect(app.commands.single['revision'], existing ? 1 : null);
        await _dismissNotice(tester);
        // Return the operation result separately from the entry reread after saving.
        app.overrides = [
          OverrideEntry(
            id: id,
            name: existing ? 'Existing' : 'New plugin',
            kind: ConfigKind.local,
            revision: savedRevision,
            body: 'rules: ["DOMAIN,first.test,DIRECT"]',
          ),
        ];
        app.changed();
        await tester.pump();
        expect(find.byType(SnackBar), findsNothing);
        editor.text = 'rules: ["DOMAIN,corrected.test,DIRECT"]';
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.save));
        await tester.pumpAndSettle();
        expect(app.commands, hasLength(2));
        expect(app.commands.last['id'], id);
        expect(app.commands.last['revision'], savedRevision);
        expect(app.commands.last['body'], contains('corrected.test'));
        expect(find.byType(ConfigTextPage), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'Loon form validation and selection keep reading anchors $language $scale',
        (tester) async {
          tester.view.physicalSize = const Size(360, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final app = OverridePageApp();
          addTearDown(app.dispose);
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [AppTaskNavigatorObserver()],
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: OperationNoticeHost(child: OverridesPage(app: app)),
            ),
          );
          final strings = lookupAppLocalizations(Locale(language));
          await tester.tap(find.byTooltip(strings.addOverride));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.remoteOverride));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('import-source')),
            'https://fixture.invalid/part',
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('loon-proxy-name')),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('loon-proxy-name')),
            'invalid,name',
          );
          await tester.pumpAndSettle();
          final targets = [
            find.byType(AlertDialog),
            find.byKey(const ValueKey('loon-proxy-name')),
            find.byKey(const ValueKey('loon-no-resolve')),
            find.text(strings.downloadAndSave),
          ];
          final field = find.byKey(const ValueKey('loon-proxy-name'));
          final viewport = tester.getRect(
            find.ancestor(of: field, matching: find.byType(Scrollable)).first,
          );
          final editableRect = tester.getRect(
            find.descendant(of: field, matching: find.byType(EditableText)),
          );
          expect(viewport.contains(editableRect.topLeft), isTrue);
          expect(
            viewport.contains(
              editableRect.bottomRight - const Offset(0.1, 0.1),
            ),
            isTrue,
          );
          final rectangles = targets.map(tester.getRect).toList();
          await tester.tap(find.text(strings.downloadAndSave));
          for (var frame = 0; frame < 16; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            for (var i = 0; i < targets.length; i++) {
              expect(tester.getRect(targets[i]), rectangles[i]);
            }
            expect(tester.takeException(), isNull);
          }
          expect(app.commands, isEmpty);
          expect(find.text(strings.loonProxyNameInvalid), findsOneWidget);
          await tester.enterText(
            find.byKey(const ValueKey('loon-proxy-name')),
            'Valid name 🧭',
          );
          for (var frame = 0; frame < 16; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            for (var i = 0; i < targets.length; i++) {
              expect(tester.getRect(targets[i]), rectangles[i]);
            }
          }
          await tester.ensureVisible(
            find.byKey(const ValueKey('loon-no-resolve')),
          );
          await tester.pumpAndSettle();
          final selectedRects = targets.map(tester.getRect).toList();
          await tester.tap(find.byKey(const ValueKey('loon-no-resolve')));
          for (var frame = 0; frame < 16; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            for (var i = 0; i < targets.length; i++) {
              expect(tester.getRect(targets[i]), selectedRects[i]);
            }
          }
          await tester.tap(find.text(strings.cancel));
          await tester.pumpAndSettle();
          expect(app.commands, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('ordinary configuration import has no Loon options', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<Map<String, Object?>>(
              context: context,
              builder: (_) => const ImportDialog(),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('loon-proxy-name')), findsNothing);
    expect(find.byKey(const ValueKey('loon-no-resolve')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'old rendered editor callback cannot borrow the restored projection epoch',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'same',
          name: 'Same',
          kind: ConfigKind.local,
          revision: 3,
          body: '{}',
        ),
      ];
      app.saveResults.add(
        const AppSnapshot(
          phase: 'STOPPED',
          resultId: 'saved',
          resultSuccess: true,
          overrideStatus: 'saved',
          targetId: 'same',
          savedRevision: 4,
        ),
      );
      await tester.pumpWidget(pluginHost(app));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      final openEditor = tester
          .widget<InkWell>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('override-same')),
                  matching: find.byType(InkWell),
                )
                .first,
          )
          .onTap!;
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
      openEditor();
      await tester.pumpAndSettle();
      final editor = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .controller!;
      expect(editor.text, '{}');
      final editorState = tester.state(find.byType(CodeEditor));
      final pageState = tester.state(find.byType(ConfigTextPage));
      final focus = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .focusNode!;
      editor.text = 'rules: ["DOMAIN,old-draft.test,REJECT"]';
      editor.value = editor.value.copyWith(
        selection: const CodeLineSelection.collapsed(index: 0, offset: 7),
        composing: const TextRange(start: 6, end: 7),
      );
      final accepted = editor.value;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(editor.value, same(accepted));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(editor.value.selection, accepted.selection);
      expect(editor.value.composing, accepted.composing);
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isFalse,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, strings.save))
            .onPressed,
        isNull,
      );
      app.changed();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(editor.value, same(accepted));
      expect(editor.value.selection, accepted.selection);
      expect(editor.value.composing, const TextRange(start: 6, end: 7));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(tester.state(find.byType(ConfigTextPage)), same(pageState));
      await tester.tap(find.text(strings.save));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      final compositionEnded = editor.value;
      expect(compositionEnded.codeLines, same(accepted.codeLines));
      expect(compositionEnded.selection, accepted.selection);
      expect(compositionEnded.composing, TextRange.empty);
      expect(compositionEnded, isNot(same(accepted)));
      app.changed();
      await tester.pump();
      expect(editor.value, same(compositionEnded));
      expect(app.accepted, 0);
      expect(app.commands, isEmpty);
      expect(app.overrides.single.revision, 3);
      expect(app.overrides.single.body, contains('restored.test'));
      expect(editor.text, 'rules: ["DOMAIN,old-draft.test,REJECT"]');
      expect(editor.value, same(compositionEnded));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(tester.state(find.byType(ConfigTextPage)), same(pageState));
      expect(_noticeText(strings.editorContextChanged), findsOneWidget);
      expect(find.byType(ConfigTextPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old rendered switch callback cannot borrow the restored projection epoch',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'same',
          name: 'Same',
          kind: ConfigKind.local,
          revision: 3,
          body: '{}',
          enabled: true,
        ),
      ];
      await tester.pumpWidget(pluginHost(app, feedback: true));
      final toggle = tester.widget<Switch>(find.byType(Switch)).onChanged!;
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
      toggle(false);
      await tester.pumpAndSettle();
      expect(app.accepted, 0);
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.commands.single['enabled'], isFalse);
      expect(app.overrides.single.enabled, isTrue);
      expect(app.overrides.single.body, contains('restored.test'));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final adding in [false, true]) {
    testWidgets(
      'old rendered menu cannot borrow the restored projection epoch; add=$adding',
      (tester) async {
        final app = _EpochPageApp();
        addTearDown(app.dispose);
        app.overrides = const [
          OverrideEntry(
            id: 'same',
            name: 'Same',
            kind: ConfigKind.local,
            revision: 3,
            body: '{}',
          ),
        ];
        await tester.pumpWidget(pluginHost(app, feedback: true));
        final strings = AppLocalizations.of(
          tester.element(find.byType(OverridesPage)),
        );
        if (adding) {
          await tester.tap(find.byTooltip(strings.addOverride));
          await tester.pumpAndSettle();
          final retired = tester.widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, strings.remoteOverride),
          );
          app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
          await tester.pumpAndSettle();
          expect(find.byType(MenuItemButton), findsNothing);
          retired.onPressed!();
          await tester.pumpAndSettle();
          expect(find.byType(ImportDialog), findsNothing);
          expect(app.commands, isEmpty);
          expect(app.accepted, 0);
          expect(app.overrides.single.body, contains('restored.test'));
          await tester.pumpWidget(const SizedBox());
          expect(tester.takeException(), isNull);
          return;
        }
        app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
        // Invoke the current button callback before the page rebuilds with the new
        // state.
        await tester.tap(find.byTooltip(strings.moreLabel));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        expect(app.accepted, 0);
        expect(app.commands, isEmpty);
        expect(app.overrides.single.mode, OverrideMode.prepend);
        expect(app.overrides.single.body, contains('restored.test'));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final restoreBeforeForm in [false, true]) {
    testWidgets(
      'remote source keeps old epoch and one global refusal reader; restore before form=$restoreBeforeForm',
      (tester) async {
        final app = _EpochPageApp();
        addTearDown(app.dispose);
        const original = OverrideEntry(
          id: 'same',
          name: 'Same remote',
          kind: ConfigKind.remote,
          revision: 7,
          body: 'rules: ["DOMAIN,old.test,DIRECT"]',
          source: 'https://fixture.invalid/original',
        );
        app.overrides = [original];
        await tester.pumpWidget(_receiptFeedbackHost(app));
        final strings = AppLocalizations.of(
          tester.element(find.byType(OverridesPage)),
        );
        await tester.tap(find.byTooltip(strings.moreLabel));
        await tester.pumpAndSettle();
        final oldSelection = tester
            .widget<MenuItemButton>(
              find.widgetWithText(MenuItemButton, strings.changeSource),
            )
            .onPressed!;
        const restoredBody = 'rules: ["DOMAIN,restored.test,REJECT"]';
        if (restoreBeforeForm) {
          app.restoreSameIdentity(restoredBody);
          await tester.pumpAndSettle();
          oldSelection();
          await tester.pumpAndSettle();
          expect(find.byType(ImportDialog), findsNothing);
          expect(find.byType(MenuItemButton), findsNothing);
          expect(app.commands, isEmpty);
          expect(app.accepted, 0);
          expect(app.overrides.single.id, original.id);
          expect(app.overrides.single.revision, original.revision);
          expect(app.overrides.single.body, restoredBody);
          await tester.pumpWidget(const SizedBox());
          return;
        }
        await tester.tap(find.text(strings.changeSource));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('import-source')),
          'https://candidate.invalid/new',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('loon-proxy-name')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('loon-proxy-name')),
          'Draft survives 🧭',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('loon-no-resolve')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('loon-no-resolve')));
        await tester.pumpAndSettle();
        if (!restoreBeforeForm) {
          app.restoreSameIdentity(restoredBody);
          await tester.pumpAndSettle();
        }
        expect(app.overrides.single.id, original.id);
        expect(app.overrides.single.revision, original.revision);
        expect(app.overrides.single.body, restoredBody);
        await tester.tap(find.text(strings.saveAndUpdate));
        final submitted = app.lastCommand!;
        expect(app.commands.single, same(submitted));
        expect(app.hasLocalFeedbackOwner, isTrue);
        expect(
          app.feedbackHandledLocally(submitted, submissionFailed: true),
          isFalse,
        );
        await tester.pump();
        expect(
          app.feedbackHandledLocally(submitted, submissionFailed: true),
          isFalse,
        );
        await tester.pumpAndSettle();
        expect(app.commands.single['storageEpoch'], 41);
        expect(app.storageEpoch, 42);
        expect(app.accepted, 0);
        expect(app.overrides.single.body, restoredBody);
        expect(find.byType(ImportDialog), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(
          app.feedbackHandledLocally(submitted, submissionFailed: true),
          isTrue,
        );
        expect(_noticeText(strings.storageContextChanged), findsOneWidget);
        await _dismissNotice(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('import-source')))
              .controller!
              .text,
          'https://candidate.invalid/new',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('loon-proxy-name')))
              .controller!
              .text,
          'Draft survives 🧭',
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const ValueKey('loon-no-resolve')),
              )
              .value,
          isTrue,
        );
        app.changed();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(app.commands, hasLength(1));
        await tester.tap(find.text(strings.cancel));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'old popup mode action keeps its open-time epoch after same-ID/revision restore',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      const entry = OverrideEntry(
        id: 'same',
        name: 'Same',
        kind: ConfigKind.local,
        revision: 3,
        body: '{}',
      );
      app.overrides = [entry];
      await tester.pumpWidget(pluginHost(app, feedback: true));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.byTooltip(strings.moreLabel));
      await tester.pumpAndSettle();
      final oldSelection = tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, strings.overrideReplace),
          )
          .onPressed!;
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
      // Callbacks queued before the new frame still use epoch 41.
      oldSelection();
      await tester.pumpAndSettle();
      expect(app.commands.single['action'], 'changeOverride');
      expect(app.commands.single['mode'], 'replace');
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.accepted, 0);
      expect(app.overrides.single.id, entry.id);
      expect(app.overrides.single.revision, entry.revision);
      expect(app.overrides.single.mode, OverrideMode.prepend);
      expect(app.overrides.single.body, contains('restored.test'));
      expect(_noticeText(strings.storageContextChanged), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'file selection keeps menu epoch instead of the restored projection epoch',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'same',
          name: 'Same',
          kind: ConfigKind.local,
          revision: 3,
          body: '{}',
        ),
      ];
      final selected = Completer<XFile?>();
      await tester.pumpWidget(
        pluginHost(app, selectFile: () => selected.future),
      );
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.byTooltip(strings.addOverride));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.importFromFile));
      await tester.pumpAndSettle();
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
      await tester.pumpAndSettle();
      selected.complete(
        XFile.fromData(
          utf8.encode('rules: ["DOMAIN,imported.test,DIRECT"]'),
          path: 'draft.yaml',
        ),
      );
      await tester.pumpAndSettle();
      expect(app.commands, isEmpty);
      expect(app.accepted, 0);
      expect(app.overrides, hasLength(1));
      expect(app.overrides.single.body, contains('restored.test'));
      expect(_noticeText(strings.storageContextChanged), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new plugin editor inherits epoch from before its naming dialog',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'same',
          name: 'Same',
          kind: ConfigKind.local,
          revision: 3,
          body: '{}',
        ),
      ];
      await tester.pumpWidget(pluginHost(app));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.byTooltip(strings.addOverride));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.newOverride));
      await tester.pumpAndSettle();
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'New draft');
      await tester.tap(find.text(strings.continueLabel));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ConfigTextPage>(find.byType(ConfigTextPage)).storageEpoch,
        41,
      );
      final editor = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .controller!;
      final editorState = tester.state(find.byType(CodeEditor));
      final pageState = tester.state(find.byType(ConfigTextPage));
      final focus = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .focusNode!;
      editor.text = 'rules: ["DOMAIN,draft.test,DIRECT"]';
      editor.value = editor.value.copyWith(
        selection: const CodeLineSelection.collapsed(index: 0, offset: 7),
        composing: const TextRange(start: 6, end: 7),
      );
      final accepted = editor.value;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(editor.value, same(accepted));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(editor.value.selection, accepted.selection);
      expect(editor.value.composing, accepted.composing);
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isFalse,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, strings.save))
            .onPressed,
        isNull,
      );
      app.changed();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(editor.value, same(accepted));
      expect(editor.value.selection, accepted.selection);
      expect(editor.value.composing, const TextRange(start: 6, end: 7));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(tester.state(find.byType(ConfigTextPage)), same(pageState));
      await tester.tap(find.text(strings.save));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      final compositionEnded = editor.value;
      expect(compositionEnded.codeLines, same(accepted.codeLines));
      expect(compositionEnded.selection, accepted.selection);
      expect(compositionEnded.composing, TextRange.empty);
      expect(compositionEnded, isNot(same(accepted)));
      app.changed();
      await tester.pump();
      expect(app.commands, isEmpty);
      expect(app.accepted, 0);
      expect(editor.value, same(compositionEnded));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(tester.state(find.byType(ConfigTextPage)), same(pageState));
      expect(_noticeText(strings.editorContextChanged), findsOneWidget);
      expect(app.overrides, hasLength(1));
      expect(app.overrides.single.body, contains('restored.test'));
      expect(find.byType(ConfigTextPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editor advances saved ID/revision but not epoch after partial save and restore',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'same',
          name: 'Same',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
      ];
      app.saveResults.add(
        AppSnapshot(
          phase: 'STOPPED',
          resultId: 'first',
          resultSuccess: false,
          overrideStatus: 'applyFailed',
          targetId: 'same',
          savedRevision: 2,
          resultMessage: messages.overrideSavedReconnectIncomplete,
        ),
      );
      await tester.pumpWidget(pluginHost(app));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.text('Same'));
      await tester.pumpAndSettle();
      final editor = tester
          .widget<CodeEditor>(find.byType(CodeEditor))
          .controller!;
      final editorState = tester.state(find.byType(CodeEditor));
      editor.text = 'rules: ["DOMAIN,first.test,DIRECT"]';
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.save));
      await tester.pumpAndSettle();
      expect(app.overrides.single.revision, 2);
      expect(app.accepted, 1);
      expect(
        _noticeText(messages.overrideSavedReconnectIncomplete.summary(strings)),
        findsOneWidget,
      );
      expect(find.text(strings.savedApplyFailed), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      await _dismissNotice(tester);
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,REJECT"]');
      await tester.pumpAndSettle();
      expect(app.overrides.single.id, 'same');
      expect(app.overrides.single.revision, 2);
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      editor.text = 'rules: ["DOMAIN,corrected.test,DIRECT"]';
      editor.value = editor.value.copyWith(
        selection: const CodeLineSelection.collapsed(index: 0, offset: 7),
        composing: const TextRange(start: 6, end: 7),
      );
      final accepted = editor.value;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(editor.value, same(accepted));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(editor.value.selection, accepted.selection);
      expect(editor.value.composing, accepted.composing);
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isFalse,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, strings.save))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text(strings.save));
      await tester.pumpAndSettle();
      expect(app.commands, hasLength(1));
      expect(app.commands.single['id'], 'same');
      expect(app.commands.single['revision'], 1);
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.accepted, 1);
      expect(app.overrides.single.body, contains('restored.test'));
      expect(editor.text, contains('corrected.test'));
      expect(editor.value, same(accepted));
      expect(tester.state(find.byType(CodeEditor)), same(editorState));
      expect(_noticeText(strings.editorContextChanged), findsOneWidget);
      expect(find.byType(ConfigTextPage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'zh']) {
    for (final accepted in [false, true]) {
      testWidgets(
        'source receipt waiting and ${accepted ? 'acceptance' : 'refusal'} retain geometry $language/2x',
        (tester) async {
          tester.view.physicalSize = const Size(360, 780);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final app = OverridePageApp()..pendingSubmit = Completer<String?>();
          addTearDown(app.dispose);
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [AppTaskNavigatorObserver()],
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: OperationNoticeHost(child: OverridesPage(app: app)),
            ),
          );
          final strings = lookupAppLocalizations(Locale(language));
          await tester.tap(find.byTooltip(strings.addOverride));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.remoteOverride));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('import-source')),
            'https://fixture.invalid/long-draft',
          );
          await tester.pumpAndSettle();
          final targets = [
            find.byKey(const ValueKey('import-source')),
            find.byKey(const ValueKey('loon-proxy-name')),
            find.byKey(const ValueKey('loon-no-resolve')),
            find.text(strings.downloadAndSave),
          ];
          final before = targets.map(tester.getRect).toList();
          await tester.tap(find.text(strings.downloadAndSave));
          for (var frame = 0; frame < 16; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            for (var i = 0; i < targets.length; i++) {
              expect(tester.getRect(targets[i]), before[i]);
            }
          }
          expect(app.commands, hasLength(1));
          expect(app.commands.single['storageEpoch'], 0);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, strings.downloadAndSave),
                )
                .onPressed,
            isNull,
          );
          app.pendingSubmit!.complete(accepted ? 'accepted-receipt' : null);
          await tester.pumpAndSettle();
          if (accepted) {
            expect(find.byType(ImportDialog), findsNothing);
            expect(find.byType(SnackBar), findsNothing);
          } else {
            expect(find.byType(ImportDialog), findsOneWidget);
            expect(
              tester
                  .widget<TextField>(
                    find.byKey(const ValueKey('import-source')),
                  )
                  .controller!
                  .text,
              'https://fixture.invalid/long-draft',
            );
            for (var i = 0; i < targets.length; i++) {
              expect(tester.getRect(targets[i]), before[i]);
            }
            expect(find.byType(AlertDialog), findsOneWidget);
          }
          expect(app.commands, hasLength(1));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'new input typed while receipt is pending is not closed by the old receipt',
    (tester) async {
      final app = OverridePageApp()..pendingSubmit = Completer<String?>();
      addTearDown(app.dispose);
      await tester.pumpWidget(pluginHost(app));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.byTooltip(strings.addOverride));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.remoteOverride));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'https://fixture.invalid/first',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.downloadAndSave));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'https://fixture.invalid/new-draft',
      );
      app.pendingSubmit!.complete('accepted-receipt');
      await tester.pumpAndSettle();
      expect(app.commands, hasLength(1));
      expect(app.commands.single['source'], 'https://fixture.invalid/first');
      expect(find.byType(ImportDialog), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('import-source')))
            .controller!
            .text,
        'https://fixture.invalid/new-draft',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, strings.downloadAndSave),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source receipt defers global result until its captured form retires',
    (tester) async {
      final app = _ReceiptPageApp()..pendingSubmit = Completer<String?>();
      addTearDown(app.dispose);
      await tester.pumpWidget(_receiptFeedbackHost(app));
      final page = tester.element(find.byType(OverridesPage));
      final strings = AppLocalizations.of(page);
      final businessRoute = ModalRoute.of(page)!;
      final readerRoute = ModalRoute.of(
        tester.element(find.byType(OperationFeedback)),
      )!;
      expect(
        identical(businessRoute.navigator, readerRoute.navigator),
        isFalse,
      );
      expect(app.dispatching, isFalse);
      expect(app.busy, isFalse);
      await tester.tap(find.byTooltip(strings.addOverride));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.remoteOverride));
      await tester.pumpAndSettle();
      final formRoute = ModalRoute.of(
        tester.element(find.byType(ImportDialog)),
      )!;
      expect(formRoute.navigator, same(readerRoute.navigator));
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'https://fixture.invalid/accepted',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.downloadAndSave));
      await tester.pump();
      expect(app.commands, hasLength(1));
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.accepted, 1);
      expect(app.dispatching, isTrue);
      expect(app.busy, isTrue);
      app.state = AppSnapshot(
        phase: 'STOPPED',
        storageEpoch: app.epoch,
        resultId: 'download-finished',
        resultSuccess: false,
        resultMessage: messages.downloadFailed,
      );
      app.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(app.dispatching, isTrue);
      expect(app.busy, isTrue);
      expect(formRoute.isCurrent, isTrue);
      expect(readerRoute.isCurrent, isFalse);
      expect(find.byType(ImportDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(_noticeText(strings.downloadFailed), findsNothing);
      app.pendingSubmit!.complete('accepted-receipt');
      await tester.pumpAndSettle();
      expect(app.dispatching, isFalse);
      expect(app.busy, isFalse);
      expect(formRoute.isActive, isFalse);
      expect(find.byType(ImportDialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(_noticeText(strings.downloadFailed), findsOneWidget);
      await _dismissNotice(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(businessRoute.isActive, isTrue);
      expect(businessRoute.isCurrent, isTrue);
      expect(readerRoute.isActive, isTrue);
      expect(readerRoute.isCurrent, isTrue);
      expect(app.commands, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'accepted source receipt removes only its form below an independent root popup',
    (tester) async {
      final app = _ReceiptPageApp()..pendingSubmit = Completer<String?>();
      addTearDown(app.dispose);
      await tester.pumpWidget(_receiptFeedbackHost(app));
      final page = tester.element(find.byType(OverridesPage));
      final strings = AppLocalizations.of(page);
      final businessRoute = ModalRoute.of(page)!;
      final readerRoute = ModalRoute.of(
        tester.element(find.byType(OperationFeedback)),
      )!;
      await tester.tap(find.byTooltip(strings.addOverride));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.remoteOverride));
      await tester.pumpAndSettle();
      final formContext = tester.element(find.byType(ImportDialog));
      final formRoute = ModalRoute.of(formContext)!;
      final rootNavigator = formRoute.navigator!;
      expect(
        rootNavigator,
        same(Navigator.of(formContext, rootNavigator: true)),
      );
      expect(rootNavigator, same(readerRoute.navigator));
      expect(identical(rootNavigator, businessRoute.navigator), isFalse);
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'https://fixture.invalid/accepted',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.downloadAndSave));
      await tester.pump();
      expect(app.dispatching, isTrue);
      expect(app.busy, isTrue);
      const popupKey = ValueKey('independent-receipt-popup');
      const popupBody = 'Independent test popup\n完整合成正文：此浮层不属于表单。';
      final popupRoute = DialogRoute<void>(
        context: formContext,
        builder: (context) => AlertDialog(
          key: popupKey,
          content: const SelectableText(popupBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(strings.close),
            ),
          ],
        ),
      );
      rootNavigator.push<void>(popupRoute);
      await tester.pumpAndSettle();
      final popupElement = tester.element(find.byKey(popupKey));
      expect(find.byType(ImportDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsNWidgets(2));
      expect(formRoute.isActive, isTrue);
      expect(formRoute.isCurrent, isFalse);
      expect(popupRoute.isActive, isTrue);
      expect(popupRoute.isCurrent, isTrue);
      app.pendingSubmit!.complete('accepted-receipt');
      await tester.pumpAndSettle();
      expect(app.dispatching, isFalse);
      expect(app.busy, isFalse);
      expect(formRoute.isActive, isFalse);
      expect(find.byType(ImportDialog), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(popupRoute.navigator, same(rootNavigator));
      expect(popupRoute.isActive, isTrue);
      expect(popupRoute.isCurrent, isTrue);
      expect(tester.element(find.byKey(popupKey)), same(popupElement));
      expect(ModalRoute.of(popupElement), same(popupRoute));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == popupBody,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(strings.close));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(popupRoute.isActive, isFalse);
      expect(businessRoute.isActive, isTrue);
      expect(businessRoute.isCurrent, isTrue);
      expect(readerRoute.isActive, isTrue);
      expect(readerRoute.isCurrent, isTrue);
      expect(find.byType(OverridesPage), findsOneWidget);
      expect(app.commands, hasLength(1));
      expect(app.commands.single['source'], 'https://fixture.invalid/accepted');
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.accepted, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source form freezes epoch at initialization before its first submission',
    (tester) async {
      final epoch = ValueNotifier(41);
      addTearDown(epoch.dispose);
      final received = <Map<String, Object?>>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: epoch,
              builder: (_, value, _) => ImportDialog(
                source: 'https://fixture.invalid/original',
                storageEpoch: value,
                onSubmit: (input) async {
                  received.add(input);
                  return false;
                },
              ),
            ),
          ),
        ),
      );
      final strings = lookupAppLocalizations(const Locale('en'));
      await tester.enterText(
        find.byKey(const ValueKey('import-source')),
        'https://fixture.invalid/draft',
      );
      await tester.pumpAndSettle();
      epoch.value = 42;
      await tester.pumpAndSettle();
      expect(
        tester.widget<ImportDialog>(find.byType(ImportDialog)).storageEpoch,
        42,
      );
      await tester.tap(find.text(strings.downloadAndSave));
      await tester.pumpAndSettle();
      expect(received.single['storageEpoch'], 41);
      expect(received.single['source'], 'https://fixture.invalid/draft');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('import-source')))
            .controller!
            .text,
        'https://fixture.invalid/draft',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('rename refusal after restore keeps the original name draft', (
    tester,
  ) async {
    final app = _EpochPageApp();
    addTearDown(app.dispose);
    app.overrides = const [
      OverrideEntry(
        id: 'same',
        name: 'Same',
        kind: ConfigKind.local,
        revision: 3,
        body: '{}',
      ),
    ];
    await tester.pumpWidget(_receiptFeedbackHost(app));
    final strings = AppLocalizations.of(
      tester.element(find.byType(OverridesPage)),
    );
    await tester.tap(find.byTooltip(strings.moreLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.rename));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Name draft');
    app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.save));
    final submitted = app.lastCommand!;
    expect(app.commands.single, same(submitted));
    expect(app.hasLocalFeedbackOwner, isTrue);
    expect(
      app.feedbackHandledLocally(submitted, submissionFailed: true),
      isFalse,
    );
    await tester.pump();
    expect(
      app.feedbackHandledLocally(submitted, submissionFailed: true),
      isFalse,
    );
    await tester.pumpAndSettle();
    expect(app.commands.single['storageEpoch'], 41);
    expect(app.commands.single['name'], 'Name draft');
    expect(app.accepted, 0);
    expect(app.overrides.single.name, 'Same');
    expect(app.overrides.single.body, contains('restored.test'));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(app.hasLocalFeedbackOwner, isFalse);
    expect(
      app.feedbackHandledLocally(submitted, submissionFailed: true),
      isTrue,
    );
    expect(_noticeText(strings.storageContextChanged), findsOneWidget);
    await _dismissNotice(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Name draft',
    );
    expect(find.byType(AlertDialog), findsOneWidget);
    app.changed();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'delete confirmation cannot delete restored content with identical ID and revision',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'same',
          name: 'Same',
          kind: ConfigKind.local,
          revision: 3,
          body: '{}',
        ),
      ];
      await tester.pumpWidget(pluginHost(app, feedback: true));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.byTooltip(strings.moreLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.overrideDelete));
      await tester.pumpAndSettle();
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
      await tester.pumpAndSettle();
      await tester.tap(find.text(strings.overrideDelete).hitTestable());
      await tester.pumpAndSettle();
      expect(app.commands.single['action'], 'deleteOverride');
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.accepted, 0);
      expect(app.overrides, hasLength(1));
      expect(app.overrides.single.id, 'same');
      expect(app.overrides.single.revision, 3);
      expect(app.overrides.single.body, contains('restored.test'));
      expect(_noticeText(strings.storageContextChanged), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'old move menu uses its captured order when restore changes list membership',
    (tester) async {
      final app = _EpochPageApp();
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'first',
          name: 'First',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
        OverrideEntry(
          id: 'second',
          name: 'Second',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
      ];
      await tester.pumpWidget(pluginHost(app, feedback: true));
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('override-first')),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pumpAndSettle();
      final oldSelection = tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, strings.overrideMoveDown),
          )
          .onPressed!;
      app.restoreSameIdentity('rules: ["DOMAIN,restored.test,DIRECT"]');
      app.overrides = [app.overrides.first];
      app.changed();
      oldSelection();
      await tester.pumpAndSettle();
      expect(app.commands.single['action'], 'reorderOverrides');
      expect(app.commands.single['ids'], ['second', 'first']);
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.accepted, 0);
      expect(app.overrides, hasLength(1));
      expect(app.overrides.single.id, 'first');
      expect(app.overrides.single.body, contains('restored.test'));
      expect(_noticeText(strings.storageContextChanged), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final leave in [false, true]) {
    testWidgets(
      'plugin file import preserves raw text and ignores late selection $leave',
      (tester) async {
        final app = OverridePageApp();
        addTearDown(app.dispose);
        final selected = Completer<XFile?>();
        var selections = 0;
        await tester.pumpWidget(
          pluginHost(
            app,
            selectFile: () {
              selections++;
              return selected.future;
            },
          ),
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(OverridesPage)),
        );
        await tester.tap(find.byTooltip(strings.addOverride));
        await tester.pumpAndSettle();
        await tester.tap(find.text(strings.importFromFile));
        await tester.pumpAndSettle();
        expect(selections, 1);
        expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
              .onPressed,
          isNull,
        );
        if (leave) await tester.pumpWidget(const SizedBox());
        final body =
            '${String.fromCharCode(0xfeff)}rules:\r\n  - MATCH,DIRECT\n# 片段\r\n';
        selected.complete(
          XFile.fromData(utf8.encode(body), path: 'fixture.yaml'),
        );
        await tester.pumpAndSettle();
        if (leave) {
          expect(app.commands, isEmpty);
        } else {
          expect(app.commands.single, {
            'storageEpoch': 0,
            'action': 'saveOverride',
            'name': 'fixture',
            'body': body,
          });
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('cancelled plugin file picker does not submit', (tester) async {
    final app = OverridePageApp();
    addTearDown(app.dispose);
    await tester.pumpWidget(pluginHost(app));
    final strings = AppLocalizations.of(
      tester.element(find.byType(OverridesPage)),
    );
    await tester.tap(find.byTooltip(strings.addOverride));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.importFromFile));
    await tester.pumpAndSettle();
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final language in ['zh', 'en']) {
    for (final cancel in [false, true]) {
      testWidgets(
        'remote HTTP plugin submits directly or cancels $language $cancel',
        (tester) async {
          final app = OverridePageApp();
          addTearDown(app.dispose);
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [AppTaskNavigatorObserver()],
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: OperationNoticeHost(child: OverridesPage(app: app)),
            ),
          );
          final strings = AppLocalizations.of(
            tester.element(find.byType(OverridesPage)),
          );
          await tester.tap(find.byTooltip(strings.addOverride));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.remoteOverride));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(1), 'Fixture');
          await tester.enterText(
            find.byType(TextField).at(0),
            'http://fixture.test/plugin.yaml',
          );
          await tester.tap(
            find.text(cancel ? strings.cancel : strings.downloadAndSave),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          if (cancel) {
            expect(app.commands, isEmpty);
          } else {
            expect(app.commands.single, {
              'storageEpoch': 0,
              'action': 'importOverride',
              'name': 'Fixture',
              'source': 'http://fixture.test/plugin.yaml',
              'proxyName': '',
              'addNoResolve': false,
            });
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'overrides change enablement and order without a separate apply step',
    (tester) async {
      final app = OverridePageApp()
        ..state = const AppSnapshot(phase: 'RUNNING');
      addTearDown(app.dispose);
      app.overrides = const [
        OverrideEntry(
          id: 'a',
          name: 'First',
          kind: ConfigKind.local,
          revision: 2,
          body: '{}',
        ),
        OverrideEntry(
          id: 'b',
          name: 'Second',
          kind: ConfigKind.remote,
          source: 'https://example.test/p',
          revision: 1,
          body: 'rules: []',
          enabled: true,
          mode: OverrideMode.replace,
        ),
      ];
      app.overridesLoaded = true;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: OperationNoticeHost(child: OverridesPage(app: app)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      expect(find.textContaining('覆盖同类设置'), findsOneWidget);
      expect(find.byKey(const ValueKey('override-apply')), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('override-a')),
          matching: find.byType(Switch),
        ),
      );
      await tester.pumpAndSettle();
      expect(app.commands.last['action'], 'changeOverride');
      expect(app.commands.last['enabled'], isTrue);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('override-a')),
          matching: find.byIcon(Icons.more_vert),
        ),
      );
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(OverridesPage)),
      );
      await tester.tap(find.text(strings.overrideMoveDown));
      await tester.pumpAndSettle();
      expect(app.commands.last['action'], 'reorderOverrides');
      expect(app.commands.last['ids'], ['b', 'a']);
      expect(app.commands, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
