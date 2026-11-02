import 'dart:async';

import 'package:clash_pseudo/src/ui/overrides/forms/shared/editor.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/save_bar.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/form_interaction.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/form_body.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/rule_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'definition_forms_test.dart' as forms;
import '../../../../support/text_scalers.dart';
import '../proxy/proxy_form_test.dart' as proxies;

Widget page(String kind, VoidCallback saved, {bool invalid = false}) =>
    switch (kind) {
      'proxy' => ProxyFormPage(
        initialDefinition: {
          'type': 'http',
          'name': 'controlled',
          'server': 'node.fixture.test',
          'port': 443,
          if (invalid) 'routing-mark': 'invalid',
        },
        onSave: (_) async => saved(),
      ),
      'group' => StrategyGroupFormPage(
        initialDefinition: {
          'name': 'controlled',
          'type': 'select',
          'proxies': ['DIRECT'],
          if (invalid) 'timeout': -1,
        },
        onSave: (_) async => saved(),
      ),
      _ => ProviderFormPage(
        ruleProvider: kind == 'rule-provider',
        initialName: 'controlled',
        initialDefinition: {
          'type': 'http',
          'url': 'https://fixture.invalid/provider',
          if (kind == 'rule-provider') 'behavior': 'domain',
          if (invalid) 'health-check': {'timeout': -1},
        },
        onSave: (_, _) async => saved(),
      ),
    };

Finder nameField(String kind) => kind == 'proxy'
    ? find.descendant(
        of: proxies.keyed('proxy-field:common/name'),
        matching: find.byType(TextField),
      )
    : forms.keyed(
        'definition-input:${kind == 'group' ? 'group' : 'provider'}/name',
      );

Rect _globalSemanticsRect(SemanticsNode node) {
  var rect = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) rect = MatrixUtils.transformRect(transform, rect);
    current = current.parent;
  }
  return rect;
}

void _expectRectNear(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, .1));
  expect(actual.top, closeTo(expected.top, .1));
  expect(actual.width, closeTo(expected.width, .1));
  expect(actual.height, closeTo(expected.height, .1));
}

Set<SemanticsNode> _reachableSemanticsNodes(WidgetTester tester) {
  final nodes = <SemanticsNode>{};
  void visit(SemanticsNode node) {
    nodes.add(node);
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  for (final view in tester.binding.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null) visit(root);
  }
  return nodes;
}

void _expectWithSemanticsEvidence(
  WidgetTester tester, {
  required String phase,
  required Finder target,
  SemanticsNode? node,
  required VoidCallback assertion,
}) {
  try {
    assertion();
  } catch (_) {
    final evidence = StringBuffer(
      'SEMANTICS EVIDENCE: $phase viewSize=${tester.view.physicalSize}\n',
    );
    try {
      final reachable = <SemanticsNode>{};
      String describe(SemanticsNode node) =>
          'id=${node.id} label=${node.label} rect=${node.rect} '
          'transform=${node.transform} attached=${node.attached} '
          'parent=${node.parent?.id}';
      void visit(SemanticsNode current, int depth) {
        reachable.add(current);
        evidence.writeln('root-tree depth=$depth ${describe(current)}');
        current.visitChildren((child) {
          visit(child, depth + 1);
          return true;
        });
      }

      for (final view in tester.binding.renderViews) {
        final root = view.owner?.semanticsOwner?.rootSemanticsNode;
        evidence.writeln('view=${view.flutterView.viewId} root=${root?.id}');
        if (root != null) visit(root, 0);
      }
      void parents(String origin, SemanticsNode? current) {
        evidence.writeln('$origin node=${current?.id}');
        while (current != null) {
          evidence.writeln(
            'target-parent ${describe(current)} '
            'rootReachable=${reachable.contains(current)}',
          );
          current = current.parent;
        }
      }

      if (node == null) {
        evidence.writeln('tester.getSemantics result: not supplied');
      } else {
        parents('tester.getSemantics result', node);
      }
      final elements = target.evaluate().toList();
      evidence.writeln('target elements=${elements.length}');
      for (final element in elements) {
        final render = element.findRenderObject();
        if (render == null) {
          evidence.writeln('target render=null');
          continue;
        }
        final paintRect = render.attached
            ? MatrixUtils.transformRect(
                render.getTransformTo(null),
                render.paintBounds,
              )
            : null;
        evidence.writeln(
          'target render=${render.runtimeType} attached=${render.attached} '
          'debugNeedsSemanticsUpdate=${render.debugNeedsSemanticsUpdate} '
          'paintBounds=${render.paintBounds} globalPaintRect=$paintRect',
        );
        parents('render.debugSemantics', render.debugSemantics);
      }
    } catch (captureError, captureStack) {
      evidence.writeln(
        'SEMANTICS EVIDENCE CAPTURE FAILED: $captureError\n$captureStack',
      );
    }
    debugPrintSynchronously(evidence.toString());
    rethrow;
  }
}

void _expectRectStrictlyBetween(
  Rect actual,
  Rect start,
  Rect end, {
  required double fixedHeight,
}) {
  for (final rect in [start, actual, end]) {
    expect(rect.bottom, rect.top + fixedHeight);
  }
  var changingDimensions = 0;
  for (final (value, from, to) in [
    (actual.left, start.left, end.left),
    (actual.top, start.top, end.top),
    (actual.width, start.width, end.width),
  ]) {
    if (from == to) {
      expect(value, closeTo(from, .1));
    } else {
      changingDimensions++;
      expect(
        value,
        inExclusiveRange(from < to ? from : to, from < to ? to : from),
      );
    }
  }
  expect(changingDimensions, greaterThanOrEqualTo(3));
}

void _expectLabelWithinClips(
  WidgetTester tester,
  Finder label,
  Finder field, {
  bool fullyVisible = true,
}) {
  final paragraph = tester.renderObject<RenderParagraph>(label);
  expect(paragraph.didExceedMaxLines, isFalse);
  final painted = MatrixUtils.transformRect(
    paragraph.getTransformTo(null),
    paragraph.paintBounds,
  );
  // The field itself must own its label's above-outline paint space. Chapter
  // padding cannot compensate when this is the first field of a local clip.
  expect(painted.top, greaterThanOrEqualTo(tester.getRect(field).top - .1));
  var clips = 0;
  tester.element(label).visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is ClipRect && widget.clipBehavior != Clip.none) {
      final render = element.findRenderObject()! as RenderClipRect;
      final bounds =
          widget.clipper?.getClip(render.size) ?? (Offset.zero & render.size);
      final clip = MatrixUtils.transformRect(
        render.getTransformTo(null),
        bounds,
      );
      expect(painted.top, greaterThanOrEqualTo(clip.top - .1));
      if (fullyVisible) {
        expect(painted.bottom, lessThanOrEqualTo(clip.bottom + .1));
      }
      clips++;
    }
    return true;
  });
  expect(clips, greaterThan(0));
}

