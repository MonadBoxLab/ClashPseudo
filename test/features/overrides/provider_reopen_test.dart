import 'package:clash_pseudo/src/features/overrides/provider_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/text_scalers.dart';

import 'definition_forms_test.dart' as forms;

void main() {
  for (final transport in forms.fixtures['transports'] as List) {
    for (final variant in forms.fixtures['ruleProviders'] as List) {
      final original = <String, Object?>{
        ...Map<String, Object?>.from(transport as Map),
        for (final entry in (variant as Map).entries)
          if (entry.key != 'id') entry.key as String: entry.value,
        'unknown-future': {
          'nested': [false, 0, '', null, 1.5],
        },
      };
      testWidgets('rule provider reopens every valid transport/behavior/format '
          '${original['type']}/${variant['id']}', (tester) async {
        var current = original;
        var name = 'original-provider';
        final changedFormat = original['format'] == 'yaml' ? 'text' : 'yaml';
        for (final round in [0, 1, 2]) {
          Map<String, Object?>? saved;
          String? savedName;
          await forms.openForm(
            tester,
            ProviderFormPage(
              ruleProvider: true,
              initialName: name,
              initialDefinition: current,
              onSave: (value, definition) async {
                savedName = value;
                saved = definition;
              },
            ),
          );
          if (round == 1) {
            await forms.text(tester, 'provider/name', 'renamed-provider');
            await forms.choose(tester, 'provider/format', changedFormat);
          }
          await forms.tap(tester, forms.keyed('definition-save:provider'));
          expect(tester.takeException(), isNull);
          expect(find.byType(ProviderFormPage), findsNothing);
          expect(
            savedName,
            round == 0 ? 'original-provider' : 'renamed-provider',
          );
          expect(saved, {...original, if (round > 0) 'format': changedFormat});
          current = saved!;
          name = savedName!;
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('embedded empty provider payload does not add window padding', (
    tester,
  ) async {
    await forms.openForm(
      tester,
      MediaQuery(
        data: const MediaQueryData(
          size: Size(440, 900),
          padding: EdgeInsets.only(top: 36, bottom: 24),
          viewPadding: EdgeInsets.only(top: 36, bottom: 24),
        ),
        child: ProviderFormPage(
          ruleProvider: false,
          initialName: 'empty-inline',
          initialDefinition: const {'type': 'inline', 'payload': <Object?>[]},
          onSave: (_, _) async {},
        ),
      ),
    );
    expect(tester.getSize(forms.keyed('provider-payload-list')).height, 0);
    expect(tester.takeException(), isNull);
  });

  for (final ruleProvider in [false, true]) {
    testWidgets(
      'reopened provider headers remain visible and editable $ruleProvider',
      (tester) async {
        Map<String, Object?>? saved;
        final original = <String, Object?>{
          'type': 'http',
          'url': 'https://example.test/provider',
          if (ruleProvider) 'behavior': 'domain',
          'header': {
            'X-One': ['first', 'second'],
            'X-Empty': <String>[],
          },
          'unknown': {'retained': false},
        };
        await forms.openForm(
          tester,
          ProviderFormPage(
            ruleProvider: ruleProvider,
            initialName: 'provider',
            initialDefinition: original,
            onSave: (_, definition) async => saved = definition,
          ),
        );
        await forms.tap(
          tester,
          forms.keyed('definition-edit:provider/header/0'),
        );
        for (final (index, value) in ['first', 'second'].indexed) {
          final input = forms.keyed(
            'definition-input:provider/header/0/values/$index',
          );
          expect(input, findsOneWidget);
          expect(tester.widget<TextField>(input).controller!.text, value);
        }
        await forms.text(
          tester,
          'provider/header/0/values/1',
          'changed-second',
        );
        await forms.tap(
          tester,
          forms.keyed('definition-add:provider/header/0/values'),
        );
        await forms.text(tester, 'provider/header/0/values/2', 'third');
        await forms.tap(
          tester,
          forms.keyed('definition-save-header:provider/header/0'),
        );
        await forms.tap(
          tester,
          forms.keyed('definition-edit:provider/header/1'),
        );
        await forms.text(tester, 'provider/header/1/key', 'X-Renamed-Empty');
        await forms.tap(
          tester,
          forms.keyed('definition-save-header:provider/header/1'),
        );
        await forms.tap(tester, forms.keyed('definition-save:provider'));
        expect(saved, {
          ...original,
          'header': {
            'X-One': ['first', 'changed-second', 'third'],
            'X-Renamed-Empty': <String>[],
          },
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final type in ['http', 'file', 'inline']) {
      testWidgets('provider reopens all original fields $ruleProvider $type', (
        tester,
      ) async {
        final transport = (forms.fixtures['transports'] as List)
            .cast<Map>()
            .singleWhere((row) => row['type'] == type);
        final original = <String, Object?>{
          ...Map<String, Object?>.from(transport),
          if (ruleProvider)
            ...Map<String, Object?>.from(
              (forms.fixtures['ruleProviders'] as List).cast<Map>().firstWhere(
                (row) => row['behavior'] == 'domain',
              ),
            )
          else
            ...Map<String, Object?>.from(
              forms.fixtures['proxyProviderCommon'] as Map,
            ),
        }..remove('id');
        // Use the same fixed public-field cases as the creation contract.
        original['type'] = type;
        if (type == 'http') original['url'] = 'https://example.test/provider';
        if (type == 'file') original['path'] = 'providers/original.yaml';
        if (ruleProvider) {
          original.addAll({
            'behavior': 'domain',
            'format': 'text',
            'payload': ['example.test', '+.example.org'],
          });
        } else {
          original.addAll({
            'health-check': {
              'enable': false,
              'url': '',
              'interval': 0,
              'timeout': 5000,
              'lazy': false,
              'expected-status': '204',
              'unknown': {'retained': true},
            },
            'override': {
              'udp': false,
              'routing-mark': 0,
              'additional-prefix': '',
              'proxy-name': [
                {'pattern': 'old', 'target': 'new', 'unknown': 7},
              ],
              'override-expr': ['udp = true'],
              'unknown': {'retained': ''},
            },
            'payload': <Object?>[],
          });
        }
        if (type == 'http') {
          original['header'] = {
            'X-One': ['first', 'second'],
            'X-Empty': <String>[],
          };
        }
        original['unknown'] = {
          'future': [false, 0, '', null, 1.5],
        };
        var current = original;
        var name = 'original-provider';
        for (final round in [0, 1, 2]) {
          Map<String, Object?>? saved;
          String? savedName;
          await forms.openForm(
            tester,
            ProviderFormPage(
              ruleProvider: ruleProvider,
              initialName: name,
              initialDefinition: current,
              onSave: (name, value) async {
                savedName = name;
                saved = value;
              },
            ),
          );
          if (round == 1) {
            await forms.text(tester, 'provider/name', 'renamed-provider');
            if (ruleProvider) {
              await forms.choose(tester, 'provider/format', 'yaml');
            } else {
              await forms.text(tester, 'provider/health-check/timeout', '6000');
            }
          }
          await forms.tap(tester, forms.keyed('definition-save:provider'));
          expect(tester.takeException(), isNull);
          expect(find.byType(ProviderFormPage), findsNothing);
          final expected = Map<String, Object?>.from(current);
          if (round == 1) {
            if (ruleProvider) {
              expected['format'] = 'yaml';
            } else {
              expected['health-check'] = {
                ...Map<String, Object?>.from(current['health-check'] as Map),
                'timeout': 6000,
              };
            }
          }
          expect(
            savedName,
            round == 0 ? 'original-provider' : 'renamed-provider',
          );
          expect(saved, expected);
          current = saved!;
          name = savedName!;
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final (ruleProvider, original) in <(bool, Map<String, Object?>)>[
    (
      false,
      {
        'type': 'inline',
        'payload': [false],
      },
    ),
    (
      false,
      {
        'type': 'inline',
        'payload': [
          {'name': 7, 'type': 'http'},
        ],
      },
    ),
    (
      false,
      {
        'type': 'inline',
        'payload': [
          {'name': 'node', 'type': null},
        ],
      },
    ),
    (
      true,
      {
        'type': 'inline',
        'payload': [17],
      },
    ),
    (true, {'type': 'inline', 'behavior': 17}),
    (
      false,
      {
        'type': 'http',
        'header': {'X-Header': 'not-a-list'},
      },
    ),
    (false, {'type': 'inline', 'health-check': false}),
    (false, {'type': 'inline', 'override': 0}),
  ]) {
    testWidgets(
      'unrepresentable provider containers keep original data $ruleProvider/$original',
      (tester) async {
        var saves = 0;
        Map<String, Object?>? saved;
        final expected = <String, Object?>{
          if (original['type'] == 'http')
            'url': 'https://fixture.invalid/provider',
          if (ruleProvider) 'behavior': 'domain',
          ...original,
        };
        await forms.openForm(
          tester,
          ProviderFormPage(
            ruleProvider: ruleProvider,
            initialName: 'preserved-provider',
            initialDefinition: expected,
            onSave: (_, definition) async {
              saves++;
              saved = definition;
            },
          ),
        );
        final field = original.keys.where((key) => key != 'type').single;
        final originalField = forms.keyed(
          'definition-original:provider/$field',
          offstage: true,
        );
        await forms.expandAncestors(tester, originalField);
        expect(originalField, findsOneWidget);
        expect(forms.keyed('definition-save:provider'), findsOneWidget);
        await forms.text(tester, 'provider/name', 'renamed-provider');
        await forms.tap(tester, forms.keyed('definition-save:provider'));
        expect(saved, expected);
        expect(saves, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (ruleProvider, type, field, value)
      in <(bool, String, String, Object?)>[
        (false, 'inline', 'filter', <String>[]),
        (false, 'inline', 'exclude-filter', false),
        (false, 'inline', 'exclude-type', 0),
        (false, 'inline', 'dialer-proxy', <String, Object?>{}),
        (false, 'inline', 'age-secret-key', false),
        (true, 'inline', 'format', <String>[]),
        (true, 'http', 'url', false),
        (false, 'http', 'proxy', 0),
        (false, 'http', 'size-limit', '12'),
        (true, 'file', 'path', <String>[]),
        (true, 'file', 'interval', false),
        (true, 'file', 'path-in-bundle', <String, Object?>{}),
        (false, 'inline', 'health-check/enable', 'false'),
        (false, 'inline', 'health-check/url', <String>[]),
        (false, 'inline', 'health-check/interval', false),
        (false, 'inline', 'health-check/timeout', '5000'),
        (false, 'inline', 'health-check/lazy', 0),
        (false, 'inline', 'health-check/expected-status', 204),
        (false, 'inline', 'override/udp', 'false'),
        (false, 'inline', 'override/up', 100),
        (false, 'inline', 'override/routing-mark', false),
        (false, 'inline', 'override/override-expr', <String, Object?>{}),
        (false, 'inline', 'override/proxy-name', false),
        (false, 'inline', 'override/proxy-name', [false]),
        (
          false,
          'inline',
          'override/proxy-name',
          [
            {'pattern': 0, 'target': ''},
          ],
        ),
        (
          false,
          'inline',
          'override/proxy-name',
          [
            {'pattern': 'old', 'target': false},
          ],
        ),
      ]) {
    testWidgets(
      'provider identifies unrepresentable field $ruleProvider/$field/$value',
      (tester) async {
        var saves = 0;
        Map<String, Object?>? saved;
        final parts = field.split('/');
        final original = <String, Object?>{
          'type': type,
          if (type == 'http') 'url': 'https://fixture.invalid/provider',
          if (type == 'file') 'path': 'providers/controlled.yaml',
          if (ruleProvider) 'behavior': 'domain',
          if (parts.length == 1)
            field: value
          else
            parts.first: {parts.last: value},
          'unknown': {'retained': false},
        };
        await forms.openForm(
          tester,
          ProviderFormPage(
            ruleProvider: ruleProvider,
            initialName: 'preserved-provider',
            initialDefinition: original,
            onSave: (_, definition) async {
              saves++;
              saved = definition;
            },
          ),
        );
        final originalField = forms.keyed(
          'definition-original:provider/$field',
          offstage: true,
        );
        await forms.expandAncestors(tester, originalField);
        expect(originalField, findsOneWidget);
        expect(find.text('provider/$field'), findsOneWidget);
        expect(forms.keyed('definition-save:provider'), findsOneWidget);
        await forms.text(tester, 'provider/name', 'renamed-provider');
        await forms.tap(tester, forms.keyed('definition-save:provider'));
        expect(saved, original);
        expect(saves, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final ruleProvider in [false, true]) {
    for (final type in ['file', 'inline']) {
      testWidgets(
        'provider preserves unknown and inactive shapes $ruleProvider/$type',
        (tester) async {
          Map<String, Object?>? saved;
          final original = <String, Object?>{
            'type': type,
            if (type == 'file') 'path': 'providers/preserved.yaml',
            'url': false,
            'proxy': <String>[],
            'size-limit': 'not-active',
            'header': false,
            if (type == 'inline') ...{
              'path': false,
              'interval': <String>[],
              'path-in-bundle': <String, Object?>{},
            },
            if (ruleProvider) ...{
              'behavior': 'domain',
              'format': null,
              'health-check': false,
              'override': <String>[],
            } else ...{
              'filter': '',
              'health-check': {
                'enable': false,
                'interval': 0,
                'url': null,
                'future': <String>[],
              },
              'override': {
                'udp': false,
                'additional-prefix': '',
                'override-expr': <String>[],
                'future': null,
              },
            },
            'payload': <Object?>[],
            'future': [
              false,
              0,
              '',
              null,
              {'retained': true},
            ],
          };
          await forms.openForm(
            tester,
            ProviderFormPage(
              ruleProvider: ruleProvider,
              initialName: 'preserved-provider',
              initialDefinition: original,
              onSave: (_, definition) async => saved = definition,
            ),
          );
          await forms.tap(tester, forms.keyed('definition-save:provider'));
          expect(saved, original);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final ruleProvider in [false, true]) {
    for (final (label, definition) in <(String, Map<String, Object?>)>[
      ('missing', {}),
      ('null', {'type': null}),
      ('numeric', {'type': 7}),
      ('unknown', {'type': 'future-provider'}),
    ]) {
      testWidgets(
        'unsupported provider type is readable $ruleProvider/$label',
        (tester) async {
          var saves = 0;
          await forms.openForm(
            tester,
            ProviderFormPage(
              ruleProvider: ruleProvider,
              initialName: 'preserved-provider',
              initialDefinition: definition,
              onSave: (_, _) async => saves++,
            ),
          );
          final strings = AppLocalizations.of(
            tester.element(find.byType(ProviderFormPage)),
          );
          expect(find.text(strings.localYamlUnsupportedEdit), findsOneWidget);
          expect(find.text('type'), findsOneWidget);
          expect(forms.keyed('definition-save:provider'), findsNothing);
          expect(saves, 0);
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
            'unsupported provider keeps layout $ruleProvider/$language/$width/$label',
            (tester) async {
              var saves = 0;
              await forms.openForm(
                tester,
                ProviderFormPage(
                  ruleProvider: ruleProvider,
                  initialName: 'preserved-provider',
                  initialDefinition: const {
                    'type': 'http',
                    'url': false,
                    'interval': 'invalid',
                  },
                  notice: const Text('source context remains visible'),
                  onSave: (_, _) async => saves++,
                ),
                size: Size(width, 1136),
                locale: Locale(language),
                scaler: scaler,
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
                  expect(find.text('provider/url'), findsOneWidget);
                  expect(find.text('provider/interval'), findsOneWidget);
                  expect(
                    find.text('source context remains visible'),
                    findsOneWidget,
                  );
                  expect(find.byType(SelectableText), findsNWidgets(4));
                  expect(
                    forms.keyed('definition-save:provider'),
                    findsOneWidget,
                  );
                  expect(saves, 0);
                  expect(tester.takeException(), isNull);
                }
              }
            },
          );
        }
      }
    }
  }

  for (final language in ['en', 'zh']) {
    for (final width in [320.0, 1704.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'inline provider 4096 rows stay lazy and save unbuilt edits $language/$width/$scale',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              Map<String, Object?>? saved;
              final builtRows = <String>{};
              final previousBuild = debugOnRebuildDirtyWidget;
              debugOnRebuildDirtyWidget = (element, builtOnce) {
                previousBuild?.call(element, builtOnce);
                final key = element.widget.key;
                if (element.widget is TextButton &&
                    key is ValueKey<String> &&
                    key.value.startsWith('provider-edit-proxy:')) {
                  builtRows.add(key.value);
                }
              };
              addTearDown(() => debugOnRebuildDirtyWidget = previousBuild);
              final payload = List.generate(
                4096,
                (index) => <String, Object?>{
                  'name': index.isEven
                      ? 'node-$index · 测试 é 🚀 — ${'long readable name ' * 8}'
                      : 'node-$index',
                  'type': 'http',
                  'server': '127.0.0.1',
                  'port': 1080,
                  'unknown': {'retained': false},
                },
              );
              await forms.openForm(
                tester,
                ProviderFormPage(
                  ruleProvider: false,
                  initialName: 'inline-provider',
                  initialDefinition: {'type': 'inline', 'payload': payload},
                  onSave: (_, definition) async => saved = definition,
                ),
                size: Size(width, 1136),
                scaler: TextScaler.linear(scale),
                locale: Locale(language),
              );
              final rowButtons = find.byWidgetPredicate((widget) {
                final key = widget.key;
                return widget is TextButton &&
                    key is ValueKey<String> &&
                    key.value.startsWith('provider-edit-proxy:');
              });
              expect(rowButtons.evaluate().length, lessThan(100));
              expect(forms.keyed('provider-edit-proxy:4095'), findsNothing);
              final list = forms.keyed('provider-payload-list');
              await tester.ensureVisible(list);
              await tester.pumpAndSettle();
              expect(
                find.byTooltip(payload.first['name'] as String),
                findsOneWidget,
              );
              expect(
                find.bySemanticsLabel(RegExp('node-0')),
                findsAtLeastNWidgets(1),
              );
              expect(find.bySemanticsLabel(RegExp('node-4095')), findsNothing);
              final scrollable = find.descendant(
                of: list,
                matching: find.byType(Scrollable),
              );
              final position = tester
                  .state<ScrollableState>(scrollable)
                  .position;
              position.jumpTo(position.maxScrollExtent);
              await tester.pumpAndSettle();
              await tester.scrollUntilVisible(
                forms.keyed('provider-edit-proxy:4095'),
                400,
                scrollable: scrollable,
              );
              expect(
                find.bySemanticsLabel('#4096\nnode-4095\nhttp'),
                findsOneWidget,
              );
              await forms.tap(tester, forms.keyed('provider-edit-proxy:4095'));
              await forms.proxyText(tester, 'common/server', '127.0.0.2');
              await forms.tap(tester, forms.keyed('proxy-save'));
              expect(
                tester.state<ScrollableState>(scrollable).position,
                same(position),
              );
              await forms.tap(
                tester,
                forms.keyed('definition-remove:provider/payload/4094'),
              );
              position.jumpTo(0);
              await tester.pumpAndSettle();
              expect(forms.keyed('provider-edit-proxy:4095'), findsNothing);
              expect(rowButtons.evaluate().length, lessThan(100));
              expect(builtRows, contains('provider-edit-proxy:4095'));
              expect(
                builtRows.length,
                lessThan(100),
                reason: 'Far jumps must not build all intermediate rows',
              );
              await forms.tap(tester, forms.keyed('definition-save:provider'));
              final expected = [...payload]..removeAt(4094);
              expected[expected.length - 1] = {
                ...expected.last,
                'server': '127.0.0.2',
              };
              expect(saved, {'type': 'inline', 'payload': expected});
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }

  testWidgets(
    'reopened provider can explicitly unset a seeded optional field',
    (tester) async {
      Map<String, Object?>? saved;
      await forms.openForm(
        tester,
        ProviderFormPage(
          ruleProvider: false,
          initialName: 'provider',
          initialDefinition: const {
            'type': 'inline',
            'override': {'udp': false, 'unknown': 'retained'},
            'payload': <Object?>[],
          },
          onSave: (_, value) async => saved = value,
        ),
      );
      await forms.choose(tester, 'provider/override/udp', null);
      await forms.tap(tester, forms.keyed('definition-save:provider'));
      expect(saved!['override'], {'unknown': 'retained'});
      expect(tester.takeException(), isNull);
    },
  );
}
