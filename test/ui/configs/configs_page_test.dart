import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:re_editor/re_editor.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/ui/configs/configs_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/readonly_override_store.dart';
import '../../support/preferences_fakes.dart';

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

class PageBridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  final commands = <Map<String, Object?>>[];
  Completer<String?>? pending;
  AppSnapshot? fieldResult;

  @override
  Future<AppSnapshot> snapshot() async => state;

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    final accepted = pending == null ? 'operation' : await pending!.future;
    if (command['storageEpoch'] != state.storageEpoch) {
      throw PlatformFailure(
        code: 'storage',
        details: messages.storageUnavailable.toMap(),
      );
    }
    if (accepted != null &&
        const ['renameConfig', 'updateConfig'].contains(command['action'])) {
      state =
          fieldResult ??
          AppSnapshot(
            phase: state.phase,
            storageEpoch: state.storageEpoch,
            configId: state.configId,
            revision: state.revision,
            resultId: accepted,
            resultSuccess: true,
            configStatus: 'saved',
            targetId: command['id'] as String,
            savedRevision: command['revision'] as int,
          );
    }
    return accepted == null
        ? null
        : OperationAdmission(
            operationId: accepted,
            remaining: const Duration(seconds: 120),
          );
  }
}

class PageStore extends ConfigStore {
  PageStore(this.collection) : super(Directory.systemTemp);
  ConfigCollection collection;

  @override
  Future<ConfigCollection> read() async => collection;
}

