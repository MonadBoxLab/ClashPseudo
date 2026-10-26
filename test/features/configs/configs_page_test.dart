import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/features/configs/config_text_page.dart';
import 'package:re_editor/re_editor.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/configs/configs_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/readonly_override_store.dart';
import '../settings/preferences_fakes.dart';

class PageBridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  final commands = <Map<String, Object?>>[];
  Completer<String?>? pending;

  @override
  Future<AppSnapshot> snapshot() async => state;

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    final accepted = pending == null ? 'operation' : await pending!.future;
    if (command['storageEpoch'] != state.storageEpoch) {
      throw PlatformException(
        code: 'storage',
        details: messages.storageUnavailable.toMap(),
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale(language),
        theme: AppTheme.forBrightness(
          dark ? Brightness.dark : Brightness.light,
          brand,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: feedback
            ? OperationFeedback(
                controller: controller,
                child: ConfigsPage(controller: controller),
              )
            : ConfigsPage(controller: controller),
      ),
    );
  }

  Finder tile(String name) => find
      .descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
        matching: find.byType(InkWell),
      )
      .first;

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
                void checkSelectionColumns(Finder selectedCard) {
                  final check = inside(selectedCard, find.byIcon(Icons.check));
                  final more = inside(
                    selectedCard,
                    find.byTooltip(strings.moreActions),
                  );
                  expect(
                    tester.getCenter(check).dx,
                    closeTo(tester.getRect(selectedCard).right - 16 - 24, .01),
                    reason: 'The selected mark uses the same trailing column as the 48dp action target.',
                  );
                  final actionSize = tester.getSize(more);
                  expect(actionSize.width, greaterThanOrEqualTo(48));
                  expect(actionSize.height, greaterThanOrEqualTo(48));
                  final saved = inside(
                    selectedCard,
                    find.byType(SingleChildScrollView),
                  );
                  if ((tester.getCenter(saved).dy - tester.getCenter(more).dy)
                          .abs() <
                      1) {
                    expect(
                      tester.getCenter(check).dx,
                      tester.getCenter(more).dx,
                    );
                  }
                  final leading = inside(
                    selectedCard,
                    find.byIcon(
                      selectedCard == remote
                          ? Icons.cloud_outlined
                          : Icons.description_outlined,
                    ),
                  );
                  expect(
                    tester.getCenter(check).dy,
                    tester.getCenter(leading).dy,
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
              if (selected == entry.id) {
                expect(
                  tester
                      .getCenter(
                        find.descendant(
                          of: card,
                          matching: find.byIcon(Icons.check),
                        ),
                      )
                      .dy,
                  closeTo(firstLineCenter, .5),
                );
              }
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
      final card = find.ancestor(
        of: find.text('Second'),
        matching: find.byType(Card),
      );
      final menu = find.descendant(of: card, matching: find.byTooltip('更多操作'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看配置错误'));
      await tester.pumpAndSettle();
      expect(find.text(messages.downloadFailed.text), findsOneWidget);
      expect(find.text('配置操作未完成'), findsOneWidget);
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
        expect(texts, contains(remote ? 'https://fixture.test/…' : '本地配置'));
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
                    'id': second.id,
                    'source': draft,
                    'storageEpoch': 1,
                  }
                : {
                    'action': 'renameConfig',
                    'id': second.id,
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
          await tester.tap(find.text('关闭').hitTestable());
          await tester.pumpAndSettle();
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
          isTrue,
        );
      }
      expect(bridge.commands, isEmpty);
      expect(store.collection.find(local.id)!.body, 'restored new body');
      expect(find.byType(ConfigTextPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-input-notice')));
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(ConfigTextPage)),
      );
      expect(find.text(strings.editorContextChanged), findsWidgets);
      await tester.tap(find.text(strings.close).hitTestable());
      await tester.pumpAndSettle();
      expect(editor.controller!.text, 'old unsaved draft');
      expect(tester.takeException(), isNull);
    },
  );

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
      expect(editor.controller!.value, same(accepted));
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isTrue,
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
      expect(find.byTooltip(strings.editorContextChanged), findsOneWidget);
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
      'id': second.id,
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
        {'action': 'select', 'id': second.id, 'storageEpoch': 0},
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
      {'action': 'select', 'id': second.id, 'storageEpoch': 0},
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
        'id': 'second',
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
          'id': candidate.id,
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
      {'action': 'delete', 'id': second.id, 'storageEpoch': 0},
    ]);
  });
}
