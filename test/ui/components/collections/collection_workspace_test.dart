import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/components/collections/reading_list.dart';
import 'package:clash_pseudo/src/ui/connections/connections_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_page.dart';
import 'package:clash_pseudo/src/ui/navigation/app_shell.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/connection_fakes.dart' as connections;
import '../../diagnostics/configuration/runtime_fakes.dart' show TestApp, core;
import '../../diagnostics/nodes/node_fakes.dart' as nodes;
import '../../diagnostics/resources/resources_test.dart'
    show ResourceBridge, resourcePage;
import '../../diagnostics/rules/rule_fakes.dart' as rules;

class _ShellBridge extends connections.ConnectionBridgeFake {
  @override
  Future<Never> traffic() async =>
      throw StateError('Controlled traffic unavailable');

  @override
  Future<Map<String, dynamic>> appMemory() async => {'valid': false};
}

class _NodeShellBridge extends nodes.NodeBridge {
  @override
  Future<Never> traffic() async =>
      throw StateError('Controlled traffic unavailable');

  @override
  Future<Map<String, dynamic>> appMemory() async => {'valid': false};
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

Finder _editorFor(TextEditingController controller) => find.byWidgetPredicate(
  (widget) =>
      widget is EditableText && identical(widget.controller, controller),
);

class _Pane extends StatefulWidget {
  const _Pane({super.key, required this.id, this.onDispose});

  final String id;
  final VoidCallback? onDispose;

  @override
  State<_Pane> createState() => _PaneState();
}

class _PaneState extends State<_Pane> {
  final input = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  var actions = 0;
  var paneActive = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    paneActive = CollectionWorkspace.paneActiveOf(context);
  }

  void invokeAction() {
    if (mounted && CollectionWorkspace.paneActiveOf(context, listen: false)) {
      actions++;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.id),
      actions: widget.id == 'master' ? const [CollectionDetailsAction()] : null,
    ),
    body: ListView(
      controller: scroll,
      children: [
        TextField(controller: input, focusNode: focus),
        TextButton(onPressed: invokeAction, child: Text('${widget.id}-action')),
        for (var i = 0; i < 40; i++)
          SizedBox(height: 48, child: Text('${widget.id}-row-$i')),
      ],
    ),
  );

  @override
  void dispose() {
    widget.onDispose?.call();
    input.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }
}

class _StatusButton extends StatefulWidget {
  const _StatusButton({super.key});

  @override
  State<_StatusButton> createState() => _StatusButtonState();
}

class _StatusButtonState extends State<_StatusButton> {
  var actions = 0;

  void _invoke() {
    if (mounted && CollectionWorkspace.paneActiveOf(context, listen: false)) {
      actions++;
    }
  }

  @override
  Widget build(BuildContext context) => Material(
    child: Center(
      child: IconButton(
        color: Theme.of(context).colorScheme.primary,
        onPressed: CollectionWorkspace.paneActiveOf(context) ? _invoke : null,
        icon: const Icon(Icons.refresh),
      ),
    ),
  );
}

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.initialSelection});

  final String? initialSelection;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final workspace = GlobalKey<CollectionWorkspaceState>();
  final disposed = <String>[];
  final masterVisibility = <bool>[];
  late String? selection = widget.initialSelection;
  var active = true;
  var reduceMotion = false;
  var closes = 0;

  void select(String? value) => setState(() => selection = value);
  void setActive(bool value) => setState(() => active = value);
  void setReduceMotion(bool value) => setState(() => reduceMotion = value);

  Widget? get _selectedPane {
    final id = selection;
    if (id == null) return null;
    return _Pane(
      key: ValueKey('detail-$id'),
      id: id,
      onDispose: () => disposed.add(id),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: CollectionWorkspace(
      key: workspace,
      active: active,
      onMasterVisibilityChanged: masterVisibility.add,
      master: const _Pane(key: ValueKey('master-pane'), id: 'master'),
      detail: _selectedPane,
      onClose: () {
        closes++;
        select(null);
      },
    ),
  );
}

