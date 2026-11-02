import 'dart:convert';

import 'package:clash_pseudo/src/logic/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proxy_form_test.dart'
    show expandAncestors, fillScalar, keyed, openForm, openGroup;

Future<void> chooseType(WidgetTester tester, String type) async {
  final selector = keyed('proxy-select-type', offstage: true);
  await expandAncestors(tester, selector);
  await tester.ensureVisible(selector);
  await tester.tap(selector);
  await tester.pumpAndSettle();
  final choice = keyed('proxy-type:$type');
  final list = find.byKey(const PageStorageKey<String>('proxy-type-list'));
  expect(list, findsOneWidget);
  final scrollable = find.descendant(
    of: list,
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsOneWidget);
  await tester.scrollUntilVisible(choice, 300, scrollable: scrollable);
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

void main() {
  final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(
    () => WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy,
  );

  testWidgets(
    'type switches preserve untouched protocol fields and exact explicit values',
    (tester) async {
      final original = <String, Object?>{
        'type': 'http',
        'name': 'identity',
        'server': 'fixture.invalid',
        'port': 443,
        'tls': false,
        'sni': '',
        'headers': <String, Object?>{},
        'skip-cert-verify': null,
        'unknown': {'zero': 0, 'empty': <Object?>[], 'null': null},
      };
      final snapshot = jsonDecode(jsonEncode(original));
      final seen = <Map<String, Object?>>[];
      await openForm(
        tester,
        'http',
        initialDefinition: original,
        onSave: (value) async {
          seen.add(value);
          throw ProxyFormSaveException(messages.storageContextChanged);
        },
      );
      for (final type in ['socks5', 'http']) {
        await chooseType(tester, type);
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(seen.last, {...original, 'type': type});
      }
      expect(seen, hasLength(2));
      expect(original, snapshot);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switching plugin does not erase untouched original options', (
    tester,
  ) async {
    const original = <String, Object?>{
      'type': 'ss',
      'name': 'identity',
      'server': 'fixture.invalid',
      'port': 443,
      'password': 'synthetic',
      'cipher': 'aes-128-gcm',
      'plugin': 'obfs',
      'plugin-opts': {
        'mode': 'tls',
        'host': '',
        'unknown': {'flag': false, 'empty': <Object?>[], 'null': null},
      },
    };
    final seen = <Map<String, Object?>>[];
    await openForm(
      tester,
      'ss',
      initialDefinition: original,
      onSave: (value) async {
        seen.add(value);
        throw ProxyFormSaveException(messages.storageContextChanged);
      },
    );
    for (final plugin in ['v2ray-plugin', 'obfs']) {
      await fillScalar(tester, 'ss', 'plugin', plugin);
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(seen.last, {...original, 'plugin': plugin});
    }
    expect(seen, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'transport switches preserve inactive options and unknown nested fields',
    (tester) async {
      const original = <String, Object?>{
        'type': 'vless',
        'name': 'identity',
        'server': 'fixture.invalid',
        'port': 443,
        'uuid': 'synthetic',
        'network': 'ws',
        'ws-opts': {
          'path': '',
          'headers': <String, Object?>{},
          'unknown': null,
        },
        'grpc-opts': {'grpc-service-name': '', 'unknown': <Object?>[]},
      };
      final seen = <Map<String, Object?>>[];
      await openForm(
        tester,
        'vless',
        initialDefinition: original,
        onSave: (value) async {
          seen.add(value);
          throw ProxyFormSaveException(messages.storageContextChanged);
        },
      );
      for (final network in ['grpc', 'ws']) {
        await fillScalar(tester, 'vless', 'network', network);
        await tester.tap(keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(seen.last, {...original, 'network': network});
      }
      expect(seen, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing one plugin option preserves all unedited original options',
    (tester) async {
      const original = <String, Object?>{
        'type': 'ss',
        'name': 'identity',
        'server': 'fixture.invalid',
        'port': 443,
        'password': 'synthetic',
        'cipher': 'aes-128-gcm',
        'plugin': 'obfs',
        'plugin-opts': {'mode': 'tls', 'host': '', 'unknown': null},
      };
      Map<String, Object?>? actual;
      await openForm(
        tester,
        'ss',
        initialDefinition: original,
        onSave: (value) async {
          actual = value;
        },
      );
      await fillScalar(tester, 'ss', 'plugin', 'v2ray-plugin');
      await openGroup(tester, 'ss/plugin-opts@v2ray-plugin');
      await fillScalar(
        tester,
        'ss/plugin-opts@v2ray-plugin',
        'host',
        'edited.invalid',
      );
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(actual, {
        ...original,
        'plugin': 'v2ray-plugin',
        'plugin-opts': {
          'mode': 'tls',
          'host': 'edited.invalid',
          'unknown': null,
        },
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no-op GUI save returns the exact original YAML bytes and captured target',
    (tester) async {
      const source =
          '﻿# original\r\n'
          'proxies:\n'
          '  - name: "identity" # target\r\n'
          '    type: http\n'
          '    server: fixture.invalid\r\n'
          '    port: 443\n'
          '    tls: false\r\n'
          '    sni: ""\n'
          '    headers: {}\r\n'
          '    unknown: {zero: 0, empty: [], value: null}\n'
          '  - {name: neighbor, type: direct}\r\n';
      final edit = LocalYamlEdit(source);
      final target = edit.definitions(LocalYamlSection.proxies).first;
      String? actual;
      await openForm(
        tester,
        'http',
        initialDefinition: edit.definitionValue(target),
        onSave: (value) async {
          actual = edit.replaceNamed(target, value);
        },
      );
      await tester.tap(keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(actual, source);
      expect(utf8.encode(actual!), utf8.encode(source));
      expect(target.path, ['proxies', 0]);
      expect(find.byType(ProxyFormPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
