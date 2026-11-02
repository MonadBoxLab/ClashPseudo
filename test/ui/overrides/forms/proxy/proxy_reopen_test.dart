import 'dart:convert';

import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'proxy_form_test.dart' as forms;

void main() {
  final fixtures = jsonDecode(forms.contractFile.readAsStringSync()) as List;
  for (final fixture in fixtures) {
    final original = Map<String, Object?>.from(
      forms.resolveFixture(fixture['definition']) as Map,
    );
    original['unknown-future'] = {
      'nested': [false, 0, '', null, 1.5],
    };
    final type = original['type'] as String;
    testWidgets(
      '${fixture['id']} original retains unknown fields after reopen',
      (tester) async {
        var current = original;
        for (final round in [0, 1, 2]) {
          Map<String, Object?>? saved;
          await forms.openForm(
            tester,
            type,
            initialDefinition: current,
            onSave: (value) async => saved = value,
          );
          if (round == 1) {
            await forms.fillScalar(tester, type, 'name', 'renamed original');
          }
          await tester.tap(forms.keyed('proxy-save'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(ProxyFormPage), findsNothing);
          expect(saved, {
            ...original,
            if (round > 0) 'name': 'renamed original',
          });
          current = saved!;
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final original in <Map<String, Object?>>[
    {'name': 'unsupported', 'type': 'future-type'},
    {'name': 'unsupported', 'type': 17},
    {'name': 'unsupported', 'type': 'tailscale', 'state-dir': <Object?>[]},
  ]) {
    testWidgets(
      'unrepresentable proxy type or state directory stays readable ${original['type']}',
      (tester) async {
        var saves = 0;
        await forms.openForm(
          tester,
          'http',
          initialDefinition: original,
          onSave: (_) async {
            saves++;
          },
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(ProxyFormPage)),
        );
        expect(find.text(strings.localYamlUnsupportedEdit), findsOneWidget);
        expect(forms.keyed('proxy-save'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        expect(saves, 0);
        expect(tester.takeException(), isNull);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(saves, 0);
      },
    );
  }

  testWidgets(
    'editing one peer keeps unknown fields and other original peers',
    (tester) async {
      final original = Map<String, Object?>.from(
        forms.resolveFixture(
          fixtures.firstWhere(
            (item) =>
                item['definition']['type'] == 'wireguard' &&
                item['definition']['peers'] is List,
          )['definition'],
        ) as Map,
      );
      final peers = original['peers'] as List;
      final first = Map<String, Object?>.from(peers.first as Map)
        ..['future-peer-field'] = {'untouched': 1.5};
      original['peers'] = [first, ...peers.skip(1)];
      Map<String, Object?>? saved;
      await forms.openForm(
        tester,
        'wireguard',
        initialDefinition: original,
        onSave: (value) async => saved = value,
      );
      await forms.openGroup(tester, 'wireguard/peers');
      final row = find
          .byWidgetPredicate(
            (widget) =>
                widget is ListTile &&
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'proxy-row:wireguard/peers/',
                ),
          )
          .first;
      final scope = (tester.widget<ListTile>(row).key! as ValueKey<String>)
          .value
          .substring('proxy-row:'.length);
      final edit = forms.keyed('proxy-edit:$scope');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await forms.fillScalar(tester, scope, 'port', 51821);
      await tester.tap(forms.keyed('proxy-save'));
      await tester.pumpAndSettle();
      await tester.tap(forms.keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(saved!['peers'], [
        {...first, 'port': 51821},
        ...peers.skip(1),
      ]);
    },
  );
}