Finder _pane(String id) =>
    find.byKey(ValueKey(id == 'master' ? 'master-pane' : 'detail-$id'));

_PaneState _state(WidgetTester tester, String id) =>
    tester.state<_PaneState>(_pane(id));

double _reveal(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byType(CollectionWorkspace),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

List<SemanticsNode> _currentSemanticsNodes(BuildContext workspaceContext) {
  final root = View.pipelineOwnerOf(workspaceContext)
      .semanticsOwner
      ?.rootSemanticsNode;
  expect(root, isNotNull);
  final currentRoot = root!;
  expect(currentRoot.attached, isTrue);
  expect(currentRoot.parent, isNull);
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    nodes.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  visit(currentRoot);
  return nodes;
}

void _expectPaneSemanticsExclusion(
  WidgetTester tester,
  String id,
  bool excluded,
) {
  final boundary = find.ancestor(
    of: _pane(id),
    matching: find.descendant(
      of: find.byType(CollectionWorkspace),
      matching: find.byType(ExcludeSemantics),
    ),
  );
  expect(boundary, findsOneWidget);
  expect(tester.widget<ExcludeSemantics>(boundary).excluding, excluded);
}

Future<_HarnessState> _mount(
  WidgetTester tester, {
  String? selection,
  Size size = const Size(1400, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(_Harness(key: key, initialSelection: selection));
  await tester.pumpAndSettle();
  return key.currentState!;
}

class _PresentationHarness extends StatefulWidget {
  const _PresentationHarness({super.key});

  @override
  State<_PresentationHarness> createState() => _PresentationHarnessState();
}

class _PresentationHarnessState extends State<_PresentationHarness> {
  final workspace = GlobalKey<CollectionWorkspaceState>();
  final masterFocus = FocusNode();
  var active = true;
  var selected = true;

  void clearSelection() => setState(() => selected = false);

  Future<void> _showPopup(BuildContext context) async {
    // Model a strict page becoming inactive under its own popup.
    // Popup ownership itself remains the consumer's authority.
    setState(() => active = false);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Owned popup'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close popup'),
          ),
        ],
      ),
    );
    if (mounted) setState(() => active = true);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: CollectionWorkspace(
      key: workspace,
      active: active,
      master: Scaffold(
        appBar: AppBar(actions: const [CollectionDetailsAction()]),
        body: Builder(
          builder: (context) => Column(
            children: [
              TextField(focusNode: masterFocus),
              TextButton(
                onPressed: () => _showPopup(context),
                child: const Text('Open master popup'),
              ),
            ],
          ),
        ),
      ),
      detail: selected
          ? Builder(
              key: const ValueKey('selected-detail'),
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => _showPopup(context),
                  child: const Text('Open popup'),
                ),
              ),
            )
          : null,
      onClose: clearSelection,
    ),
  );

  @override
  void dispose() {
    masterFocus.dispose();
    super.dispose();
  }
}

Future<_PresentationHarnessState> _mountPresentation(
  WidgetTester tester,
  Size size,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final key = GlobalKey<_PresentationHarnessState>();
  await tester.pumpWidget(_PresentationHarness(key: key));
  await tester.pumpAndSettle();
  return key.currentState!;
}

BuildContext _detailContext(WidgetTester tester) =>
    tester.element(find.byKey(const ValueKey('selected-detail')));

