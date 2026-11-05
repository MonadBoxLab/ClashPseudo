import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:flutter/services.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/logic/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form_type_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../shared/definition_forms_test.dart'
    show dismissNotice, expandAncestors;
export '../shared/definition_forms_test.dart'
    show dismissNotice, expandAncestors, tap;

final contractFile = File('test/fixtures/form_contracts/proxies.json');

Object? resolveFixture(Object? value) {
  if (value is String && value.startsWith('@fixture:')) {
    return File('test/fixtures/${value.substring('@fixture:'.length)}')
        .readAsStringSync();
  }
  if (value is Map) {
    return value.map(
      (key, value) => MapEntry(key as String, resolveFixture(value)),
    );
  }
  if (value is List) return value.map(resolveFixture).toList();
  return value;
}

Future<void> openForm(
  WidgetTester tester,
  String type, {
  required Future<void> Function(Map<String, Object?>) onSave,
  Map<String, Object?>? initialDefinition,
  Widget? notice,
  VoidCallback? onSaveHandled,
  Locale locale = const Locale('en'),
  TextScaler scaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [AppTaskNavigatorObserver()],
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaler),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const ValueKey('open-proxy-form'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => OperationNoticeHost(
                  child: ProxyFormPage(
                    initialType: type,
                    initialDefinition: initialDefinition,
                    notice: notice,
                    onSaveHandled: onSaveHandled,
                    onSave: onSave,
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-proxy-form')));
  await tester.pumpAndSettle();
}

Finder keyed(String value, {bool offstage = false}) =>
    find.byKey(ValueKey(value), skipOffstage: !offstage);

Finder definitionCollection(String id) => find.byWidgetPredicate(
  (widget) =>
      widget is DefinitionStringListField && widget.id == id ||
      widget is DefinitionHeadersField && widget.id == id,
  skipOffstage: false,
);

Future<void> openGroup(WidgetTester tester, String id) async {
  final definition = definitionCollection(id);
  if (definition.evaluate().isNotEmpty) {
    await expandAncestors(tester, definition);
    final enabled = keyed('definition-presence:$id', offstage: true);
    if (enabled.evaluate().isNotEmpty &&
        !tester.widget<Switch>(enabled).value) {
      await tester.ensureVisible(enabled);
      await tester.tap(enabled);
      await tester.pumpAndSettle();
    }
    return;
  }
  final group = keyed('proxy-group:$id', offstage: true);
  expect(group, findsOneWidget, reason: id);
  await expandAncestors(tester, group);
  final header = find
      .descendant(
        of: group,
        matching: find.byType(ListTile, skipOffstage: false),
      )
      .first;
  final controller = ExpansibleController.of(tester.element(header));
  if (!controller.isExpanded) {
    controller.expand();
    await tester.pumpAndSettle();
  }
  final enabled = keyed('proxy-enable:$id', offstage: true);
  if (enabled.evaluate().isNotEmpty && !tester.widget<Switch>(enabled).value) {
    await tester.ensureVisible(enabled);
    await tester.tap(enabled);
    await tester.pumpAndSettle();
  }
}

String fieldId(String scope, String key, String prefix) {
  if (!scope.contains('/') &&
      keyed('$prefix:common/$key', offstage: true).evaluate().isNotEmpty) {
    return 'common/$key';
  }
  return '$scope/$key';
}

Future<void> fillScalar(
  WidgetTester tester,
  String scope,
  String key,
  Object value,
) async {
  await dismissNotice(tester);
  var definition = keyed('definition-input:$scope/$key', offstage: true);
  if (definition.evaluate().isEmpty && key == 'value') {
    definition = keyed('definition-input:$scope', offstage: true);
  }
  if (definition.evaluate().isNotEmpty) {
    final input = definition;
    await expandAncestors(tester, input);
    await tester.ensureVisible(input);
    await tester.enterText(input, '$value');
    await tester.pump();
    return;
  }
  final choiceId = fieldId(scope, key, 'proxy-choice');
  final choice = keyed('proxy-choice:$choiceId', offstage: true);
  if (choice.evaluate().isNotEmpty) {
    await expandAncestors(tester, choice);
    await tester.ensureVisible(choice);
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ProxyFormPage));
    final strings = AppLocalizations.of(context);
    final text = value is bool
        ? (value ? strings.proxyTrue : strings.proxyFalse)
        : '$value';
    final item = find.widgetWithText(MenuItemButton, text);
    await tester.ensureVisible(item);
    await tester.pump();
    await tester.tap(item);
    await tester.pumpAndSettle();
    return;
  }
  final id = fieldId(scope, key, 'proxy-field');
  final field = keyed('proxy-field:$id', offstage: true);
  expect(field, findsOneWidget, reason: '$scope/$key');
  await expandAncestors(tester, field);
  final enabled = keyed('proxy-enable:$id', offstage: true);
  if (enabled.evaluate().isNotEmpty && !tester.widget<Switch>(enabled).value) {
    await tester.ensureVisible(enabled);
    await tester.tap(enabled);
    await tester.pumpAndSettle();
  }
  final input = find
      .descendant(
        of: field,
        matching: find.byType(TextField, skipOffstage: false),
      )
      .first;
  await tester.ensureVisible(input);
  await tester.enterText(input, '$value');
  await tester.pump();
}

Future<String> addRow(WidgetTester tester, String id) async {
  await openGroup(tester, id);
  final definition = definitionCollection(id);
  if (definition.evaluate().isNotEmpty) {
    final mapping = tester.widget(definition) is DefinitionHeadersField;
    final before = find
        .byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'definition-row:$id/',
              ),
          skipOffstage: false,
        )
        .evaluate()
        .map((element) => element.widget.key)
        .toSet();
    final add = keyed('definition-add:$id', offstage: true);
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    if (mapping) {
      final save = find.byWidgetPredicate(
        (widget) =>
            widget is FilledButton &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'definition-save-header:$id/',
            ),
      );
      expect(save, findsOneWidget);
      return (tester.widget<FilledButton>(save).key! as ValueKey<String>).value
          .substring('definition-save-header:'.length);
    }
    final added = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'definition-row:$id/',
          ) &&
          !before.contains(widget.key),
    );
    expect(added, findsOneWidget);
    return (tester.widget(added).key! as ValueKey<String>).value.substring(
      'definition-row:'.length,
    );
  }
  final add = keyed('proxy-add:$id', offstage: true);
  await tester.ensureVisible(add);
  await tester.tap(add);
  await tester.pumpAndSettle();
  final editor = find.byWidgetPredicate(
    (widget) =>
        widget is Scaffold &&
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'proxy-record-editor:$id/',
        ),
  );
  expect(editor, findsOneWidget);
  return (tester.widget<Scaffold>(editor).key! as ValueKey<String>).value
      .substring('proxy-record-editor:'.length);
}

