import 'dart:async';

import 'package:clash_pseudo/src/app/app_shell.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/collection_workspace.dart';
import 'package:clash_pseudo/src/app/widgets/reading_list.dart';
import 'package:clash_pseudo/src/features/connections/connections_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/nodes_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/resources_page.dart';
import 'package:clash_pseudo/src/features/diagnostics/rules_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/connections/connection_fakes.dart' as connections;
import '../features/diagnostics/node_fakes.dart' as nodes;
import '../features/diagnostics/rule_fakes.dart' as rules;
import '../features/diagnostics/resources_test.dart'
    show ResourceBridge, resourcePage;
import '../features/diagnostics/runtime_fakes.dart' show TestApp, core;

class _ShellBridge extends connections.ConnectionBridgeFake {
  @override
  Future<Never> traffic() async =>
      throw StateError('Controlled traffic unavailable');

  @override
  Future<Map<String, dynamic>> processMemory() async => {'valid': false};
}

class _NodeShellBridge extends nodes.NodeBridge {
  @override
  Future<Never> traffic() async =>
      throw StateError('Controlled traffic unavailable');

  @override
  Future<Map<String, dynamic>> processMemory() async => {'valid': false};
}

List<Completer<Map<String, dynamic>>> replies(AppBridge bridge) =>
    switch (bridge) {
      nodes.NodeBridge() => bridge.replies,
      rules.RuleBridge() => bridge.replies,
      ResourceBridge() => bridge.replies,
      _ => throw StateError('Unexpected fixture bridge'),
    };

Map<String, dynamic> data(String kind, {bool empty = false}) {
  if (kind == 'rules') {
    return rules.rulePage(
      total: empty ? 0 : 51,
      token: empty ? 'd' * 64 : 'c' * 64,
    );
  }
  if (kind == 'resources') return resourcePage(core(1));
  final value = nodes.page();
  if (empty) {
    value['page'] = {
      'token': 'a' * 64,
      'total': 0,
      'nextOffset': -1,
      'nodes': <Map<String, dynamic>>[],
    };
  }
  return value;
}

