import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:flutter/services.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction, SemanticsNode;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/text_scalers.dart';

import 'shared/definition_forms_test.dart' as forms;

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

void main() {
  group('draft scope and failure reading', () {
    for (final language in ['en', 'zh']) {
      for (final typed in [true, false]) {
        testWidgets(
          'draft stays local and full error is copied only from technical details $language/$typed',
          (tester) async {
            const raw =
                'native failure: unknown-field\nline 2 · 原始值\n{"future":false,"zero":0}\n';
            final failure = typed
                ? ConfigFailure(
                    messages.configSavedReconnectIncomplete.withDetail(raw),
                  )
                : StateError(raw);
            final expectedDetail = typed ? raw : failure.toString();
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
            var saves = 0;
            Object? saved;
            await forms.openForm(
              tester,
              StrategyGroupFormPage(
                initialDefinition: const {
                  'name': 'kept group',
                  'type': 'select',
                  'proxies': ['DIRECT'],
                  'future': {'enabled': false, 'zero': 0},
                },
                onSave: (value) async {
                  saves++;
                  if (saves == 1) throw failure;
                  saved = value;
                },
              ),
              locale: Locale(language),
            );
            final strings = AppLocalizations.of(
              tester.element(find.byType(StrategyGroupFormPage)),
            );
            expect(
              find.byKey(const ValueKey('definition-draft-notice:group')),
              findsNothing,
            );
            expect(saves, 0);
            final input = forms.keyed('definition-input:group/name');
            final controller = tester.widget<TextField>(input).controller!;
            final before = controller.value;
            await tester.tap(
              find.byKey(const ValueKey('definition-save:group')),
            );
            await tester.pumpAndSettle();
            expect(saves, 1);
            expect(find.byType(StrategyGroupFormPage), findsOneWidget);
            expect(find.byType(SnackBar), findsOneWidget);
            expect(find.text(strings.errorDetails), findsOneWidget);
            expect(find.textContaining('unknown-field'), findsNothing);
            await tester.tap(
              find
                  .descendant(
                    of: find.byType(SnackBar),
                    matching: find.byType(TextButton),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            expect(
              find.text(
                typed
                    ? strings.configSavedReconnectIncomplete
                    : strings.proxySaveFailed,
              ),
              findsOneWidget,
            );
            expect(find.textContaining('unknown-field'), findsNothing);
            expect(copied, isNull);
            await tester.tap(
              find.byKey(const ValueKey('operation-technical-details')),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<SelectableText>(
                    find.byKey(const ValueKey('operation-technical-text')),
                  )
                  .data,
              expectedDetail,
            );
            final copy = find.byKey(const ValueKey('operation-technical-copy'));
            await tester.ensureVisible(copy);
            await tester.pumpAndSettle();
            await tester.tap(copy);
            await tester.pumpAndSettle();
            expect(copied, expectedDetail);
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byType(StrategyGroupFormPage), findsOneWidget);
            expect(
              tester.widget<TextField>(input).controller,
              same(controller),
            );
            expect(controller.value, before);
            expect(saves, 1);
            await tester.tap(
              find.byKey(const ValueKey('definition-save:group')),
            );
            await tester.pumpAndSettle();
            expect(saves, 2);
            expect(saved, const {
              'name': 'kept group',
              'type': 'select',
              'proxies': ['DIRECT'],
              'future': {'enabled': false, 'zero': 0},
            });
            expect(find.byType(StrategyGroupFormPage), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  for (final (label, fields) in <(String, Map<String, Object?>)>[
    ('missing type', {}),
    ('null type', {'type': null}),
    ('numeric type', {'type': 7}),
    ('unknown type', {'type': 'future-group'}),
    ('container name', {'type': 'select', 'name': <String>[]}),
    (
      'non-string members',
      {
        'type': 'select',
        'proxies': [false],
      },
    ),
    ('map providers', {'type': 'select', 'use': <String, Object?>{}}),
    ('non-boolean option', {'type': 'select', 'lazy': 'false'}),
    (
      'non-integer option',
      {
        'type': 'select',
        'interval': [0],
      },
    ),
    ('container text option', {'type': 'select', 'icon': <String, Object?>{}}),
  ]) {
    testWidgets(
      'unrepresentable group original is readable without rewriting: $label',
      (tester) async {
        var saves = 0;
        final original = <String, Object?>{
          'name': 'preserved-group',
          ...fields,
          'future': {'retained': false},
        };
        Map<String, Object?>? saved;
        await forms.openForm(
          tester,
          StrategyGroupFormPage(
            initialDefinition: original,
            onSave: (definition) async {
              saves++;
              saved = definition;
            },
          ),
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(StrategyGroupFormPage)),
        );
        final field = fields.keys.lastOrNull ?? 'type';
        if (field == 'type' || field == 'name') {
          expect(find.text(strings.localYamlUnsupportedEdit), findsOneWidget);
          expect(find.text(field), findsOneWidget);
          expect(forms.keyed('definition-save:group'), findsNothing);
          expect(find.byType(TextField), findsNothing);
          expect(saves, 0);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(saves, 0);
        } else {
          final originalField = forms.keyed(
            'definition-original:group/$field',
            offstage: true,
          );
          await forms.expandAncestors(tester, originalField);
          expect(originalField, findsOneWidget);
          expect(
            find.descendant(
              of: originalField,
              matching: find.byType(TextField),
            ),
            findsNothing,
          );
          expect(find.text(strings.localYamlUnsupportedField), findsOneWidget);
          expect(find.text('group/$field'), findsOneWidget);
          await forms.tap(tester, forms.keyed('definition-save:group'));
          expect(saved, original);
          expect(saves, 1);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 1704.0]) {
      for (final (label, scaler) in [
        ('1', TextScaler.noScaling),
        ('2', TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          'unsupported group remains readable $language/$width/$label',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              var saves = 0;
              await forms.openForm(
                tester,
                StrategyGroupFormPage(
                  initialDefinition: const {
                    'name': 'original',
                    'type': 'select',
                    'proxies': [false],
                    'interval': 'not-an-integer',
                  },
                  onSave: (_) async => saves++,
                ),
                size: Size(width, 1136),
                locale: Locale(language),
                scaler: scaler,
              );
              await forms.expandAncestors(
                tester,
                forms.keyed(
                  'definition-original:group/interval',
                  offstage: true,
                ),
              );
              final maximum = switch (label) {
                '1' => 1600.0,
                '2' => 3200.0,
                _ => 2720.0,
              };
              final content = forms.keyed('definition-content');
              final scrollable = find
                  .descendant(of: content, matching: find.byType(Scrollable))
                  .first;
              final position = tester
                  .state<ScrollableState>(scrollable)
                  .position;
              final name = forms.keyed('definition-input:group/name');
              final nameElement = tester.element(name);
              final nameController = tester.widget<TextField>(name).controller;
              expect(nameController, isNotNull);
              final focus = FocusManager.instance.primaryFocus;
              final identities = {
                for (final (id, chapter) in const [
                  ('group/proxies', 'members'),
                  ('group/interval', 'advanced'),
                ])
                  id: (
                    field: tester.element(
                      forms.keyed('definition-original:$id'),
                    ),
                    unset: tester.element(
                      forms.keyed('definition-unset-original:$id'),
                    ),
                    chapter: tester.element(
                      forms.keyed('definition-chapter:$chapter'),
                    ),
                  ),
              };
              for (final nextWidth in [width, 280.0, 1704.0, width]) {
                tester.view.physicalSize = Size(nextWidth, 1136);
                for (final ms in [0, 16]) {
                  await tester.pump(Duration(milliseconds: ms));
                  final bounds = tester.getRect(content);
                  expect(bounds.width, nextWidth.clamp(0, maximum));
                  expect(bounds.center.dx, closeTo(nextWidth / 2, .01));
                  expect(
                    tester.state<ScrollableState>(scrollable).position,
                    same(position),
                  );
                  expect(tester.element(name), same(nameElement));
                  expect(
                    tester.widget<TextField>(name).controller,
                    same(nameController),
                  );
                  expect(FocusManager.instance.primaryFocus, same(focus));
                  final viewport = tester.getRect(scrollable);
                  final reachableNodes = _reachableSemanticsNodes(tester);
                  expect(find.text('group/proxies'), findsOneWidget);
                  expect(find.text('group/interval'), findsOneWidget);
                  for (final (id, value) in const [
                    ('group/proxies', '[\n  false\n]'),
                    ('group/interval', '"not-an-integer"'),
                  ]) {
                    final originalField = forms.keyed(
                      'definition-original:$id',
                    );
                    expect(originalField, findsOneWidget);
                    final strings = AppLocalizations.of(
                      tester.element(originalField),
                    );
                    expect(
                      tester
                          .widgetList<SelectableText>(
                            find.descendant(
                              of: originalField,
                              matching: find.byType(SelectableText),
                            ),
                          )
                          .map((text) => text.data),
                      [id, strings.localYamlUnsupportedField, value],
                    );
                    expect(
                      find.descendant(
                        of: originalField,
                        matching: find.byType(TextField),
                      ),
                      findsNothing,
                    );
                    expect(
                      forms.keyed('definition-view-original:$id'),
                      findsNothing,
                    );
                    final identity = identities[id]!;
                    expect(tester.element(originalField), same(identity.field));
                    final chapterId = id == 'group/proxies'
                        ? 'members'
                        : 'advanced';
                    final chapter = forms.keyed(
                      'definition-chapter:$chapterId',
                    );
                    expect(tester.element(chapter), same(identity.chapter));
                    final unset = forms.keyed('definition-unset-original:$id');
                    expect(tester.element(unset), same(identity.unset));
                    final fieldBounds = tester.getRect(originalField);
                    final chapterBounds = tester.getRect(chapter);
                    final buttonBounds = tester.getRect(unset);
                    final minimum =
                        (id == 'group/proxies' ? 320.0 : 480.0) *
                        scaler.scale(14) /
                        14;
                    expect(
                      chapterBounds.width,
                      greaterThanOrEqualTo(
                        minimum.clamp(
                          0.0,
                          tester.getSize(find.byType(Form)).width,
                        ),
                      ),
                    );
                    expect(buttonBounds.width, greaterThanOrEqualTo(48));
                    expect(buttonBounds.height, greaterThanOrEqualTo(48));
                    expect(
                      chapterBounds.left,
                      greaterThanOrEqualTo(viewport.left),
                    );
                    expect(
                      chapterBounds.right,
                      lessThanOrEqualTo(viewport.right),
                    );
                    expect(
                      fieldBounds.left,
                      greaterThanOrEqualTo(chapterBounds.left),
                    );
                    expect(
                      fieldBounds.right,
                      lessThanOrEqualTo(chapterBounds.right),
                    );
                    expect(
                      buttonBounds.left,
                      greaterThanOrEqualTo(fieldBounds.left),
                    );
                    expect(
                      buttonBounds.right,
                      lessThanOrEqualTo(fieldBounds.right),
                    );
                    expect(
                      buttonBounds.top,
                      greaterThanOrEqualTo(fieldBounds.top),
                    );
                    expect(
                      buttonBounds.bottom,
                      lessThanOrEqualTo(fieldBounds.bottom),
                    );
                    final render = tester.renderObject<RenderBox>(unset);
                    final paintBounds = MatrixUtils.transformRect(
                      render.getTransformTo(null),
                      render.paintBounds,
                    );
                    expect(paintBounds, rectMoreOrLessEquals(buttonBounds));
                    final visibleBounds = paintBounds.intersect(viewport);
                    if (!visibleBounds.isEmpty) {
                      final point = visibleBounds.center;
                      expect(
                        tester
                            .hitTestOnBinding(point)
                            .path
                            .any((entry) => identical(entry.target, render)),
                        isTrue,
                        reason: '$id/$nextWidth/$ms',
                      );
                      final node = tester.getSemantics(unset);
                      expect(reachableNodes, contains(node));
                      final data = node.getSemanticsData();
                      expect(data.flagsCollection.isButton, isTrue);
                      expect(data.hasAction(SemanticsAction.tap), isTrue);
                      expect(data.label, strings.definitionFormUnsetField);
                      expect(
                        _globalSemanticsRect(node).intersect(viewport),
                        rectMoreOrLessEquals(visibleBounds),
                      );
                    }
                  }
                  expect(find.byType(SelectableText), findsNWidgets(6));
                  expect(forms.keyed('definition-save:group'), findsOneWidget);
                  expect(saves, 0);
                  expect(tester.takeException(), isNull);
                }
              }
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }

  for (final type in ['select', 'url-test', 'fallback', 'load-balance']) {
    testWidgets(
      'group shape admission keeps unknown fields and literal values $type',
      (tester) async {
        Map<String, Object?>? saved;
        final original = <String, Object?>{
          'name': 'original-group',
          'type': type,
          if (type != 'select') 'default-selected': 7,
          if (type != 'url-test') 'tolerance': <String>[],
          if (type != 'load-balance') ...{
            'strategy': false,
            'hash-key': <String, Object?>{},
          },
          'proxies': <String>[],
          'use': null,
          'lazy': false,
          'interval': 0,
          'icon': '',
          'future': {
            'retained': [false, 0, '', null],
          },
        };
        await forms.openForm(
          tester,
          StrategyGroupFormPage(
            initialDefinition: original,
            onSave: (definition) async => saved = definition,
          ),
        );
        await forms.tap(tester, forms.keyed('definition-save:group'));
        expect(saved, original);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