void main() {
  group('collection_workspace', () {
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
            if (masterPosition.maxScrollExtent >= 100) {
              masterPosition.jumpTo(100);
            }
            final masterOffset = masterPosition.pixels;
            final detail = find.byType(Scaffold).last;
            final detailState = tester.state<ScrollableState>(
              find
                  .descendant(of: detail, matching: find.byType(Scrollable))
                  .first,
            );
            final detailPosition = detailState.position;
            if (detailPosition.maxScrollExtent >= 100) {
              detailPosition.jumpTo(100);
            }
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
              expect(
                masterState.position.pixels,
                masterOffset,
                reason: '$kind $size',
              );
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
              final editor = tester.widget<EditableText>(_editorFor(field));
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
          final field = tester
              .widget<TextField>(find.byType(TextField))
              .controller!;
          final editor = tester.widget<EditableText>(_editorFor(field));
          expect(editor.focusNode.hasFocus, isTrue);
          await tester.enterText(find.byType(TextField), 'absent');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(find.byType(TextField).hitTestable(), findsOneWidget);
          await tester.tap(
            find.byKey(const ValueKey('collection-show-details')),
          );
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
        final nodesEntry = find.text('Proxy nodes');
        await tester.scrollUntilVisible(
          nodesEntry,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pump();
        expect(nodesEntry.hitTestable(), findsOneWidget);
        expect(find.byType(NodesPage), findsNothing);
        expect(bridge.replies, isEmpty);
        await tester.tap(nodesEntry);
        await tester.pump();
        expect(find.byType(NodesPage), findsOneWidget);
        expect(bridge.replies, hasLength(1));
        bridge.replies.single.complete(nodes.page());
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'node-0'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField).hitTestable(), findsNothing);
        final field = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byType(TextField).hitTestable(), findsOneWidget);
        expect(
          tester.widget<EditableText>(_editorFor(field)).focusNode.hasFocus,
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'shell Back closes selected connection before leaving its task',
      (tester) async {
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
      },
    );
  });
  group('collection_workspace_motion', () {
    for (final visiblePane in ['master', 'detail']) {
      testWidgets(
        'visible inactive $visiblePane finishes SDK disabled color while transparent pane stays muted',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(700, 900);
          addTearDown(tester.view.reset);
          final workspace = GlobalKey<CollectionWorkspaceState>();
          final theme = AppTheme.light;
          late StateSetter rebuild;
          var active = true;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return CollectionWorkspace(
                    key: workspace,
                    active: active,
                    master: const _StatusButton(key: ValueKey('ticker-master')),
                    detail: const _StatusButton(key: ValueKey('ticker-detail')),
                    onClose: () {},
                  );
                },
              ),
            ),
          );
          if (visiblePane == 'master') {
            workspace.currentState!.showMaster();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 80));
            final master = find.byKey(const ValueKey('ticker-master'));
            final reveal = find.ancestor(
              of: master,
              matching: find.descendant(
                of: find.byType(CollectionWorkspace),
                matching: find.byType(Opacity),
              ),
            );
            expect(reveal, findsOneWidget);
            expect(
              tester.widget<Opacity>(reveal).opacity,
              inExclusiveRange(0, 1),
            );
            final masterState = tester.state<_StatusButtonState>(master);
            expect(TickerMode.valuesOf(masterState.context).enabled, isTrue);
            final masterButton = find.descendant(
              of: master,
              matching: find.byType(IconButton),
            );
            expect(
              tester.widget<IconButton>(masterButton).onPressed,
              isNotNull,
            );
            await tester.pump(const Duration(milliseconds: 160));
          } else {
            await tester.pump(const Duration(milliseconds: 240));
          }
          final hiddenPane = visiblePane == 'master' ? 'detail' : 'master';
          final visible = find.byKey(ValueKey('ticker-$visiblePane'));
          final hidden = find.byKey(ValueKey('ticker-$hiddenPane'));
          final visibleState = tester.state<_StatusButtonState>(visible);
          final hiddenState = tester.state<_StatusButtonState>(hidden);
          final button = find.descendant(
            of: visible,
            matching: find.byType(IconButton),
          );
          final hiddenButton = find.descendant(
            of: hidden,
            matching: find.byType(IconButton),
          );
          Color glyphColor() => tester
              .widget<RichText>(
                find.descendant(of: button, matching: find.byType(RichText)),
              )
              .text
              .style!
              .color!;
          final rect = tester.getRect(button);
          final enabledColor = theme.colorScheme.primary;
          final disabledColor = theme.colorScheme.onSurface.withAlpha(97);
          final staleAction = tester.widget<IconButton>(button).onPressed;
          expect(staleAction, isNotNull);
          expect(glyphColor(), enabledColor);
          expect(TickerMode.valuesOf(visibleState.context).enabled, isTrue);
          expect(TickerMode.valuesOf(hiddenState.context).enabled, isFalse);

          void expectInactive() {
            expect(tester.widget<IconButton>(button).onPressed, isNull);
            expect(tester.widget<IconButton>(hiddenButton).onPressed, isNull);
            expect(button.hitTestable(), findsNothing);
            expect(
              CollectionWorkspace.paneActiveOf(
                visibleState.context,
                listen: false,
              ),
              isFalse,
            );
            expect(
              CollectionWorkspace.paneActiveOf(
                hiddenState.context,
                listen: false,
              ),
              isFalse,
            );
            expect(workspace.currentState!.masterVisible, isFalse);
            expect(workspace.currentState!.detailVisible, isFalse);
            expect(TickerMode.valuesOf(visibleState.context).enabled, isTrue);
            expect(TickerMode.valuesOf(hiddenState.context).enabled, isFalse);
            expect(tester.getRect(button), rect);
            expect(
              tester.state<_StatusButtonState>(visible),
              same(visibleState),
            );
            expect(tester.state<_StatusButtonState>(hidden), same(hiddenState));
            expect(visibleState.actions, 0);
            expect(hiddenState.actions, 0);
          }

          rebuild(() => active = false);
          await tester.pump();
          expect(glyphColor(), enabledColor);
          expectInactive();
          staleAction!();
          expect(visibleState.actions, 0);

          await tester.pump(const Duration(milliseconds: 80));
          expect(glyphColor(), isNot(enabledColor));
          expect(glyphColor(), isNot(disabledColor));
          expectInactive();

          await tester.pump(const Duration(milliseconds: 160));
          expect(glyphColor(), disabledColor);
          expectInactive();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets('wide detail changes animate only the reserved right content', (
      tester,
    ) async {
      final host = await _mount(tester);
      final master = _state(tester, 'master');
      final masterRect = tester.getRect(_pane('master'));
      final masterPosition = master.scroll.position;
      final strings = AppLocalizations.of(
        tester.element(find.byType(CollectionWorkspace)),
      );
      expect(find.text(strings.selectDetails), findsOneWidget);

      host.select('a');
      await tester.pump();
      expect(_reveal(tester), 0);
      expect(tester.getRect(_pane('master')), masterRect);
      final detailRect = tester.getRect(_pane('a'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(_reveal(tester), inExclusiveRange(0, 1));
      expect(tester.getRect(_pane('master')), masterRect);
      expect(tester.getRect(_pane('a')), detailRect);

      final first = _state(tester, 'a');
      final revealBeforeReplacement = _reveal(tester);
      host.select('b');
      await tester.pump();
      expect(first.mounted, isFalse);
      expect(host.disposed, ['a']);
      expect(_pane('a'), findsNothing);
      expect(_pane('b'), findsOneWidget);
      expect(_reveal(tester), closeTo(revealBeforeReplacement, .000001));
      expect(tester.getRect(_pane('b')), detailRect);
      expect(tester.getRect(_pane('master')), masterRect);
      await tester.pumpAndSettle();
      expect(_reveal(tester), 1);

      final second = _state(tester, 'b');
      host.select(null);
      await tester.pump();
      expect(second.mounted, isFalse);
      expect(host.disposed, ['a', 'b']);
      expect(find.text(strings.selectDetails), findsOneWidget);
      expect(_reveal(tester), 0);
      await tester.pump(const Duration(milliseconds: 80));
      expect(_reveal(tester), inExclusiveRange(0, 1));
      expect(tester.getRect(_pane('master')), masterRect);
      await tester.pumpAndSettle();
      expect(_state(tester, 'master'), same(master));
      expect(master.scroll.position, same(masterPosition));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'continuous constraints and reversals retain visual and reading identity',
      (tester) async {
        final host = await _mount(tester, selection: 'a');
        final master = _state(tester, 'master');
        final detail = _state(tester, 'a');
        final masterPosition = master.scroll.position;
        final detailPosition = detail.scroll.position;
        master.scroll.jumpTo(120);
        detail.scroll.jumpTo(180);
        master.input.value = const TextEditingValue(
          text: 'master input',
          selection: TextSelection(baseOffset: 1, extentOffset: 5),
          composing: TextRange(start: 1, end: 5),
        );
        detail.input.value = const TextEditingValue(
          text: 'detail input',
          selection: TextSelection(baseOffset: 2, extentOffset: 6),
          composing: TextRange(start: 2, end: 6),
        );
        await tester.pump();
        final masterInput = master.input.value;
        final detailInput = detail.input.value;
        final initialWidth = tester.getSize(_pane('master')).width;

        tester.view.physicalSize = const Size(750, 900);
        await tester.pump();
        expect(tester.getSize(_pane('master')).width, initialWidth);
        await tester.pump(const Duration(milliseconds: 70));
        final collapseWidth = tester.getSize(_pane('master')).width;
        expect(collapseWidth, inExclusiveRange(initialWidth, 750));

        tester.view.physicalSize = const Size(1000, 900);
        await tester.pump();
        expect(
          tester.getSize(_pane('master')).width,
          closeTo(collapseWidth, .000001),
        );
        await tester.pump(const Duration(milliseconds: 50));
        final reverseWidth = tester.getSize(_pane('master')).width;
        expect(reverseWidth, inExclusiveRange(380, collapseWidth));

        tester.view.physicalSize = const Size(700, 900);
        await tester.pump();
        expect(
          tester.getSize(_pane('master')).width,
          closeTo(reverseWidth, .000001),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester.getSize(_pane('master')).width,
          inExclusiveRange(reverseWidth, 700),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(_pane('master')).width, 700);
        expect(tester.getTopLeft(_pane('a')).dx, 0);
        expect(tester.getSize(_pane('a')).width, 700);

        tester.view.physicalSize = const Size(1400, 900);
        await tester.pumpAndSettle();
        expect(_state(tester, 'master'), same(master));
        expect(_state(tester, 'a'), same(detail));
        expect(master.scroll.position, same(masterPosition));
        expect(detail.scroll.position, same(detailPosition));
        expect(master.scroll.offset, 120);
        expect(detail.scroll.offset, 180);
        expect(master.input.value, masterInput);
        expect(detail.input.value, detailInput);
        expect(host.disposed, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'retiring panes lose hit focus and semantics before their fade ends',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final host = await _mount(tester, selection: 'a');
          final workspaceContext = tester.element(
            find.byType(CollectionWorkspace),
          );
          SemanticsNode captureAction(String label) {
            final nodes = _currentSemanticsNodes(workspaceContext)
                .where((node) => node.getSemanticsData().label == label)
                .toList();
            expect(nodes, hasLength(1));
            return nodes.single;
          }

          void expectRetired(String label, SemanticsNode oldNode) {
            final nodes = _currentSemanticsNodes(workspaceContext);
            expect(
              nodes.where((node) => node.getSemanticsData().label == label),
              isEmpty,
            );
            expect(nodes.any((node) => identical(node, oldNode)), isFalse);
          }

          final detail = _state(tester, 'a');
          detail.focus.requestFocus();
          await tester.pump();
          expect(detail.focus.hasFocus, isTrue);
          captureAction('a-action');
          final wideMasterAction = captureAction('master-action');

          tester.view.physicalSize = const Size(700, 900);
          await tester.pumpAndSettle();
          expect(find.text('master-action').hitTestable(), findsNothing);
          expectRetired('master-action', wideMasterAction);
          _expectPaneSemanticsExclusion(tester, 'master', true);
          final detailAction = captureAction('a-action');
          host.workspace.currentState!.showMaster();
          await tester.pump();
          // The outgoing pane is still painted at this first frame, but already inert.
          expect(detail.mounted, isTrue);
          expect(detail.paneActive, isFalse);
          expect(host.workspace.currentState!.detailVisible, isFalse);
          expect(host.workspace.currentState!.masterVisible, isTrue);
          detail.invokeAction();
          expect(detail.actions, 0);
          expect(find.text('a-action').hitTestable(), findsNothing);
          expectRetired('a-action', detailAction);
          _expectPaneSemanticsExclusion(tester, 'a', true);
          _expectPaneSemanticsExclusion(tester, 'master', false);
          expect(detail.focus.hasFocus, isFalse);
          detail.focus.requestFocus();
          await tester.pump(const Duration(milliseconds: 40));
          expect(detail.focus.hasFocus, isFalse);
          final beforeReverse = tester
              .widget<Opacity>(
                find
                    .ancestor(of: _pane('a'), matching: find.byType(Opacity))
                    .first,
              )
              .opacity;
          expect(beforeReverse, inExclusiveRange(0, 1));
          final masterAction = captureAction('master-action');

          final action = tester.widget<IconButton>(
            find.byKey(const ValueKey('collection-show-details')),
          );
          action.onPressed!();
          await tester.pump();
          final afterReverse = tester
              .widget<Opacity>(
                find
                    .ancestor(of: _pane('a'), matching: find.byType(Opacity))
                    .first,
              )
              .opacity;
          expect(afterReverse, closeTo(beforeReverse, .000001));
          expect(find.text('master-action').hitTestable(), findsNothing);
          expectRetired('master-action', masterAction);
          _expectPaneSemanticsExclusion(tester, 'master', true);
          _expectPaneSemanticsExclusion(tester, 'a', false);
          final resumedDetailAction = captureAction('a-action');
          expect(_state(tester, 'a'), same(detail));
          await tester.pumpAndSettle();

          host.workspace.currentState!.showMaster();
          await tester.pumpAndSettle();
          final staleAction = tester.widget<IconButton>(
            find.byKey(const ValueKey('collection-show-details')),
          );
          final masterBeforeInactive = captureAction('master-action');
          host.setActive(false);
          await tester.pump();
          expect(find.text('master-action').hitTestable(), findsNothing);
          expect(find.text('a-action').hitTestable(), findsNothing);
          expectRetired('master-action', masterBeforeInactive);
          expectRetired('a-action', resumedDetailAction);
          _expectPaneSemanticsExclusion(tester, 'master', true);
          _expectPaneSemanticsExclusion(tester, 'a', true);
          staleAction.onPressed!();
          host.workspace.currentState!.showMaster();
          detail.focus.requestFocus();
          _state(tester, 'master').focus.requestFocus();
          await tester.pump();
          expect(host.workspace.currentState!.showingDetail, isFalse);
          expect(detail.focus.hasFocus, isFalse);
          expect(_state(tester, 'master').focus.hasFocus, isFalse);
          expect(_state(tester, 'master').paneActive, isFalse);
          expect(detail.paneActive, isFalse);
          expect(host.workspace.currentState!.masterVisible, isFalse);
          expect(host.workspace.currentState!.detailVisible, isFalse);
          expect(host.masterVisibility.last, isFalse);
          expect(host.closes, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'cached detail controls cannot act on a replacement or disposed workspace',
      (tester) async {
        final host = await _mount(
          tester,
          selection: 'a',
          size: const Size(700, 900),
        );
        host.workspace.currentState!.showMaster();
        await tester.pumpAndSettle();
        final retired = tester
            .widget<IconButton>(
              find.byKey(const ValueKey('collection-show-details')),
            )
            .onPressed!;

        host.select('b');
        await tester.pumpAndSettle();
        host.workspace.currentState!.showMaster();
        await tester.pumpAndSettle();
        retired();
        await tester.pump();
        expect(host.workspace.currentState!.showingDetail, isFalse);
        expect(host.workspace.currentState!.detailVisible, isFalse);
        final current = tester
            .widget<IconButton>(
              find.byKey(const ValueKey('collection-show-details')),
            )
            .onPressed!;
        current();
        await tester.pumpAndSettle();
        expect(host.workspace.currentState!.showingDetail, isTrue);
        expect(host.workspace.currentState!.detailVisible, isTrue);
        expect(_pane('b').hitTestable(), findsOneWidget);

        final workspace = host.workspace.currentState!;
        await tester.pumpWidget(const SizedBox());
        retired();
        current();
        workspace.showMaster();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'reducing motion settles an in-flight split and content immediately',
      (tester) async {
        final host = await _mount(tester);
        final master = _state(tester, 'master');
        host.select('a');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(_reveal(tester), inExclusiveRange(0, 1));
        final detail = _state(tester, 'a');
        tester.view.physicalSize = const Size(700, 900);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester.getSize(_pane('master')).width,
          inExclusiveRange(532, 700),
        );

        host.setReduceMotion(true);
        await tester.pump();
        expect(tester.getSize(_pane('master')).width, 700);
        expect(tester.getTopLeft(_pane('a')).dx, 0);
        expect(_reveal(tester), 1);
        expect(_state(tester, 'master'), same(master));
        expect(_state(tester, 'a'), same(detail));

        tester.view.physicalSize = const Size(1400, 900);
        await tester.pump();
        expect(tester.getSize(_pane('master')).width, 532);
        expect(tester.getTopLeft(_pane('a')).dx, 533);
        host.select('b');
        await tester.pump();
        expect(detail.mounted, isFalse);
        expect(_reveal(tester), 1);
        expect(tester.getSize(_pane('master')).width, 532);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
  group('collection_workspace_presentation', () {
    testWidgets('wide master focus does not hide the presented detail', (
      tester,
    ) async {
      final host = await _mountPresentation(tester, const Size(1400, 900));
      final workspace = host.workspace.currentState!;
      expect(workspace.showingDetail, isTrue);

      host.masterFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(host.masterFocus.hasFocus, isTrue);
      expect(workspace.showingDetail, isFalse);
      expect(workspace.detailPresented, isTrue);
      expect(workspace.masterPresented, isTrue);
      expect(workspace.masterVisible, isTrue);
      expect(workspace.detailVisible, isTrue);
      expect(CollectionWorkspace.paneActiveOf(_detailContext(tester)), isTrue);

      tester.view.physicalSize = const Size(700, 900);
      await tester.pump();
      expect(workspace.detailPresented, isFalse);
      expect(workspace.detailVisible, isFalse);
      expect(workspace.masterVisible, isTrue);
      expect(CollectionWorkspace.paneActiveOf(_detailContext(tester)), isFalse);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'narrow return to master retires detail presentation immediately',
      (tester) async {
        final host = await _mountPresentation(tester, const Size(700, 900));
        final workspace = host.workspace.currentState!;
        expect(workspace.detailPresented, isTrue);
        expect(workspace.masterPresented, isFalse);

        workspace.showMaster();
        await tester.pump();
        expect(workspace.showingDetail, isFalse);
        expect(workspace.detailPresented, isFalse);
        expect(workspace.masterPresented, isTrue);
        expect(workspace.detailVisible, isFalse);
        expect(workspace.masterVisible, isTrue);
        expect(find.byKey(const ValueKey('selected-detail')), findsOneWidget);
        expect(
          CollectionWorkspace.paneActiveOf(_detailContext(tester)),
          isFalse,
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('collection-show-details')));
        await tester.pump();
        expect(workspace.detailPresented, isTrue);
        expect(workspace.detailVisible, isTrue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    for (final size in [const Size(1400, 900), const Size(700, 900)]) {
      testWidgets('own popup keeps presentation but not eligibility at $size', (
        tester,
      ) async {
        final host = await _mountPresentation(tester, size);
        final workspace = host.workspace.currentState!;
        final detail = tester.element(
          find.byKey(const ValueKey('selected-detail')),
        );
        if (size.width == 1400) {
          host.masterFocus.requestFocus();
          await tester.pumpAndSettle();
          expect(workspace.showingDetail, isFalse);
        }

        await tester.tap(find.text('Open popup'));
        await tester.pumpAndSettle();
        expect(find.text('Owned popup'), findsOneWidget);
        expect(host.active, isFalse);
        expect(workspace.detailPresented, isTrue);
        expect(workspace.masterPresented, size.width == 1400);
        expect(workspace.detailVisible, isFalse);
        expect(workspace.masterVisible, isFalse);
        expect(
          CollectionWorkspace.paneActiveOf(detail, listen: false),
          isFalse,
        );
        expect(_detailContext(tester), same(detail));

        if (size.width == 1400) {
          tester.view.physicalSize = const Size(700, 900);
          await tester.pump();
          expect(workspace.detailPresented, isFalse);
          expect(workspace.detailVisible, isFalse);
          tester.view.physicalSize = size;
          await tester.pump();
          expect(workspace.detailPresented, isTrue);
          expect(workspace.detailVisible, isFalse);
        }

        await tester.tap(find.text('Close popup'));
        await tester.pumpAndSettle();
        expect(host.active, isTrue);
        expect(workspace.detailPresented, isTrue);
        expect(workspace.detailVisible, isTrue);
        expect(CollectionWorkspace.paneActiveOf(detail, listen: false), isTrue);
        expect(host.workspace.currentState, same(workspace));
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'master popup keeps presentation but not eligibility at $size',
        (tester) async {
          final host = await _mountPresentation(tester, size);
          final workspace = host.workspace.currentState!;
          workspace.showMaster();
          await tester.pumpAndSettle();
          final master = tester.element(find.byType(TextField));
          expect(workspace.masterPresented, isTrue);
          expect(workspace.masterVisible, isTrue);

          await tester.tap(find.text('Open master popup'));
          await tester.pumpAndSettle();
          expect(find.text('Owned popup'), findsOneWidget);
          expect(host.active, isFalse);
          expect(workspace.masterPresented, isTrue);
          expect(workspace.masterVisible, isFalse);
          expect(workspace.detailVisible, isFalse);
          expect(
            CollectionWorkspace.paneActiveOf(master, listen: false),
            isFalse,
          );

          tester.view.physicalSize = size.width == 1400
              ? const Size(700, 900)
              : const Size(1400, 900);
          await tester.pump();
          expect(workspace.masterPresented, isTrue);
          expect(workspace.masterVisible, isFalse);

          host.clearSelection();
          await tester.pump();
          expect(workspace.masterPresented, isTrue);
          expect(workspace.detailPresented, isFalse);
          expect(workspace.masterVisible, isFalse);
          expect(
            CollectionWorkspace.paneActiveOf(master, listen: false),
            isFalse,
          );

          await tester.tap(find.text('Close popup'));
          await tester.pumpAndSettle();
          expect(host.active, isTrue);
          expect(workspace.masterPresented, isTrue);
          expect(workspace.masterVisible, isTrue);
          expect(
            CollectionWorkspace.paneActiveOf(master, listen: false),
            isTrue,
          );
          expect(host.workspace.currentState, same(workspace));
          expect(tester.element(find.byType(TextField)), same(master));
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('no selected detail is never presented at $size', (
        tester,
      ) async {
        final host = await _mountPresentation(tester, size);
        final workspace = host.workspace.currentState!;
        expect(workspace.detailPresented, isTrue);

        host.clearSelection();
        await tester.pump();
        expect(workspace.showingDetail, isFalse);
        expect(workspace.detailPresented, isFalse);
        expect(workspace.masterPresented, isTrue);
        expect(find.byKey(const ValueKey('selected-detail')), findsNothing);
        await tester.pumpAndSettle();
        expect(workspace.detailPresented, isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
