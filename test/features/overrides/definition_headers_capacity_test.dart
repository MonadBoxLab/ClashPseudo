import 'package:clash_pseudo/src/features/overrides/definition_form_body.dart';
import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';

import 'package:clash_pseudo/src/features/overrides/provider_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import 'definition_forms_test.dart' as forms;

const _id = 'controlled/headers';

Future<void> _open(
  WidgetTester tester,
  Map<String, List<String>>? initial,
  ValueChanged<Map<String, List<String>>?> onSave, {
  String language = 'en',
  double width = 440,
  TextScaler scaler = TextScaler.noScaling,
}) async {
  final form = GlobalKey<FormState>();
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await forms.openForm(
    tester,
    Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DefinitionFormBody(
                  form: form,
                  controller: scroll,
                  chapters: [
                    DefinitionFormChapter(
                      id: 'headers',
                      title: 'Headers',
                      children: [
                        Builder(
                          builder: (context) => DefinitionHeadersField(
                            id: _id,
                            label: AppLocalizations.of(context)
                                .providerFormHeaders,
                            initialValue: initial,
                            onSaved: onSave,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SafeArea(
                child: FilledButton(
                  key: const ValueKey('headers-save'),
                  onPressed: () {
                    if (DefinitionFormBody.validate(form)) {
                      form.currentState!.save();
                    }
                  },
                  child: const Text('Save parent'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    locale: Locale(language),
    scaler: scaler,
    size: Size(width, 1136),
  );
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: forms.keyed('definition-header-list:$_id'),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

Future<void> _discard(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  final strings = AppLocalizations.of(tester.element(dialog));
  await forms.tap(tester, find.text(strings.discard));
}

void main() {
  testWidgets(
    'header collection does not eagerly construct every nested input',
    (tester) async {
      await _open(tester, {
        for (var i = 0; i < 128; i++) 'X-Control-$i': ['value-$i'],
      }, (_) {});
      expect(
        find.byType(TextField, skipOffstage: false).evaluate().length,
        lessThan(60),
      );
      final rows = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'definition-header:$_id/',
            ),
      );
      expect(rows.evaluate().length, lessThan(60));
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'zh']) {
    for (final width in [320.0, 1704.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '4096 headers edit, cancel, stale removal and save $language/$width/$scale',
          (tester) async {
            final names = [
              for (var i = 0; i < 4096; i++)
                i == 4095 ? 'X-末项-é-🧭-${'long-' * 80}' : 'X-Control-$i',
            ];
            final original = <String, List<String>>{
              for (final (i, name) in names.indexed)
                name: i.isEven ? ['value-$i', '', 'unchanged-$i'] : [],
            };
            Map<String, List<String>>? actual;
            final built = <String>{};
            final previous = debugOnRebuildDirtyWidget;
            debugOnRebuildDirtyWidget = (element, builtOnce) {
              previous?.call(element, builtOnce);
              final key = element.widget.key;
              if (key is ValueKey<String> &&
                  key.value.startsWith('definition-header:$_id/')) {
                built.add(key.value);
              }
            };
            addTearDown(() => debugOnRebuildDirtyWidget = previous);
            await _open(
              tester,
              original,
              (value) => actual = value,
              language: language,
              width: width,
              scaler: TextScaler.linear(scale),
            );
            final removeFirst = tester
                .widget<IconButton>(forms.keyed('definition-remove:$_id/0'))
                .onPressed!;
            final position = _position(tester);
            position.jumpTo(position.maxScrollExtent);
            await tester.pumpAndSettle();
            await forms.tap(tester, forms.keyed('definition-edit:$_id/4095'));
            final keyInput = forms.keyed('definition-input:$_id/4095/key');
            expect(
              tester.widget<TextField>(keyInput).controller!.text,
              names.last,
            );
            await forms.text(tester, '$_id/4095/key', 'X-Renamed-Last');
            await forms.tap(
              tester,
              forms.keyed('definition-add:$_id/4095/values'),
            );
            await forms.text(tester, '$_id/4095/values/0', 'last-value');
            await forms.tap(
              tester,
              forms.keyed('definition-save-header:$_id/4095'),
            );
            expect(_position(tester), same(position));
            await forms.tap(tester, forms.keyed('definition-edit:$_id/4095'));
            expect(
              tester.widget<TextField>(keyInput).controller!.text,
              'X-Renamed-Last',
            );
            expect(
              tester
                  .widget<TextField>(
                    forms.keyed('definition-input:$_id/4095/values/0'),
                  )
                  .controller!
                  .text,
              'last-value',
            );
            await forms.text(tester, '$_id/4095/key', 'X-Cancelled');
            await _discard(tester);
            removeFirst();
            removeFirst();
            await tester.pumpAndSettle();
            position.jumpTo(0);
            await tester.pumpAndSettle();
            expect(forms.keyed('definition-edit:$_id/4095'), findsNothing);
            await forms.tap(tester, forms.keyed('headers-save'));
            expect(actual!.keys.toList(), [
              ...names.skip(1).take(4094),
              'X-Renamed-Last',
            ]);
            expect(actual, {
              for (final name in names.skip(1).take(4094))
                name: original[name]!,
              'X-Renamed-Last': ['last-value'],
            });
            expect(built.length, lessThan(100));
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'header parent rejects an unbuilt empty key and repairs without losing values',
    (tester) async {
      var saves = 0;
      Map<String, List<String>>? actual;
      final original = <String, List<String>>{
        for (var i = 0; i < 4096; i++)
          i == 2048 ? '' : 'X-Control-$i': ['value-$i'],
      };
      await _open(tester, original, (value) {
        saves++;
        actual = value;
      });
      expect(forms.keyed('definition-edit:$_id/2048'), findsNothing);
      if (const bool.fromEnvironment('validationDisableHeaderParent')) {
        final element = find
            .byWidgetPredicate(
              (widget) => widget is FormField<Map<String, List<String>>>,
            )
            .evaluate()
            .single;
        final original = element.widget as FormField<Map<String, List<String>>>;
        element.owner!.buildScope(
          element,
          () => element.update(
            FormField<Map<String, List<String>>>(
              key: original.key,
              initialValue: original.initialValue,
              onSaved: original.onSaved,
              builder: original.builder,
            ),
          ),
        );
      }
      final saveRect = tester.getRect(forms.keyed('headers-save'));
      await forms.tap(tester, forms.keyed('headers-save'));
      expect(saves, 0);
      expect(actual, isNull);
      expect(tester.getRect(forms.keyed('headers-save')), saveRect);
      expect(
        forms.keyed('definition-edit:$_id/2048').hitTestable(),
        findsOneWidget,
      );
      await forms.tap(tester, forms.keyed('definition-edit:$_id/2048'));
      await forms.text(tester, '$_id/2048/key', 'X-Repaired');
      expect(
        tester
            .widget<TextField>(
              forms.keyed('definition-input:$_id/2048/values/0'),
            )
            .controller!
            .text,
        'value-2048',
      );
      await forms.tap(tester, forms.keyed('definition-save-header:$_id/2048'));
      await forms.tap(tester, forms.keyed('headers-save'));
      expect(saves, 1);
      expect(actual, {
        for (final entry in original.entries)
          entry.key.isEmpty ? 'X-Repaired' : entry.key: entry.value,
      });
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'zh']) {
    testWidgets(
      'new header cancellation keeps absence and editing preserves empty lists $language',
      (tester) async {
        var saves = 0;
        Map<String, List<String>>? actual;
        await _open(tester, null, (value) {
          saves++;
          actual = value;
        }, language: language);
        await forms.tap(tester, forms.keyed('definition-add:$_id'));
        await forms.text(tester, '$_id/0/key', 'X-Cancelled-New');
        await _discard(tester);
        expect(
          tester.widget<Switch>(forms.keyed('definition-presence:$_id')).value,
          isFalse,
        );
        await forms.tap(tester, forms.keyed('headers-save'));
        expect(saves, 1);
        expect(actual, isNull);
        await forms.tap(tester, forms.keyed('definition-add:$_id'));
        await forms.text(tester, '$_id/0/key', 'X-Empty');
        await forms.tap(tester, forms.keyed('definition-save-header:$_id/0'));
        await forms.tap(tester, forms.keyed('headers-save'));
        expect(actual, {'X-Empty': <String>[]});
        await forms.tap(tester, forms.keyed('definition-presence:$_id'));
        await forms.tap(tester, forms.keyed('headers-save'));
        expect(actual, isNull);
        await forms.tap(tester, forms.keyed('definition-presence:$_id'));
        await forms.tap(tester, forms.keyed('definition-edit:$_id/0'));
        expect(
          tester
              .widget<TextField>(forms.keyed('definition-input:$_id/0/key'))
              .controller!
              .text,
          'X-Empty',
        );
        await forms.tap(tester, forms.keyed('definition-save-header:$_id/0'));
        await forms.tap(tester, forms.keyed('headers-save'));
        expect(actual, {'X-Empty': <String>[]});
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 1704.0]) {
      for (final (scaleName, scaler) in [
        ('1', TextScaler.noScaling),
        ('2', TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          'header item validation, keyboard and route geometry $language/$width/$scaleName',
          (tester) async {
            Map<String, List<String>>? actual;
            await _open(
              tester,
              {
                'X-First': ['first'],
                'X-Second': [],
              },
              (value) => actual = value,
              language: language,
              width: width,
              scaler: scaler,
            );
            final position = _position(tester);
            final before = tester.getRect(
              forms.keyed('definition-header:$_id/0'),
            );
            final remove = tester
                .widget<IconButton>(forms.keyed('definition-remove:$_id/0'))
                .onPressed!;
            final open = tester
                .widget<IconButton>(forms.keyed('definition-edit:$_id/0'))
                .onPressed!;
            open();
            open();
            await tester.pumpAndSettle();
            expect(
              find.byKey(
                const ValueKey('definition-save-header:$_id/0'),
                skipOffstage: false,
              ),
              findsOneWidget,
            );
            remove();
            await tester.pump();
            final title = find
                .descendant(
                  of: find.byType(AppBar),
                  matching: find.byType(Text),
                )
                .first;
            expect(
              MediaQuery.textScalerOf(tester.element(title)).scale(22),
              scaler.scale(22),
            );
            expect(
              tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
              isFalse,
            );
            final name = forms.keyed('definition-input:$_id/0/key');
            final value = forms.keyed('definition-input:$_id/0/values/0');
            final save = forms.keyed('definition-save-header:$_id/0');
            await forms.text(tester, '$_id/0/key', 'X-Second');
            await tester.pumpAndSettle();
            final strings = AppLocalizations.of(tester.element(name));
            final nameRect = tester.getRect(name);
            final valueRect = tester.getRect(value);
            final saveRect = tester.getRect(save);
            await tester.tap(save);
            for (final ms in [0, 16, 80]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(name), nameRect);
              expect(tester.getRect(value), valueRect);
              expect(tester.getRect(save), saveRect);
              expect(tester.takeException(), isNull);
            }
            expect(find.text(strings.proxyDuplicateKey), findsOneWidget);
            tester.view.viewInsets = const FakeViewPadding(bottom: 360);
            addTearDown(tester.view.resetViewInsets);
            await tester.pumpAndSettle();
            await forms.text(tester, '$_id/0/key', ' ');
            await tester.pumpAndSettle();
            final keyboardSave = tester.getRect(save);
            final keyboardName = tester.getRect(name);
            await tester.tap(save);
            for (final ms in [0, 16, 80]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(save), keyboardSave);
              expect(tester.getRect(name), keyboardName);
              expect(tester.takeException(), isNull);
            }
            expect(find.text(strings.proxyRequired), findsOneWidget);
            expect(keyboardSave.bottom, lessThanOrEqualTo(1136 - 360));
            tester.view.resetViewInsets();
            await tester.pumpAndSettle();
            await forms.text(tester, '$_id/0/key', 'X-改名-é-🧭');
            await forms.tap(tester, save);
            expect(_position(tester), same(position));
            expect(position.pixels, 0);
            expect(
              tester.getRect(forms.keyed('definition-header:$_id/0')),
              before,
            );
            await forms.tap(tester, forms.keyed('headers-save'));
            expect(actual, {
              'X-改名-é-🧭': ['first'],
              'X-Second': <String>[],
            });
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets(
      'header prototype and untriggered errors stay out of semantics $language',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _open(
            tester,
            {
              for (var i = 0; i < 128; i++) 'X-Control-$i': ['value-$i'],
            },
            (_) {},
            language: language,
          );
          var root = tester.getSemantics(forms.keyed('headers-save'));
          while (root.parent != null) {
            root = root.parent!;
          }
          final labels = <String>[];
          void collect(SemanticsNode node) {
            labels.add(node.getSemanticsData().label);
            node.visitChildren((child) {
              collect(child);
              return true;
            });
          }

          collect(root);
          expect(labels.any((label) => label.contains('X-Control-0')), isTrue);
          expect(
            labels.any((label) => label.contains('X-Control-127')),
            isFalse,
          );
          final strings = AppLocalizations.of(
            tester.element(forms.keyed('headers-save')),
          );
          expect(
            labels.any((label) => label.contains(strings.proxyRequired)),
            isFalse,
          );
          expect(
            labels.any((label) => label.contains(strings.proxyDuplicateKey)),
            isFalse,
          );
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets('covered header edit callback cannot open a second route', (
    tester,
  ) async {
    Map<String, List<String>>? actual;
    await _open(tester, {
      'X-Controlled': ['value'],
    }, (value) => actual = value);
    final edit = tester
        .widget<IconButton>(forms.keyed('definition-edit:$_id/0'))
        .onPressed!;
    final navigator = Navigator.of(tester.element(forms.keyed('headers-save')));
    final covered = navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(body: Text('controlled cover')),
      ),
    );
    await tester.pumpAndSettle();
    edit();
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('definition-save-header:$_id/0'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(find.text('controlled cover'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await covered;
    await tester.pumpAndSettle();
    await forms.tap(tester, forms.keyed('headers-save'));
    expect(actual, {
      'X-Controlled': ['value'],
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'header child save cannot close a cover, double-pop, or replay after disposal',
    (tester) async {
      Map<String, List<String>>? actual;
      await _open(tester, {
        'X-Controlled': ['value'],
      }, (value) => actual = value);
      await forms.tap(tester, forms.keyed('definition-edit:$_id/0'));
      final childSave = forms.keyed('definition-save-header:$_id/0');
      final save = tester.widget<FilledButton>(childSave).onPressed!;
      final navigator = Navigator.of(tester.element(childSave));
      final cover = navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('controlled child cover')),
        ),
      );
      await tester.pumpAndSettle();
      save();
      await tester.pumpAndSettle();
      expect(find.text('controlled child cover'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await cover;
      await tester.pumpAndSettle();
      expect(childSave, findsOneWidget);
      save();
      save();
      await tester.pumpAndSettle();
      save();
      await tester.pump();
      expect(forms.keyed('headers-save'), findsOneWidget);
      await forms.tap(tester, forms.keyed('headers-save'));
      expect(actual, {
        'X-Controlled': ['value'],
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'covered provider save callback cannot publish while the header editor owns the route',
    (tester) async {
      var saves = 0;
      await forms.openForm(
        tester,
        ProviderFormPage(
          ruleProvider: false,
          initialName: 'controlled',
          initialDefinition: const {
            'type': 'http',
            'url': 'https://fixture.invalid/provider',
            'header': {
              'X-Controlled': ['value'],
            },
          },
          onSave: (_, _) async {
            saves++;
          },
        ),
      );
      final save = tester
          .widget<FilledButton>(forms.keyed('definition-save:provider'))
          .onPressed!;
      await forms.tap(tester, forms.keyed('definition-edit:provider/header/0'));
      save();
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(
        forms.keyed('definition-save-header:provider/header/0'),
        findsOneWidget,
      );
      expect(
        find.byType(ProviderFormPage, skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
