import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'editor_fakes.dart';

void main() {
  testWidgets('selection toolbar retires interaction before its fade completes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final visibility = ValueNotifier(true);
      final focus = FocusNode();
      final controller = CodeLineEditingController.fromText('fixture');
      addTearDown(visibility.dispose);
      addTearDown(focus.dispose);
      addTearDown(controller.dispose);
      final link = LayerLink();
      var taps = 0;
      const actionKey = ValueKey('toolbar-action');
      final toolbar = MobileSelectionToolbarController(
        builder:
            ({
              required context,
              required anchors,
              required controller,
              required onDismiss,
              required onRefresh,
            }) => Material(
              child: TextButton(
                key: actionKey,
                focusNode: focus,
                onPressed: () => taps++,
                child: const Text('Toolbar action'),
              ),
            ),
      );
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          home: Scaffold(
            body: Builder(
              builder: (context) {
                host = context;
                return CompositedTransformTarget(
                  link: link,
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      );
      toolbar.show(
        context: host,
        controller: controller,
        anchors: const TextSelectionToolbarAnchors(
          primaryAnchor: Offset(100, 100),
        ),
        renderRect: const Rect.fromLTWH(0, 0, 800, 600),
        layerLink: link,
        visibility: visibility,
      );
      await tester.pumpAndSettle();
      final action = find.byKey(actionKey);
      SemanticsNode rootNode() {
        final render = tester.renderObject(action);
        expect(render.attached, isTrue);
        return render.owner!.semanticsOwner!.rootSemanticsNode!;
      }

      List<SemanticsNode> reachableNodes(SemanticsNode root) {
        final nodes = <SemanticsNode>[];
        void visit(SemanticsNode node) {
          if (nodes.contains(node)) {
            return;
          }
          nodes.add(node);
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(root);
        return nodes;
      }

      List<SemanticsNode> parentChain(SemanticsNode node) {
        final chain = <SemanticsNode>[];
        SemanticsNode? current = node;
        while (current != null && !chain.contains(current)) {
          chain.add(current);
          current = current.parent;
        }
        return chain;
      }

      bool hasActionLabel(SemanticsNode node) =>
          node.getSemanticsData().label.contains('Toolbar action');
      String evidence(
        SemanticsNode root,
        List<SemanticsNode> reachable,
        Iterable<SemanticsNode> candidates,
      ) => [
        'root=${root.id}, attached=${root.attached}',
        for (final node in candidates)
          'candidate=${node.id}, attached=${node.attached}, '
              'reachable=${reachable.contains(node)}, '
              'label=${node.getSemanticsData().label}, '
              'parents=${parentChain(node).map((parent) => '${parent.id}:${parent.attached}').join(' -> ')}',
        root.toStringDeep(),
      ].join('\n');
      void expectReachableTree(
        SemanticsNode root,
        List<SemanticsNode> reachable,
        String details,
      ) {
        for (final node in reachable) {
          expect(node.attached, isTrue, reason: details);
          expect(parentChain(node).last, same(root), reason: details);
        }
      }

      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(find.bySemanticsLabel('Toolbar action'), findsOneWidget);
      final visibleRoot = rootNode();
      final visibleNodes = reachableNodes(visibleRoot);
      final visibleActions = visibleNodes.where(hasActionLabel).toList();
      final visibleEvidence = evidence(
        visibleRoot,
        visibleNodes,
        visibleActions,
      );
      expectReachableTree(visibleRoot, visibleNodes, visibleEvidence);
      expect(visibleActions, hasLength(1), reason: visibleEvidence);
      final originalAction = visibleActions.single;

      visibility.value = false;
      await tester.pump();
      // The old pixels still paint, but the action must already be retired.
      final fade = tester.widget<FadeTransition>(
        find.ancestor(of: action, matching: find.byType(FadeTransition)).first,
      );
      expect(fade.opacity.value, greaterThan(0));
      expect(focus.hasFocus, isFalse);
      final hiddenRoot = rootNode();
      final hiddenNodes = reachableNodes(hiddenRoot);
      final cachedNodes = find
          .bySemanticsLabel('Toolbar action')
          .evaluate()
          .map((element) => element.findRenderObject()?.debugSemantics)
          .whereType<SemanticsNode>();
      final candidates = {originalAction, ...cachedNodes};
      final hiddenEvidence = evidence(hiddenRoot, hiddenNodes, candidates);
      expectReachableTree(hiddenRoot, hiddenNodes, hiddenEvidence);
      expect(
        hiddenNodes.where(hasActionLabel),
        isEmpty,
        reason: hiddenEvidence,
      );
      for (final candidate in candidates.where(hasActionLabel)) {
        final attachedToRoot =
            candidate.attached &&
            identical(parentChain(candidate).last, hiddenRoot);
        expect(
          hiddenNodes.contains(candidate) && attachedToRoot,
          isFalse,
          reason: hiddenEvidence,
        );
      }
      await tester.tap(action, warnIfMissed: false);
      expect(taps, 0);
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      expect(fade.opacity.value, 0);

      visibility.value = true;
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      final restoredRoot = rootNode();
      final restoredNodes = reachableNodes(restoredRoot);
      final restoredActions = restoredNodes.where(hasActionLabel).toList();
      final restoredEvidence = evidence(
        restoredRoot,
        restoredNodes,
        restoredActions,
      );
      expectReachableTree(restoredRoot, restoredNodes, restoredEvidence);
      expect(restoredActions, hasLength(1), reason: restoredEvidence);
      await tester.tap(action);
      expect(taps, 1);
      toolbar.hide(host);
      await tester.pumpAndSettle();
      expect(action, findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  for (final reason in ['background', 'task exit', 'route exit']) {
    testWidgets('retained editor menu callbacks cannot act after $reason', (
      tester,
    ) async {
      final app = EditorApp();
      final active = ValueNotifier(true);
      addTearDown(app.dispose);
      addTearDown(active.dispose);
      var clipboardWrites = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboardWrites++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ValueListenableBuilder<bool>(
                    valueListenable: active,
                    builder: (_, value, child) => AppTaskActivity(
                      active: value,
                      isActiveNow: () => active.value,
                      child: child!,
                    ),
                    child: ConfigTextPage(app: app, initialText: 'fixture'),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final editorFinder = find.byType(CodeEditor);
      final editor = tester.widget<CodeEditor>(editorFinder);
      final context = tester.element(editorFinder);
      final pageState = tester.state(find.byType(ConfigTextPage));
      expect(pageState.mounted, isTrue);
      expect(app.foreground, isTrue);
      expect(active.value, isTrue);
      expect(AppTaskActivity.isActive(context), isTrue);
      expect(ModalRoute.of(context)!.isCurrent, isTrue);
      expect(
        find.textContaining(AppLocalizations.of(context).bodyPrepFailed),
        findsNothing,
      );
      expect(editor.controller, isNotNull);
      expect(
        editor.findController,
        isNotNull,
        reason: 'The page must finish preparing its own find controller.',
      );
      final controller = editor.controller!;
      final findController = editor.findController!;
      expect(controller.text, 'fixture');
      expect(findController.value, isNull);
      expect(tester.takeException(), isNull);
      editor.focusNode!.requestFocus();
      await tester.pump();
      expect(editor.focusNode!.hasFocus, isTrue);
      controller.selection = const CodeLineSelection(
        baseIndex: 0,
        baseOffset: 1,
        extentIndex: 0,
        extentOffset: 3,
      );
      final before = controller.value;
      final visibility = ValueNotifier(true);
      addTearDown(visibility.dispose);
      editor.toolbarController!.show(
        context: context,
        controller: controller,
        anchors: const TextSelectionToolbarAnchors(
          primaryAnchor: Offset(100, 200),
        ),
        renderRect: const Rect.fromLTWH(0, 0, 800, 600),
        layerLink: LayerLink(),
        visibility: visibility,
      );
      await tester.pumpAndSettle();
      final menu = tester.widget<AdaptiveTextSelectionToolbar>(
        find.byType(AdaptiveTextSelectionToolbar),
      );
      final callbacks = {
        for (final item in menu.buttonItems!) item.type: item.onPressed,
      };
      final currentEditor = tester.widget<CodeEditor>(editorFinder);
      expect(currentEditor.controller, same(controller));
      expect(currentEditor.findController, same(findController));
      expect(currentEditor.focusNode, same(editor.focusNode));
      final openFind = tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Find',
            ),
          )
          .onPressed!;
      if (reason == 'background') {
        app.setForeground(false);
      } else if (reason == 'task exit') {
        active.value = false;
      } else {
        Navigator.of(context).pop();
        // The route has exited but is still mounted for its reverse animation.
        expect(pageState.mounted, isTrue);
      }
      callbacks[ContextMenuButtonType.copy]!();
      callbacks[ContextMenuButtonType.cut]!();
      callbacks[ContextMenuButtonType.paste]!();
      callbacks[ContextMenuButtonType.selectAll]!();
      openFind();
      await tester.pump();
      expect(editor.focusNode!.hasFocus, isFalse);
      expect(controller.value, same(before));
      expect(findController.value, isNull);
      expect(clipboardWrites, 0);
      expect(app.commands, isEmpty);
      if (reason == 'route exit') {
        await tester.pumpAndSettle();
        expect(pageState.mounted, isFalse);
        // Holding a callback beyond dispose cannot refresh an overlay either.
        callbacks[ContextMenuButtonType.selectAll]!();
        callbacks[ContextMenuButtonType.copy]!();
        openFind();
        await tester.pump();
        expect(clipboardWrites, 0);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'find toolbar keeps one input through motion and resize, reduced=$reduced',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(800, 700);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final app = EditorApp();
        addTearDown(app.dispose);
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
            home: ConfigTextPage(app: app, initialText: 'fixture'),
          ),
        );
        await tester.pumpAndSettle();
        final editorFinder = find.byType(CodeEditor);
        final editorState = tester.state(editorFinder);
        final editor = tester.widget<CodeEditor>(editorFinder);
        final controller = editor.controller!;
        controller.selection = const CodeLineSelection.collapsed(
          index: 0,
          offset: 2,
        );
        final value = controller.value;
        final input = find.byType(TextField);
        final query = editor.findController!.findInputController;
        double opacity() => tester
            .widget<Opacity>(
              find.ancestor(of: input, matching: find.byType(Opacity)).first,
            )
            .opacity;
        await tester.tap(find.byTooltip('Find'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        if (reduced) {
          expect(opacity(), 1);
        } else {
          expect(opacity(), greaterThan(0));
          expect(opacity(), lessThan(1));
        }
        final middle = opacity();
        final inputState = tester.state(input);
        await tester.tap(find.byTooltip('Close find'));
        await tester.pump();
        if (!reduced) expect(opacity(), closeTo(middle, 0.001));
        await tester.pump(const Duration(milliseconds: 32));
        if (!reduced) expect(opacity(), lessThan(middle));
        await tester.tap(find.byTooltip('Find'));
        await tester.pumpAndSettle();
        expect(opacity(), 1);
        expect(tester.state(input), same(inputState));
        expect(tester.state(editorFinder), same(editorState));
        expect(
          tester.widget<CodeEditor>(editorFinder).controller,
          same(controller),
        );
        expect(controller.codeLines, same(value.codeLines));
        expect(controller.selection, value.selection);
        expect(controller.composing, value.composing);

        const composing = TextEditingValue(
          text: 'zzz',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        );
        query.value = composing;
        final toolbar = find.byKey(const ValueKey('editor-toolbar-size'));
        void expectResizeFrame(String phase) {
          if (reduced) return;
          final row = find
              .ancestor(of: input, matching: find.byType(Row))
              .first;
          final flex = tester.renderObject<RenderFlex>(row);
          final details =
              '$phase; viewport=${tester.view.physicalSize}; '
              'constraints=${flex.constraints}; size=${flex.size}; '
              'creator=${flex.debugCreator}\n${flex.toStringDeep()}';
          expect(tester.takeException(), isNull, reason: details);
          expect(
            flex.size.width,
            tester.view.physicalSize.width / tester.view.devicePixelRatio,
            reason: details,
          );
          expect(
            tester.getSize(input).width,
            greaterThanOrEqualTo(96),
            reason: details,
          );
          for (final tooltip in ['Previous', 'Next', 'Close find']) {
            final button = find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == tooltip,
            );
            final size = tester.getSize(button);
            expect(size.width, greaterThanOrEqualTo(48), reason: details);
            expect(size.height, greaterThanOrEqualTo(48), reason: details);
          }
        }

        final wideHeight = tester.getSize(toolbar).height;
        tester.view.physicalSize = const Size(320, 700);
        await tester.pump();
        expectResizeFrame('800 -> 320 first frame');
        await tester.pump(const Duration(milliseconds: 80));
        expectResizeFrame('800 -> 320 at 80 ms');
        final middleHeight = tester.getSize(toolbar).height;
        if (!reduced) expect(middleHeight, greaterThan(wideHeight));
        expect(query.value, composing);
        expect(tester.state(input), same(inputState));
        expect(tester.state(editorFinder), same(editorState));
        await tester.pump(const Duration(milliseconds: 200));
        expectResizeFrame('800 -> 320 after the size transition');
        final narrowHeight = tester.getSize(toolbar).height;
        expect(narrowHeight, greaterThan(wideHeight));
        if (reduced) {
          expect(middleHeight, narrowHeight);
        } else {
          expect(middleHeight, lessThan(narrowHeight));
        }
        expect(query.value, composing);
        expect(controller.codeLines, same(value.codeLines));
        expect(controller.selection, value.selection);
        expect(controller.composing, value.composing);
        expect(tester.widget<TextField>(input).controller, same(query));
        if (!reduced) {
          tester.view.physicalSize = const Size(800, 700);
          await tester.pump();
          expectResizeFrame('320 -> 800 first frame');
          await tester.pump(const Duration(milliseconds: 48));
          expectResizeFrame('320 -> 800 at 48 ms');
          tester.view.physicalSize = const Size(320, 700);
          await tester.pump();
          expectResizeFrame('reversed 800 -> 320 first frame');
          await tester.pump(const Duration(milliseconds: 80));
          expectResizeFrame('reversed 800 -> 320 at 80 ms');
          await tester.pump(const Duration(milliseconds: 200));
          expectResizeFrame('reversed 800 -> 320 after the size transition');
          expect(tester.state(input), same(inputState));
          expect(tester.state(editorFinder), same(editorState));
          expect(tester.widget<TextField>(input).controller, same(query));
          expect(
            tester.widget<CodeEditor>(editorFinder).controller,
            same(controller),
          );
          expect(query.value, composing);
          expect(controller.codeLines, same(value.codeLines));
          expect(controller.selection, value.selection);
          expect(controller.composing, value.composing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(app.commands, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
