import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/features/configs/configs_page.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class PageBridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  final commands = <Map<String, Object?>>[];
  Completer<String?>? pending;

  @override
  Future<AppSnapshot> snapshot() async => state;

  @override
  Future<String?> submit(Map<String, Object?> command) async {
    commands.add(command);
    return pending == null ? 'operation' : pending!.future;
  }
}

class PageStore extends ConfigStore {
  PageStore(this.collection) : super(Directory.systemTemp);
  ConfigCollection collection;

  @override
  Future<ConfigCollection> read() async => collection;
}

void main() {
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
  }) async {
    bridge = PageBridge()
      ..state = AppSnapshot(
        phase: running ? 'RUNNING' : 'STOPPED',
        configId: running ? first.id : null,
        operation: busy ? '正在切换' : null,
      );
    store = PageStore(
      ConfigCollection(entries: [first, candidate], selectedId: first.id),
    );
    controller = AppController(bridge, store: store);
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ConfigsPage(controller: controller),
      ),
    );
  }

  Finder tile(String name) => find
      .descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
        matching: find.byType(InkWell),
      )
      .first;

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
            ('first', 'STOPPED', 1, '受控错误'),
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
        candidate: second.withContent(null, error: '下载失败，正文已失效'),
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
      expect(find.text('下载失败，正文已失效'), findsOneWidget);
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
        {'action': 'select', 'id': second.id},
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
      {'action': 'select', 'id': second.id},
    ]);
    bridge.pending!.complete('operation');
    await tester.pump();
  });

  testWidgets('selected and unavailable candidates cannot be selected', (
    tester,
  ) async {
    await showPage(
      tester,
      candidate: const ConfigEntry(
        id: 'second',
        name: 'Unavailable',
        source: 'https://example.test/second',
        revision: 1,
        body: null,
      ),
    );
    for (final label in ['First', 'Unavailable']) {
      expect(tester.widget<InkWell>(tile(label)).onTap, isNull);
    }
    expect(bridge.commands, isEmpty);
  });

  testWidgets('platform work disables selection', (tester) async {
    await showPage(tester, running: true, busy: true);
    expect(tester.widget<InkWell>(tile('Second')).onTap, isNull);
    expect(bridge.commands, isEmpty);
  });

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
      {'action': 'delete', 'id': second.id},
    ]);
  });
}