void main() {
  for (final kind in ['proxy', 'group', 'provider', 'rule']) {
    testWidgets(
      '$kind pending save rejects exits and completed save exits with its actual result',
      (tester) async {
        final app = AppController(AppBridge());
        addTearDown(app.dispose);
        var taskActive = true;
        final pending = Completer<void>();
        final accepted = <Object>[];
        Object? saved;
        String? savedName;
        var handled = 0;
        final original = <String, Object?>{
          'type': kind == 'group'
              ? 'select'
              : kind == 'proxy'
              ? 'http'
              : 'inline',
          if (kind != 'provider') 'name': 'controlled',
          if (kind == 'proxy') ...{'server': 'node.fixture.test', 'port': 443},
          if (kind == 'group') 'proxies': ['DIRECT'],
          if (kind == 'provider') 'payload': <Object?>[],
          'unknown': {
            'flag': false,
            'null': null,
            'zero': 0,
            'empty': '',
            'list': <Object?>[],
            'map': <String, Object?>{},
          },
        };
        Future<void> save(Object value) async {
          accepted.add(value);
          await pending.future;
          saved = value;
        }

        void notify() => handled++;
        final formPage = switch (kind) {
          'proxy' => ProxyFormPage(
            initialDefinition: original,
            onSave: save,
            onSaveHandled: notify,
          ),
          'group' => StrategyGroupFormPage(
            initialDefinition: original,
            onSave: save,
            onSaveHandled: notify,
          ),
          'provider' => ProviderFormPage(
            ruleProvider: false,
            initialName: 'controlled',
            initialDefinition: original,
            onSave: (name, value) {
              savedName = name;
              return save(value);
            },
            onSaveHandled: notify,
          ),
          _ => RuleFormPage(
            targets: const ['DIRECT', 'REJECT'],
            initialRule: 'DOMAIN,fixture.invalid,DIRECT',
            onSave: save,
            onSaveHandled: notify,
          ),
        };
        await forms.openForm(
          tester,
          AppTaskScope(
            owner: app,
            task: AppTask.strategies,
            open: (_) {},
            child: AppTaskActivity(
              active: true,
              isActiveNow: () => app.interactive && taskActive,
              isSourceCurrent: () => taskActive,
              child: formPage,
            ),
          ),
          size: const Size(1000, 900),
        );
        final form = find.byType(formPage.runtimeType);
        final origin = tester.element(form);
        final route = ModalRoute.of(origin)!;
        final navigator = Navigator.of(origin);
        final leave = app.overviewLeaveFor(route)!;
        var returned = false;
        Object? result;
        unawaited(
          route.popped.then<void>((value) {
            returned = true;
            result = value;
          }),
        );
        final input = kind == 'rule'
            ? forms.keyed('definition-input:rule/target')
            : nameField(kind);
        await tester.enterText(
          input,
          kind == 'rule' ? 'REJECT' : 'completed identity',
        );
        await tester.pumpAndSettle();
        final controller = tester.widget<TextField>(input).controller!;
        final inputState = tester.state(input);
        final editable = find.descendant(
          of: input,
          matching: find.byType(EditableText),
        );
        final editableState = tester.state<EditableTextState>(editable);
        final inputFocus = editableState.widget.focusNode;
        expect(inputFocus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        final composingValue = controller.value.copyWith(
          selection: TextSelection.collapsed(offset: controller.text.length),
          composing: const TextRange(start: 1, end: 4),
        );
        tester.testTextInput.updateEditingValue(composingValue);
        await tester.pump();
        expect(controller.value, composingValue);
        expect(controller.value.isComposingRangeValid, isTrue);
        expect(controller.value.composing, const TextRange(start: 1, end: 4));
        final saveButton = kind == 'proxy'
            ? proxies.keyed('proxy-save')
            : forms.keyed('definition-save:$kind');
        final oldSave = tester.widget<FilledButton>(saveButton).onPressed!;
        final saveRect = tester.getRect(saveButton);
        final inputRect = tester.getRect(input);
        final barRect = tester.getRect(find.byType(DefinitionSaveBar));
        final Object expected = switch (kind) {
          'rule' => 'DOMAIN,fixture.invalid,REJECT',
          'provider' => original,
          _ => {...original, 'name': 'completed identity'},
        };
        await tester.tap(saveButton);
        await tester.pump();
        // 点击保存会禁用字段；SDK 随后关闭输入连接并清除组合输入范围（composing）。
        expect(inputFocus.hasFocus, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        final value = composingValue.copyWith(composing: TextRange.empty);
        expect(controller.value, value);
        expect(controller.value.text, composingValue.text);
        expect(controller.value.selection, composingValue.selection);
        expect(tester.state(input), same(inputState));
        expect(tester.state<EditableTextState>(editable), same(editableState));
        expect(accepted, [expected]);
        expect(saved, isNull);
        expect(handled, 0);
        final progress = find.descendant(
          of: saveButton,
          matching: find.byType(CircularProgressIndicator),
        );
        expect(progress, findsOneWidget);
        expect(
          tester.widget<CircularProgressIndicator>(progress).value,
          isNull,
        );
        expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
        expect(tester.getRect(saveButton), saveRect);
        expect(tester.getRect(input), inputRect);
        expect(tester.getRect(find.byType(DefinitionSaveBar)), barRect);
        for (final field in tester.widgetList<TextField>(
          find.byType(TextField),
        )) {
          expect(field.enabled, isFalse);
        }
        await tester.pageBack();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(await leave(), isFalse);
        expect(route.isCurrent, isTrue);
        expect(returned, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        expect(progress, findsOneWidget);
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(tester.state(input), same(inputState));
        expect(tester.state<EditableTextState>(editable), same(editableState));
        expect(controller.value, value);
        final cover = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('completed save cover')),
        );
        unawaited(navigator.push(cover));
        await tester.pumpAndSettle();
        expect(editableState.mounted, isTrue);
        expect(editableState.widget.controller, same(controller));
        expect(controller.value, value);
        pending.complete();
        await tester.pumpAndSettle();
        expect(saved, expected);
        expect(saved, same(accepted.single));
        if (kind == 'provider') expect(savedName, 'completed identity');
        expect(handled, 1);
        expect(editableState.mounted, isTrue);
        expect(editableState.widget.controller, same(controller));
        expect(controller.value, value);
        expect(inputFocus.hasFocus, isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        expect(cover.isCurrent, isTrue);
        expect(route.isActive, isTrue);
        expect(route.isCurrent, isFalse);
        expect(returned, isFalse);
        expect(await leave(), isFalse);
        oldSave();
        expect(accepted, [expected]);
        navigator.pop();
        await tester.pump();
        await tester.pump(cover.reverseTransitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        expect(route.isCurrent, isTrue);
        expect(returned, isFalse);
        expect(tester.element(form), same(origin));
        expect(progress, findsNothing);
        expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(tester.state(input), same(inputState));
        expect(tester.state<EditableTextState>(editable), same(editableState));
        expect(controller.value, value);
        expect(tester.getRect(saveButton), saveRect);
        expect(tester.getRect(input), inputRect);
        expect(tester.getRect(find.byType(DefinitionSaveBar)), barRect);
        for (final field in tester.widgetList<TextField>(
          find.byType(TextField),
        )) {
          expect(field.enabled, isFalse);
        }
        oldSave();
        await tester.pump();
        expect(accepted, [expected]);
        expect(handled, 1);
        expect(returned, isFalse);
        if (kind == 'group') {
          taskActive = false;
          await tester.pump();
          expect(await leave(), isFalse);
          expect(returned, isFalse);
          taskActive = true;
          await tester.pump();
        }
        if (kind == 'provider') {
          // 关闭上层页面后，焦点回到页面的 FocusScope；按 Tab 将焦点移回表单。
          for (var step = 0; step < 5; step++) {
            if (FocusManager.instance.primaryFocus?.context
                    ?.findAncestorWidgetOfExactType<DefinitionEditor>() !=
                null) {
              break;
            }
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pump();
          }
          expect(
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<DefinitionEditor>(),
            isNotNull,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else if (kind == 'rule') {
          final departure = leave();
          await tester.pumpAndSettle();
          expect(await departure, isTrue);
        } else {
          await tester.pageBack();
        }
        if (kind == 'group') {
          await tester.pump();
          expect(route.animation!.status, AnimationStatus.reverse);
          expect(origin.mounted, isTrue);
          var actions = 0;
          unawaited(
            navigator.push<void>(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  body: TextButton(
                    onPressed: () => actions++,
                    child: const Text('new route command'),
                  ),
                ),
              ),
            ),
          );
          expect(await leave(), isFalse);
          oldSave();
          await tester.pumpAndSettle();
          await tester.tap(find.text('new route command'));
          expect(actions, 1);
        } else {
          await tester.pumpAndSettle();
        }
        expect(returned, isTrue);
        expect(result, same(saved));
        expect(result, expected);
        expect(route.isActive, isFalse);
        expect(
          find.byType(formPage.runtimeType, skipOffstage: false),
          findsNothing,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(accepted, [expected]);
        expect(handled, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'save source stays with owner A when the same scope changes to owner B during actual save',
    (tester) async {
      final a = AppController(AppBridge());
      final b = AppController(AppBridge());
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final owner = ValueNotifier<AppController>(a);
      addTearDown(owner.dispose);
      final pending = Completer<void>();
      const original = <String, Object?>{
        'type': 'select',
        'name': 'captured owner',
        'proxies': ['DIRECT'],
        'unknown': {'flag': false, 'null': null, 'empty': <Object?>[]},
      };
      final accepted = <Map<String, Object?>>[];
      Map<String, Object?>? saved;
      var handled = 0;
      await forms.openForm(
        tester,
        ValueListenableBuilder<AppController>(
          valueListenable: owner,
          child: StrategyGroupFormPage(
            initialDefinition: original,
            onSave: (value) async {
              accepted.add(value);
              await pending.future;
              saved = value;
            },
            onSaveHandled: () => handled++,
          ),
          builder: (_, current, child) => AppTaskScope(
            owner: current,
            task: AppTask.strategies,
            open: (_) {},
            child: AppTaskActivity(
              active: true,
              isActiveNow: () => current.interactive,
              isSourceCurrent: () => true,
              child: child!,
            ),
          ),
        ),
      );
      final form = find.byType(StrategyGroupFormPage);
      final origin = tester.element(form);
      final route = ModalRoute.of(origin)!;
      final scope = origin
          .getElementForInheritedWidgetOfExactType<AppTaskScope>()!;
      final oldLeave = a.overviewLeaveFor(route)!;
      final save = forms.keyed('definition-save:group');
      final oldSave = tester.widget<FilledButton>(save).onPressed!;
      var returned = false;
      unawaited(route.popped.then<void>((_) => returned = true));
      await tester.tap(save);
      await tester.pump();
      expect(accepted, [original]);
      expect(saved, isNull);
      owner.value = b;
      await tester.pump();
      expect(tester.element(form), same(origin));
      expect(
        origin.getElementForInheritedWidgetOfExactType<AppTaskScope>(),
        same(scope),
      );
      expect((scope.widget as AppTaskScope).owner, same(b));
      expect(a.overviewLeaveFor(route), isNull);
      final newLeave = b.overviewLeaveFor(route)!;
      pending.complete();
      await tester.pumpAndSettle();
      expect(saved, original);
      expect(saved, same(accepted.single));
      expect(handled, 1);
      expect(route.isCurrent, isTrue);
      expect(returned, isFalse);
      final editor = tester.widget<DefinitionEditor>(
        find.byType(DefinitionEditor),
      );
      expect(editor.completedResult, same(saved));
      expect(editor.isCompletedSourceCurrent!(), isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(await oldLeave(), isFalse);
      expect(await newLeave(), isFalse);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      oldSave();
      await tester.pump();
      expect(route.isCurrent, isTrue);
      expect(returned, isFalse);
      expect(tester.element(form), same(origin));
      expect(accepted, [original]);
      expect(saved, original);
      expect(handled, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('open form menu then Escape consumes only the menu layer', (
    tester,
  ) async {
    final app = AppController(AppBridge());
    addTearDown(app.dispose);
    var calls = 0;
    const original = <String, Object?>{
      'name': 'controlled',
      'type': 'select',
      'proxies': ['DIRECT'],
    };
    await forms.openForm(
      tester,
      AppTaskScope(
        owner: app,
        task: AppTask.strategies,
        open: (_) {},
        child: AppTaskActivity(
          active: true,
          isActiveNow: () => app.interactive,
          isSourceCurrent: () => true,
          child: StrategyGroupFormPage(
            initialDefinition: original,
            onSave: (_) async {
              calls++;
            },
          ),
        ),
      ),
      size: const Size(1000, 900),
    );
    final form = find.byType(StrategyGroupFormPage);
    final origin = tester.element(form);
    final route = ModalRoute.of(origin)!;
    final leave = app.overviewLeaveFor(route)!;
    var returned = false;
    unawaited(route.popped.then<void>((_) => returned = true));
    // 打开类型菜单会添加 LocalHistoryEntry，并将焦点移到菜单按钮。
    await tester.tap(forms.keyed('definition-menu:group/type'));
    await tester.pumpAndSettle();
    final menuItem = find.byType(MenuItemButton);
    expect(menuItem, findsWidgets);
    final nameEditor = find.descendant(
      of: forms.keyed('definition-input:group/name'),
      matching: find.byType(EditableText),
    );
    final nameFocus = tester
        .state<EditableTextState>(nameEditor)
        .widget
        .focusNode;
    nameFocus.requestFocus();
    await tester.pumpAndSettle();
    expect(nameFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(menuItem, findsNothing);
    expect(route.isCurrent, isTrue);
    expect(returned, isFalse);
    expect(tester.element(form), same(origin));
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls, 0);
    expect(tester.takeException(), isNull);
    // 菜单关闭后，调用同一个退出回调即可退出表单。
    expect(await leave(), isTrue);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  for (final outcome in [
    'current',
    'covered',
    'reverse-new-route',
    'task-retired',
  ]) {
    testWidgets(
      'group save keeps its actual success and only exits its current route $outcome',
      (tester) async {
        final app = AppController(AppBridge());
        addTearDown(app.dispose);
        var taskActive = true;
        final pending = Completer<void>();
        const original = <String, Object?>{
          'type': 'select',
          'name': 'saved group',
          'proxies': ['DIRECT'],
          'unknown': {'null': null, 'false': false, 'zero': 0},
        };
        final accepted = <Map<String, Object?>>[];
        Map<String, Object?>? saved;
        var handled = 0;
        var returned = false;
        Object? result;
        await forms.openForm(
          tester,
          AppTaskScope(
            owner: app,
            task: AppTask.strategies,
            open: (_) {},
            child: AppTaskActivity(
              active: true,
              isActiveNow: () => taskActive,
              child: StrategyGroupFormPage(
                initialDefinition: original,
                onSave: (value) async {
                  accepted.add(value);
                  await pending.future;
                  saved = value;
                },
                onSaveHandled: () => handled++,
              ),
            ),
          ),
        );
        final form = find.byType(StrategyGroupFormPage);
        final origin = tester.element(form);
        final route = ModalRoute.of(origin)!;
        final navigator = Navigator.of(origin);
        unawaited(
          route.popped.then<void>((value) {
            returned = true;
            result = value;
          }),
        );
        final save = forms.keyed('definition-save:group');
        final oldSave = tester.widget<FilledButton>(save).onPressed!;
        await tester.tap(save);
        await tester.pump();
        expect(accepted, [original]);
        expect(saved, isNull);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        var newActions = 0;
        void cover() {
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: TextButton(
                  onPressed: () => newActions++,
                  child: const Text('unrelated current command'),
                ),
              ),
            ),
          );
        }

        if (outcome == 'covered') {
          cover();
          await tester.pumpAndSettle();
        } else if (outcome == 'reverse-new-route') {
          navigator.pop();
          expect(route.animation!.status, AnimationStatus.reverse);
          expect(origin.mounted, isTrue);
          cover();
        } else if (outcome == 'task-retired') {
          // 保持 AppTaskActivity.active 为 true，只让实时检查读取的 taskActive 变为 false。
          taskActive = false;
        }
        pending.complete();
        if (outcome == 'task-retired') {
          await tester.pump();
        } else {
          await tester.pumpAndSettle();
        }
        expect(saved, original);
        expect(accepted, [original]);
        expect(handled, outcome == 'reverse-new-route' ? 0 : 1);
        if (outcome == 'current') {
          expect(returned, isTrue);
          expect(result, original);
          expect(form, findsNothing);
        } else if (outcome == 'covered' || outcome == 'reverse-new-route') {
          final action = find.widgetWithText(
            TextButton,
            'unrelated current command',
          );
          expect(action, findsOneWidget);
          await tester.tap(action);
          expect(newActions, 1);
          if (outcome == 'covered') {
            expect(
              find.byType(StrategyGroupFormPage, skipOffstage: false),
              findsOneWidget,
            );
            expect(
              tester.element(
                find.byType(StrategyGroupFormPage, skipOffstage: false),
              ),
              same(origin),
            );
            expect(returned, isFalse);
            final coverRoute = ModalRoute.of(tester.element(action))!;
            navigator.pop();
            await tester.pump();
            await tester.pump(coverRoute.reverseTransitionDuration);
            await tester.pump();
            expect(route.isCurrent, isTrue);
            expect(form, findsOneWidget);
            expect(returned, isFalse);
          } else {
            expect(returned, isTrue);
            expect(result, isNull);
            expect(
              find.byType(StrategyGroupFormPage, skipOffstage: false),
              findsNothing,
            );
          }
        } else {
          expect(route.isCurrent, isTrue);
          expect(form, findsOneWidget);
          expect(returned, isFalse);
          taskActive = true;
          await tester.pump();
          expect(form, findsOneWidget);
          expect(returned, isFalse);
        }
        oldSave();
        if (outcome == 'covered' || outcome == 'task-retired') {
          await tester.pump();
        } else {
          await tester.pumpAndSettle();
        }
        expect(accepted, [original]);
        expect(saved, original);
        if (outcome == 'covered' || outcome == 'task-retired') {
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          final progress = find.descendant(
            of: save,
            matching: find.byType(CircularProgressIndicator),
          );
          expect(progress, findsNothing);
          expect(returned, isFalse);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final change in [
    'current-after-wait',
    'covered-at-entry',
    'task-at-entry',
    'covered-during-wait',
    'task-during-wait',
    'reverse-new-route-during-wait',
  ]) {
    testWidgets(
      'definitionSaved cannot borrow navigation after waiting $change',
      (tester) async {
        final app = AppController(AppBridge());
        addTearDown(app.dispose);
        var taskActive = true;
        late BuildContext origin;
        await forms.openForm(
          tester,
          AppTaskScope(
            owner: app,
            task: AppTask.strategies,
            open: (_) {},
            child: AppTaskActivity(
              active: true,
              isActiveNow: () => taskActive,
              child: Builder(
                builder: (context) {
                  origin = context;
                  return const Scaffold(body: Text('saved origin'));
                },
              ),
            ),
          ),
        );
        final route = ModalRoute.of(origin)!;
        final navigator = Navigator.of(origin);
        var returned = false;
        Object? result;
        unawaited(
          route.popped.then<void>((value) {
            returned = true;
            result = value;
          }),
        );
        void cover() {
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('new current route')),
            ),
          );
        }

        app.setInteractive(false);
        if (change == 'covered-at-entry') {
          cover();
          await tester.pumpAndSettle();
        } else if (change == 'task-at-entry') {
          taskActive = false;
        }
        var finished = false;
        final completion = definitionSaved(
          origin,
          'actual-result',
        ).whenComplete(() => finished = true);
        await tester.pump();
        final invalidAtEntry =
            change == 'covered-at-entry' || change == 'task-at-entry';
        expect(finished, invalidAtEntry);
        if (change == 'covered-during-wait') {
          cover();
          await tester.pumpAndSettle();
        } else if (change == 'task-during-wait') {
          taskActive = false;
        } else if (change == 'reverse-new-route-during-wait') {
          navigator.pop();
          expect(route.animation!.status, AnimationStatus.reverse);
          expect(origin.mounted, isTrue);
          cover();
        }
        app.setInteractive(true);
        await tester.pumpAndSettle();
        await completion;
        expect(finished, isTrue);
        if (change == 'current-after-wait') {
          expect(returned, isTrue);
          expect(result, 'actual-result');
          expect(find.text('saved origin'), findsNothing);
        } else if (change == 'reverse-new-route-during-wait') {
          expect(returned, isTrue);
          expect(result, isNull);
          expect(find.text('new current route'), findsOneWidget);
        } else {
          expect(returned, isFalse);
          expect(
            find.text('saved origin', skipOffstage: false),
            findsOneWidget,
          );
          if (change.startsWith('covered-')) {
            expect(find.text('new current route'), findsOneWidget);
            navigator.pop();
          } else {
            taskActive = true;
          }
          await tester.pumpAndSettle();
          expect(route.isCurrent, isTrue);
          expect(find.text('saved origin'), findsOneWidget);
          expect(returned, isFalse);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  group('outlined first-field paint space', () {
    for (final language in ['en', 'zh']) {
      for (final (scaleName, scaler) in [
        ('1', TextScaler.noScaling),
        ('2', TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        for (final reduced in [false, true]) {
          testWidgets(
            'label stays inside local clips through IME and reversal $language/$scaleName/$reduced',
            (tester) async {
              final scroll = ScrollController();
              addTearDown(scroll.dispose);
              addTearDown(tester.view.resetViewInsets);
              final formKey = GlobalKey<FormState>();
              final originalKey = GlobalKey();
              var visible = true;
              late StateSetter update;
              final labelText = language == 'zh' ? '原始字段' : 'Original field';
              await forms.openForm(
                tester,
                StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(disableAnimations: reduced),
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          inputDecorationTheme: const InputDecorationTheme(
                            floatingLabelStyle: TextStyle(fontSize: 28),
                          ),
                        ),
                        child: Scaffold(
                          body: DefinitionFormBody(
                            form: formKey,
                            controller: scroll,
                            chapters: [
                              DefinitionFormChapter(
                                id: 'label-space',
                                title: 'Fields',
                                children: [
                                  DefinitionFormVisibility(
                                    visible: visible,
                                    child: DefinitionOriginalField(
                                      key: originalKey,
                                      id: 'paint/first',
                                      label: labelText,
                                      originalValue: 'fixture',
                                    ),
                                  ),
                                  const DefinitionTextField(
                                    id: 'paint/editing',
                                    label: 'Editing',
                                    initialValue: 'retained draft',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                locale: Locale(language),
                scaler: scaler,
                size: const Size(1000, 1136),
              );
              final original = find.byKey(originalKey, skipOffstage: false);
              final label = find.descendant(
                of: original,
                matching: find.text(labelText, skipOffstage: false),
                skipOffstage: false,
              );
              final originalElement = tester.element(original);
              final input = forms.keyed(
                'definition-input:paint/editing',
                offstage: true,
              );
              final inputState = tester.state(input);
              final editable = find.descendant(
                of: input,
                matching: find.byType(EditableText, skipOffstage: false),
                skipOffstage: false,
              );
              final editableState = tester.state<EditableTextState>(editable);
              final controller = tester.widget<TextField>(input).controller!;
              final form = formKey.currentState;
              final position = scroll.position;
              await tester.tap(input);
              await tester.pump();
              const composing = TextEditingValue(
                text: 'retained draft',
                selection: TextSelection(baseOffset: 1, extentOffset: 5),
                composing: TextRange(start: 1, end: 5),
              );
              tester.testTextInput.updateEditingValue(composing);
              await tester.pump();

              void expectDraft(TextEditingValue value) {
                expect(tester.element(original), same(originalElement));
                expect(tester.state(input), same(inputState));
                expect(
                  tester.state<EditableTextState>(editable),
                  same(editableState),
                );
                expect(
                  tester.widget<TextField>(input).controller,
                  same(controller),
                );
                expect(formKey.currentState, same(form));
                expect(scroll.position, same(position));
                expect(controller.value, value);
                expect(tester.takeException(), isNull);
              }

              _expectLabelWithinClips(tester, label, original);
              for (final bottom in [240.0, 0.0, 320.0, 0.0]) {
                tester.view.viewInsets = FakeViewPadding(bottom: bottom);
                for (final ms in [0, 16, 80]) {
                  await tester.pump(Duration(milliseconds: ms));
                  _expectLabelWithinClips(tester, label, original);
                  expectDraft(composing);
                  expect(editableState.widget.focusNode.hasFocus, isTrue);
                }
              }
              update(() => visible = false);
              await tester.pump();
              expectDraft(composing);
              if (!reduced) {
                _expectLabelWithinClips(
                  tester,
                  label,
                  original,
                  fullyVisible: false,
                );
                await tester.pump(const Duration(milliseconds: 60));
                _expectLabelWithinClips(
                  tester,
                  label,
                  original,
                  fullyVisible: false,
                );
                expectDraft(composing);
              }
              update(() => visible = true);
              for (final ms in [0, 30, 60, 180]) {
                await tester.pump(Duration(milliseconds: ms));
                _expectLabelWithinClips(
                  tester,
                  label,
                  original,
                  fullyVisible: false,
                );
                expectDraft(composing);
              }
              await tester.pumpAndSettle();
              _expectLabelWithinClips(tester, label, original);

              final chapter = ExpansibleController.of(tester.element(label));
              chapter.collapse();
              await tester.pump();
              // Retiring the editing section ends the actual SDK IME connection;
              // its draft and selection survive, without restoring stale composing.
              final retired = composing.copyWith(composing: TextRange.empty);
              expectDraft(retired);
              expect(editableState.widget.focusNode.hasFocus, isFalse);
              if (!reduced) {
                await tester.pump(const Duration(milliseconds: 60));
                _expectLabelWithinClips(
                  tester,
                  label,
                  original,
                  fullyVisible: false,
                );
                expectDraft(retired);
              }
              chapter.expand();
              for (final ms in [0, 30, 60, 180]) {
                await tester.pump(Duration(milliseconds: ms));
                _expectLabelWithinClips(
                  tester,
                  label,
                  original,
                  fullyVisible: false,
                );
                expectDraft(retired);
              }
              await tester.pumpAndSettle();
              _expectLabelWithinClips(tester, label, original);
              expectDraft(retired);
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'chapter columns keep one editing tree through intermediate resize and reversal reduced=$reduced',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          final formKey = GlobalKey<FormState>();
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          final editorKey = GlobalKey();
          final secondKey = GlobalKey();
          const fixedHeight = 100.0;
          final secondSemanticsKey = GlobalKey();
          final thirdKey = GlobalKey();
          var pointerHits = 0;
          var disableAnimations = reduced;
          late StateSetter updateMotion;
          await forms.openForm(
            tester,
            StatefulBuilder(
              builder: (context, setState) {
                updateMotion = setState;
                return MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: disableAnimations),
                  child: Scaffold(
                    body: DefinitionFormBody(
                      form: formKey,
                      controller: scroll,
                      chapters: [
                        DefinitionFormChapter(
                          id: 'first',
                          title: 'First',
                          children: [
                            DefinitionTextField(
                              key: editorKey,
                              id: 'motion/input',
                              label: 'Input',
                              initialValue: 'retained draft',
                            ),
                          ],
                        ),
                        DefinitionFormChapter(
                          id: 'second',
                          title: 'Second',
                          secondary: true,
                          children: [
                            Semantics(
                              key: secondSemanticsKey,
                              container: true,
                              label: 'moving chapter target',
                              onTap: () {},
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerDown: (_) => pointerHits++,
                                child: SizedBox(
                                  key: secondKey,
                                  height: fixedHeight,
                                  child: const Text('second chapter'),
                                ),
                              ),
                            ),
                          ],
                        ),
                        DefinitionFormChapter(
                          id: 'third',
                          title: 'Third',
                          children: [
                            SizedBox(
                              key: thirdKey,
                              height: 100,
                              child: const Text('third chapter'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            size: const Size(1200, 900),
          );
          final moving = find.byKey(secondKey);
          // Measure real endpoint Rects at each constraint before editing. These
          // single-frame reduced layouts do not duplicate or remount the form.
          final endpoints = <double, Rect>{};
          updateMotion(() => disableAnimations = true);
          for (final width in [700.0, 880.0, 980.0, 1080.0, 1200.0]) {
            tester.view.physicalSize = Size(width, 900);
            await tester.pump();
            final endpoint = tester.getRect(moving);
            expect(
              tester.renderObject<RenderBox>(moving).size.height,
              fixedHeight,
            );
            expect(endpoint.bottom, endpoint.top + fixedHeight);
            endpoints[width] = endpoint;
          }
          updateMotion(() => disableAnimations = reduced);
          await tester.pump();
          final inputFinder = forms.keyed('definition-input:motion/input');
          await tester.tap(inputFinder);
          await tester.pump();
          final controller = tester.widget<TextField>(inputFinder).controller!;
          controller.value = const TextEditingValue(
            text: 'retained draft',
            selection: TextSelection(baseOffset: 1, extentOffset: 5),
            composing: TextRange(start: 1, end: 5),
          );
          final value = controller.value;
          final inputState = tester.state(find.byKey(editorKey));
          final form = formKey.currentState;
          final wideTop = endpoints[1200]!.top;
          tester.view.physicalSize = const Size(700, 900);
          await tester.pump();
          final startRect = tester.getRect(moving);
          expect(
            tester.renderObject<RenderBox>(moving).size.height,
            fixedHeight,
          );
          expect(startRect.bottom, startRect.top + fixedHeight);
          if (!reduced) {
            await tester.pump(const Duration(milliseconds: 60));
            final middle = tester.getRect(moving);
            expect(
              tester.renderObject<RenderBox>(moving).size.height,
              fixedHeight,
            );
            _expectRectStrictlyBetween(
              middle,
              startRect,
              endpoints[700]!,
              fixedHeight: fixedHeight,
            );
            final node = tester.getSemantics(find.byKey(secondSemanticsKey));
            final secondExpansion = ExpansibleController.of(
              tester.element(find.byKey(secondSemanticsKey)),
            );
            expect(secondExpansion.isExpanded, isTrue);
            expect(node.attached, isTrue);
            expect(_reachableSemanticsNodes(tester), contains(same(node)));
            expect(
              node.getSemanticsData().hasAction(SemanticsAction.tap),
              isTrue,
            );
            _expectRectNear(_globalSemanticsRect(node), middle);
            // Dispatch actual pointer events at the moving Rect, not cached
            // widget callbacks. Cancel the stale probe so an unrelated header
            // under the old position cannot change the chapter being measured.
            final stalePoint = Offset(startRect.center.dx, startRect.top + 1);
            expect(middle.contains(stalePoint), isFalse);
            final staleGesture = await tester.startGesture(stalePoint);
            await staleGesture.cancel();
            expect(pointerHits, 0);
            await tester.tapAt(middle.center);
            expect(pointerHits, 1);
            expect(secondExpansion.isExpanded, isTrue);
            expect(controller.value, value);
            tester.view.physicalSize = const Size(1200, 900);
            await tester.pump();
            expect(tester.getRect(moving).top, closeTo(middle.top, .1));
            await tester.pump(const Duration(milliseconds: 30));
            expect(
              tester.getRect(moving).top,
              inExclusiveRange(wideTop, middle.top),
            );
            var previousWidth = 1200.0;
            for (final width in [1080.0, 980.0, 880.0]) {
              final beforeResize = tester.getRect(moving);
              tester.view.physicalSize = Size(width, 900);
              await tester.pump();
              final resized = tester.getRect(moving);
              // New bounds can change width, but cannot reset motion progress.
              expect(resized.top, closeTo(beforeResize.top, .1));
              expect(
                (resized.width - beforeResize.width).abs(),
                lessThanOrEqualTo((width - previousWidth).abs() + .1),
              );
              await tester.pump(const Duration(milliseconds: 16));
              final frame = tester.getRect(moving);
              expect(
                tester.renderObject<RenderBox>(moving).size.height,
                fixedHeight,
              );
              expect(frame.bottom, frame.top + fixedHeight);
              expect(
                frame.top,
                inExclusiveRange(endpoints[width]!.top, resized.top),
              );
              expect(
                (frame.top - resized.top).abs(),
                lessThan((endpoints[700]!.top - wideTop) / 3),
              );
              final frameNode = tester.getSemantics(
                find.byKey(secondSemanticsKey),
              );
              _expectWithSemanticsEvidence(
                tester,
                phase: 'columns reduced=$reduced width=$width after16ms',
                target: find.byKey(secondSemanticsKey),
                node: frameNode,
                assertion: () {
                  expect(secondExpansion.isExpanded, isTrue);
                  expect(frameNode.attached, isTrue);
                  expect(
                    _reachableSemanticsNodes(tester),
                    contains(same(frameNode)),
                  );
                  _expectRectNear(_globalSemanticsRect(frameNode), frame);
                },
              );
              expect(
                tester.widget<TextField>(inputFinder).controller,
                same(controller),
              );
              expect(controller.value, value);
              previousWidth = width;
            }
            final beforeReduce = tester.getRect(moving);
            expect(beforeReduce.top, greaterThan(endpoints[880]!.top));
            updateMotion(() => disableAnimations = true);
            await tester.pump();
            _expectWithSemanticsEvidence(
              tester,
              phase: 'columns reduce first frame expected=${endpoints[880]}',
              target: find.byKey(secondSemanticsKey),
              assertion: () =>
                  _expectRectNear(tester.getRect(moving), endpoints[880]!),
            );
            await tester.pump(const Duration(milliseconds: 16));
            _expectWithSemanticsEvidence(
              tester,
              phase: 'columns reduce after16ms expected=${endpoints[880]}',
              target: find.byKey(secondSemanticsKey),
              assertion: () =>
                  _expectRectNear(tester.getRect(moving), endpoints[880]!),
            );
          } else {
            _expectRectNear(startRect, endpoints[700]!);
          }
          tester.view.physicalSize = const Size(700, 900);
          await tester.pumpAndSettle();
          _expectRectNear(tester.getRect(moving), endpoints[700]!);
          // The real proxy shape interleaves primary/secondary/primary chapters.
          // Narrow layout must retain source order, not concatenate two groups.
          expect(
            tester.getTopLeft(inputFinder).dy,
            lessThan(tester.getRect(moving).top),
          );
          expect(
            tester.getRect(moving).top,
            lessThan(tester.getTopLeft(find.byKey(thirdKey)).dy),
          );
          expect(formKey.currentState, same(form));
          expect(tester.state(find.byKey(editorKey)), same(inputState));
          expect(controller.value, value);
          expect(find.byType(Form), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
    );

    testWidgets(
      'section exit revokes cached action, semantics and focus before last frame reduced=$reduced',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          var visible = true;
          var disableAnimations = reduced;
          var acted = 0;
          late StateSetter update;
          final input = TextEditingController(text: 'draft');
          final focus = FocusNode();
          addTearDown(input.dispose);
          addTearDown(focus.dispose);
          final form = GlobalKey<FormState>();
          final scroll = ScrollController();
          addTearDown(scroll.dispose);
          await forms.openForm(
            tester,
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: disableAnimations),
                  child: Scaffold(
                    body: DefinitionFormBody(
                      form: form,
                      controller: scroll,
                      children: [
                        DefinitionFormVisibility(
                          visible: visible,
                          child: Column(
                            children: [
                              TextField(
                                key: const ValueKey('moving-input'),
                                controller: input,
                                focusNode: focus,
                              ),
                              DefinitionChoiceField(
                                id: 'moving-choice',
                                label: 'moving choice',
                                options: const {'a': 'A'},
                                onChanged: (_) => acted++,
                              ),
                              Semantics(
                                key: const ValueKey('moving-semantics'),
                                label: 'moving-draft-section',
                                child: const SizedBox(width: 100, height: 100),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(
                          key: ValueKey('after-moving'),
                          height: 40,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
          await tester.tap(forms.keyed('moving-input'));
          await tester.pump();
          final state = tester.state(forms.keyed('moving-input'));
          final collapsedTop = tester.getTopLeft(find.byType(Form)).dy;
          final oldTop = tester.getTopLeft(forms.keyed('after-moving')).dy;
          final menu = tester.widget<ChoiceMenuButton<String>>(
            forms.keyed('definition-menu:moving-choice'),
          );
          Iterable<SemanticsNode> markerNodes() =>
              _reachableSemanticsNodes(tester)
                  .where((node) => node.label.contains('moving-draft-section'));
          final marker = find.byKey(
            const ValueKey('moving-semantics'),
            skipOffstage: false,
          );
          _expectWithSemanticsEvidence(
            tester,
            phase: 'section reduced=$reduced visible before hide',
            target: marker,
            assertion: () => expect(markerNodes(), hasLength(1)),
          );
          update(() => visible = false);
          await tester.pump();
          _expectWithSemanticsEvidence(
            tester,
            phase: 'section reduced=$reduced hidden first frame',
            target: marker,
            assertion: () => expect(markerNodes(), isEmpty),
          );
          menu.onSelected('a');
          expect(acted, 0);
          expect(focus.hasFocus, isFalse);
          expect(forms.keyed('moving-input').hitTestable(), findsNothing);
          if (!reduced) {
            await tester.pump(const Duration(milliseconds: 60));
            final mid = tester.getTopLeft(forms.keyed('after-moving')).dy;
            expect(mid, inExclusiveRange(collapsedTop, oldTop));
            update(() => visible = true);
            await tester.pump();
            expect(
              tester.getTopLeft(forms.keyed('after-moving')).dy,
              closeTo(mid, .1),
            );
            await tester.pump(const Duration(milliseconds: 30));
            expect(
              tester.getTopLeft(forms.keyed('after-moving')).dy,
              inExclusiveRange(mid, oldTop),
            );
            update(() => disableAnimations = true);
            await tester.pump();
            expect(tester.getTopLeft(forms.keyed('after-moving')).dy, oldTop);
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.getTopLeft(forms.keyed('after-moving')).dy, oldTop);
          } else {
            expect(
              tester.getTopLeft(forms.keyed('after-moving')).dy,
              collapsedTop,
            );
            update(() => visible = true);
            await tester.pump();
          }
          await tester.pumpAndSettle();
          expect(tester.state(forms.keyed('moving-input')), same(state));
          expect(input.text, 'draft');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
    );
  }
  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'save bar retains focus and state geometry $language/$scale',
        (tester) async {
          var compact = false;
          var saving = false;
          var completed = false;
          var saves = 0;
          late StateSetter update;
          await forms.openForm(
            tester,
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: DefinitionSaveBar(
                      id: 'controlled',
                      compact: compact,
                      saving: saving,
                      completed: completed,
                      onSave: () => saves++,
                    ),
                  ),
                );
              },
            ),
            size: const Size(280, 480),
            locale: Locale(language),
            scaler: TextScaler.linear(scale),
          );
          final save = forms.keyed('definition-save:controlled');
          final button = tester.state(save);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focus = FocusManager.instance.primaryFocus;
          expect(
            focus?.context?.findAncestorWidgetOfExactType<FilledButton>(),
            isNotNull,
          );
          for (final next in [true, false, true]) {
            update(() => compact = next);
            await tester.pumpAndSettle();
            expect(tester.state(save), same(button));
            expect(FocusManager.instance.primaryFocus, same(focus));
            expect(save.hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          for (final next in [false, true]) {
            update(() => compact = next);
            await tester.pumpAndSettle();
            final bounds = tester.getRect(save);
            final bar = tester.getRect(find.byType(DefinitionSaveBar));
            for (final state in [
              (true, false),
              (false, true),
              (false, false),
            ]) {
              update(() {
                saving = state.$1;
                completed = state.$2;
              });
              await tester.pump();
              expect(tester.getRect(save), bounds);
              expect(tester.getRect(find.byType(DefinitionSaveBar)), bar);
              expect(tester.state(save), same(button));
              expect(
                tester.widget<FilledButton>(save).onPressed == null,
                saving || completed,
              );
              expect(
                forms.keyed('definition-details:controlled').hitTestable(),
                findsNothing,
              );
              expect(tester.takeException(), isNull);
            }
            await tester.tap(save);
            await tester.pump();
          }
          expect(saves, 2);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final kind in ['proxy', 'group', 'proxy-provider', 'rule-provider']) {
    for (final language in ['en', 'zh']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '$kind chapters retain the form and editing value through both axes $language/$scale',
          (tester) async {
            var saves = 0;
            await forms.openForm(
              tester,
              page(kind, () => saves++),
              size: const Size(2000, 900),
              locale: Locale(language),
              scaler: TextScaler.linear(scale),
            );
            final basic = forms.keyed('definition-chapter:basic');
            final secondary = forms.keyed(
              'definition-chapter:${switch (kind) {
                'proxy-provider' => 'advanced',
                'rule-provider' => 'source',
                _ => 'protocol',
              }}',
            );
            expect(
              tester.getRect(basic).right,
              lessThan(tester.getRect(secondary).left),
            );
            expect(
              tester.getTopLeft(basic).dy,
              tester.getTopLeft(secondary).dy,
            );
            final form = tester.state<FormState>(find.byType(Form).first);
            final body = tester.state(find.byType(DefinitionFormBody));
            addTearDown(tester.view.resetViewInsets);
            final field = nameField(kind);
            await tester.enterText(field, 'retained draft');
            final input = tester.widget<TextField>(field).controller!;
            input.value = input.value.copyWith(
              selection: const TextSelection(baseOffset: 1, extentOffset: 5),
              composing: const TextRange(start: 1, end: 5),
            );
            await tester.pump();
            final value = input.value;
            final editor = tester.widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            );
            for (final size in [
              const Size(700, 479),
              const Size(280, 480),
              const Size(2000, 900),
            ]) {
              tester.view.physicalSize = size;
              tester.view.viewInsets = const FakeViewPadding(bottom: 160);
              await tester.pumpAndSettle();
              expect(
                tester.state<FormState>(find.byType(Form).first),
                same(form),
              );
              expect(tester.state(find.byType(DefinitionFormBody)), same(body));
              expect(tester.widget<TextField>(field).controller, same(input));
              final current = tester.widget<EditableText>(
                find.descendant(of: field, matching: find.byType(EditableText)),
              );
              expect(current.focusNode, same(editor.focusNode));
              expect(current.focusNode.hasFocus, isTrue);
              expect(input.value, value);
              expect(
                field.hitTestable(),
                findsOneWidget,
                reason: '$size at $scale',
              );
              expect(saves, 0);
              expect(tester.takeException(), isNull);
            }
            tester.view.resetViewInsets();
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  for (final kind in ['proxy', 'group', 'proxy-provider']) {
    testWidgets(
      '$kind save exposes the first invalid field in a collapsed chapter',
      (tester) async {
        var saves = 0;
        await forms.openForm(tester, page(kind, () => saves++, invalid: true));
        final chapterId = kind == 'proxy-provider'
            ? 'health-check'
            : 'advanced';
        final chapter = forms.keyed('definition-chapter:$chapterId');
        final header = find
            .descendant(of: chapter, matching: find.byType(ListTile))
            .first;
        final expansion = ExpansibleController.of(tester.element(header));
        final field = kind == 'proxy'
            ? find.descendant(
                of: proxies.keyed(
                  'proxy-field:common/routing-mark',
                  offstage: true,
                ),
                matching: find.byType(TextField, skipOffstage: false),
                skipOffstage: false,
              )
            : forms.keyed(
                'definition-input:${kind == 'group' ? 'group/timeout' : 'provider/health-check/timeout'}',
                offstage: true,
              );
        await forms.expandAncestors(tester, field);
        await tester.ensureVisible(field);
        final initialInput = tester.widget<TextField>(field).controller!;
        final invalidValue = initialInput.text;
        await tester.enterText(field, '$invalidValue-edited');
        await tester.enterText(field, invalidValue);
        await tester.pump();
        expansion.collapse();
        await tester.pumpAndSettle();
        final input = tester.widget<TextField>(field).controller!;
        final draft = input.value;
        final save = kind == 'proxy'
            ? proxies.keyed('proxy-save')
            : forms.keyed(
                'definition-save:${kind == 'group' ? 'group' : 'provider'}',
              );
        final saveRect = tester.getRect(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(saves, 0);
        expect(expansion.isExpanded, isTrue);
        final revealed = tester.getRect(field);
        await forms.dismissNotice(tester);
        expect(tester.getRect(field), revealed);
        expect(field.hitTestable(), findsOneWidget);
        expect(input.value.text, draft.text);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(of: field, matching: find.byType(EditableText)),
              )
              .focusNode
              .hasFocus,
          isTrue,
        );
        expect(tester.getRect(save), saveRect);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final keyboardFirst in [true, false]) {
    testWidgets(
      'short keyboard workspace shows input and error together, keyboard first: $keyboardFirst',
      (tester) async {
        var saves = 0;
        await forms.openForm(
          tester,
          ProxyFormPage(
            initialDefinition: const {
              'type': 'http',
              'name': '',
              'server': 'controlled.fixture.test',
              'port': 443,
            },
            onSave: (_) async => saves++,
          ),
          size: const Size(350, 660),
          scaler: const TextScaler.linear(2),
        );
        addTearDown(tester.view.resetViewInsets);
        if (keyboardFirst) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
        }
        final nameInput = find.descendant(
          of: proxies.keyed('proxy-field:common/name'),
          matching: find.byType(TextField),
        );
        await tester.enterText(nameInput, 'edited');
        await tester.enterText(nameInput, '');
        await tester.pump();
        await tester.tap(proxies.keyed('proxy-save'));
        await tester.pumpAndSettle();
        if (!keyboardFirst) {
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
        }
        final field = proxies.keyed('proxy-field:common/name');
        final strings = AppLocalizations.of(tester.element(field));
        expect(
          find.descendant(
            of: field,
            matching: find.text(strings.proxyRequired),
          ),
          findsNothing,
        );
        final validation = tester.widget<DefinitionFieldValidation>(
          find.descendant(
            of: field,
            matching: find.byType(DefinitionFieldValidation),
          ),
        );
        expect(validation.hasError, isTrue);
        expect(validation.message, strings.proxyRequired);
        final viewport = tester.getRect(find.byType(SingleChildScrollView));
        final input = find.descendant(
          of: field,
          matching: find.byType(TextField),
        );
        final inputBounds = tester.getRect(input);
        expect(inputBounds.top, greaterThanOrEqualTo(viewport.top));
        expect(inputBounds.bottom, lessThanOrEqualTo(viewport.bottom));
        await forms.dismissNotice(tester);
        expect(tester.getRect(input), inputBounds);
        expect(input.hitTestable(), findsOneWidget);
        expect(saves, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('an unbuilt numeric record is exposed by its stable ID', (
    tester,
  ) async {
    var saves = 0;
    await forms.openForm(
      tester,
      ProxyFormPage(
        initialDefinition: {
          'type': 'wireguard',
          'name': 'controlled',
          'private-key': 'controlled-key',
          'reserved': List<Object>.generate(
            128,
            (index) => index == 97 ? 256 : index % 256,
          ),
        },
        onSave: (_) async => saves++,
      ),
    );
    await proxies.openGroup(tester, 'wireguard/reserved');
    final presence = forms.keyed(
      'definition-presence:wireguard/reserved',
      offstage: true,
    );
    await tester.ensureVisible(presence);
    await tester.tap(presence);
    await tester.pump();
    await tester.tap(presence);
    await tester.pump();
    const id = 'wireguard/reserved/97';
    expect(forms.keyed('definition-input:$id', offstage: true), findsNothing);
    await tester.tap(proxies.keyed('proxy-save'));
    await tester.pumpAndSettle();
    final field = forms.keyed('definition-input:$id');
    expect(saves, 0);
    expect(field.hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, '256');
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
