import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/ui/overrides/forms/shared/editor.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/form_interaction.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/shared/fields.dart';
import 'package:clash_pseudo/src/logic/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/provider/provider_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/rule_form.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

final fixtures = jsonDecode(
  File('test/fixtures/form_contracts/definitions.json').readAsStringSync(),
) as Map<String, dynamic>;
final generated = <String, Object?>{};
Finder keyed(String key, {bool offstage = false}) =>
    find.byKey(ValueKey(key), skipOffstage: !offstage);

Future<void> expandAncestors(WidgetTester tester, Finder target) async {
  final elements = <Element>[];
  tester.element(target).visitAncestorElements((element) {
    if (element.widget is Expansible) elements.add(element);
    return true;
  });
  for (final element in elements.reversed) {
    final tile = find.byWidget(element.widget, skipOffstage: false);
    final header = find
        .descendant(
          of: tile,
          matching: find.byType(ListTile, skipOffstage: false),
        )
        .first;
    final controller = ExpansibleController.of(tester.element(header));
    if (!controller.isExpanded) {
      controller.expand();
      await tester.pumpAndSettle();
    }
  }
}

Future<void> openForm(
  WidgetTester tester,
  Widget page, {
  Locale locale = const Locale('en'),
  TextScaler scaler = TextScaler.noScaling,
  Size size = const Size(440, 900),
  GlobalKey<NavigatorState>? navigator,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(const SizedBox());
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [AppTaskNavigatorObserver()],
      navigatorKey: navigator,
      theme: ThemeData(brightness: brightness),
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
            key: const ValueKey('open'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<Object>(
                builder: (_) => OperationNoticeHost(child: page),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(keyed('open'));
  await tester.pumpAndSettle();
}

Future<void> dismissNotice(WidgetTester tester) async {
  if (find.byType(SnackBar).evaluate().isEmpty) return;
  await tester.pumpAndSettle();
  final close = find
      .descendant(
        of: find.byType(SnackBar),
        matching: find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.onPressed != null,
        ),
      )
      .hitTestable();
  if (close.evaluate().isEmpty) return;
  await tester.tap(close);
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await expandAncestors(tester, finder);
  if (finder.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(finder);
    await tester.pump();
  }
  if (finder.hitTestable().evaluate().isEmpty) {
    await dismissNotice(tester);
  }
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String id, String? value) async {
  await tap(tester, keyed('definition-menu:$id', offstage: true));
  final optionKey = ValueKey(value ?? '\u0000unset');
  final item = find.byWidgetPredicate(
    (widget) => widget is MenuItemButton && widget.key == optionKey,
  );
  expect(item, findsOneWidget);
  await tap(tester, item);
}

Future<void> text(WidgetTester tester, String id, String value) async {
  final presence = keyed('definition-presence:$id', offstage: true);
  if (presence.evaluate().isNotEmpty &&
      !tester.widget<Switch>(presence).value) {
    await tap(tester, presence);
  }
  final field = keyed('definition-input:$id', offstage: true);
  await expandAncestors(tester, field);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> list(WidgetTester tester, String id, List<dynamic> values) async {
  if (values.isEmpty) {
    await tap(tester, keyed('definition-presence:$id', offstage: true));
    return;
  }
  for (final (index, value) in values.indexed) {
    await tap(tester, keyed('definition-add:$id', offstage: true));
    await text(tester, '$id/$index', value as String);
  }
}

Future<void> proxyText(WidgetTester tester, String id, String value) async {
  final field = find.descendant(
    of: keyed('proxy-field:$id'),
    matching: find.byType(TextField),
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> addProxy(
  WidgetTester tester,
  Map<String, Object?> definition,
) async {
  await tap(tester, keyed('provider-add-proxy'));
  expect(find.byType(ProxyFormPage), findsOneWidget);
  for (final key in ['name', 'server', 'port']) {
    await proxyText(tester, 'common/$key', '${definition[key]}');
  }
  await tap(tester, keyed('proxy-save'));
  expect(find.byType(ProxyFormPage), findsNothing);
}

Future<void> fill(
  WidgetTester tester,
  String scope,
  Map<String, Object?> values,
) async {
  for (final entry in values.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key == 'type') continue;
    final id = '$scope/$key';
    if (value is bool || keyed('definition-menu:$id').evaluate().isNotEmpty) {
      await choose(tester, id, '$value');
    } else if (scope == 'provider' &&
        key == 'payload' &&
        value is List &&
        value.firstOrNull is Map) {
      for (final node in value) {
        await addProxy(tester, Map<String, Object?>.from(node as Map));
      }
    } else if (key == 'header' && value is Map) {
      for (final (index, header) in value.entries.indexed) {
        await tap(tester, keyed('definition-add:$id', offstage: true));
        await text(tester, '$id/$index/key', header.key as String);
        if ((header.value as List).isNotEmpty) {
          await list(tester, '$id/$index/values', header.value as List);
        }
        await tap(tester, keyed('definition-save-header:$id/$index'));
      }
    } else if (key == 'proxy-name' && value is List) {
      for (final (index, row) in value.indexed) {
        await tap(tester, keyed('definition-add:$id', offstage: true));
        await text(
          tester,
          '$id/$index/pattern',
          (row as Map)['pattern'] as String,
        );
        await text(tester, '$id/$index/target', row['target'] as String);
      }
    } else if (value is Map) {
      await fill(tester, id, Map<String, Object?>.from(value));
    } else if (value is List) {
      await list(tester, id, value);
    } else if (value != null) {
      await text(tester, id, '$value');
    }
  }
}

void main() {
  for (final originalType in ['url-test', 'load-balance', 'select']) {
    testWidgets(
      '$originalType only changes its discriminator, never hidden originals',
      (tester) async {
        final original = <String, Object?>{
          'name': 'captured group',
          'type': originalType,
          'tolerance': 0,
          'default-selected': '',
          'strategy': 'future-strategy',
          'hash-key': null,
          'proxies': <String>[],
          'use': <String>[],
          'lazy': false,
          'interval': 0,
          'filter': null,
          'future': {
            'false': false,
            'zero': 0,
            'null': null,
            'map': <String, Object?>{},
            'list': <Object?>[],
          },
        };
        final seen = <Map<String, Object?>>[];
        await openForm(
          tester,
          StrategyGroupFormPage(
            initialDefinition: original,
            onSave: (value) async {
              seen.add(value);
              throw ConfigFailure(messages.storageContextChanged);
            },
          ),
        );
        for (final type in [
          'fallback',
          'select',
          'load-balance',
          'url-test',
          originalType,
        ]) {
          await choose(tester, 'group/type', type);
          await tap(tester, keyed('definition-save:group'));
          expect(seen.last, {...original, 'type': type});
        }
        await text(tester, 'group/name', 'edited group');
        await tap(tester, keyed('definition-save:group'));
        expect(seen.last, {...original, 'name': 'edited group'});
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final kind in ['proxy', 'provider', 'group']) {
    testWidgets(
      '$kind original reader uses captured source, never reserialized YAML',
      (tester) async {
        const raw =
            "{ quoted: 'yes', flag: false, count: 0, empty: [], nullable: null }\r\n";
        final requests = <List<Object>>[];
        String? originalText(List<Object> path) {
          requests.add(List.of(path));
          return path.last == 'tls' ||
                  path.last == 'header' ||
                  path.last == 'lazy'
              ? raw
              : null;
        }

        final value = {
          'quoted': 'yes',
          'flag': false,
          'count': 0,
          'empty': <Object?>[],
          'nullable': null,
        };
        final original = <String, Object?>{
          'type': kind == 'group' ? 'select' : 'http',
          if (kind != 'provider') 'name': 'captured identity',
          if (kind == 'proxy') ...{
            'server': 'fixture.invalid',
            'port': 443,
            'tls': value,
          },
          if (kind == 'provider') ...{
            'url': 'https://fixture.invalid',
            'header': value,
          },
          if (kind == 'group') 'lazy': value,
        };
        final path = kind == 'proxy'
            ? 'http/tls'
            : kind == 'provider'
            ? 'provider/header'
            : 'group/lazy';
        Object? saved;
        await openForm(tester, switch (kind) {
          'proxy' => ProxyFormPage(
            initialDefinition: original,
            originalValueText: originalText,
            onSave: (value) async => saved = value,
          ),
          'provider' => ProviderFormPage(
            ruleProvider: false,
            initialName: 'captured identity',
            initialDefinition: original,
            originalValueText: originalText,
            onSave: (_, value) async => saved = value,
          ),
          _ => StrategyGroupFormPage(
            initialDefinition: original,
            originalValueText: originalText,
            onSave: (value) async => saved = value,
          ),
        });
        await tap(
          tester,
          keyed('definition-view-original:$path', offstage: true),
        );
        final reader = tester.widget<OriginalTextView>(
          find.byType(OriginalTextView),
        );
        expect(reader.text, raw);
        expect(reader.identity, isNotNull);
        expect(
          requests,
          anyElement(orderedEquals(<Object>[path.split('/').last])),
        );
        expect(find.byType(Dialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tap(
          tester,
          keyed(kind == 'proxy' ? 'proxy-save' : 'definition-save:$kind'),
        );
        expect(saved, original);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final kind in ['group', 'provider', 'rule']) {
    testWidgets(
      '$kind pending save keeps its originating acknowledgement after rebuild',
      (tester) async {
        final pending = Completer<void>();
        var originalHandled = 0;
        var replacementHandled = 0;
        final callback = ValueNotifier<VoidCallback>(() => originalHandled++);
        addTearDown(callback.dispose);
        await openForm(
          tester,
          ValueListenableBuilder<VoidCallback>(
            valueListenable: callback,
            builder: (_, handled, _) => switch (kind) {
              'group' => StrategyGroupFormPage(
                initialDefinition: const {
                  'name': 'captured group',
                  'type': 'select',
                },
                onSave: (_) => pending.future,
                onSaveHandled: handled,
              ),
              'provider' => ProviderFormPage(
                ruleProvider: false,
                initialName: 'captured provider',
                initialDefinition: const {
                  'type': 'http',
                  'url': 'https://fixture.invalid',
                },
                onSave: (_, _) => pending.future,
                onSaveHandled: handled,
              ),
              _ => RuleFormPage(
                targets: const ['DIRECT'],
                initialRule: 'DOMAIN,fixture.invalid,DIRECT',
                onSave: (_) => pending.future,
                onSaveHandled: handled,
              ),
            },
          ),
        );
        await tester.tap(keyed('definition-save:$kind'));
        await tester.pump();
        callback.value = () => replacementHandled++;
        await tester.pump();
        pending.completeError(
          ConfigFailure(messages.configSavedReconnectIncomplete),
        );
        await tester.pumpAndSettle();
        expect(originalHandled, 1);
        expect(replacementHandled, 0);
        expect(keyed('definition-save:$kind'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final retirement in ['identity', 'section']) {
    testWidgets(
      'captured original reader rejects late clipboard feedback after $retirement retirement',
      (tester) async {
        const raw = "{ quoted: 'yes', nullable: null }\r\n";
        var identity = Object();
        var visible = true;
        late StateSetter update;
        final pending = Completer<void>();
        var copies = 0;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copies++;
            expect((call.arguments as Map)['text'], raw);
            await pending.future;
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await openForm(
          tester,
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return DefinitionEditor(
                dirty: false,
                saving: false,
                onSave: () {},
                child: Scaffold(
                  body: DefinitionFormVisibility(
                    visible: visible,
                    child: DefinitionOriginalField(
                      key: const ValueKey('captured-original'),
                      id: 'captured/value',
                      label: 'captured value',
                      identity: identity,
                      originalValue: const {'quoted': 'yes', 'nullable': null},
                      originalText: raw,
                    ),
                  ),
                ),
              );
            },
          ),
        );
        await tap(tester, keyed('definition-view-original:captured/value'));
        final reader = tester.widget<OriginalTextView>(
          find.byType(OriginalTextView),
        );
        expect(reader.isCurrent!(), isTrue);
        final copy = keyed('original-text-copy');
        await tester.tap(copy);
        await tester.pump();
        expect(copies, 1);
        update(() {
          if (retirement == 'identity') {
            identity = Object();
          } else {
            visible = false;
          }
        });
        await tester.pump();
        expect(reader.isCurrent!(), isFalse);
        pending.completeError(
          PlatformFailure(code: 'controlled clipboard failure'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(OriginalTextView), findsOneWidget);
        await tester.tap(copy);
        await tester.pump();
        expect(copies, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'explicit null originals expose the actual model value without fabricated source',
    (tester) async {
      await openForm(
        tester,
        const Scaffold(
          body: DefinitionOriginalField(
            id: 'captured/null',
            label: 'nullable',
            originalValue: null,
          ),
        ),
      );
      expect(find.text('null'), findsOneWidget);
      expect(keyed('definition-view-original:captured/null'), findsNothing);
      expect(find.byType(OriginalTextView), findsNothing);
    },
  );
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });
  tearDownAll(() {
    final output = Platform.environment['DEFINITION_FORMS_OUTPUT'];
    if (output != null) {
      File(output).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(generated)}\n',
      );
    }
  });
  for (final raw in fixtures['groups'] as List) {
    final item = raw as Map;
    final expected = <String, Object?>{
      ...fixtures['groupCommon'] as Map<String, dynamic>,
      ...item['special'] as Map<String, dynamic>,
    };
    final type = expected['type'] as String;
    testWidgets('all public $type group fields produce the exact definition', (
      tester,
    ) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        StrategyGroupFormPage(
          initialType: type,
          onSave: (value) async {
            actual = value;
          },
        ),
      );
      await fill(tester, 'group', expected);
      await tap(tester, keyed('definition-save:group'));
      expect(tester.takeException(), isNull);
      expect(actual, expected);
      final yaml = LocalYamlEdit('{}').addStrategyGroup(actual!);
      expect((loadYaml(yaml)['proxy-groups'] as List).single, expected);
      generated['group/$type'] = {'definition': actual, 'yaml': yaml};
      expect(find.byType(StrategyGroupFormPage), findsNothing);
    });
  }

  for (final transport in fixtures['transports'] as List) {
    final type = transport['type'] as String;
    final expected = <String, Object?>{
      ...transport as Map<String, dynamic>,
      ...fixtures['proxyProviderCommon'] as Map<String, dynamic>,
    };
    testWidgets(
      'all public proxy-provider $type fields and real node draft editor',
      (tester) async {
        Map<String, Object?>? actual;
        String? name;
        await openForm(
          tester,
          ProviderFormPage(
            ruleProvider: false,
            initialType: type,
            onSave: (key, value) async {
              name = key;
              actual = value;
            },
          ),
        );
        await text(tester, 'provider/name', 'fixture-provider');
        await fill(tester, 'provider', expected);
        await tap(tester, keyed('definition-save:provider'));
        expect(tester.takeException(), isNull);
        expect(name, 'fixture-provider');
        expect(actual, expected);
        final yaml = LocalYamlEdit('{}').addProxyProvider(name!, actual!);
        expect(loadYaml(yaml)['proxy-providers'][name], expected);
        generated['proxy-provider/$type'] = {
          'name': name,
          'definition': actual,
          'yaml': yaml,
        };
        expect(find.byType(ProviderFormPage), findsNothing);
      },
    );
    for (final behavior in fixtures['ruleProviders'] as List) {
      final expected = <String, Object?>{
        ...transport,
        ...behavior as Map<String, dynamic>,
      }..remove('id');
      if (type == 'inline') expected.remove('path-in-bundle');
      final id = '$type/${behavior['id']}';
      testWidgets(
        'rule-provider $id preserves payload, format, headers and path',
        (tester) async {
          Map<String, Object?>? actual;
          await openForm(
            tester,
            ProviderFormPage(
              ruleProvider: true,
              initialType: type,
              onSave: (key, value) async {
                expect(key, 'fixture-rules');
                actual = value;
              },
            ),
          );
          await text(tester, 'provider/name', 'fixture-rules');
          await fill(tester, 'provider', expected);
          await tap(tester, keyed('definition-save:provider'));
          expect(tester.takeException(), isNull);
          expect(actual, expected);
          final yaml = LocalYamlEdit('{}')
              .addRuleProvider('fixture-rules', actual!);
          expect(loadYaml(yaml)['rule-providers']['fixture-rules'], expected);
          expect(
            loadYaml(yaml)['rules'],
            isNull,
          ); // Never invent a RULE-SET reference.
          generated['rule-provider/$id'] = {
            'name': 'fixture-rules',
            'definition': actual,
            'yaml': yaml,
          };
        },
      );
    }
  }

  test(
    'fixtures and actual raw token UI cover exactly 37 supported rule types',
    () {
      expect(
        (fixtures['rules'] as List).map((row) => row[0]).toSet(),
        ruleFormTypes.toSet(),
      );
      expect(ruleFormTypes, hasLength(37));
    },
  );
  for (final row in fixtures['rules'] as List) {
    final type = row[0] as String;
    final payload = row[1] as String?;
    final target = type == 'SUB-RULE' ? 'child-set' : 'future outbound';
    testWidgets(
      '$type emits its native rule without inferred aliases or fields',
      (tester) async {
        String? actual;
        await openForm(
          tester,
          RuleFormPage(
            initialType: type,
            initialValue: payload,
            initialTarget: target,
            targets: const [],
            onSave: (value) async {
              actual = value;
            },
          ),
        );
        if (type == 'MATCH') {
          expect(keyed('definition-input:rule/value'), findsNothing);
        }
        await tap(tester, keyed('definition-save:rule'));
        final expected = [type, ?payload, target].join(',');
        expect(tester.takeException(), isNull);
        expect(actual, expected);
        final yaml = LocalYamlEdit("rules: ['MATCH,DIRECT']").addRule(actual!);
        expect((loadYaml(yaml)['rules'] as List).first, actual);
        generated['rule/$type'] = {
          'rule': actual,
          'type': type,
          'payload': payload ?? '',
          'target': target,
          'yaml': yaml,
        };
      },
    );
  }

  testWidgets(
    'optional group values omitted, explicit empty collections and strings retained',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        StrategyGroupFormPage(
          onSave: (value) async {
            actual = value;
          },
        ),
      );
      await text(tester, 'group/name', 'minimal');
      await list(tester, 'group/proxies', []);
      await text(tester, 'group/filter', '');
      await choose(tester, 'group/lazy', 'false');
      await text(tester, 'group/interval', '0');
      await tap(tester, keyed('definition-save:group'));
      expect(actual, {
        'type': 'select',
        'name': 'minimal',
        'proxies': <String>[],
        'filter': '',
        'lazy': false,
        'interval': 0,
      });
    },
  );

  testWidgets(
    'inactive group branch skips invalid fields and recovers its unchanged draft',
    (tester) async {
      final seen = <Map<String, Object?>>[];
      await openForm(
        tester,
        StrategyGroupFormPage(
          initialType: 'url-test',
          onSave: (value) async {
            seen.add(value);
            throw ConfigFailure(messages.storageContextChanged);
          },
        ),
      );
      await text(tester, 'group/name', 'manual');
      await text(tester, 'group/tolerance', '70000');
      await choose(tester, 'group/type', 'fallback');
      await tap(tester, keyed('definition-save:group'));
      expect(seen.single, {'type': 'fallback', 'name': 'manual'});
      await choose(tester, 'group/type', 'url-test');
      expect(
        tester
            .widget<TextField>(keyed('definition-input:group/tolerance'))
            .controller!
            .text,
        '70000',
      );
      await tap(tester, keyed('definition-save:group'));
      expect(seen, hasLength(1));
    },
  );

  testWidgets(
    'all load balance strategies are selectable and do not invent a hash key',
    (tester) async {
      final seen = <Map<String, Object?>>[];
      await openForm(
        tester,
        StrategyGroupFormPage(
          initialType: 'load-balance',
          onSave: (value) async {
            seen.add(value);
            throw ConfigFailure(messages.storageContextChanged);
          },
        ),
      );
      await text(tester, 'group/name', 'manual');
      for (final strategy in [
        'consistent-hashing',
        'round-robin',
        'sticky-sessions',
      ]) {
        await choose(tester, 'group/strategy', strategy);
        await tap(tester, keyed('definition-save:group'));
        expect(seen.last, {
          'type': 'load-balance',
          'name': 'manual',
          'strategy': strategy,
        });
      }
      await choose(tester, 'group/hash-key', 'in-user');
      await choose(tester, 'group/strategy', 'round-robin');
      await tap(tester, keyed('definition-save:group'));
      expect(seen, hasLength(3));
      await choose(tester, 'group/hash-key', '');
      await tap(tester, keyed('definition-save:group'));
      expect(seen.last, {
        'type': 'load-balance',
        'name': 'manual',
        'strategy': 'round-robin',
        'hash-key': '',
      });
      await choose(tester, 'group/strategy', 'consistent-hashing');
      await choose(tester, 'group/hash-key', 'in-user');
      await tap(tester, keyed('definition-save:group'));
      expect(seen.last['hash-key'], 'in-user');
    },
  );

  testWidgets(
    'provider pointer strings, false and zero do not inject other defaults',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        ProviderFormPage(
          ruleProvider: false,
          initialType: 'inline',
          onSave: (_, value) async {
            actual = value;
          },
        ),
      );
      await text(tester, 'provider/name', 'minimal');
      await text(tester, 'provider/override/additional-prefix', '');
      await choose(tester, 'provider/override/udp', 'false');
      await text(tester, 'provider/override/routing-mark', '0');
      await tap(tester, keyed('definition-presence:provider/payload'));
      await tap(tester, keyed('definition-save:provider'));
      expect(actual, {
        'type': 'inline',
        'override': {'additional-prefix': '', 'udp': false, 'routing-mark': 0},
        'payload': <Object?>[],
      });
    },
  );

  for (final ruleProvider in [false, true]) {
    testWidgets(
      '${ruleProvider ? 'rule' : 'proxy'} provider source switches retain every untouched original field',
      (tester) async {
        final original = <String, Object?>{
          'type': 'http',
          'url': 'https://fixture.invalid/provider',
          'path': 'providers/original.yaml',
          'proxy': '',
          'header': <String, Object?>{},
          'size-limit': 0,
          'interval': 0,
          'payload': <Object?>[],
          'unknown': {'null': null, 'empty': <Object?>[], 'flag': false},
          if (ruleProvider) ...{
            'behavior': 'domain',
            'format': 'yaml',
            'path-in-bundle': '',
          } else ...{
            'health-check': {'enable': false, 'unknown': null},
            'override': <String, Object?>{},
          },
        };
        final seen = <Map<String, Object?>>[];
        await openForm(
          tester,
          ProviderFormPage(
            ruleProvider: ruleProvider,
            initialName: 'original identity',
            initialDefinition: original,
            onSave: (name, value) async {
              expect(name, 'original identity');
              seen.add(value);
              throw ConfigFailure(messages.storageContextChanged);
            },
          ),
        );
        for (final type in ['file', 'inline', 'http']) {
          await choose(tester, 'provider/type', type);
          await tap(tester, keyed('definition-save:provider'));
          expect(seen.last, {...original, 'type': type});
          expect(find.byType(ProviderFormPage), findsOneWidget);
        }
        expect(seen, hasLength(3));
        expect(original['type'], 'http');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'provider source round trip preserves the same input controller and edited draft',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        ProviderFormPage(
          ruleProvider: false,
          initialName: 'identity',
          initialDefinition: const {
            'type': 'http',
            'url': 'https://fixture.invalid/original',
            'path': 'providers/original.yaml',
          },
          onSave: (_, value) async => actual = value,
        ),
      );
      final url = keyed('definition-input:provider/url', offstage: true);
      await text(tester, 'provider/url', 'https://fixture.invalid/edited');
      final controller = tester.widget<TextField>(url).controller;
      await choose(tester, 'provider/type', 'inline');
      expect(url.hitTestable(), findsNothing);
      expect(controller!.text, 'https://fixture.invalid/edited');
      await choose(tester, 'provider/type', 'http');
      expect(tester.widget<TextField>(url).controller, same(controller));
      await tap(tester, keyed('definition-save:provider'));
      expect(actual, {
        'type': 'http',
        'url': 'https://fixture.invalid/edited',
        'path': 'providers/original.yaml',
      });
      expect(tester.takeException(), isNull);
    },
  );

  for (final removeForm in [false, true]) {
    testWidgets(
      'provider late save ${removeForm ? 'does not acknowledge a removed form' : 'retains its covered route without borrowing navigation'}',
      (tester) async {
        final pending = Completer<void>();
        var handled = 0;
        var calls = 0;
        var completed = 0;
        String? savedName;
        Map<String, Object?>? savedDefinition;
        const original = <String, Object?>{
          'type': 'inline',
          'payload': <Object?>[],
          'unknown': {'flag': false, 'null': null},
        };
        await openForm(
          tester,
          ProviderFormPage(
            ruleProvider: false,
            initialName: 'captured identity',
            initialDefinition: original,
            onSaveHandled: () => handled++,
            onSave: (name, value) {
              savedName = name;
              savedDefinition = value;
              if (!removeForm) {
                calls++;
                return pending.future.then<void>((_) {
                  completed++;
                });
              }
              return pending.future;
            },
          ),
        );
        final context = tester.element(find.byType(ProviderFormPage));
        final ownRoute = ModalRoute.of(context)!;
        final navigator = Navigator.of(context);
        final save = keyed('definition-save:provider');
        final oldSave = removeForm
            ? null
            : tester.widget<FilledButton>(save).onPressed!;
        var returned = false;
        if (!removeForm) {
          unawaited(
            ownRoute.popped.then<void>((_) {
              returned = true;
            }),
          );
        }
        await tester.tap(keyed('definition-save:provider'));
        await tester.pump();
        if (removeForm) {
          navigator.removeRoute(ownRoute);
        } else {
          unawaited(
            navigator.push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    Scaffold(appBar: AppBar(), body: const Text('cover route')),
              ),
            ),
          );
        }
        await tester.pumpAndSettle();
        pending.complete();
        await tester.pumpAndSettle();
        expect(savedName, 'captured identity');
        expect(savedDefinition, original);
        expect(handled, removeForm ? 0 : 1);
        if (removeForm) {
          expect(ownRoute.isActive, isFalse);
          expect(
            find.byType(ProviderFormPage, skipOffstage: false),
            findsNothing,
          );
          expect(keyed('open'), findsOneWidget);
        } else {
          expect(calls, 1);
          expect(completed, 1);
          expect(ownRoute.isActive, isTrue);
          expect(ownRoute.isCurrent, isFalse);
          expect(returned, isFalse);
          final form = find.byType(ProviderFormPage, skipOffstage: false);
          expect(form, findsOneWidget);
          expect(tester.element(form), same(context));
          final cover = find.text('cover route');
          expect(cover, findsOneWidget);
          final coverRoute = ModalRoute.of(tester.element(cover))!;
          expect(coverRoute.isCurrent, isTrue);
          navigator.pop();
          await tester.pump();
          await tester.pump(coverRoute.reverseTransitionDuration);
          await tester.pump();
          expect(ownRoute.isCurrent, isTrue);
          expect(tester.element(form), same(context));
          expect(returned, isFalse);
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          final progress = find.descendant(
            of: save,
            matching: find.byType(CircularProgressIndicator),
          );
          expect(progress, findsNothing);
          oldSave!();
          await tester.pump();
          expect(calls, 1);
          expect(completed, 1);
          expect(savedName, 'captured identity');
          expect(savedDefinition, original);
          expect(handled, 1);
          expect(ownRoute.isCurrent, isTrue);
          expect(tester.element(form), same(context));
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          expect(returned, isFalse);
        }
        expect(tester.takeException(), isNull);
        if (!removeForm) await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'MRS/classical is rejected without moving save or field anchors; correcting retains payload',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        ProviderFormPage(
          ruleProvider: true,
          initialType: 'inline',
          onSave: (_, value) async {
            actual = value;
          },
        ),
        size: const Size(320, 860),
        scaler: const TextScaler.linear(2),
      );
      await text(tester, 'provider/name', 'rules');
      await choose(tester, 'provider/behavior', 'classical');
      await choose(tester, 'provider/format', 'mrs');
      final saveRect = tester.getRect(keyed('definition-save:provider'));
      final errorContext = tester.element(
        keyed('definition-choice:provider/format'),
      );
      final field = errorContext as StatefulElement;
      final before = tester.getSize(keyed('definition-choice:provider/format'));
      (field.state as FormFieldState<String>).validate();
      await tester.pump();
      expect(
        tester.getSize(keyed('definition-choice:provider/format')),
        before,
      );
      expect(tester.getRect(keyed('definition-save:provider')), saveRect);
      await tap(tester, keyed('definition-save:provider'));
      expect(actual, isNull);
      await choose(tester, 'provider/format', 'text');
      await tap(tester, keyed('definition-save:provider'));
      expect(actual, {
        'type': 'inline',
        'behavior': 'classical',
        'format': 'text',
      });
      expect(tester.takeException(), isNull);
    },
  );

  test('managed relative path validation never rewrites or promises symlink checks', () {
    for (final path in [
      '',
      'providers/cache.yaml',
      './providers/cache.yaml',
      'providers//cache.yaml',
      '规则/缓存.yaml',
    ]) {
      expect(isManagedProviderRelativePath(path), isTrue, reason: path);
    }
    for (final path in [
      '/data/cache',
      '../outside',
      'a/../outside',
      'C:\\cache',
      'a\\cache',
      '.',
      'a/',
      'a/\u0000bad',
    ]) {
      expect(isManagedProviderRelativePath(path), isFalse, reason: path);
    }
  });

  testWidgets(
    'HTTP optional path can become required file path without disabling its input',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        ProviderFormPage(
          ruleProvider: true,
          onSave: (_, value) async {
            actual = value;
          },
        ),
      );
      await text(tester, 'provider/name', 'rules');
      await choose(tester, 'provider/behavior', 'domain');
      await choose(tester, 'provider/type', 'file');
      expect(
        tester
            .widget<TextField>(keyed('definition-input:provider/path'))
            .enabled,
        isTrue,
      );
      await text(tester, 'provider/path', 'providers/file.yaml');
      await tap(tester, keyed('definition-save:provider'));
      expect(actual, {
        'type': 'file',
        'behavior': 'domain',
        'path': 'providers/file.yaml',
      });
    },
  );

  testWidgets(
    'duplicate header keys do not overwrite draft rows; values stay string lists',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        ProviderFormPage(
          ruleProvider: true,
          onSave: (_, value) async {
            actual = value;
          },
        ),
      );
      await fill(tester, 'provider', {
        'name': 'rules',
        'url': 'https://fixture.invalid/rules',
        'behavior': 'domain',
        'header': {
          'X-First': ['one'],
          'X-Second': ['two'],
        },
      });
      await tap(tester, keyed('definition-edit:provider/header/1'));
      await text(tester, 'provider/header/1/key', 'X-First');
      await tap(tester, keyed('definition-save-header:provider/header/1'));
      expect(actual, isNull);
      expect(
        find.byKey(const ValueKey('definition-input:provider/header/1/key')),
        findsOneWidget,
      );
      await text(tester, 'provider/header/1/key', 'X-Second');
      await tap(tester, keyed('definition-save-header:provider/header/1'));
      await tap(tester, keyed('definition-save:provider'));
      expect(actual!['header'], {
        'X-First': ['one'],
        'X-Second': ['two'],
      });
    },
  );

  testWidgets(
    'member reordering and removal preserve other row identities, text and order',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        StrategyGroupFormPage(
          onSave: (value) async {
            actual = value;
          },
        ),
      );
      await text(tester, 'group/name', 'ordered');
      await list(tester, 'group/proxies', ['first', 'second', 'third']);
      await tap(tester, keyed('definition-up:group/proxies/2'));
      await tap(tester, keyed('definition-remove:group/proxies/0'));
      expect(
        tester
            .widget<TextField>(keyed('definition-input:group/proxies/1'))
            .controller!
            .text,
        'second',
      );
      expect(
        tester
            .widget<TextField>(keyed('definition-input:group/proxies/2'))
            .controller!
            .text,
        'third',
      );
      await tap(tester, keyed('definition-save:group'));
      expect(actual!['proxies'], ['third', 'second']);
    },
  );

  testWidgets(
    'inline node edit cancel preserves parent; save replaces only original GUI draft',
    (tester) async {
      Map<String, Object?>? actual;
      await openForm(
        tester,
        ProviderFormPage(
          ruleProvider: false,
          initialType: 'inline',
          onSave: (_, value) async {
            actual = value;
          },
        ),
      );
      await text(tester, 'provider/name', 'inline');
      await addProxy(tester, {
        'name': 'first',
        'server': '127.0.0.1',
        'port': 1080,
      });
      await tap(tester, keyed('provider-edit-proxy:0'));
      await proxyText(tester, 'common/name', 'discarded');
      Navigator.of(tester.element(find.byType(ProxyFormPage))).pop();
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      expect(find.text('discarded'), findsNothing);
      await tap(tester, keyed('provider-edit-proxy:0'));
      final original = find.descendant(
        of: keyed('proxy-field:common/name'),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(original).controller!.text, 'first');
      await proxyText(tester, 'common/name', 'edited');
      await tap(tester, keyed('proxy-save'));
      await tap(tester, keyed('definition-save:provider'));
      expect(actual!['payload'], [
        {'name': 'edited', 'type': 'http', 'server': '127.0.0.1', 'port': 1080},
      ]);
    },
  );

  testWidgets(
    'rule flags are literal options only on parser-supported families',
    (tester) async {
      final seen = <String>[];
      await openForm(
        tester,
        RuleFormPage(
          initialType: 'IP-CIDR',
          initialValue: '192.0.2.0/24',
          initialTarget: 'DIRECT',
          targets: const ['DIRECT'],
          onSave: (value) async {
            seen.add(value);
            throw ConfigFailure(messages.storageContextChanged);
          },
        ),
      );
      await tap(tester, keyed('rule-src'));
      await tap(tester, keyed('rule-no-resolve'));
      await tap(tester, keyed('definition-save:rule'));
      expect(seen.last, 'IP-CIDR,192.0.2.0/24,DIRECT,src,no-resolve');
      generated['rule/flags'] = {
        'rule': seen.last,
        'yaml': LocalYamlEdit("rules: ['MATCH,DIRECT']").addRule(seen.last),
        'type': 'IP-CIDR',
        'payload': '192.0.2.0/24',
        'target': 'DIRECT',
        'params': ['src', 'no-resolve'],
      };
      await choose(tester, 'rule/type', 'SRC-IP-CIDR');
      expect(keyed('rule-src'), findsNothing);
      await tap(tester, keyed('definition-save:rule'));
      expect(seen.last, 'SRC-IP-CIDR,192.0.2.0/24,DIRECT');
      await choose(tester, 'rule/type', 'MATCH');
      await tap(tester, keyed('definition-save:rule'));
      expect(seen.last, 'MATCH,DIRECT');
    },
  );

  testWidgets(
    'SUB-RULE target is independent of outbound; RULE-SET payload uses provider namespace',
    (tester) async {
      final seen = <String>[];
      await openForm(
        tester,
        RuleFormPage(
          initialTarget: 'outbound',
          initialValue: 'example.test',
          targets: const ['outbound'],
          subRules: const ['child'],
          ruleProviders: const ['resource'],
          onSave: (value) async {
            seen.add(value);
            throw ConfigFailure(messages.storageContextChanged);
          },
        ),
      );
      await choose(tester, 'rule/type', 'SUB-RULE');
      await text(tester, 'rule/sub-rule', 'child');
      await text(
        tester,
        'rule/condition',
        '(AND,((DOMAIN,example.test),(DST-PORT,443)))',
      );
      await tap(tester, keyed('definition-save:rule'));
      expect(
        seen.last,
        'SUB-RULE,(AND,((DOMAIN,example.test),(DST-PORT,443))),child',
      );
      await choose(tester, 'rule/type', 'RULE-SET');
      await text(tester, 'rule/provider', 'resource');
      await tap(tester, keyed('definition-save:rule'));
      expect(seen.last, 'RULE-SET,resource,outbound');
    },
  );

  for (final target in ['bad,name', ' leading', 'trailing ']) {
    testWidgets(
      'rule rejects unrepresentable target [$target] without trimming input',
      (tester) async {
        var saves = 0;
        await openForm(
          tester,
          RuleFormPage(
            initialType: 'MATCH',
            initialTarget: target,
            targets: const [],
            onSave: (_) async {
              saves++;
            },
          ),
        );
        await tap(tester, keyed('definition-save:rule'));
        expect(saves, 0);
        expect(
          tester
              .widget<TextField>(keyed('definition-input:rule/target'))
              .controller!
              .text,
          target,
        );
      },
    );
  }
  testWidgets(
    'regex comma is preserved but comma-space normalization is not silently accepted',
    (tester) async {
      var saves = 0;
      await openForm(
        tester,
        RuleFormPage(
          initialType: 'DOMAIN-REGEX',
          initialValue: 'a, b',
          initialTarget: 'DIRECT',
          targets: const [],
          onSave: (_) async {
            saves++;
          },
        ),
      );
      await tap(tester, keyed('definition-save:rule'));
      expect(saves, 0);
      expect(
        tester
            .widget<TextField>(keyed('definition-input:rule/value'))
            .controller!
            .text,
        'a, b',
      );
      await text(tester, 'rule/value', 'a,[ ]b');
      await tap(tester, keyed('definition-save:rule'));
      expect(saves, 1);
    },
  );

  for (final (kind, language) in [
    for (final kind in ['group', 'provider', 'rule'])
      for (final language in ['en', 'zh']) (kind, language),
  ]) {
    testWidgets(
      '$kind $language keeps geometry, input, and privacy through pending/failure/retry and covered success',
      (tester) async {
        final copiedDetails = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copiedDetails.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final navigator = GlobalKey<NavigatorState>();
        var pending = Completer<void>();
        var calls = 0;
        Future<void> save() {
          calls++;
          return pending.future;
        }

        final page = switch (kind) {
          'group' => StrategyGroupFormPage(onSave: (_) => save()),
          'provider' => ProviderFormPage(
            ruleProvider: true,
            initialType: 'inline',
            onSave: (_, _) => save(),
          ),
          _ => RuleFormPage(
            initialType: 'MATCH',
            initialTarget: 'DIRECT',
            targets: const ['DIRECT'],
            onSave: (_) => save(),
          ),
        };
        await openForm(
          tester,
          page,
          navigator: navigator,
          size: const Size(320, 720),
          scaler: const TextScaler.linear(2),
          locale: Locale(language),
          brightness: language == 'en' ? Brightness.dark : Brightness.light,
        );
        final origin = tester.element(find.byType(page.runtimeType));
        final ownRoute = ModalRoute.of(origin)!;
        final oldSave = tester
            .widget<FilledButton>(keyed('definition-save:$kind'))
            .onPressed!;
        var returned = false;
        unawaited(
          ownRoute.popped.then<void>((_) {
            returned = true;
          }),
        );
        if (kind != 'rule') await text(tester, '$kind/name', '很长的自定义名称-不会丢失');
        if (kind == 'provider') {
          await choose(tester, 'provider/behavior', 'domain');
        }
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetViewInsets);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final saveButton = keyed('definition-save:$kind');
        final bodyScroll = tester
            .widget<SingleChildScrollView>(
              find
                  .descendant(
                    of: find.byType(page.runtimeType),
                    matching: find.byType(SingleChildScrollView),
                  )
                  .first,
            )
            .controller!;
        final readingOffset = bodyScroll.offset;
        final input = keyed(
          'definition-input:$kind/${kind == 'rule' ? 'target' : 'name'}',
        );
        final inputBefore = tester.getRect(input);
        final before = tester.getRect(saveButton);
        await tester.tap(saveButton);
        await tester.pump();
        expect(calls, 1);
        expect(tester.getRect(saveButton), before);
        expect(bodyScroll.offset, readingOffset);
        expect(tester.getRect(input), inputBefore);
        expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
        for (final field in tester.widgetList<TextField>(
          find.byType(TextField),
        )) {
          expect(field.enabled, isFalse);
        }
        pending.completeError(
          StateError('private-token-synthetic-do-not-display'),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(saveButton), before);
        expect(bodyScroll.offset, readingOffset);
        expect(tester.getRect(input), inputBefore);
        expect(find.textContaining('private-token'), findsNothing);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        await tap(
          tester,
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(TextButton),
              )
              .first,
        );
        expect(find.textContaining('private-token'), findsNothing);
        await tap(tester, keyed('operation-technical-details'));
        final originalError = StateError(
          'private-token-synthetic-do-not-display',
        ).toString();
        expect(
          tester.widget<SelectableText>(keyed('operation-technical-text')).data,
          originalError,
        );
        expect(find.textContaining('private-token'), findsOneWidget);
        await tap(tester, keyed('operation-technical-copy'));
        expect(copiedDetails, [originalError]);
        final close = AppLocalizations.of(
          tester.element(find.byType(AlertDialog)),
        ).close;
        await tester.tap(find.widgetWithText(TextButton, close));
        await tester.pumpAndSettle();
        pending = Completer<void>();
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        expect(calls, 2);
        expect(tester.getRect(saveButton), before);
        var saveCompleted = false;
        unawaited(
          pending.future.then<void>((_) {
            saveCompleted = true;
          }),
        );
        final controller = tester.widget<TextField>(input).controller!;
        final inputValue = controller.value;
        final coverRoute = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        );
        unawaited(navigator.currentState!.push(coverRoute));
        await tester.pump(const Duration(milliseconds: 400));
        pending.complete();
        await tester.pumpAndSettle();
        expect(saveCompleted, isTrue);
        expect(find.text('cover'), findsOneWidget);
        expect(coverRoute.isCurrent, isTrue);
        expect(ownRoute.isActive, isTrue);
        expect(ownRoute.isCurrent, isFalse);
        expect(returned, isFalse);
        expect(
          tester.element(find.byType(page.runtimeType, skipOffstage: false)),
          same(origin),
        );
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(coverRoute.reverseTransitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        expect(find.text('cover'), findsNothing);
        expect(ownRoute.isCurrent, isTrue);
        expect(tester.element(find.byType(page.runtimeType)), same(origin));
        expect(returned, isFalse);
        expect(calls, 2);
        expect(tester.getRect(saveButton), before);
        expect(bodyScroll.offset, readingOffset);
        expect(tester.getRect(input), inputBefore);
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(controller.value, inputValue);
        expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
        final progress = find.descendant(
          of: saveButton,
          matching: find.byType(CircularProgressIndicator),
        );
        expect(progress, findsNothing);
        oldSave();
        await tester.pump();
        expect(calls, 2);
        expect(saveCompleted, isTrue);
        expect(ownRoute.isCurrent, isTrue);
        expect(tester.element(find.byType(page.runtimeType)), same(origin));
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(controller.value, inputValue);
        expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
        expect(returned, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('校验不改变字段高度且错误通过 Semantics hint 提供', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final form = GlobalKey<FormState>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Form(
              key: form,
              child: Column(
                children: [
                  DefinitionTextField(
                    id: 'test',
                    label: 'required-name',
                    required: true,
                    onSaved: (_) {},
                  ),
                  const Text('anchor', key: ValueKey('anchor')),
                ],
              ),
            ),
          ),
        ),
      );
      final before = tester.getRect(keyed('anchor'));
      expect(find.bySemanticsLabel(RegExp(r'Enter a value\.')), findsNothing);
      expect(form.currentState!.validate(), isFalse);
      await tester.pump();
      expect(tester.getRect(keyed('anchor')), before);
      expect(
        tester
            .getSemantics(keyed('definition-input:test'))
            .getSemanticsData()
            .hint,
        contains('Enter a value.'),
      );
      expect(
        tester
            .widget<TextField>(keyed('definition-input:test'))
            .decoration!
            .errorText,
        isNull,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'suggestion arrivals do not change input geometry or composing text',
    (tester) async {
      final suggestions = ValueNotifier<List<String>>(const []);
      addTearDown(suggestions.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Form(
              child: ValueListenableBuilder<List<String>>(
                valueListenable: suggestions,
                builder: (_, values, _) => DefinitionTextField(
                  id: 'suggestion',
                  label: 'target',
                  suggestions: values,
                ),
              ),
            ),
          ),
        ),
      );
      await text(tester, 'suggestion', 'draft');
      final input = tester.widget<TextField>(
        keyed('definition-input:suggestion'),
      );
      input.controller!.value = const TextEditingValue(
        text: 'draft',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      );
      final before = tester.getRect(find.byType(EditableText));
      suggestions.value = const ['new very long target suggestion'];
      await tester.pump();
      expect(tester.getRect(find.byType(EditableText)), before);
      expect(
        input.controller!.value.composing,
        const TextRange(start: 0, end: 5),
      );
    },
  );

  testWidgets(
    'connection targets are read-only suggestions, ordinary targets remain manual',
    (tester) async {
      String? actual;
      await openForm(
        tester,
        RuleFormPage(
          initialType: 'MATCH',
          targets: const ['DIRECT'],
          restrictTargets: true,
          onSave: (value) async {
            actual = value;
          },
        ),
      );
      expect(
        tester
            .widget<TextField>(keyed('definition-input:rule/target'))
            .readOnly,
        isTrue,
      );
      await tap(tester, keyed('definition-suggestions:rule/target'));
      await tap(tester, find.widgetWithText(MenuItemButton, 'DIRECT'));
      await tap(tester, keyed('definition-save:rule'));
      expect(actual, 'MATCH,DIRECT');
    },
  );

  for (final kind in ['group', 'provider', 'rule']) {
    testWidgets(
      '$kind notifies its local reader exactly once per handled result',
      (tester) async {
        var fail = true;
        var handled = 0;
        Future<void> save() async {
          if (fail) throw ConfigFailure(messages.storageContextChanged);
        }

        void notify() {
          handled++;
        }

        final page = switch (kind) {
          'group' => StrategyGroupFormPage(
            onSave: (_) => save(),
            onSaveHandled: notify,
          ),
          'provider' => ProviderFormPage(
            ruleProvider: true,
            initialType: 'inline',
            onSave: (_, _) => save(),
            onSaveHandled: notify,
          ),
          _ => RuleFormPage(
            initialType: 'MATCH',
            initialTarget: 'DIRECT',
            targets: const [],
            onSave: (_) => save(),
            onSaveHandled: notify,
          ),
        };
        await openForm(tester, page);
        if (kind != 'rule') {
          await text(tester, '$kind/name', 'draft');
        }
        if (kind == 'provider') {
          await choose(tester, 'provider/behavior', 'domain');
        }
        await tap(tester, keyed('definition-save:$kind'));
        expect(handled, 1);
        expect(find.byType(page.runtimeType), findsOneWidget);
        await tap(
          tester,
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(TextButton),
              )
              .first,
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(AlertDialog)),
        );
        expect(
          find.text(messages.storageContextChanged.resolve(strings)),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
        fail = false;
        await tap(tester, keyed('definition-save:$kind'));
        expect(handled, 2);
        expect(find.byType(page.runtimeType), findsNothing);
      },
    );
  }

  testWidgets(
    'numeric limits use exact signed integers and Go duration units',
    (tester) async {
      final form = GlobalKey<FormState>();
      int? seconds;
      int? milliseconds;
      int? signed;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  children: [
                    DefinitionNumberField(
                      id: 'seconds',
                      label: 'interval',
                      max: definitionMaxSeconds,
                      onSaved: (value) => seconds = value,
                    ),
                    DefinitionNumberField(
                      id: 'milliseconds',
                      label: 'timeout',
                      max: definitionMaxMilliseconds,
                      onSaved: (value) => milliseconds = value,
                    ),
                    DefinitionNumberField(
                      id: 'signed',
                      label: 'routing-mark',
                      min: definitionInt64Min,
                      onSaved: (value) => signed = value,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await text(tester, 'seconds', '$definitionMaxSeconds');
      await text(tester, 'milliseconds', '$definitionMaxMilliseconds');
      await text(tester, 'signed', '$definitionInt64Min');
      expect(form.currentState!.validate(), isTrue);
      form.currentState!.save();
      expect(seconds, definitionMaxSeconds);
      expect(milliseconds, definitionMaxMilliseconds);
      expect(signed, definitionInt64Min);
      for (final input in [
        '${definitionMaxSeconds + 1}',
        '-1',
        '1.5',
        '1e3',
        '9223372036854775808',
      ]) {
        await text(tester, 'seconds', input);
        expect(form.currentState!.validate(), isFalse, reason: input);
      }
      await text(tester, 'seconds', '0');
      await text(tester, 'milliseconds', '${definitionMaxMilliseconds + 1}');
      expect(form.currentState!.validate(), isFalse);
      await text(tester, 'milliseconds', '0');
      await text(tester, 'signed', '$definitionInt64Max');
      expect(form.currentState!.validate(), isTrue);
      form.currentState!.save();
      expect(seconds, 0);
      expect(milliseconds, 0);
      expect(signed, definitionInt64Max);
    },
  );

  testWidgets(
    'tristate changes preserve geometry and unset really omits the boolean',
    (tester) async {
      final form = GlobalKey<FormState>();
      bool? saved;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Form(
              key: form,
              child: DefinitionBoolField(
                id: 'boolean',
                label: 'lazy',
                onSaved: (value) => saved = value,
              ),
            ),
          ),
        ),
      );
      final before = tester.getRect(keyed('definition-choice:boolean'));
      for (final value in ['true', 'false', null]) {
        await choose(tester, 'boolean', value);
        form.currentState!.save();
        expect(saved, value == null ? null : value == 'true');
        expect(tester.getRect(keyed('definition-choice:boolean')), before);
      }
    },
  );

  for (final path in [
    '../escape.yaml',
    '/absolute.yaml',
    'nested/../escape.yaml',
  ]) {
    testWidgets(
      'unsafe provider path [$path] blocks publication and preserves the exact input',
      (tester) async {
        var saves = 0;
        await openForm(
          tester,
          ProviderFormPage(
            ruleProvider: true,
            initialType: 'file',
            onSave: (_, _) async {
              saves++;
            },
          ),
        );
        await text(tester, 'provider/name', 'rules');
        await choose(tester, 'provider/behavior', 'domain');
        await text(tester, 'provider/path', path);
        final before = tester.getSize(keyed('definition-input:provider/path'));
        await tap(tester, keyed('definition-save:provider'));
        expect(saves, 0);
        expect(
          tester
              .widget<TextField>(keyed('definition-input:provider/path'))
              .controller!
              .text,
          path,
        );
        expect(tester.getSize(keyed('definition-input:provider/path')), before);
      },
    );
  }

  testWidgets(
    'narrow large-text native type menu keeps its geometry after selection',
    (tester) async {
      await openForm(
        tester,
        RuleFormPage(
          initialType: 'MATCH',
          targets: const [],
          onSave: (_) async {},
        ),
        size: const Size(320, 900),
        scaler: const TextScaler.linear(2),
        brightness: Brightness.dark,
      );
      final choice = keyed('definition-choice:rule/type');
      final before = tester.getRect(choice);
      await choose(tester, 'rule/type', 'PROCESS-NAME-WILDCARD');
      expect(tester.getRect(choice), before);
      await choose(tester, 'rule/type', 'UID');
      expect(tester.getRect(choice), before);
      await choose(tester, 'rule/type', 'MATCH');
      expect(tester.getRect(choice), before);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['group', 'provider', 'rule']) {
    testWidgets(
      '$kind ignores a pending save failure after its route is disposed',
      (tester) async {
        final pending = Completer<void>();
        var handled = 0;
        final page = switch (kind) {
          'group' => StrategyGroupFormPage(
            onSave: (_) => pending.future,
            onSaveHandled: () => handled++,
          ),
          'provider' => ProviderFormPage(
            ruleProvider: true,
            initialType: 'inline',
            onSave: (_, _) => pending.future,
            onSaveHandled: () => handled++,
          ),
          _ => RuleFormPage(
            initialType: 'MATCH',
            initialTarget: 'DIRECT',
            targets: const [],
            onSave: (_) => pending.future,
            onSaveHandled: () => handled++,
          ),
        };
        await openForm(tester, page);
        if (kind != 'rule') {
          await text(tester, '$kind/name', 'draft');
        }
        if (kind == 'provider') {
          await choose(tester, 'provider/behavior', 'domain');
        }
        final route = ModalRoute.of(
          tester.element(find.byType(page.runtimeType)),
        )!;
        await tester.tap(keyed('definition-save:$kind'));
        await tester.pump();
        route.navigator!.removeRoute(route);
        await tester.pumpAndSettle();
        pending.completeError(ConfigFailure(messages.storageContextChanged));
        await tester.pumpAndSettle();
        expect(keyed('open'), findsOneWidget);
        expect(handled, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'restricted target rejects an initial value outside current options',
    (tester) async {
      var saves = 0;
      await openForm(
        tester,
        RuleFormPage(
          initialType: 'MATCH',
          initialTarget: 'stale-target',
          targets: const ['DIRECT', 'REJECT'],
          restrictTargets: true,
          onSave: (_) async {
            saves++;
          },
        ),
      );
      await tap(tester, keyed('definition-save:rule'));
      expect(saves, 0);
      expect(
        tester
            .widget<TextField>(keyed('definition-input:rule/target'))
            .controller!
            .text,
        'stale-target',
      );
    },
  );

  testWidgets(
    'restricted target rechecks changed options and recovers without resetting input',
    (tester) async {
      final targets = ValueNotifier<List<String>>(const ['current-group']);
      addTearDown(targets.dispose);
      final saved = <String>[];
      await openForm(
        tester,
        ValueListenableBuilder<List<String>>(
          valueListenable: targets,
          builder: (_, options, _) => RuleFormPage(
            initialType: 'MATCH',
            initialTarget: 'current-group',
            targets: options,
            restrictTargets: true,
            onSave: (rule) async {
              saved.add(rule);
              throw ConfigFailure(messages.storageContextChanged);
            },
          ),
        ),
      );
      await tap(tester, keyed('definition-save:rule'));
      expect(saved, ['MATCH,current-group']);
      final input = keyed('definition-input:rule/target');
      final size = tester.getSize(input);
      targets.value = const [];
      await tester.pump();
      expect(tester.getSize(input), size);
      await tap(tester, keyed('definition-save:rule'));
      expect(saved, hasLength(1));
      expect(tester.widget<TextField>(input).controller!.text, 'current-group');
      targets.value = const ['current-group'];
      await tester.pump();
      expect(tester.getSize(input), size);
      await tap(tester, keyed('definition-save:rule'));
      expect(saved, ['MATCH,current-group', 'MATCH,current-group']);
    },
  );

  for (final type in ['MATCH', 'SUB-RULE']) {
    testWidgets(
      '$type ordinary reference namespace is not gated by outbound suggestions',
      (tester) async {
        String? saved;
        await openForm(
          tester,
          RuleFormPage(
            initialType: type,
            initialTarget: 'manual-reference',
            initialValue: type == 'SUB-RULE' ? '(DOMAIN,example.test)' : null,
            targets: const [],
            subRules: const [],
            restrictTargets: type == 'SUB-RULE',
            onSave: (rule) async {
              saved = rule;
            },
          ),
        );
        await tap(tester, keyed('definition-save:rule'));
        expect(
          saved,
          type == 'MATCH'
              ? 'MATCH,manual-reference'
              : 'SUB-RULE,(DOMAIN,example.test),manual-reference',
        );
      },
    );
  }
}
