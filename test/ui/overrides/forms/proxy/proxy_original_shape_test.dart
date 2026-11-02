import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/text_scalers.dart';

import 'proxy_form_test.dart' as forms;

void main() {
  final fixtures = (jsonDecode(forms.contractFile.readAsStringSync()) as List)
      .cast<Map>();
  for (final (fixture, path, value, identity)
      in <(String, List<String>, Object?, String)>[
        ('http', ['server'], <String>[], 'common/server'),
        ('http', ['port'], <String, Object?>{}, 'common/port'),
        ('http', ['tls'], 'false', 'http/tls'),
        ('http', ['sni'], 0, 'http/sni'),
        ('http', ['headers'], false, 'http/headers'),
        ('http', ['headers'], {'X-Header': <String>[]}, 'http/headers'),
        ('ssh', ['host-key'], [false], 'ssh/host-key'),
        ('masque-all-fields', ['ip-stack'], false, 'masque/ip-stack'),
        (
          'vmess-transport-ws',
          ['ws-opts', 'path'],
          <String>[],
          'vmess/ws-opts/path',
        ),
        ('vmess-transport-ws', ['network'], false, 'vmess/network'),
        (
          'vmess-transport-http',
          ['http-opts', 'headers'],
          {
            'X-Header': [0],
          },
          'vmess/http-opts/headers',
        ),
        ('wireguard-peer-fields', ['peers'], [false], 'wireguard/peers'),
        ('wireguard-peer-fields', ['reserved'], [false], 'wireguard/reserved'),
        ('ss-plugin-obfs', ['plugin'], false, 'ss/plugin'),
        ('ss-plugin-obfs', ['plugin-opts'], false, 'ss/plugin-opts'),
        ('snell-obfs-http', ['obfs-opts', 'mode'], 0, 'snell/obfs-opts/mode'),
      ]) {
    testWidgets(
      'unsupported original field stays read-only and unchanged $identity/$value',
      (tester) async {
        final original = Map<String, Object?>.from(
          forms.resolveFixture(
            fixtures.singleWhere((row) => row['id'] == fixture)['definition'],
          ) as Map,
        );
        Map parent = original;
        for (final key in path.take(path.length - 1)) {
          parent = parent[key] as Map;
        }
        parent[path.last] = value;
        original['future'] = {
          'retained': [false, 0, '', null],
        };
        Map<String, Object?>? saved;
        await forms.openForm(
          tester,
          original['type'] as String,
          initialDefinition: original,
          onSave: (definition) async => saved = definition,
        );
        final warning = forms.keyed(
          'proxy-original-field:$identity',
          offstage: true,
        );
        expect(warning, findsOneWidget);
        await forms.expandAncestors(tester, warning);
        await tester.ensureVisible(warning);
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: warning, matching: find.byType(SelectableText)),
          findsNWidgets(3),
        );
        expect(
          find.descendant(of: warning, matching: find.byType(TextField)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await forms.fillScalar(
          tester,
          original['type'] as String,
          'name',
          'renamed-original',
        );
        await tester.tap(forms.keyed('proxy-save'));
        await tester.pumpAndSettle();
        expect(saved, {...original, 'name': 'renamed-original'});
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (label, definition, field)
      in <(String, Map<String, Object?>, String)>[
        ('missing type', {}, 'type'),
        ('null type', {'type': null}, 'type'),
        ('numeric type', {'type': 7}, 'type'),
        ('unknown type', {'type': 'future-proxy'}, 'type'),
        (
          'state directory container',
          {'type': 'tailscale', 'state-dir': <String>[]},
          'state-dir',
        ),
      ]) {
    testWidgets('unsupported node original explains its field $label', (
      tester,
    ) async {
      var saves = 0;
      await forms.openForm(
        tester,
        'http',
        initialDefinition: definition,
        notice: const Text('original source context'),
        onSave: (_) async => saves++,
      );
      final strings = AppLocalizations.of(
        tester.element(find.byType(ProxyFormPage)),
      );
      expect(find.text(strings.localYamlUnsupportedEdit), findsOneWidget);
      expect(find.text(field), findsOneWidget);
      expect(find.text('original source context'), findsOneWidget);
      expect(forms.keyed('proxy-save'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'unsupported nested record field preserves the complete original record',
    (tester) async {
      final original = Map<String, Object?>.from(
        forms.resolveFixture(
          fixtures.singleWhere(
            (row) => row['id'] == 'wireguard-peer-fields',
          )['definition'],
        ) as Map,
      );
      final peers = original['peers'] as List;
      (peers.first as Map)['port'] = {'controlled': false};
      Map<String, Object?>? saved;
      await forms.openForm(
        tester,
        'wireguard',
        initialDefinition: original,
        onSave: (definition) async => saved = definition,
      );
      await forms.openGroup(tester, 'wireguard/peers');
      await tester.ensureVisible(
        forms.keyed('proxy-record-list:wireguard/peers'),
      );
      await tester.pumpAndSettle();
      final edit = find
          .byWidgetPredicate(
            (widget) =>
                widget is IconButton &&
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'proxy-edit:wireguard/peers/',
                ),
          )
          .first;
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final warning = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return key is ValueKey<String> &&
            key.value.startsWith('proxy-original-field:wireguard/peers/r') &&
            key.value.endsWith('/port');
      }, skipOffstage: false);
      expect(warning, findsOneWidget);
      await forms.expandAncestors(tester, warning);
      await tester.ensureVisible(warning);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(forms.keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      await forms.fillScalar(tester, 'wireguard', 'name', 'renamed-wireguard');
      await tester.tap(forms.keyed('proxy-save'));
      await tester.pumpAndSettle();
      expect(saved, {...original, 'name': 'renamed-wireguard'});
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 1704.0]) {
      for (final (label, scaler) in [
        ('1', TextScaler.noScaling),
        ('2', TextScaler.linear(2)),
        ('nonlinear', const NonlinearTextScaler()),
      ]) {
        testWidgets(
          'unsupported field keeps draft and geometry through save $language/$width/$label',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1136);
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final original = Map<String, Object?>.from(
              forms.resolveFixture(
                fixtures.singleWhere(
                  (row) => row['id'] == 'http',
                )['definition'],
              ) as Map,
            )..['password'] = {'controlled': 'NOT_A_REAL_SECRET'};
            final pending = Completer<void>();
            var calls = 0;
            await forms.openForm(
              tester,
              'http',
              initialDefinition: original,
              locale: Locale(language),
              scaler: scaler,
              onSave: (definition) {
                expect(definition, original);
                calls++;
                return calls == 1 ? pending.future : Future<void>.value();
              },
            );
            final warning = forms.keyed('proxy-original-field:common/password');
            await tester.ensureVisible(warning);
            await tester.pumpAndSettle();
            final strings = AppLocalizations.of(
              tester.element(find.byType(ProxyFormPage)),
            );
            expect(
              find.text(strings.localYamlUnsupportedField),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: warning,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is SelectableText &&
                      widget.data?.contains('NOT_A_REAL_SECRET') == true,
                ),
              ),
              findsOneWidget,
            );
            final warningBounds = tester.getRect(warning);
            final save = forms.keyed('proxy-save');
            final saveBounds = tester.getRect(save);
            await tester.tap(save);
            for (final ms in [0, 16, 80]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(warning), warningBounds);
              expect(tester.getRect(save), saveBounds);
              expect(tester.takeException(), isNull);
            }
            pending.completeError(
              ProxyFormSaveException(messages.configSavedReconnectIncomplete),
            );
            for (final ms in [0, 16, 80]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(warning), warningBounds);
              expect(tester.getRect(save), saveBounds);
              expect(tester.takeException(), isNull);
            }
            await tester.pumpAndSettle();
            await tester.tap(find.widgetWithText(TextButton, strings.retry));
            await tester.pumpAndSettle();
            expect(calls, 2);
            expect(find.byType(ProxyFormPage), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