Future<void> fillValue(
  WidgetTester tester,
  String scope,
  String key,
  Object? value,
) async {
  var id = '$scope/$key';
  if (key == 'plugin-opts') {
    final branch = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'proxy-object:$id@',
          ) &&
          !(widget.key! as ValueKey<String>).value
              .substring('proxy-object:$id@'.length)
              .contains('/'),
      skipOffstage: false,
    );
    expect(branch, findsOneWidget);
    id = (tester.widget(branch).key! as ValueKey<String>).value.substring(
      'proxy-object:'.length,
    );
  }
  if (value is Map) {
    if (keyed('proxy-object:$id', offstage: true).evaluate().isNotEmpty) {
      await openGroup(tester, id);
      await fillObject(tester, id, Map<String, Object?>.from(value));
    } else {
      await openGroup(tester, id);
      for (final entry in value.entries) {
        final row = await addRow(tester, id);
        await fillScalar(tester, row, 'key', entry.key as String);
        if (entry.value is List) {
          await fillValue(tester, row, 'values', entry.value);
        } else {
          await fillScalar(tester, row, 'value', entry.value as Object);
        }
        await tester.tap(keyed('definition-save-header:$row'));
        await tester.pumpAndSettle();
      }
    }
  } else if (value is List) {
    await openGroup(tester, id);
    for (final item in value) {
      final row = await addRow(tester, id);
      if (item is Map) {
        await fillObject(tester, row, Map<String, Object?>.from(item));
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
      } else {
        await fillScalar(tester, row, 'value', item as Object);
      }
    }
  } else if (value != null) {
    await fillScalar(tester, scope, key, value);
  }
}

