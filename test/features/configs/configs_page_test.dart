import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/features/configs/configs_page.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
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
  final ConfigCollection collection;

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

  Future<void> showPage(
    WidgetTester tester, {
    bool running = false,
    bool busy = false,
    ConfigEntry candidate = second,
  }) async {
    bridge = PageBridge()
      ..state = AppSnapshot(
        phase: running ? 'RUNNING' : 'STOPPED',
        configId: running ? first.id : null,
        operation: busy ? '正在切换' : null,
      );
    controller = AppController(
      bridge,
      store: PageStore(
        ConfigCollection(entries: [first, candidate], selectedId: first.id),
      ),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(home: ConfigsPage(controller: controller)),
    );
  }

  for (final running in [false, true]) {
    testWidgets('selection submits directly when running=$running', (
      tester,
    ) async {
      await showPage(tester, running: running);
      final choice = find.widgetWithText(TextButton, running ? '切换接管' : '选择');
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
    final choice = find.widgetWithText(TextButton, '切换接管');
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pump();
    expect(tester.widget<TextButton>(choice).onPressed, isNull);
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
    for (final label in ['已选择', '选择']) {
      final button = find.widgetWithText(TextButton, label);
      expect(tester.widget<TextButton>(button).onPressed, isNull);
    }
    expect(bridge.commands, isEmpty);
  });

  testWidgets('platform work disables selection', (tester) async {
    await showPage(tester, running: true, busy: true);
    final button = find.widgetWithText(TextButton, '切换接管');
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(bridge.commands, isEmpty);
  });

  testWidgets('deletion still waits for confirmation', (tester) async {
    await showPage(tester);
    final card = find.ancestor(
      of: find.text('Second'),
      matching: find.byType(Card),
    );
    final remove = find.descendant(
      of: card,
      matching: find.widgetWithText(TextButton, '删除'),
    );
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('删除“Second”？'), findsOneWidget);
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