void main() {
  testWidgets(
    'focused collection input remains visible with its composing range while panes collapse',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.reset);
      final input = TextEditingController();
      addTearDown(input.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CollectionWorkspace(
            master: Scaffold(
              appBar: AppBar(actions: const [CollectionDetailsAction()]),
              body: ListView(children: [TextField(controller: input)]),
            ),
            detail: const Scaffold(
              body: Center(child: Text('Retained detail')),
            ),
            onClose: () {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'controlled');
      input.value = input.value.copyWith(
        selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        composing: const TextRange(start: 1, end: 5),
      );
      await tester.pump();
      final expected = input.value;
      final editor = tester.widget<EditableText>(find.byType(EditableText));
      for (final size in [
        const Size(700, 479),
        const Size(280, 280),
        const Size(1400, 900),
      ]) {
        tester.view.physicalSize = size;
        tester.view.viewInsets = const FakeViewPadding(bottom: 160);
        await tester.pumpAndSettle();
        expect(find.byType(TextField).hitTestable(), findsOneWidget);
        final actual = tester.widget<EditableText>(find.byType(EditableText));
        expect(actual.controller, same(input));
        expect(actual.focusNode, same(editor.focusNode));
        expect(actual.focusNode.hasFocus, isTrue);
        expect(input.value, expected);
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(700, 479);
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(input.text, 'controlled');
      await tester.tap(find.byKey(const ValueKey('collection-show-details')));
      await tester.pumpAndSettle();
      expect(find.text('Retained detail'), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final kind in ['nodes', 'rules', 'resources']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        '$kind keeps selection, controllers and both reading positions across pane changes $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1400, 900);
          addTearDown(tester.view.reset);
          final AppBridge bridge = switch (kind) {
            'nodes' => nodes.NodeBridge(),
            'rules' => rules.RuleBridge(),
            _ => ResourceBridge(),
          };
          final app = TestApp(bridge);
          addTearDown(app.dispose);
          final page = switch (kind) {
            'nodes' => NodesPage(app: app),
            'rules' => RulesPage(app: app),
            _ => ResourcesPage(app: app),
          };
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light,
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: page,
            ),
          );
          replies(bridge).single.complete(data(kind));
          await tester.pumpAndSettle();
          final strings = AppLocalizations.of(
            tester.element(find.byType(CollectionWorkspace)),
          );
          expect(find.text(strings.selectDetails), findsOneWidget);
          final selected = switch (kind) {
            'nodes' => 'node-0',
            'rules' => 'set',
            _ => 'remote',
          };
          await tester.tap(find.widgetWithText(ListTile, selected));
          await tester.pumpAndSettle();
          expect(find.text(strings.selectDetails), findsNothing);
          expect(
            tester
                .widget<ListTile>(find.widgetWithText(ListTile, selected))
                .selected,
            isTrue,
          );
          final master = find.byType(ReadingList);
          final masterState = tester.state<ScrollableState>(
            find
                .descendant(of: master, matching: find.byType(Scrollable))
                .first,
          );
          final masterPosition = masterState.position;
          if (masterPosition.maxScrollExtent >= 100) masterPosition.jumpTo(100);
          final masterOffset = masterPosition.pixels;
          final detail = find.byType(Scaffold).last;
          final detailState = tester.state<ScrollableState>(
            find
                .descendant(of: detail, matching: find.byType(Scrollable))
                .first,
          );
          final detailPosition = detailState.position;
          if (detailPosition.maxScrollExtent >= 100) detailPosition.jumpTo(100);
          final detailOffset = detailPosition.pixels;
          final field = tester
              .widget<TextField>(find.byType(TextField))
              .controller!;
          final calls = replies(bridge).length;
          for (final size in [
            const Size(700, 479),
            const Size(280, 280),
            const Size(1400, 900),
          ]) {
            tester.view.physicalSize = size;
            await tester.pumpAndSettle();
            expect(
              tester.state<ScrollableState>(
                find
                    .descendant(of: detail, matching: find.byType(Scrollable))
                    .first,
              ),
              same(detailState),
            );
            expect(detailState.position.pixels, detailOffset);
            expect(
              tester
                  .widget<TextField>(
                    find.byType(TextField, skipOffstage: false),
                  )
                  .controller,
              same(field),
            );
            expect(masterState.position.pixels, masterOffset);
            expect(replies(bridge).length, calls);
            expect(tester.takeException(), isNull);
          }
          tester.view.physicalSize = const Size(700, 900);
          await tester.pumpAndSettle();
          for (final modifier in [
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.metaLeft,
          ]) {
            await tester.sendKeyDownEvent(modifier);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
            await tester.sendKeyUpEvent(modifier);
            await tester.pumpAndSettle();
            final editor = tester.widget<EditableText>(
              find.byType(EditableText),
            );
            expect(editor.controller, same(field));
            expect(editor.focusNode.hasFocus, isTrue);
            expect(find.byType(TextField).hitTestable(), findsOneWidget);
            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pumpAndSettle();
            expect(find.byType(TextField).hitTestable(), findsOneWidget);
            await tester.tap(
              find.byKey(const ValueKey('collection-show-details')),
            );
            await tester.pumpAndSettle();
            expect(find.byType(TextField).hitTestable(), findsNothing);
            expect(detailState.position.pixels, detailOffset);
            expect(replies(bridge).length, calls);
          }
          tester.view.physicalSize = const Size(1400, 900);
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'absent');
          await tester.pump(const Duration(milliseconds: 250));
          if (kind != 'resources') {
            replies(bridge).last.complete(data(kind, empty: true));
          }
          await tester.pumpAndSettle();
          expect(find.text(strings.selectionOutsideList), findsOneWidget);
          expect(detailState.position.pixels, detailOffset);
          detailState.position.jumpTo(0);
          await tester.pump();
          expect(
            find.byWidgetPredicate(
              (widget) => widget is SelectableText && widget.data == selected,
            ),
            findsOneWidget,
          );
          if (kind != 'resources') {
            await tester.enterText(find.byType(TextField), '');
            await tester.pump(const Duration(milliseconds: 250));
            final replacement = data(kind);
            final page = replacement['page'] as Map;
            if (kind == 'nodes') {
              final row = (page['nodes'] as List).first as Map;
              row['sourceVersion'] = 2;
              row['udp'] = false;
            } else {
              page['sourceToken'] = 'f' * 64;
            }
            replies(bridge).last.complete(replacement);
            await tester.pumpAndSettle();
            expect(find.text(strings.coreSnapshotStale), findsWidgets);
            if (kind == 'nodes') {
              final udp = find.widgetWithText(ListTile, 'UDP');
              expect(
                tester
                    .widget<SelectableText>(
                      find.descendant(
                        of: udp,
                        matching: find.byType(SelectableText),
                      ),
                    )
                    .data,
                strings.proxyTrue,
              );
            } else {
              expect(
                tester
                    .widget<TextButton>(
                      find.widgetWithText(
                        TextButton,
                        '${strings.ruleSets} · set',
                      ),
                    )
                    .onPressed,
                isNull,
              );
            }
            await tester.tap(find.widgetWithText(ListTile, selected));
            await tester.pumpAndSettle();
            if (kind == 'nodes') {
              final udp = find.widgetWithText(ListTile, 'UDP');
              expect(
                tester
                    .widget<SelectableText>(
                      find.descendant(
                        of: udp,
                        matching: find.byType(SelectableText),
                      ),
                    )
                    .data,
                strings.proxyFalse,
              );
            } else {
              expect(
                tester
                    .widget<TextButton>(
                      find.widgetWithText(
                        TextButton,
                        '${strings.ruleSets} · set',
                      ),
                    )
                    .onPressed,
                isNotNull,
              );
            }
          }
          app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
          if (!replies(bridge).last.isCompleted) {
            replies(bridge).last
                .completeError(StateError('Replacement source unavailable'));
          }
          await tester.pump();
          expect(
            find.byWidgetPredicate(
              (widget) => widget is SelectableText && widget.data == selected,
            ),
            findsOneWidget,
          );
          expect(find.text(strings.coreSnapshotStale), findsWidgets);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'connection find returns to its collection and keeps cached details',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 900);
      addTearDown(tester.view.reset);
      final app = connections.ConnectionAppFake(
        connections.ConnectionBridgeFake(),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConnectionsPage(app: app),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(ConnectionsPage));
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsOneWidget);
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
        final editor = tester.widget<EditableText>(find.byType(EditableText));
        expect(editor.focusNode.hasFocus, isTrue);
        await tester.enterText(find.byType(TextField), 'absent');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.byType(TextField).hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('collection-show-details')));
        await tester.pumpAndSettle();
        expect(find.text('Connection details'), findsOneWidget);
        expect(
          find.text(
            lookupAppLocalizations(const Locale('en')).selectionOutsideList,
          ),
          findsOneWidget,
        );
        expect(tester.state(find.byType(ConnectionsPage)), same(state));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'nested node task keeps keyboard ownership when details take over',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 900);
      addTearDown(tester.view.reset);
      final bridge = _NodeShellBridge();
      final app = TestApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Proxy nodes'));
      await tester.tap(find.text('Proxy nodes'));
      await tester.pump();
      bridge.replies.single.complete(nodes.page());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'node-0'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField).hitTestable(), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('shell Back closes selected connection before leaving its task', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);
    final bridge = _ShellBridge();
    final app = connections.ConnectionAppFake(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppShell(controller: app),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connections'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('one.fixture.test'));
    await tester.pumpAndSettle();
    expect(find.text('Connection details'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Connection details'), findsNothing);
    expect(find.text('Recent connections'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Network activity'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