Future<void> fillObject(
  WidgetTester tester,
  String scope,
  Map<String, Object?> values,
) async {
  final entries = values.entries.where((entry) => entry.key != 'type').toList();
  for (final entry in entries.where(
    (entry) => ['network', 'plugin', 'mode'].contains(entry.key),
  )) {
    await fillValue(tester, scope, entry.key, entry.value);
  }
  for (final entry in entries.where(
    (entry) => !['network', 'plugin', 'mode'].contains(entry.key),
  )) {
    await fillValue(tester, scope, entry.key, entry.value);
  }
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
            await openForm(
              tester,
              'direct',
              initialDefinition: const {
                'name': 'kept proxy',
                'type': 'direct',
                'future': {'enabled': false, 'zero': 0},
              },
              locale: Locale(language),
              onSave: (value) async {
                saves++;
                if (saves == 1) throw failure;
                saved = value;
              },
            );
            final strings = AppLocalizations.of(
              tester.element(find.byType(ProxyFormPage)),
            );
            expect(
              find.byKey(const ValueKey('definition-draft-notice:proxy')),
              findsNothing,
            );
            expect(saves, 0);
            final input = find.descendant(
              of: keyed('proxy-field:common/name'),
              matching: find.byType(TextField),
            );
            final controller = tester.widget<TextField>(input).controller!;
            final before = controller.value;
            await tester.tap(find.byKey(const ValueKey('proxy-save')));
            await tester.pumpAndSettle();
            expect(saves, 1);
            expect(find.byType(ProxyFormPage), findsOneWidget);
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
            expect(find.byType(ProxyFormPage), findsOneWidget);
            expect(
              tester.widget<TextField>(input).controller,
              same(controller),
            );
            expect(controller.value, before);
            expect(saves, 1);
            await tester.tap(find.byKey(const ValueKey('proxy-save')));
            await tester.pumpAndSettle();
            expect(saves, 2);
            expect(saved, const {
              'name': 'kept proxy',
              'type': 'direct',
              'future': {'enabled': false, 'zero': 0},
            });
            expect(find.byType(ProxyFormPage), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  });

  for (final plugin in ['v2ray-plugin', 'gost-plugin', 'shadow-tls', '']) {
    testWidgets(
      'SS plugin $plugin retains untouched shared and opaque option values',
      (tester) async {
        final original = <String, Object?>{
          'type': 'ss',
          'name': 'captured node',
          'server': 'fixture.invalid',
          'port': 443,
          'password': 'synthetic-password',
          'cipher': 'aes-128-gcm',
          'plugin': 'obfs',
          'plugin-opts': {
            'mode': 'http',
            'host': null,
            'tls': false,
            'port': 0,
            'headers': <String, Object?>{},
            'future': <Object?>[],
          },
          'unknown': {'null': null, 'false': false, 'zero': 0},
        };
        Map<String, Object?>? saved;
        await openForm(
          tester,
          'ss',
          initialDefinition: original,
          onSave: (value) async => saved = value,
        );
        if (plugin.isEmpty) {
          final strings = AppLocalizations.of(
            tester.element(find.byType(ProxyFormPage)),
          );
          await fillScalar(tester, 'ss', 'plugin', strings.proxyUnset);
        } else {
          await fillScalar(tester, 'ss', 'plugin', plugin);
        }
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        final expected = {...original};
        if (plugin.isEmpty) {
          expected.remove('plugin');
        } else {
          expected['plugin'] = plugin;
        }
        expect(saved, expected);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final target in ['grpc', 'http', '']) {
    testWidgets(
      'transport $target does not remove existing hidden options or normalize same-name values',
      (tester) async {
        final original = <String, Object?>{
          'type': 'vmess',
          'name': 'captured node',
          'server': 'fixture.invalid',
          'port': 443,
          'uuid': 'synthetic-uuid',
          'alterId': 0,
          'cipher': 'auto',
          'network': 'ws',
          'ws-opts': {
            'path': '',
            'headers': <String, Object?>{},
            'future': null,
          },
          'grpc-opts': {
            'grpc-service-name': null,
            'min-streams': 0,
            'future': false,
          },
          'http-opts': {
            'method': '',
            'path': <String>[],
            'future': <Object?>[],
          },
        };
        Map<String, Object?>? saved;
        await openForm(
          tester,
          'vmess',
          initialDefinition: original,
          onSave: (value) async => saved = value,
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(ProxyFormPage)),
        );
        await fillScalar(
          tester,
          'vmess',
          'network',
          target.isEmpty ? strings.proxyUnset : target,
        );
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        final expected = {...original};
        if (target.isEmpty) {
          expected.remove('network');
        } else {
          expected['network'] = target;
        }
        expect(saved, expected);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'actual type replacement preserves unknown and unedited same-name originals',
    (tester) async {
      final original = <String, Object?>{
        'type': 'http',
        'name': 'captured node',
        'server': 'fixture.invalid',
        'port': 443,
        'tls': false,
        'headers': <String, Object?>{},
        'cipher': '',
        'password': null,
        'unknown': {
          'false': false,
          'zero': 0,
          'null': null,
          'list': <Object?>[],
        },
      };
      Map<String, Object?>? saved;
      await openForm(
        tester,
        'http',
        initialDefinition: original,
        onSave: (value) async => saved = value,
      );
      await tester.ensureVisible(keyed('proxy-select-type'));
      await tester.tap(keyed('proxy-select-type'));
      await tester.pumpAndSettle();
      final row = keyed('proxy-type:ss');
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(row);
      await tester.pumpAndSettle();
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(saved, {...original, 'type': 'ss'});
      expect(tester.takeException(), isNull);
    },
  );
  final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(
    () => WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy,
  );
  final fixtures = (jsonDecode(contractFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('contract fixtures cover all 28 raw type branches', () {
    expect(
      fixtures.map((fixture) => (fixture['definition'] as Map)['type']).toSet(),
      ProxyFormType.values.map((type) => type.raw).toSet(),
    );
  });

  for (final fixture in fixtures) {
    testWidgets(
      '${fixture['id']} controls produce the exact definition and local YAML',
      (tester) async {
        final expected = Map<String, Object?>.from(
          resolveFixture(fixture['definition']) as Map,
        );
        final type = expected['type'] as String;
        Map<String, Object?>? actual;
        await openForm(
          tester,
          type,
          onSave: (definition) async {
            actual = definition;
          },
        );
        await fillObject(tester, type, expected);
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(actual, expected);
        final yaml = LocalYamlEdit('{}').addProxy(actual!);
        expect((loadYaml(yaml)['proxies'] as List).single, expected);
        expect(fixture['yaml'], isA<String>());
        expect(yaml, fixture['yaml']);
        expect(find.byType(ProxyFormPage), findsNothing);
      },
    );
    testWidgets(
      '${fixture['id']} unsaved GUI draft round trips without editing',
      (tester) async {
        final expected = Map<String, Object?>.from(
          resolveFixture(fixture['definition']) as Map,
        );
        final parentDraft = Map<String, Object?>.from(
          jsonDecode(jsonEncode(expected)) as Map,
        );
        Map<String, Object?>? actual;
        await openForm(
          tester,
          'http',
          initialDefinition: parentDraft,
          onSave: (definition) async {
            actual = definition;
          },
        );
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(actual, expected);
        expect(parentDraft, expected);
        expect(find.byType(ProxyFormPage), findsNothing);
      },
    );
  }

  testWidgets(
    'inline draft changes and cancellation never mutate the parent map',
    (tester) async {
      final parent = <String, Object?>{
        'name': 'parent',
        'type': 'http',
        'server': '127.0.0.1',
        'port': 1080,
        'tls': false,
        'headers': <String, Object?>{'X-Draft': 'original'},
      };
      final expected = jsonDecode(jsonEncode(parent));
      var saves = 0;
      await openForm(
        tester,
        'http',
        initialDefinition: parent,
        onSave: (_) async {
          saves++;
        },
      );
      await fillScalar(tester, 'http', 'name', 'changed child');
      await openGroup(tester, 'http/headers');
      final edit = keyed('definition-edit:http/headers/0');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await fillScalar(tester, 'http/headers/0', 'value', 'changed header');
      await tester.tap(keyed('definition-save-header:http/headers/0'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(parent, expected);
      expect(find.byType(ProxyFormPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('prefill deep copy isolates later external nested mutations', (
    tester,
  ) async {
    final parent = <String, Object?>{
      'name': 'isolated',
      'type': 'http',
      'server': '127.0.0.1',
      'port': 1080,
      'tls': false,
      'headers': <String, Object?>{'X-Draft': 'original'},
    };
    final expected = jsonDecode(jsonEncode(parent));
    Map<String, Object?>? actual;
    await openForm(
      tester,
      'http',
      initialDefinition: parent,
      onSave: (definition) async {
        actual = definition;
      },
    );
    parent['name'] = 'external';
    (parent['headers'] as Map)['X-Draft'] = 'external';
    await tester.tap(keyed('proxy-save'));
    await tester.pumpAndSettle();
    expect(actual, expected);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late successful save retains its covered route without borrowing navigation',
    (tester) async {
      final pending = Completer<void>();
      const original = <String, Object?>{
        'type': 'http',
        'name': 'covered',
        'server': '127.0.0.1',
        'port': 1080,
      };
      final accepted = <Map<String, Object?>>[];
      Map<String, Object?>? saved;
      var handled = 0;
      await openForm(
        tester,
        'http',
        initialDefinition: original,
        onSave: (definition) async {
          accepted.add(definition);
          await pending.future;
          saved = definition;
        },
        onSaveHandled: () => handled++,
      );
      final context = tester.element(find.byType(ProxyFormPage));
      final own = ModalRoute.of(context)!;
      final navigator = Navigator.of(context);
      final save = keyed('proxy-save');
      final oldSave = tester.widget<FilledButton>(save).onPressed!;
      var returned = false;
      unawaited(
        own.popped.then<void>((_) {
          returned = true;
        }),
      );
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      expect(accepted, [original]);
      expect(saved, isNull);
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Cover')),
              body: const Text('cover route'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(saved, original);
      expect(accepted, [original]);
      expect(handled, 1);
      final cover = find.text('cover route');
      expect(cover, findsOneWidget);
      final coverRoute = ModalRoute.of(tester.element(cover))!;
      expect(coverRoute.isCurrent, isTrue);
      expect(own.isActive, isTrue);
      expect(own.isCurrent, isFalse);
      expect(returned, isFalse);
      final form = find.byType(ProxyFormPage, skipOffstage: false);
      expect(form, findsOneWidget);
      expect(tester.element(form), same(context));
      navigator.pop();
      await tester.pump();
      await tester.pump(coverRoute.reverseTransitionDuration);
      await tester.pump(const Duration(microseconds: 1));
      expect(cover, findsNothing);
      expect(own.isCurrent, isTrue);
      expect(tester.element(form), same(context));
      expect(returned, isFalse);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      final progress = find.descendant(
        of: save,
        matching: find.byType(CircularProgressIndicator),
      );
      expect(progress, findsNothing);
      oldSave();
      await tester.pump();
      expect(accepted, [original]);
      expect(saved, original);
      expect(handled, 1);
      expect(own.isCurrent, isTrue);
      expect(tester.element(form), same(context));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(returned, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late completion after forced removal does not navigate or set state',
    (tester) async {
      final pending = Completer<void>();
      await openForm(
        tester,
        'http',
        initialDefinition: {
          'type': 'http',
          'name': 'removed',
          'server': '127.0.0.1',
          'port': 1080,
        },
        onSave: (_) => pending.future,
      );
      final context = tester.element(find.byType(ProxyFormPage));
      final own = ModalRoute.of(context)!;
      final navigator = Navigator.of(context);
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      navigator.removeRoute(own);
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(keyed('open-proxy-form'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new Tailscale forms receive independent directories and retries retain identity',
    (tester) async {
      final directories = <String>[];
      for (var instance = 0; instance < 2; instance++) {
        var calls = 0;
        await openForm(
          tester,
          'tailscale',
          onSave: (definition) async {
            directories.add(definition['state-dir']! as String);
            if (calls++ == 0) {
              throw ProxyFormSaveException(
                messages.configSavedReconnectIncomplete,
              );
            }
          },
        );
        await fillScalar(tester, 'tailscale', 'name', 'instance-$instance');
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(find.byType(ProxyFormPage), findsOneWidget);
        final strings = AppLocalizations.of(
          tester.element(find.byType(ProxyFormPage)),
        );
        await tester.tap(find.widgetWithText(TextButton, strings.retry));
        await tester.pumpAndSettle();
        expect(directories[instance * 2], directories[instance * 2 + 1]);
        expect(directories.last, matches(RegExp(r'^tailscale/[0-9a-f]{32}$')));
      }
      expect(directories.first, isNot(directories.last));
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      '${locale.languageCode} narrow large-font bool states keep field and save anchors',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final value in <bool?>[false, true, null]) {
          Map<String, Object?>? actual;
          await openForm(
            tester,
            'http',
            locale: locale,
            scaler: const TextScaler.linear(2),
            initialDefinition: {
              'type': 'http',
              'name': 'three states',
              'server': '127.0.0.1',
              'port': 1080,
            },
            onSave: (definition) async {
              actual = definition;
            },
          );
          final choice = keyed('proxy-choice:http/tls', offstage: true);
          await tester.ensureVisible(choice);
          await tester.pumpAndSettle();
          final rect = tester.getRect(choice);
          final next = tester.getRect(
            keyed('proxy-field:http/sni', offstage: true),
          );
          final save = tester.getRect(keyed('proxy-save'));
          final strings = AppLocalizations.of(
            tester.element(find.byType(ProxyFormPage)),
          );
          await fillScalar(tester, 'http', 'tls', value ?? strings.proxyUnset);
          expect(tester.getRect(choice), rect);
          expect(
            tester.getRect(keyed('proxy-field:http/sni', offstage: true)),
            next,
          );
          expect(tester.getRect(keyed('proxy-save')), save);
          await tester.tap(keyed('proxy-save'));
          await tester.pumpAndSettle();
          expect(actual!.containsKey('tls'), value != null);
          if (value != null) expect(actual!['tls'], value);
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      '${locale.languageCode} long identifiers and keyboard keep failed/retry anchors stable',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pending = Completer<void>();
        await openForm(
          tester,
          'zerotier',
          locale: locale,
          scaler: const TextScaler.linear(2),
          initialDefinition: {
            'type': 'zerotier',
            'name': 'very long readable node name retained intact',
            'network': '0123456789abcdef',
          },
          onSave: (_) => pending.future,
        );
        await fillScalar(tester, 'zerotier', 'remote-trace-level', '31');
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        final numberField = keyed('proxy-field:zerotier/remote-trace-level');
        await Scrollable.ensureVisible(
          tester.element(numberField),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
        final numberInput = find.descendant(
          of: numberField,
          matching: find.byType(TextField),
        );
        await Scrollable.ensureVisible(
          tester.element(numberInput),
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
        await tester.pumpAndSettle();
        final viewport = tester.getRect(keyed('proxy-form-scroll'));
        expect(
          tester.getRect(numberInput).top,
          greaterThanOrEqualTo(viewport.top),
        );
        expect(
          tester.getRect(numberInput).bottom,
          lessThanOrEqualTo(viewport.bottom),
        );
        final type = tester.getRect(keyed('proxy-select-type'));
        final save = tester.getRect(keyed('proxy-save'));
        final number = tester.getRect(numberField);
        await tester.tap(keyed('proxy-save'));
        await tester.pump();
        expect(tester.getRect(keyed('proxy-select-type')), type);
        expect(tester.getRect(keyed('proxy-save')), save);
        expect(
          tester.getRect(keyed('proxy-field:zerotier/remote-trace-level')),
          number,
        );
        await fillScalar(tester, 'zerotier', 'remote-trace-level', '30');
        final beforePending = tester.getRect(keyed('proxy-save'));
        await tester.tap(keyed('proxy-save'));
        await tester.pump();
        expect(tester.getRect(keyed('proxy-save')), beforePending);
        pending.completeError(
          ProxyFormSaveException(messages.configSavedReconnectIncomplete),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));
        expect(tester.getRect(keyed('proxy-save')), beforePending);
        expect(find.byType(ProxyFormPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'native numeric limits reject unsafe values without clamping input',
    (tester) async {
      final cases = <({String type, String field, List<String> invalid})>[
        (
          type: 'zerotier',
          field: 'remote-trace-level',
          invalid: [
            '-1',
            '31',
            '9223372036854775808',
            '18446744073709551615',
            '18446744073709551616',
            '1.5',
            '1e3',
          ],
        ),
        for (final field in [
          'initial-stream-receive-window',
          'max-stream-receive-window',
          'initial-connection-receive-window',
          'max-connection-receive-window',
        ])
          (
            type: 'hysteria2',
            field: field,
            invalid: [
              '-1',
              '4611686018427387904',
              '9223372036854775808',
              '18446744073709551615',
              '18446744073709551616',
              '1.5',
              '1e3',
            ],
          ),
      ];
      for (final item in cases) {
        final seed = Map<String, Object?>.from(
          resolveFixture(
            fixtures.singleWhere(
              (fixture) => fixture['id'] == item.type,
            )['definition'],
          ) as Map,
        );
        Map<String, Object?>? actual;
        await openForm(
          tester,
          item.type,
          initialDefinition: seed,
          onSave: (definition) async {
            actual = definition;
          },
        );
        for (final invalid in item.invalid) {
          await fillScalar(tester, item.type, item.field, invalid);
          await tester.tap(keyed('proxy-save'));
          await tester.pump();
          expect(actual, isNull, reason: '${item.field}=$invalid');
          final input = tester.widget<TextField>(
            find.descendant(
              of: keyed('proxy-field:${item.type}/${item.field}'),
              matching: find.byType(TextField),
            ),
          );
          expect(input.controller!.text, invalid);
        }
        await fillScalar(tester, item.type, item.field, '0');
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(actual![item.field], 0);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'TimeSpec validates combined range without changing the other input',
    (tester) async {
      for (final nested in [false, true]) {
        final seed = Map<String, Object?>.from(
          resolveFixture(
            fixtures.singleWhere(
              (fixture) => fixture['id'] == 'vmess-tlsmirror-all-fields',
            )['definition'],
          ) as Map,
        );
        Map<String, Object?>? actual;
        await openForm(
          tester,
          'vmess',
          initialDefinition: seed,
          onSave: (definition) async {
            actual = definition;
          },
        );
        final scope = nested
            ? 'vmess/tlsmirror-opts/embedded-traffic-generator/steps/r0/wait-time'
            : 'vmess/tlsmirror-opts/defer-instance-derived-write-time';
        // The seeded step is r2 after cipher-suite rows r0/r1; locate its stable
        // record identity.
        var target = scope;
        if (nested) {
          const listId =
              'vmess/tlsmirror-opts/embedded-traffic-generator/steps';
          await openGroup(tester, listId);
          await tester.ensureVisible(keyed('proxy-record-list:$listId'));
          await tester.pumpAndSettle();
          final rows = find.byWidgetPredicate(
            (widget) =>
                widget is ListTile &&
                widget.key is ValueKey<String> &&
                RegExp(
                  r'^proxy-row:vmess/tlsmirror-opts/embedded-traffic-generator/steps/r[0-9]+$',
                ).hasMatch((widget.key! as ValueKey<String>).value),
          );
          expect(rows, findsOneWidget);
          final rowScope = (tester.widget(rows).key! as ValueKey<String>).value
              .substring('proxy-row:'.length);
          final edit = keyed('proxy-edit:$rowScope');
          await tester.ensureVisible(edit);
          await tester.tap(edit);
          await tester.pumpAndSettle();
          target = '$rowScope/wait-time';
        }
        await openGroup(tester, target);
        for (final pair in [
          ('9223372036854775807', '2'),
          ('1', '9223372036854775808'),
          ('9223372036854775808', '0'),
          ('0', '18446744073709551615'),
          ('0', '18446744073709551616'),
        ]) {
          await fillScalar(tester, target, 'base-nanoseconds', pair.$1);
          await fillScalar(
            tester,
            target,
            'uniform-random-multiplier-nanoseconds',
            pair.$2,
          );
          await tester.tap(keyed('proxy-save'));
          await tester.pump();
          expect(actual, isNull, reason: '$target $pair');
          for (final field in [
            ('base-nanoseconds', pair.$1),
            ('uniform-random-multiplier-nanoseconds', pair.$2),
          ]) {
            final input = tester.widget<TextField>(
              find.descendant(
                of: keyed('proxy-field:$target/${field.$1}'),
                matching: find.byType(TextField),
              ),
            );
            expect(input.controller!.text, field.$2);
          }
        }
        await fillScalar(
          tester,
          target,
          'base-nanoseconds',
          '9223372036854775807',
        );
        await fillScalar(
          tester,
          target,
          'uniform-random-multiplier-nanoseconds',
          '0',
        );
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        if (nested) {
          await tester.tap(keyed('proxy-save'));
          await tester.pumpAndSettle();
        }
        final mirror = actual!['tlsmirror-opts'] as Map;
        final spec = nested
            ? (((mirror['embedded-traffic-generator'] as Map)['steps'] as List)
                      .single
                  as Map)['wait-time']
            : mirror['defer-instance-derived-write-time'];
        expect(spec, {
          'base-nanoseconds': 9223372036854775807,
          'uniform-random-multiplier-nanoseconds': 0,
        });
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('enabled empty TimeSpec does not write implicit zero defaults', (
    tester,
  ) async {
    final seed = Map<String, Object?>.from(
      resolveFixture(
        fixtures.singleWhere(
          (fixture) => fixture['id'] == 'vmess',
        )['definition'],
      ) as Map,
    );
    Map<String, Object?>? actual;
    await openForm(
      tester,
      'vmess',
      initialDefinition: seed,
      onSave: (definition) async {
        actual = definition;
      },
    );
    await openGroup(tester, 'vmess/tlsmirror-opts');
    await openGroup(
      tester,
      'vmess/tlsmirror-opts/defer-instance-derived-write-time',
    );
    await tester.tap(keyed('proxy-save'));
    await tester.pumpAndSettle();
    expect(actual!['tlsmirror-opts'], {
      'defer-instance-derived-write-time': <String, Object?>{},
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'record editing retains selection under an old hidden removal, then preserves values after deletion',
    (tester) async {
      final seed = Map<String, Object?>.from(
        resolveFixture(
          fixtures.singleWhere(
            (fixture) => fixture['id'] == 'wireguard',
          )['definition'],
        ) as Map,
      );
      seed['peers'] = [
        for (var i = 1; i <= 3; i++)
          <String, Object?>{
            'server': '127.0.0.$i',
            'port': 1080 + i,
            'public-key': seed['public-key'],
            'allowed-ips': ['0.0.0.0/0'],
          },
      ];
      final untouched = jsonDecode(jsonEncode(seed));
      Map<String, Object?>? actual;
      await openForm(
        tester,
        'wireguard',
        initialDefinition: seed,
        onSave: (definition) async {
          actual = definition;
        },
      );
      await openGroup(tester, 'wireguard/peers');
      final rows = find
          .byWidgetPredicate(
            (widget) =>
                widget is ListTile &&
                widget.key is ValueKey<String> &&
                RegExp(r'^proxy-row:wireguard/peers/r[0-9]+$')
                    .hasMatch((widget.key! as ValueKey<String>).value),
            skipOffstage: false,
          )
          .evaluate()
          .map(
            (element) => (element.widget.key! as ValueKey<String>).value
                .substring('proxy-row:'.length),
          )
          .toList();
      expect(rows.length, 3);
      final oldRemove = tester
          .widget<IconButton>(keyed('proxy-remove:${rows[1]}', offstage: true))
          .onPressed!;
      final edit = keyed('proxy-edit:${rows.last}');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await fillScalar(tester, rows.last, 'server', '127.0.0.4');
      final input = find.descendant(
        of: keyed('proxy-field:${rows.last}/server', offstage: true),
        matching: find.byType(TextField, skipOffstage: false),
      );
      final controller = tester.widget<TextField>(input).controller!;
      controller.selection = const TextSelection(
        baseOffset: 2,
        extentOffset: 5,
      );
      final selection = controller.selection;
      oldRemove();
      await tester.pump();
      expect(
        identical(tester.widget<TextField>(input).controller, controller),
        isTrue,
      );
      expect(controller.text, '127.0.0.4');
      expect(controller.selection, selection);
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      final remove = keyed('proxy-remove:${rows[1]}');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect((actual!['peers'] as List).length, 2);
      expect(((actual!['peers'] as List).last as Map)['server'], '127.0.0.4');
      expect(((actual!['peers'] as List).last as Map)['port'], 1083);
      expect(seed, untouched);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'duplicate header keys show stable validation and preserve both rows for repair',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        'http',
        initialDefinition: {
          'type': 'http',
          'name': 'headers',
          'server': '127.0.0.1',
          'port': 1080,
          'headers': {'X-Fixture': 'first'},
        },
        onSave: (definition) async {
          actual = definition;
        },
      );
      final row = await addRow(tester, 'http/headers');
      await fillScalar(tester, row, 'key', 'X-Fixture');
      await fillScalar(tester, row, 'value', 'second');
      final input = keyed('definition-input:$row/key');
      final field = find.ancestor(
        of: input,
        matching: find.byType(DefinitionTextField),
      );
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      final before = tester.getRect(field);
      final saveButton = keyed('definition-save-header:$row');
      final save = tester.getRect(saveButton);
      await tester.tap(saveButton);
      await tester.pump();
      expect(actual, isNull);
      expect(tester.getRect(field), before);
      expect(tester.getRect(saveButton), save);
      final state = tester.state<FormFieldState<String>>(
        find.ancestor(
          of: input,
          matching: find.byWidgetPredicate(
            (widget) => widget is FormField<String>,
          ),
        ),
      );
      final strings = AppLocalizations.of(tester.element(saveButton));
      expect(state.hasError, isTrue);
      await tester.pumpAndSettle();
      expect(tester.getRect(field), before);
      expect(tester.getRect(saveButton), save);
      expect(
        find.text(strings.proxyDuplicateKey).hitTestable(),
        findsOneWidget,
      );
      await fillScalar(tester, row, 'key', 'X-Second');
      await tester.tap(saveButton);
      await tester.pumpAndSettle();
      expect(actual, isNull);
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(actual!['headers'], {'X-Fixture': 'first', 'X-Second': 'second'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty object list and nullable pointer presence survives GUI draft save',
    (tester) async {
      for (final id in ['vmess', 'vless']) {
        final seed = Map<String, Object?>.from(
          resolveFixture(
            fixtures.singleWhere(
              (fixture) => fixture['id'] == id,
            )['definition'],
          ) as Map,
        );
        seed.addAll({'alpn': <String>[], 'ech-opts': <String, Object?>{}});
        if (id == 'vless') seed['ws-headers'] = <String, Object?>{};
        Map<String, Object?>? actual;
        await openForm(
          tester,
          id,
          initialDefinition: seed,
          onSave: (definition) async {
            actual = definition;
          },
        );
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(actual, seed);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'clearing the nested header list emits empty values instead of cached rows',
    (tester) async {
      final seed = Map<String, Object?>.from(
        resolveFixture(
          fixtures.singleWhere(
            (fixture) => fixture['id'] == 'vmess',
          )['definition'],
        ) as Map,
      );
      Map<String, Object?>? actual;
      await openForm(
        tester,
        'vmess',
        initialDefinition: seed,
        onSave: (definition) async {
          actual = definition;
        },
      );
      await fillScalar(tester, 'vmess', 'network', 'http');
      await openGroup(tester, 'vmess/http-opts');
      final row = await addRow(tester, 'vmess/http-opts/headers');
      await fillScalar(tester, row, 'key', 'X-Fixture');
      await fillValue(tester, row, 'values', ['cached']);
      final remove = keyed('definition-remove:$row/values/0');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(keyed('definition-save-header:$row'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect((actual!['http-opts'] as Map)['headers'], {
        'X-Fixture': <String>[],
      });
      expect(actual!['ws-opts'], seed['ws-opts']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'type switches preserve shared input and only save the active protocol draft',
    (tester) async {
      final seed = Map<String, Object?>.from(
        resolveFixture(
          fixtures.singleWhere(
            (fixture) => fixture['id'] == 'http',
          )['definition'],
        ) as Map,
      );
      Map<String, Object?>? actual;
      await openForm(
        tester,
        'http',
        initialDefinition: seed,
        onSave: (definition) async {
          actual = definition;
        },
      );
      final saveBefore = tester.getRect(keyed('proxy-save'));
      for (final raw in ['ss', 'http']) {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.ensureVisible(keyed('proxy-select-type'));
        await tester.pumpAndSettle();
        final typeBefore = tester.getRect(keyed('proxy-select-type'));
        await tester.tap(keyed('proxy-select-type'));
        await tester.pumpAndSettle();
        final row = keyed('proxy-type:$raw');
        await tester.scrollUntilVisible(
          row,
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(tester.getRect(keyed('proxy-select-type')), typeBefore);
        expect(tester.getRect(keyed('proxy-save')), saveBefore);
        if (raw == 'ss') {
          await fillScalar(tester, 'ss', 'cipher', 'aes-128-gcm');
        }
      }
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(actual, seed);
      expect(actual!.containsKey('cipher'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing SS plugin isolates incompatible option drafts and restores the original branch',
    (tester) async {
      final seed = Map<String, Object?>.from(
        resolveFixture(
          fixtures.singleWhere(
            (fixture) => fixture['id'] == 'ss-plugin-obfs',
          )['definition'],
        ) as Map,
      );
      Map<String, Object?>? actual;
      await openForm(
        tester,
        'ss',
        initialDefinition: seed,
        onSave: (definition) async {
          actual = definition;
        },
      );
      await fillScalar(tester, 'ss', 'plugin', 'v2ray-plugin');
      await openGroup(tester, 'ss/plugin-opts@v2ray-plugin');
      await fillScalar(
        tester,
        'ss/plugin-opts@v2ray-plugin',
        'mode',
        'websocket',
      );
      await fillScalar(tester, 'ss/plugin-opts@v2ray-plugin', 'tls', true);
      await fillScalar(tester, 'ss', 'plugin', 'obfs');
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(actual, seed);
      expect((actual!['plugin-opts'] as Map).containsKey('tls'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending save blocks back while generic failures do not expose exception text',
    (tester) async {
      final pending = Completer<void>();
      await openForm(
        tester,
        'http',
        initialDefinition: {
          'type': 'http',
          'name': 'safe failure',
          'server': '127.0.0.1',
          'port': 1080,
        },
        onSave: (_) => pending.future,
      );
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(ProxyFormPage), findsOneWidget);
      pending.completeError(StateError('sensitive-yaml-sentinel'));
      await tester.pumpAndSettle();
      expect(find.textContaining('sensitive-yaml-sentinel'), findsNothing);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(TextButton),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      );
      expect(find.text(strings.proxySaveFailed), findsOneWidget);
      expect(find.textContaining('sensitive-yaml-sentinel'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Gost exposes only its actual public websocket mode', (
    tester,
  ) async {
    final seed = Map<String, Object?>.from(
      resolveFixture(
        fixtures.singleWhere(
          (fixture) => fixture['id'] == 'ss-plugin-gost-plugin',
        )['definition'],
      ) as Map,
    );
    await openForm(tester, 'ss', initialDefinition: seed, onSave: (_) async {});
    final choice = keyed(
      'proxy-choice:ss/plugin-opts@gost-plugin/mode',
      offstage: true,
    );
    await expandAncestors(tester, choice);
    await tester.ensureVisible(choice);
    await tester.pumpAndSettle();
    await tester.tap(choice);
    await tester.pumpAndSettle();
    final items = find.byType(MenuItemButton);
    expect(
      items
          .evaluate()
          .map((element) => (element.widget.key as ValueKey<String>).value)
          .toList(),
      ['', 'websocket'],
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'KCP units match actual seconds milliseconds bytes packets and byte rate',
    (tester) async {
      final seed = Map<String, Object?>.from(
        resolveFixture(
          fixtures.singleWhere(
            (fixture) => fixture['id'] == 'ss-plugin-kcptun',
          )['definition'],
        ) as Map,
      );
      await openForm(
        tester,
        'ss',
        initialDefinition: seed,
        onSave: (_) async {},
      );
      final strings = AppLocalizations.of(
        tester.element(find.byType(ProxyFormPage)),
      );
      for (final entry in {
        'autoexpire': strings.proxyUnitSeconds,
        'scavengettl': strings.proxyUnitSeconds,
        'keepalive': strings.proxyUnitSeconds,
        'interval': strings.proxyUnitMilliseconds,
        'sockbuf': strings.proxyUnitBytes,
        'smuxbuf': strings.proxyUnitBytes,
        'framesize': strings.proxyUnitBytes,
        'streambuf': strings.proxyUnitBytes,
        'mtu': strings.proxyUnitBytes,
        'sndwnd': strings.proxyUnitPackets,
        'rcvwnd': strings.proxyUnitPackets,
        'ratelimit': 'B/s',
      }.entries) {
        final input = find.descendant(
          of: keyed(
            'proxy-field:ss/plugin-opts@kcptun/${entry.key}',
            offstage: true,
          ),
          matching: find.byType(TextField, skipOffstage: false),
        );
        expect(
          tester.widget<TextField>(input).decoration!.suffixText,
          entry.value,
          reason: entry.key,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ConfigFailure is shown once in the local reader while notice draft and anchors remain',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      final captured = <Map<String, Object?>>[];
      await openForm(
        tester,
        'http',
        notice: const Text(
          'Disabled draft stays disabled',
          key: ValueKey('proxy-notice'),
        ),
        initialDefinition: {
          'type': 'http',
          'name': 'keep this draft',
          'server': '127.0.0.1',
          'port': 1080,
        },
        onSave: (definition) {
          captured.add(definition);
          return calls++ == 0 ? pending.future : Future<void>.value();
        },
      );
      final name = tester.getRect(keyed('proxy-field:common/name'));
      final type = tester.getRect(keyed('proxy-select-type'));
      final save = tester.getRect(keyed('proxy-save'));
      final notice = tester.getRect(keyed('proxy-notice'));
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      pending.completeError(
        ConfigFailure(messages.configSavedReconnectIncomplete),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProxyFormPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.getRect(keyed('proxy-field:common/name')), name);
      expect(tester.getRect(keyed('proxy-select-type')), type);
      expect(tester.getRect(keyed('proxy-save')), save);
      expect(tester.getRect(keyed('proxy-notice')), notice);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(TextButton),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(AlertDialog)),
      );
      expect(find.text(strings.configSavedReconnectIncomplete), findsOneWidget);
      await tester.tap(find.text(strings.close));
      await tester.pumpAndSettle();
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(captured.length, 2);
      expect(captured[1], captured[0]);
      expect(find.byType(ProxyFormPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feedback hook waits for actual outcomes and runs before successful route close',
    (tester) async {
      final pending = Completer<void>();
      var handled = 0;
      await openForm(
        tester,
        'http',
        onSave: (_) => pending.future,
        onSaveHandled: () {
          handled++;
          final context = tester.element(find.byType(ProxyFormPage));
          expect(ModalRoute.of(context)!.isActive, isTrue);
        },
      );
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      expect(handled, 0);
      await fillScalar(tester, 'http', 'name', 'hook order');
      await fillScalar(tester, 'http', 'server', '127.0.0.1');
      await fillScalar(tester, 'http', 'port', 1080);
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      expect(handled, 0);
      pending.complete();
      await tester.pumpAndSettle();
      expect(handled, 1);
      expect(find.byType(ProxyFormPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local typed and generic failures acknowledge once after retaining their reader state',
    (tester) async {
      for (final failure in <Object>[
        ProxyFormSaveException(messages.configSavedReconnectIncomplete),
        ConfigFailure(messages.configSavedReconnectIncomplete),
        StateError('do-not-display-error-text'),
      ]) {
        final pending = Completer<void>();
        var handled = 0;
        await openForm(
          tester,
          'http',
          initialDefinition: {
            'type': 'http',
            'name': 'kept reader',
            'server': '127.0.0.1',
            'port': 1080,
          },
          onSave: (_) => pending.future,
          onSaveHandled: () {
            handled++;
            expect(find.byType(ProxyFormPage), findsOneWidget);
          },
        );
        await tester.tap(keyed('proxy-save'));
        await tester.pump();
        expect(handled, 0);
        pending.completeError(failure);
        await tester.pumpAndSettle();
        expect(handled, 1);
        expect(find.byType(ProxyFormPage), findsOneWidget);
        expect(find.text('kept reader'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(keyed('proxy-save')).onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<TextButton>(
                find
                    .descendant(
                      of: find.byType(SnackBar),
                      matching: find.byType(TextButton),
                    )
                    .first,
              )
              .onPressed,
          isNotNull,
        );
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.textContaining('do-not-display-error-text'), findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('closed forms never acknowledge late success or failure', (
    tester,
  ) async {
    for (final fail in [false, true]) {
      final pending = Completer<void>();
      var handled = 0;
      await openForm(
        tester,
        'http',
        initialDefinition: {
          'type': 'http',
          'name': 'closed owner',
          'server': '127.0.0.1',
          'port': 1080,
        },
        onSave: (_) => pending.future,
        onSaveHandled: () => handled++,
      );
      final context = tester.element(find.byType(ProxyFormPage));
      final route = ModalRoute.of(context)!;
      final navigator = Navigator.of(context);
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      navigator.removeRoute(route);
      await tester.pumpAndSettle();
      if (fail) {
        pending.completeError(
          ConfigFailure(messages.configSavedReconnectIncomplete),
        );
      } else {
        pending.complete();
      }
      await tester.pumpAndSettle();
      expect(handled, 0);
      expect(keyed('open-proxy-form'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'pending outcome remains bound to its original feedback callback after rebuild',
    (tester) async {
      final pending = Completer<void>();
      var original = 0;
      var replacement = 0;
      final callback = ValueNotifier<VoidCallback>(() => original++);
      addTearDown(callback.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ValueListenableBuilder<VoidCallback>(
            valueListenable: callback,
            builder: (_, handled, child) => ProxyFormPage(
              initialDefinition: const {
                'type': 'http',
                'name': 'same draft',
                'server': '127.0.0.1',
                'port': 1080,
              },
              onSave: (_) => pending.future,
              onSaveHandled: handled,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      callback.value = () => replacement++;
      await tester.pump();
      pending.completeError(
        ConfigFailure(messages.configSavedReconnectIncomplete),
      );
      await tester.pumpAndSettle();
      expect(original, 1);
      expect(replacement, 0);
      expect(find.byType(ProxyFormPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('validation keeps header, save, fields, and input stable', (
    tester,
  ) async {
    var saves = 0;
    await openForm(
      tester,
      'http',
      onSave: (_) async {
        saves++;
      },
    );
    await fillScalar(tester, 'http', 'name', 'kept');
    await fillScalar(tester, 'http', 'server', '127.0.0.1');
    await fillScalar(tester, 'http', 'port', 'not-an-integer');
    final typeBefore = tester.getRect(keyed('proxy-select-type'));
    final saveBefore = tester.getRect(keyed('proxy-save'));
    final portBefore = tester.getRect(keyed('proxy-field:common/port'));
    await tester.tap(keyed('proxy-save'));
    await tester.pump();
    expect(saves, 0);
    expect(tester.getRect(keyed('proxy-select-type')), typeBefore);
    expect(tester.getRect(keyed('proxy-save')), saveBefore);
    expect(tester.getRect(keyed('proxy-field:common/port')), portBefore);
    expect(find.text('not-an-integer'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending, saved-apply-failed, and retry keep the original draft and anchors',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      final captured = <Map<String, Object?>>[];
      await openForm(
        tester,
        'http',
        onSave: (definition) {
          captured.add(definition);
          calls++;
          return calls == 1 ? pending.future : Future<void>.value();
        },
      );
      await fillScalar(tester, 'http', 'name', 'do-not-lose');
      await fillScalar(tester, 'http', 'server', '127.0.0.1');
      await fillScalar(tester, 'http', 'port', 1080);
      // Finish the SDK's input caret reveal before measuring save feedback.
      await tester.pumpAndSettle();
      final save = tester.getRect(keyed('proxy-save'));
      final type = tester.getRect(keyed('proxy-select-type'));
      final port = tester.getRect(keyed('proxy-field:common/port'));
      final scrollable = find
          .descendant(
            of: keyed('proxy-form-scroll'),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final pixels = position.pixels;
      void expectAnchors() {
        expect(tester.getRect(keyed('proxy-save')), save);
        expect(tester.getRect(keyed('proxy-select-type')), type);
        expect(tester.getRect(keyed('proxy-field:common/port')), port);
        expect(
          tester.state<ScrollableState>(scrollable).position,
          same(position),
        );
        expect(position.pixels, pixels);
      }

      await tester.tap(keyed('proxy-save'));
      for (final ms in [0, 16, 32, 80]) {
        await tester.pump(Duration(milliseconds: ms));
        expectAnchors();
      }
      expect(calls, 1);
      expect(
        tester.widget<FilledButton>(keyed('proxy-save')).onPressed,
        isNull,
      );
      expect(tester.getRect(keyed('proxy-save')), save);
      expect(tester.getRect(keyed('proxy-select-type')), type);
      await tester.tap(keyed('proxy-save'));
      await tester.pump();
      expect(calls, 1);
      pending.completeError(
        ProxyFormSaveException(messages.configSavedReconnectIncomplete),
      );
      for (final ms in [0, 16, 32, 80]) {
        await tester.pump(Duration(milliseconds: ms));
        expectAnchors();
      }
      expect(find.byType(ProxyFormPage), findsOneWidget);
      expect(find.text('do-not-lose'), findsOneWidget);
      expect(tester.getRect(keyed('proxy-save')), save);
      expect(tester.getRect(keyed('proxy-select-type')), type);
      final strings = AppLocalizations.of(
        tester.element(find.byType(ProxyFormPage)),
      );
      final details = find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.errorDetails),
      );
      for (
        var frame = 0;
        frame < 30 && details.hitTestable().evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
        expectAnchors();
      }
      expect(details.hitTestable(), findsOneWidget);
      await tester.tap(details.hitTestable());
      await tester.pumpAndSettle();
      expect(find.text(strings.configSavedReconnectIncomplete), findsOneWidget);
      await tester.tap(find.text(strings.close));
      await tester.pumpAndSettle();
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(captured[1], captured[0]);
      expect(find.byType(ProxyFormPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