void main() {
  tearDown(() => setMessageLanguage(AppLanguage.system));
  const first = ConfigEntry(
    id: 'first',
    name: 'First',
    source: 'https://example.test/first',
    revision: 1,
    body: 'rules: []',
  );
  const second = ConfigEntry(
    id: 'second',
    name: 'Second',
    source: 'https://example.test/second',
    revision: 1,
    body: 'rules: []',
  );
  Map<String, Object?> capturedTarget(ConfigEntry entry) => {
    'id': entry.id,
    'revision': entry.revision,
    'expectedSource': entry.source,
    'expectedName': entry.name,
  };
  late PageBridge bridge;
  late AppController controller;
  late PageStore store;

  Future<void> showPage(
    WidgetTester tester, {
    bool running = false,
    bool busy = false,
    ConfigEntry candidate = second,
    double scale = 1,
    bool dark = false,
    BrandColor brand = BrandColor.cinnabar,
    String language = 'zh',
    int storageEpoch = 0,
    bool feedback = false,
    bool Function()? isActiveNow,
    bool disableAnimations = false,
    ValueNotifier<bool>? reducedMotion,
  }) async {
    bridge = PageBridge()
      ..state = AppSnapshot(
        phase: running ? 'RUNNING' : 'STOPPED',
        storageEpoch: storageEpoch,
        configId: running ? first.id : null,
        operation: busy ? messages.stageStartingTunnel : null,
      );
    store = PageStore(
      ConfigCollection(entries: [first, candidate], selectedId: first.id),
    );
    controller = AppController(
      bridge,
      store: store,
      preferencesStore: MemoryPreferencesStore()
        ..value = AppPreferences(
          language: AppLanguage.values.byName(language),
          brand: brand,
        ),
      overrideStore: ReadOnlyOverrideStore(),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale(language),
        theme: AppTheme.forBrightness(
          dark ? Brightness.dark : Brightness.light,
          brand,
        ),
        builder: (context, child) {
          final content = AppTaskActivity(
            active: true,
            isActiveNow: isActiveNow,
            child: child!,
          );
          Widget media(bool reduced) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduced,
            ),
            child: content,
          );
          return reducedMotion == null
              ? media(disableAnimations)
              : ValueListenableBuilder<bool>(
                  valueListenable: reducedMotion,
                  builder: (_, reduced, _) => media(reduced),
                );
        },
        home: OperationNoticeHost(
          child: feedback
              ? OperationFeedback(
                  controller: controller,
                  child: ConfigsPage(controller: controller),
                )
              : ConfigsPage(controller: controller),
        ),
      ),
    );
  }

  Finder tile(String name) => find
      .descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
        matching: find.byType(InkWell),
      )
      .first;

  group('configuration state and error actions', () {
    for (final language in ['en', 'zh']) {
      testWidgets(
        'error action reads the full cause without selecting $language',
        (tester) async {
          final raw =
              'FormatException: original matcher\nunknown-field: {value: raw}\n' *
              40;
          final error = const AppMessage('downloadFailed').withDetail(raw);
          final entry = ConfigEntry(
            id: 'second',
            name: 'Failed configuration 配置',
            kind: ConfigKind.local,
            revision: 1,
            body: '{}',
            error: error,
          );
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
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await showPage(tester, candidate: entry, language: language);
          await tester.pumpAndSettle();
          final strings = lookupAppLocalizations(Locale(language));
          expect(
            find.byKey(const ValueKey('config-error-second')),
            findsNothing,
          );
          final card = find.byKey(const ValueKey('config-second'));
          final menu = find.descendant(
            of: card,
            matching: find.byTooltip(strings.moreActions),
          );
          final cardRect = tester.getRect(card);
          final menuRect = tester.getRect(menu);
          final action = find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, strings.errorDetails),
          );
          expect(action, findsOneWidget);
          final cached = tester.widget<TextButton>(action).onPressed!;
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(tester.getRect(card), cardRect);
          expect(tester.getRect(menu), menuRect);
          expect(find.byType(ConfigTextPage), findsNothing);
          expect(controller.collection.selectedId, first.id);
          expect(bridge.commands, isEmpty);
          expect(find.text(strings.configActionFailed), findsWidgets);
          expect(find.text(error.summary(strings)), findsNothing);
          expect(find.text(error.resolve(strings)), findsNothing);
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
          final copy = find.byKey(const ValueKey('operation-technical-copy'));
          await tester.ensureVisible(copy);
          await tester.pumpAndSettle();
          await tester.tap(copy);
          await tester.pumpAndSettle();
          expect(copied, detail);
          final lateCopy = tester.widget<TextButton>(copy).onPressed!;
          copied = null;
          controller.setForeground(false);
          controller.setForeground(true);
          lateCopy();
          await tester.pumpAndSettle();
          expect(copied, isNull);
          expect(find.byType(AlertDialog), findsNothing);
          controller.setForeground(false);
          cached();
          controller.setForeground(true);
          cached();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(controller.collection.selectedId, first.id);
          expect(bridge.commands, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('selection and running revisions remain distinct $language', (
        tester,
      ) async {
        await showPage(tester, language: language);
        final strings = lookupAppLocalizations(Locale(language));
        bridge.state = const AppSnapshot(
          phase: 'RUNNING',
          configId: 'second',
          revision: 0,
        );
        await controller.refresh();
        await tester.pumpAndSettle();
        final selected = find.byKey(const ValueKey('config-first'));
        final running = find.byKey(const ValueKey('config-second'));
        bool selectedSemantics(Finder card) => tester
            .widget<Semantics>(
              find
                  .ancestor(
                    of: card,
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is Semantics &&
                          widget.properties.label == strings.selectConfig,
                    ),
                  )
                  .first,
            )
            .properties
            .selected!;
        expect(selectedSemantics(selected), isTrue);
        expect(selectedSemantics(running), isFalse);
        expect(
          find.descendant(of: selected, matching: find.byIcon(Icons.check)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: running,
            matching: find.textContaining(strings.runningOldBody),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: running, matching: find.byIcon(Icons.check)),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('config-state-first')), findsNothing);
        expect(find.byKey(const ValueKey('config-state-second')), findsNothing);
        final rectangles = [tester.getRect(selected), tester.getRect(running)];
        store.collection = ConfigCollection(
          entries: [first, second],
          selectedId: second.id,
        );
        bridge.state = const AppSnapshot(
          phase: 'RUNNING',
          configId: 'second',
          revision: 1,
        );
        await controller.refresh();
        await tester.pumpAndSettle();
        expect(selectedSemantics(selected), isFalse);
        expect(selectedSemantics(running), isTrue);
        expect(
          find.descendant(of: running, matching: find.byIcon(Icons.check)),
          findsNothing,
        );
        expect(
          find.descendant(
            of: running,
            matching: find.textContaining(strings.runningConfig),
          ),
          findsOneWidget,
        );
        expect([tester.getRect(selected), tester.getRect(running)], rectangles);
        expect(bridge.commands, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('real Tab and Enter open the configuration error notice', (
      tester,
    ) async {
      final entry = second.withContent(
        second.body,
        error: messages.downloadFailed,
      );
      await showPage(tester, candidate: entry, language: 'en');
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      final action = find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.errorDetails),
      );
      bool focused(Finder target) {
        final owner = tester.element(target);
        final context = FocusManager.instance.primaryFocus?.context;
        if (identical(owner, context)) return true;
        var belongs = false;
        context?.visitAncestorElements((element) {
          if (identical(element, owner)) belongs = true;
          return !belongs;
        });
        return belongs;
      }

      for (var step = 0; step < 24 && !focused(action); step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(focused(action), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(ConfigTextPage), findsNothing);
      expect(controller.collection.selectedId, first.id);
      expect(bridge.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'configuration empty header bypasses size animation without retiring the list',
    (tester) async {
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      await showPage(tester, language: 'en', reducedMotion: reduced);
      final page = find.byType(ConfigsPage);
      final pageState = tester.state(page);
      final viewport = tester.element(find.byType(CustomScrollView));
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller;
      final strings = lookupAppLocalizations(const Locale('en'));
      final sizes = find.descendant(
        of: page,
        matching: find.bySubtype<AnimatedSize>(skipOffstage: false),
        skipOffstage: false,
      );
      Future<void> pumpClean([int milliseconds = 0]) async {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(tester.takeException(), isNull);
      }

      Future<void> publish(List<ConfigEntry> entries) async {
        store.collection = ConfigCollection(
          entries: entries,
          selectedId: entries.isEmpty ? null : first.id,
        );
        await controller.refresh();
        await pumpClean();
      }

      await publish([]);
      expect(find.text(strings.noSavedConfigs), findsOneWidget);
      expect(sizes, findsNothing);
      final emptyHeight = tester
          .getSize(
            find
                .ancestor(
                  of: find.text(strings.noSavedConfigs),
                  matching: find.byType(Padding),
                )
                .first,
          )
          .height;
      await publish([first]);
      expect(find.text(strings.noSavedConfigs), findsNothing);
      expect(sizes, findsNothing);
      final firstCard = find.byKey(const ValueKey('config-first'));
      final reducedCard = tester.element(firstCard);
      reduced.value = false;
      await pumpClean();
      expect(tester.element(firstCard), same(reducedCard));
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
      expect(expanding, greaterThan(0));
      expect(expanding, lessThan(emptyHeight));
      await publish([first]);
      expect(tester.getSize(sizes.first).height, closeTo(expanding, .01));
      await pumpClean(60);
      expect(tester.getSize(sizes.first).height, lessThan(expanding));
      final returningCard = tester.element(firstCard);
      final cardScroll = tester.state<ScrollableState>(
        find.descendant(of: firstCard, matching: find.byType(Scrollable)),
      );
      reduced.value = true;
      await pumpClean();
      expect(sizes, findsNothing);
      expect(tester.element(firstCard), same(returningCard));
      expect(
        tester.state<ScrollableState>(
          find.descendant(of: firstCard, matching: find.byType(Scrollable)),
        ),
        same(cardScroll),
      );
      await publish([]);
      expect(find.text(strings.noSavedConfigs), findsOneWidget);
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
      expect(tester.widget<ConfigsPage>(page).controller, same(controller));
      expect(bridge.commands, isEmpty);
    },
  );

  testWidgets(
    'configuration card height keeps content state through reverse and dynamic reduce',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(600, 1000);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final reduced = ValueNotifier(false);
      addTearDown(reduced.dispose);
      await showPage(tester, language: 'en', reducedMotion: reduced);
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('config-second'));
      final element = tester.element(card);
      final titleElement = tester.element(find.text(second.name));
      final cardScroll = tester.state<ScrollableState>(
        find.descendant(of: card, matching: find.byType(Scrollable)),
      );
      final pageState = tester.state(find.byType(ConfigsPage));
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
        store.collection = store.collection.replace(second.renamed(name));
        await controller.refresh();
        await pumpClean();
      }

      final originalHeight = tester.getSize(sizeTween()).height;
      final longName = 'Second wrapped configuration name ' * 12;
      await rename(longName);
      final expandedHeight = tester.getSize(card).height;
      expect(expandedHeight, greaterThan(originalHeight));
      expect(tester.getSize(sizeTween()).height, closeTo(originalHeight, .01));
      await pumpClean(70);
      final middle = tester.getSize(sizeTween()).height;
      expect(middle, greaterThan(originalHeight));
      expect(middle, lessThan(expandedHeight));
      await rename(second.name);
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
      await rename(second.name);
      await pumpClean(60);
      reduced.value = true;
      await pumpClean();
      expect(tester.getSize(card).height, closeTo(originalHeight, .01));
      expect(tester.element(card), same(element));
      expect(tester.element(find.text(second.name)), same(titleElement));
      expect(
        tester.state<ScrollableState>(
          find.descendant(of: card, matching: find.byType(Scrollable)),
        ),
        same(cardScroll),
      );
      expect(tester.state(find.byType(ConfigsPage)), same(pageState));
      expect(
        tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller,
        same(scroll),
      );
      expect(bridge.commands, isEmpty);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached configuration update and selection lose task authority before rebuild',
    (tester) async {
      var active = true;
      await showPage(tester, language: 'en', isActiveNow: () => active);
      await tester.pumpAndSettle();
      final update = tester
          .widget<IconButton>(
            find.descendant(
              of: find.byKey(const ValueKey('config-second')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip ==
                        lookupAppLocalizations(const Locale('en')).updateConfig,
              ),
            ),
          )
          .onPressed!;
      final select = tester.widget<InkWell>(tile('Second')).onTap!;
      active = false;
      update();
      select();
      expect(bridge.commands, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'configuration cards retain identity and interpolate column regrouping reduced=$reduced',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final semantics = tester.ensureSemantics();
        try {
          final motion = ValueNotifier(reduced);
          addTearDown(motion.dispose);
          await showPage(tester, language: 'en', reducedMotion: motion);
          await tester.pumpAndSettle();
          final card = find.byKey(const ValueKey('config-second'));
          final element = tester.element(card);
          final wide = tester.getRect(card);
          tester.view.physicalSize = const Size(740, 900);
          await tester.pump();
          final start = tester.getRect(card);
          if (!reduced) {
            expect(
              find.ancestor(of: card, matching: find.bySubtype<AnimatedSize>()),
              findsNothing,
            );
            expect(start.left, closeTo(wide.left, .01));
            expect(start.top, closeTo(wide.top, .01));
            expect(start.width, closeTo(wide.width, .01));
            await tester.pump(const Duration(milliseconds: 80));
            final middle = tester.getRect(card);
            expect(middle.left, lessThan(wide.left));
            expect(middle.top, greaterThan(wide.top));
            expect(middle.width, greaterThan(wide.width));
            final title = find.text('Second');
            final node = tester.getSemantics(title);
            var semanticTransform = Matrix4.identity();
            for (var current = node; ;) {
              if (current.transform != null) {
                semanticTransform = current.transform! * semanticTransform;
              }
              final parent = current.parent;
              if (parent == null) break;
              current = parent;
            }
            final semanticRect = MatrixUtils.transformRect(
              semanticTransform,
              node.rect,
            );
            expect(semanticRect.contains(tester.getCenter(title)), isTrue);
            await tester.tap(title);
            await tester.pump();
            expect(bridge.commands.single, {
              'action': 'select',
              ...capturedTarget(second),
              'storageEpoch': 0,
            });
            tester.view.physicalSize = const Size(800, 900);
            await tester.pump();
            final reverse = tester.getRect(card);
            expect(reverse.left, closeTo(middle.left, .01));
            expect(reverse.top, closeTo(middle.top, .01));
            expect(reverse.width, closeTo(middle.width, .01));
            await tester.pump(const Duration(milliseconds: 80));
            final returning = tester.getRect(card);
            expect(returning.left, greaterThan(reverse.left));
            expect(returning.width, lessThan(reverse.width));
            motion.value = true;
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(
              find.ancestor(of: card, matching: find.bySubtype<AnimatedSize>()),
              findsNothing,
            );
            expect(tester.getRect(card).width, closeTo(wide.width, .01));
            expect(tester.element(card), same(element));
            motion.value = false;
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(tester.element(card), same(element));
          } else {
            expect(start.left, lessThan(wide.left));
            expect(start.top, greaterThan(wide.top));
            expect(start.width, greaterThan(wide.width));
          }
          await tester.pumpAndSettle();
          expect(tester.element(card), same(element));
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets('dragging a moving grid card retains its scroll ancestor', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await showPage(tester, language: 'en');
    store.collection = ConfigCollection(
      entries: [
        first,
        second,
        for (var index = 2; index < 12; index++)
          ConfigEntry(
            id: 'extra-$index',
            name: 'Extra $index',
            kind: ConfigKind.local,
            revision: 1,
            body: '',
          ),
      ],
      selectedId: first.id,
    );
    await controller.refresh();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(740, 700);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scroll.controller!.offset, 0);
    await tester.dragFrom(
      tester.getCenter(find.text('Second')),
      const Offset(0, -80),
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.controller!.offset, greaterThan(0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('more actions retire across background and resume', (
    tester,
  ) async {
    try {
      await showPage(tester, language: 'en');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      expect(find.text('Rename').hitTestable(), findsOneWidget);
      controller.setForeground(false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(find.text('Rename').hitTestable(), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      controller.setForeground(true);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
      expect(bridge.commands, isEmpty);
      await tester.tap(find.byIcon(Icons.more_vert).first);
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
        for (final width in [320.0, 411.0, 760.0]) {
          for (final scale in [1.0, 1.3, 2.0]) {
            testWidgets(
              'card roles and stable metadata $dark/$brand/$language/$width/$scale',
              (tester) async {
                tester.view.physicalSize = Size(width, 1100);
                tester.view.devicePixelRatio = 1;
                addTearDown(tester.view.resetPhysicalSize);
                addTearDown(tester.view.resetDevicePixelRatio);
                final local = ConfigEntry(
                  id: 'second',
                  name: '配置 Long name 🌐 ' * 3,
                  kind: ConfigKind.local,
                  revision: 1,
                  body: '',
                );
                await showPage(
                  tester,
                  candidate: local,
                  scale: scale,
                  dark: dark,
                  brand: brand,
                  language: language,
                );
                await tester.pumpAndSettle();
                final card = find.ancestor(
                  of: find.text(local.name),
                  matching: find.byType(Card),
                );
                final remote = find.ancestor(
                  of: find.text(first.name),
                  matching: find.byType(Card),
                );
                final strings = lookupAppLocalizations(Locale(language));
                final palette = HomePalette(dark, brand: brand);
                Finder inside(Finder root, Finder child) =>
                    find.descendant(of: root, matching: child);
                final appBar = find.byType(AppBar);
                final pageTitle = inside(
                  appBar,
                  find.text(strings.configTitle),
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
                void checkSelectionColumns(Finder selectedCard) {
                  expect(
                    inside(selectedCard, find.byIcon(Icons.check)),
                    findsNothing,
                  );
                  final more = inside(
                    selectedCard,
                    find.byTooltip(strings.moreActions),
                  );
                  final actionSize = tester.getSize(more);
                  expect(actionSize.width, greaterThanOrEqualTo(48));
                  expect(actionSize.height, greaterThanOrEqualTo(48));
                  final name = selectedCard == remote ? first.name : local.name;
                  expect(
                    tester
                        .widget<Text>(inside(selectedCard, find.text(name)))
                        .style!
                        .fontWeight,
                    FontWeight.w700,
                  );
                }

                checkSelectionColumns(remote);
                final targets = [
                  card,
                  inside(card, find.text(local.name)),
                  inside(card, find.text(strings.localConfig)),
                  inside(card, find.byType(SingleChildScrollView)),
                  inside(card, find.byTooltip(strings.editConfig)),
                  inside(card, find.byTooltip(strings.moreActions)),
                ];
                final rectangles = targets.map(tester.getRect).toList();
                expect(
                  tester
                      .widget<Text>(inside(card, find.text(local.name)))
                      .maxLines,
                  isNull,
                );
                for (final icon in [
                  (remote, Icons.cloud_outlined, palette.remoteSource),
                  (card, Icons.description_outlined, palette.localSource),
                ]) {
                  expect(
                    tester
                        .widget<Icon>(inside(icon.$1, find.byIcon(icon.$2)))
                        .color,
                    icon.$3,
                  );
                }
                expect(
                  IconTheme.of(
                    tester.element(inside(remote, find.byIcon(Icons.refresh))),
                  ).color,
                  palette.syncAction,
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
                expect(
                  tester.getTopLeft(targets[1]).dx,
                  tester.getTopLeft(targets[2]).dx,
                );
                expect(
                  tester.getTopLeft(targets[1]).dx,
                  tester.getTopLeft(targets[3]).dx,
                );
                for (final (phase, revision, error, busy, selection) in [
                  ('RUNNING', 1, null, false, 'second'),
                  ('RUNNING', 2, messages.downloadFailed, true, 'first'),
                  ('UNKNOWN', 1, messages.downloadFailed, false, 'second'),
                  ('STOPPED', 1, null, false, 'first'),
                ]) {
                  store.collection = ConfigCollection(
                    entries: [
                      first,
                      local.withContent(local.body, error: error),
                    ],
                    selectedId: selection,
                  );
                  bridge.state = AppSnapshot(
                    phase: phase,
                    configId: 'second',
                    revision: revision,
                    operation: busy ? messages.stageStartingTunnel : null,
                  );
                  await controller.refresh();
                  for (var frame = 0; frame < 8; frame++) {
                    await tester.pump(const Duration(milliseconds: 16));
                    expect(targets.map(tester.getRect).toList(), rectangles);
                    checkSelectionColumns(selection == 'first' ? remote : card);
                    expect(tester.takeException(), isNull);
                  }
                }
                expect(bridge.commands, isEmpty);
                await tester.pumpWidget(const SizedBox.shrink());
              },
            );
          }
        }
      }
    }
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'compact cards retain geometry across states dark=$dark scale=$scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const entry = ConfigEntry(
            id: 'second',
            name: '很长的配置名称 Long configuration 🌐',
            kind: ConfigKind.local,
            revision: 1,
            body: '',
          );
          await showPage(tester, candidate: entry, scale: scale, dark: dark);
          final card = find.ancestor(
            of: find.text(entry.name),
            matching: find.byType(Card),
          );
          await tester.ensureVisible(card);
          await tester.pumpAndSettle();
          final before = tester.getRect(card);
          final theme = dark ? AppTheme.dark : AppTheme.light;
          final luminances = [
            theme.colorScheme.primary.computeLuminance(),
            theme.colorScheme.surface.computeLuminance(),
          ]..sort();
          expect(
            (luminances.last + .05) / (luminances.first + .05),
            greaterThanOrEqualTo(3),
          );
          final initialShape =
              tester.widget<Card>(card).shape! as RoundedRectangleBorder;
          expect(initialShape.side.width, 1.5);
          expect(initialShape.side.color, Colors.transparent);
          final namePosition = tester.getTopLeft(find.text(entry.name));
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text(entry.name),
              matching: find.byType(RichText),
            ),
          );
          final firstGlyph = paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 1),
              )
              .single;
          final firstLineCenter =
              namePosition.dy + (firstGlyph.top + firstGlyph.bottom) / 2;
          expect(
            tester
                .getCenter(
                  find.descendant(
                    of: card,
                    matching: find.byIcon(Icons.description_outlined),
                  ),
                )
                .dy,
            closeTo(firstLineCenter, .5),
          );
          final edit = find.descendant(
            of: card,
            matching: find.byTooltip('编辑配置'),
          );
          final menu = find.descendant(
            of: card,
            matching: find.byTooltip('更多操作'),
          );
          final buttons = [tester.getRect(edit), tester.getRect(menu)];
          expect(find.text('当前选择'), findsNothing);
          expect(find.byTooltip('配置说明'), findsNothing);
          expect(find.byTooltip('配置状态'), findsNothing);
          for (final (selected, phase, revision, error) in [
            ('second', 'STOPPED', 1, null),
            ('second', 'RUNNING', 1, null),
            ('first', 'RUNNING', 2, null),
            ('first', 'STOPPED', 1, messages.downloadFailed),
            ('first', 'STOPPED', 1, null),
          ]) {
            store.collection = ConfigCollection(
              entries: [
                first,
                entry.withContent('', error: error),
              ],
              selectedId: selected,
            );
            bridge.state = AppSnapshot(
              phase: phase,
              configId: 'second',
              revision: revision,
            );
            await controller.refresh();
            for (var frame = 0; frame < 12; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.takeException(), isNull);
              expect(tester.getRect(card), before);
              expect(tester.getTopLeft(find.text(entry.name)), namePosition);
              expect(
                find.descendant(of: card, matching: find.byIcon(Icons.check)),
                findsNothing,
              );
              expect(
                tester.widget<Text>(find.text(entry.name)).style!.fontWeight,
                selected == entry.id ? FontWeight.w700 : FontWeight.w400,
              );
              final shape =
                  tester.widget<Card>(card).shape! as RoundedRectangleBorder;
              expect(shape.borderRadius, initialShape.borderRadius);
              expect(shape.side.width, 1.5);
              expect(
                shape.side.color,
                selected == entry.id
                    ? theme.colorScheme.primary
                    : Colors.transparent,
              );
              expect([tester.getRect(edit), tester.getRect(menu)], buttons);
            }
          }
        },
      );
    }
  }

  testWidgets(
    'error details remain available without normal information buttons',
    (tester) async {
      await showPage(
        tester,
        candidate: second.withContent(
          second.body,
          error: messages.downloadFailed,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(SnackBar), matching: find.text('错误详情')),
      );
      await tester.pumpAndSettle();
      expect(find.text('配置操作未完成'), findsWidgets);
      await tester.tap(find.text('技术详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining(messages.downloadFailed.text), findsOneWidget);
      expect(bridge.commands, isEmpty);
    },
  );

  for (final remote in [false, true]) {
    for (final known in [false, true]) {
      testWidgets('time has no repeated type remote=$remote known=$known', (
        tester,
      ) async {
        await showPage(
          tester,
          candidate: ConfigEntry(
            id: 'second',
            name: 'Metadata',
            kind: remote ? ConfigKind.remote : ConfigKind.local,
            source: remote ? 'https://fixture.test/config' : null,
            revision: 1,
            body: '',
            updatedAt: known ? DateTime(2026, 10, 17, 12) : null,
          ),
        );
        final card = find.ancestor(
          of: find.text('Metadata'),
          matching: find.byType(Card),
        );
        final texts = tester
            .widgetList<Text>(
              find.descendant(of: card, matching: find.byType(Text)),
            )
            .map((text) => text.data ?? '')
            .toList();
        expect(
          texts,
          contains(remote ? 'https://fixture.test/config' : '本地配置'),
        );
        final label = remote ? '更新' : '保存';
        expect(
          texts.where(
            (text) => text.startsWith(known ? '$label于 ' : '$label时间未知'),
          ),
          hasLength(1),
        );
        expect(
          texts.any(
            (text) => text.startsWith('本地 ·') || text.startsWith('远程 ·'),
          ),
          isFalse,
        );
      });
    }
  }

  for (final source in [false, true]) {
    for (final outcome in [
      'retired-before-paint',
      'read-before-retirement',
      'read-reduced-before-retirement',
      'saved-success',
      'pending-without-error',
    ]) {
      testWidgets(
        'configuration ${source ? 'source' : 'name'} feedback uses its painted owner outcome=$outcome',
        (tester) async {
          bridge = PageBridge()
            ..state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
          store = PageStore(
            ConfigCollection(entries: [first, second], selectedId: first.id),
          );
          controller = AppController(
            bridge,
            store: store,
            preferencesStore: MemoryPreferencesStore(),
            overrideStore: ReadOnlyOverrideStore(),
          );
          addTearDown(controller.dispose);
          await controller.refresh();
          final active = ValueNotifier(true);
          var liveTask = true;
          addTearDown(active.dispose);
          final root = GlobalKey<NavigatorState>();
          final routes = AppTaskNavigatorObserver();
          final businessRoutes = AppTaskNavigatorObserver();
          final strings = lookupAppLocalizations(const Locale('en'));
          final reduced = outcome != 'read-before-retirement';
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: root,
              navigatorObservers: [routes],
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduced),
                child: child!,
              ),
              home: AppTaskScope(
                open: (_) {},
                task: AppTask.configurations,
                owner: controller,
                child: OperationNoticeHost(
                  child: OperationFeedback(
                    controller: controller,
                    child: Scaffold(
                      body: ValueListenableBuilder<bool>(
                        valueListenable: active,
                        builder: (_, current, _) => AppTaskActivity(
                          active: current,
                          isActiveNow: () => active.value && liveTask,
                          child: Navigator(
                            observers: [businessRoutes],
                            onGenerateRoute: (_) => FocusedPageRoute<void>(
                              builder: (_) =>
                                  ConfigsPage(controller: controller),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final card = find.byKey(const ValueKey('config-second'));
          final menu = find.descendant(
            of: card,
            matching: find.byTooltip(strings.moreActions),
          );
          await tester.ensureVisible(menu);
          await tester.tap(menu);
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(
              MenuItemButton,
              source ? strings.changeSourceUpdate : strings.rename,
            ),
          );
          await tester.pumpAndSettle();
          final field = find.byType(TextField);
          final editRoute = ModalRoute.of(tester.element(field))!;
          expect(editRoute.navigator, same(root.currentState));
          expect(AppTaskScope.maybeOf(tester.element(field)), isNull);
          final draft = source
              ? 'http://fixture.test/draft?token=complete'
              : 'Retained name draft';
          await tester.enterText(field, draft);
          await tester.pump();
          final anchor = tester.getRect(field);
          final message = messages.downloadFailed.withDetail(
            StateError('complete field diagnostic 原文🙂\nsecond line'),
          );
          final successful = outcome == 'saved-success';
          bridge.fieldResult = AppSnapshot(
            phase: 'STOPPED',
            storageEpoch: 1,
            resultId: 'operation',
            resultSuccess: successful,
            resultMessage: message,
            configStatus: 'saved',
            targetId: second.id,
            savedRevision: second.revision,
          );
          bridge.pending = Completer<String?>();
          Element? localFeedback;
          if (outcome == 'retired-before-paint') {
            var retiring = false;
            void retireBeforePaint() {
              if (retiring || controller.state.resultId != 'operation') return;
              retiring = true;
              scheduleMicrotask(() {
                expect(editRoute.isActive, isTrue);
                expect(find.byType(SnackBar), findsNothing);
                expect(
                  controller.feedbackHandledLocally(
                    controller.lastCommand!,
                    submissionFailed: false,
                    resultId: 'operation',
                  ),
                  isFalse,
                );
                liveTask = false;
                root.currentState!.removeRoute(editRoute);
              });
            }

            controller.addListener(retireBeforePaint);
            addTearDown(() => controller.removeListener(retireBeforePaint));
          }
          await tester.tap(
            find.widgetWithText(
              TextButton,
              source ? strings.saveAndUpdate : strings.save,
            ),
          );
          await tester.pump();
          expect(controller.hasLocalFeedbackOwner, isTrue);
          expect(bridge.commands.single, {
            'action': source ? 'updateConfig' : 'renameConfig',
            ...capturedTarget(second),
            if (source) 'source': draft else 'name': draft,
            'storageEpoch': 1,
          });
          bridge.pending!.complete(
            outcome == 'pending-without-error' ? null : 'operation',
          );
          if (outcome.startsWith('read-')) {
            final text = _noticeText(message.summary(strings));
            bool painted() {
              if (text.evaluate().isEmpty) return false;
              final render = tester.renderObject<RenderBox>(text);
              if (!render.attached || !render.hasSize || render.size.isEmpty) {
                return false;
              }
              var opacity = 1.0;
              for (
                RenderObject? node = render;
                node != null;
                node = node.parent
              ) {
                if (node is RenderOffstage && node.offstage) return false;
                if (node is RenderOpacity) opacity *= node.opacity;
                if (node is RenderAnimatedOpacity) {
                  opacity *= node.opacity.value;
                }
              }
              return (opacity * 255).round() > 0;
            }

            for (var frame = 0; frame < 24; frame++) {
              await tester.pump(Duration(milliseconds: frame == 0 ? 0 : 16));
              final visible = painted();
              expect(controller.hasLocalFeedbackOwner, !visible);
              expect(
                controller.feedbackHandledLocally(
                  controller.lastCommand!,
                  submissionFailed: false,
                  resultId: 'operation',
                ),
                visible,
              );
              expect(tester.widget<TextField>(field).controller!.text, draft);
              expect(tester.getRect(field), anchor);
              expect(find.byType(AlertDialog), findsOneWidget);
              if (visible) {
                localFeedback = tester.element(find.byType(SnackBar));
                break;
              }
            }
            expect(localFeedback, isNotNull);
          }
          await tester.pumpAndSettle();
          final submitted = controller.lastCommand!;
          final rendered = _noticeText(message.summary(strings));
          Future<void> expectTechnicalCause() async {
            expect(find.text(message.resolve(strings)), findsNothing);
            await tester.tap(
              find.descendant(
                of: find.byType(SnackBar),
                matching: find.text(strings.errorDetails),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text(strings.technicalDetails).hitTestable());
            await tester.pumpAndSettle();
            final original = tester
                .widget<SelectableText>(
                  find.byKey(const ValueKey('operation-technical-text')),
                )
                .data;
            expect(original, message.technicalDetail(strings));
            expect(
              '${message.summary(strings)}\n$original',
              message.resolve(strings),
            );
          }

          expect(find.byType(OperationFeedback), findsOneWidget);
          if (outcome == 'retired-before-paint') {
            expect(localFeedback, isNull);
            expect(controller.hasLocalFeedbackOwner, isFalse);
            expect(
              controller.feedbackHandledLocally(
                submitted,
                submissionFailed: false,
                resultId: 'operation',
              ),
              isFalse,
            );
            expect(find.byType(TextField), findsNothing);
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byType(SnackBar), findsOneWidget);
            expect(rendered, findsOneWidget);
            await expectTechnicalCause();
            expect(store.collection.find(second.id)!.toJson(), second.toJson());
            await tester.tap(find.text(strings.close).hitTestable());
          } else if (outcome.startsWith('read-')) {
            expect(localFeedback, isNotNull);
            expect(localFeedback!.mounted, isTrue);
            expect(tester.element(find.byType(SnackBar)), same(localFeedback));
            expect(editRoute.isCurrent, isTrue);
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(find.byType(SnackBar), findsOneWidget);
            expect(rendered, findsOneWidget);
            await expectTechnicalCause();
            expect(tester.widget<TextField>(field).controller!.text, draft);
            expect(tester.getRect(field), anchor);
            expect(controller.hasLocalFeedbackOwner, isFalse);
            expect(
              controller.feedbackHandledLocally(
                submitted,
                submissionFailed: false,
                resultId: 'operation',
              ),
              isTrue,
            );
            expect(
              controller.feedbackHandledLocally(
                submitted,
                submissionFailed: false,
                resultId: 'not-this-result',
              ),
              isFalse,
            );
            await tester.tap(find.text(strings.close).hitTestable());
            await tester.pumpAndSettle();
            expect(tester.widget<TextField>(field).controller!.text, draft);
            expect(tester.getRect(field), anchor);
            active.value = false;
            root.currentState!.removeRoute(editRoute);
          } else if (successful) {
            expect(localFeedback, isNull);
            expect(find.byType(TextField), findsNothing);
            expect(find.byType(AlertDialog), findsNothing);
            expect(controller.hasLocalFeedbackOwner, isFalse);
            expect(
              controller.feedbackHandledLocally(
                submitted,
                submissionFailed: false,
                resultId: 'operation',
              ),
              isTrue,
            );
          } else {
            expect(localFeedback, isNull);
            expect(controller.commandErrorMessage, isNull);
            expect(controller.hasLocalFeedbackOwner, isFalse);
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(rendered, findsNothing);
            expect(tester.widget<TextField>(field).controller!.text, draft);
            expect(tester.getRect(field), anchor);
            root.currentState!.removeRoute(editRoute);
          }
          await tester.pumpAndSettle();
          for (var repeat = 0; repeat < 2; repeat++) {
            await controller.refresh();
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
            expect(rendered, findsNothing);
          }
          expect(bridge.commands, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final source in [false, true]) {
    for (final restoreWithMenu in [false, true]) {
      testWidgets(
        'restored menu retires or old ${source ? 'source' : 'name'} form keeps input menu=$restoreWithMenu',
        (tester) async {
          await showPage(tester, storageEpoch: 1, feedback: true, scale: 2);
          final menu = find.descendant(
            of: find.ancestor(
              of: find.text(second.name),
              matching: find.byType(Card),
            ),
            matching: find.byTooltip('更多操作'),
          );
          await tester.ensureVisible(menu);
          await tester.pumpAndSettle();
          await tester.tap(menu);
          await tester.pumpAndSettle();
          Future<void> restore() async {
            store.collection = ConfigCollection(
              entries: [
                first,
                ConfigEntry(
                  id: second.id,
                  name: second.name,
                  source: second.source,
                  revision: second.revision,
                  body: 'restored same identity, different body',
                ),
              ],
              selectedId: first.id,
            );
            bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
            await controller.refresh();
            await tester.pump();
            expect(controller.storageEpoch, 2);
          }

          final oldSelection = tester
              .widget<MenuItemButton>(
                find.widgetWithText(MenuItemButton, source ? '修改来源并更新' : '重命名'),
              )
              .onPressed!;
          if (restoreWithMenu) {
            await restore();
            oldSelection();
            await tester.pumpAndSettle();
            expect(find.byType(TextField), findsNothing);
            expect(bridge.commands, isEmpty);
            expect(
              store.collection.find(second.id)!.body,
              'restored same identity, different body',
            );
            expect(tester.takeException(), isNull);
            return;
          }
          await tester.tap(find.text(source ? '修改来源并更新' : '重命名'));
          await tester.pumpAndSettle();
          final field = find.byType(TextField);
          final draft = source
              ? 'http://fixture.test/draft?token=retained'
              : 'Retained unsaved name';
          await tester.enterText(field, draft);
          await tester.pump();
          final anchor = tester.getRect(field);
          if (!restoreWithMenu) await restore();
          bridge.pending = Completer<String?>();
          await tester.tap(find.text(source ? '保存并更新' : '保存'));
          for (final frame in [
            Duration.zero,
            const Duration(milliseconds: 16),
            const Duration(milliseconds: 80),
          ]) {
            await tester.pump(frame);
            expect(tester.widget<TextField>(field).controller!.text, draft);
            expect(tester.getRect(field), anchor);
            expect(
              tester
                  .widget<TextButton>(
                    find.widgetWithText(TextButton, source ? '保存并更新' : '保存'),
                  )
                  .onPressed,
              isNull,
            );
          }
          bridge.pending!.complete('operation');
          await tester.pumpAndSettle();
          expect(
            bridge.commands.single,
            source
                ? {
                    'action': 'updateConfig',
                    ...capturedTarget(second),
                    'source': draft,
                    'storageEpoch': 1,
                  }
                : {
                    'action': 'renameConfig',
                    ...capturedTarget(second),
                    'name': draft,
                    'storageEpoch': 1,
                  },
          );
          expect(find.text(messages.storageUnavailable.text), findsWidgets);
          expect(
            store.collection.find(second.id)!.body,
            'restored same identity, different body',
          );
          expect(store.collection.find(second.id)!.name, second.name);
          expect(find.byType(SnackBar), findsOneWidget);
          expect(find.byType(AlertDialog), findsOneWidget);
          await _dismissNotice(tester);
          expect(tester.widget<TextField>(field).controller!.text, draft);
          expect(tester.getRect(field), anchor);
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'same-id revision restore rejects an already open body draft without replacing its input',
    (tester) async {
      const local = ConfigEntry(
        id: 'second',
        name: 'Local',
        kind: ConfigKind.local,
        revision: 1,
        body: 'original body',
      );
      await showPage(tester, candidate: local, storageEpoch: 1, feedback: true);
      final edit = find.descendant(
        of: find.ancestor(
          of: find.text(local.name),
          matching: find.byType(Card),
        ),
        matching: find.byTooltip('编辑配置'),
      );
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      editor.controller!.text = 'old unsaved draft';
      await tester.pump();
      store.collection = ConfigCollection(
        entries: [
          first,
          const ConfigEntry(
            id: 'second',
            name: 'Local',
            kind: ConfigKind.local,
            revision: 1,
            body: 'restored new body',
          ),
        ],
        selectedId: first.id,
      );
      bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
      await controller.refresh();
      await tester.pump();
      expect(editor.controller!.text, 'old unsaved draft');
      expect(
        tester.widget<ConfigTextPage>(find.byType(ConfigTextPage)).storageEpoch,
        1,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('保存'));
      for (final elapsed in [Duration.zero, const Duration(milliseconds: 16)]) {
        await tester.pump(elapsed);
        expect(editor.controller!.text, 'old unsaved draft');
        expect(
          tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
          isFalse,
        );
      }
      expect(bridge.commands, isEmpty);
      expect(store.collection.find(local.id)!.body, 'restored new body');
      expect(find.byType(ConfigTextPage), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-input-notice')), findsNothing);
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(ConfigTextPage)),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(_noticeText(strings.editorContextChanged), findsOneWidget);
      await _dismissNotice(tester);
      expect(editor.controller!.text, 'old unsaved draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('连续更换输入来源后显示当前提示并撤销旧 action', (tester) async {
    const local = ConfigEntry(
      id: 'second',
      name: 'Local',
      kind: ConfigKind.local,
      revision: 1,
      body: 'rules: []\n# original',
    );
    await showPage(
      tester,
      candidate: local,
      storageEpoch: 1,
      feedback: true,
      language: 'en',
    );
    final card = find.byKey(const ValueKey('config-second'));
    final strings = lookupAppLocalizations(const Locale('en'));
    final edit = find.descendant(
      of: card,
      matching: find.byTooltip(strings.editConfig),
    );
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    final body = find.byType(CodeEditor);
    final page = find.byType(ConfigTextPage);
    final editor = tester.widget<CodeEditor>(body);
    final draft = editor.controller!;
    draft.text = 'rules: [MATCH,DIRECT]\n# retained draft';
    draft.value = draft.value.copyWith(
      selection: const CodeLineSelection.collapsed(index: 0, offset: 7),
      composing: const TextRange(start: 6, end: 7),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final accepted = draft.value;
    final bodyState = tester.state(body);
    final pageState = tester.state(page);
    final save = find.widgetWithText(TextButton, strings.save);
    final rectangles = [tester.getRect(body), tester.getRect(save)];
    final retiredActions = <VoidCallback>[];
    Element? previousNotice;
    for (final epoch in [2, 3, 4]) {
      store.collection = ConfigCollection(
        entries: [
          first,
          ConfigEntry(
            id: local.id,
            name: local.name,
            kind: ConfigKind.local,
            revision: local.revision,
            body: 'rules: []\n# restored epoch $epoch',
          ),
        ],
        selectedId: first.id,
      );
      bridge.state = AppSnapshot(phase: 'STOPPED', storageEpoch: epoch);
      await controller.refresh();
      for (final milliseconds in [0, 16, 100, 200]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect([tester.getRect(body), tester.getRect(save)], rectangles);
        expect(tester.state(body), same(bodyState));
        expect(tester.state(page), same(pageState));
        expect(tester.widget<CodeEditor>(body).controller, same(draft));
        expect(draft.value, same(accepted));
        expect(draft.value.selection, accepted.selection);
        expect(draft.value.composing, accepted.composing);
        expect(editor.focusNode!.hasFocus, isTrue);
        expect(tester.widget<CodeEditor>(body).readOnly, isFalse);
        expect(tester.widget<TextButton>(save).onPressed, isNull);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      final notice = find.byType(SnackBar);
      expect(notice, findsOneWidget);
      expect(_noticeText(strings.editorContextChanged), findsOneWidget);
      final current = tester.element(notice);
      if (previousNotice != null) expect(current, isNot(same(previousNotice)));
      for (final action in retiredActions) {
        action();
        await tester.pumpAndSettle();
        expect(tester.element(notice), same(current));
        expect(_noticeText(strings.editorContextChanged), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(draft.value, same(accepted));
      }
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(tester.element(notice), same(current));
      expect(draft.value, same(accepted));
      retiredActions.add(
        tester
            .widget<IconButton>(
              find.descendant(of: notice, matching: find.byType(IconButton)),
            )
            .onPressed!,
      );
      retiredActions.addAll(
        tester
            .widgetList<TextButton>(
              find.descendant(of: notice, matching: find.byType(TextButton)),
            )
            .map((button) => button.onPressed!),
      );
      previousNotice = current;
    }
    draft.text = '${draft.text}\n# another edit';
    await tester.pump();
    expect(draft.text, endsWith('# another edit'));
    expect(tester.element(find.byType(SnackBar)), same(previousNotice));
    expect(bridge.commands, isEmpty);
    expect(store.collection.find(local.id)!.body, endsWith('restored epoch 4'));
    await _dismissNotice(tester);
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.commands, isEmpty);
    expect(tester.state(body), same(bodyState));
    expect(tester.state(page), same(pageState));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an edit callback from the old rendered row cannot borrow the new projection epoch',
    (tester) async {
      const local = ConfigEntry(
        id: 'second',
        name: 'Local',
        kind: ConfigKind.local,
        revision: 1,
        body: 'old rendered body',
      );
      await showPage(tester, candidate: local, storageEpoch: 1, feedback: true);
      final edit = find.descendant(
        of: find.ancestor(
          of: find.text(local.name),
          matching: find.byType(Card),
        ),
        matching: find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '编辑配置',
        ),
      );
      await tester.ensureVisible(edit);
      final callback = tester.widget<IconButton>(edit).onPressed!;
      store.collection = ConfigCollection(
        entries: [
          first,
          const ConfigEntry(
            id: 'second',
            name: 'Local',
            kind: ConfigKind.local,
            revision: 1,
            body: 'restored body before next frame',
          ),
        ],
        selectedId: first.id,
      );
      bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
      await controller.refresh();
      callback();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ConfigTextPage>(find.byType(ConfigTextPage)).storageEpoch,
        1,
      );
      final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
      expect(editor.controller!.text, local.body);
      final accepted = editor.controller!.value;
      editor.controller!.text = 'retained old-row edit';
      await tester.pump();
      expect(editor.controller!.text, 'retained old-row edit');
      expect(editor.controller!.canUndo, isTrue);
      editor.controller!.undo();
      expect(editor.controller!.codeLines.equals(accepted.codeLines), isTrue);
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isFalse,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(bridge.commands, isEmpty);
      expect(
        store.collection.find(local.id)!.body,
        'restored body before next frame',
      );
      expect(editor.controller!.text, local.body);
      final strings = AppLocalizations.of(
        tester.element(find.byType(ConfigTextPage)),
      );
      expect(_noticeText(strings.editorContextChanged), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('old delete menu cannot delete the restored same-id entry', (
    tester,
  ) async {
    await showPage(tester, storageEpoch: 1, feedback: true);
    final menu = find.descendant(
      of: find.ancestor(
        of: find.text(second.name),
        matching: find.byType(Card),
      ),
      matching: find.byTooltip('更多操作'),
    );
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final deleteSelection = tester
        .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, '删除'))
        .onPressed!;
    store.collection = ConfigCollection(
      entries: [
        first,
        ConfigEntry(
          id: second.id,
          name: second.name,
          source: second.source,
          revision: second.revision,
          body: 'restored body',
        ),
      ],
      selectedId: first.id,
    );
    bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
    await controller.refresh();
    // Simulate a selection already queued before the refreshed widget frame.
    deleteSelection();
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await tester.pumpAndSettle();
    expect(bridge.commands.single, {
      'action': 'delete',
      ...capturedTarget(second),
      'storageEpoch': 1,
    });
    expect(store.collection.find(second.id)!.body, 'restored body');
    expect(find.text(messages.storageUnavailable.text), findsWidgets);
  });

  for (final running in [false, true]) {
    testWidgets('selection submits directly when running=$running', (
      tester,
    ) async {
      await showPage(tester, running: running);
      final choice = tile('Second');
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pump();
      expect(bridge.commands, [
        {'action': 'select', ...capturedTarget(second), 'storageEpoch': 0},
      ]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('停止并切换'), findsNothing);
    });
  }

  testWidgets('pending submission disables another selection', (tester) async {
    await showPage(tester, running: true);
    bridge.pending = Completer<String?>();
    final choice = tile('Second');
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pump();
    expect(tester.widget<InkWell>(choice).onTap, isNull);
    await tester.tap(choice);
    expect(bridge.commands, [
      {'action': 'select', ...capturedTarget(second), 'storageEpoch': 0},
    ]);
    bridge.pending!.complete('operation');
    await tester.pump();
  });

  testWidgets(
    'selected item stays disabled while empty content can be selected',
    (tester) async {
      await showPage(
        tester,
        candidate: const ConfigEntry(
          id: 'second',
          name: 'Empty content',
          source: 'https://example.test/second',
          revision: 1,
          body: '',
        ),
      );
      expect(tester.widget<InkWell>(tile('First')).onTap, isNull);
      final candidate = tile('Empty content');
      expect(tester.widget<InkWell>(candidate).onTap, isNotNull);
      await tester.ensureVisible(candidate);
      await tester.tap(candidate);
      await tester.pump();
      expect(bridge.commands.single, {
        'action': 'select',
        ...capturedTarget(
          const ConfigEntry(
            id: 'second',
            name: 'Empty content',
            source: 'https://example.test/second',
            revision: 1,
            body: '',
          ),
        ),
        'storageEpoch': 0,
      });
    },
  );

  testWidgets('platform work disables selection', (tester) async {
    await showPage(tester, running: true, busy: true);
    expect(tester.widget<InkWell>(tile('Second')).onTap, isNull);
    expect(bridge.commands, isEmpty);
  });

  for (final changeSource in [false, true]) {
    testWidgets(
      'HTTP ${changeSource ? 'source change' : 'update'} submits directly',
      (tester) async {
        const candidate = ConfigEntry(
          id: 'second',
          name: 'HTTP config',
          source: 'http://fixture.test/old?token=private',
          revision: 3,
          body: '',
        );
        await showPage(tester, candidate: candidate);
        final card = find.ancestor(
          of: find.text(candidate.name),
          matching: find.byType(Card),
        );
        if (changeSource) {
          final menu = find.descendant(
            of: card,
            matching: find.byTooltip('更多操作'),
          );
          await tester.ensureVisible(menu);
          await tester.tap(menu);
          await tester.pumpAndSettle();
          await tester.tap(find.text('修改来源并更新'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextField),
            'http://fixture.test/new?token=private',
          );
          await tester.tap(find.text('保存并更新'));
        } else {
          final update = find.descendant(
            of: card,
            matching: find.byTooltip('更新配置'),
          );
          await tester.ensureVisible(update);
          await tester.tap(update);
        }
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(bridge.commands.single, {
          'action': 'updateConfig',
          'storageEpoch': 0,
          ...capturedTarget(candidate),
          'source': changeSource
              ? 'http://fixture.test/new?token=private'
              : candidate.source,
        });
      },
    );
  }

  testWidgets('deletion still waits for confirmation', (tester) async {
    await showPage(tester);
    final card = find.ancestor(
      of: find.text('Second'),
      matching: find.byType(Card),
    );
    final remove = find.descendant(of: card, matching: find.byTooltip('更多操作'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除配置？'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Second'),
      ),
      findsOneWidget,
    );
    expect(bridge.commands, isEmpty);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')),
    );
    await tester.pumpAndSettle();
    expect(bridge.commands, [
      {'action': 'delete', ...capturedTarget(second), 'storageEpoch': 0},
    ]);
  });
}
