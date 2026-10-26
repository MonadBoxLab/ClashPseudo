import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_popup.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/provenance_fakes.dart';
import 'strategy_fakes.dart';

Map<String, dynamic> _wire({
  CoreSnapshot core = previewCore,
  Object? provenance,
  String now = 'A',
}) => {
  'generation': core.generation,
  'configId': core.configId,
  'revision': core.revision,
  'purpose': core.purpose,
  'composition': core.composition,
  'mode': 'rule',
  'globalReferenced': false,
  'unrestored': [],
  'groups': [
    {
      'name': '出口',
      'type': 'select',
      'hidden': false,
      'now': now,
      'currentIdentity': '',
      'fixed': '',
      'icon': '',
      'members': [
        {'name': 'A', 'type': 'Socks5'},
        {'name': 'B', 'type': 'Direct'},
      ],
      'provenance': ?provenance,
    },
  ],
};

Map<String, dynamic> _sources(String first, {String? second}) =>
    definitionProvenanceWire([
      sourceContributorWire(
        id: 'first',
        name: first,
        role: 'localCustom',
        path: '/proxy-groups/1',
      ),
      if (second != null)
        sourceContributorWire(
          id: 'second',
          name: second,
          path: '/proxy-groups/0',
        ),
      sourceContributorWire(
        kind: 'config',
        id: 'one',
        revision: 1,
        name: 'Main without extra label',
        path: '/proxy-groups/2',
      ),
    ]);

void main() {
  test('strategy real wire preserves provenance and full query identity', () {
    final raw = _wire(
      provenance: _sources('Z high-priority plugin', second: 'A lower plugin'),
    );
    final value = StrategySnapshot.fromMap(
      jsonDecode(jsonEncode(raw)) as Map<String, dynamic>,
    );
    final group = value.find('出口')!;
    expect(group.provenance!.plugins.map((source) => source.name), [
      'Z high-priority plugin',
      'A lower plugin',
    ]);
    expect(group.provenance!.plugins.map((source) => source.path), [
      '/proxy-groups/1',
      '/proxy-groups/0',
    ]);
    expect(group.provenance!.plugins.first.isLocalCustom, isTrue);
    expect(value.matches(previewCore), isTrue);
    expect(value.matches(vpnCore), isFalse);
    final source =
        ((raw['groups'] as List).single['provenance']['contributors'] as List)
                .first
            as Map;
    source['name'] = 'Latest disk rename';
    expect(group.provenance!.plugins.first.name, 'Z high-priority plugin');
  });

  test(
    'unknown/malformed strategy source cannot become a local-custom identity',
    () {
      for (final raw in [
        {'contributors': []},
        definitionProvenanceWire([
          {...sourceContributorWire(path: '/proxy-groups/0'), 'revision': 0},
        ]),
        definitionProvenanceWire([sourceContributorWire(path: '/proxies/0')]),
        definitionProvenanceWire([
          {
            ...sourceContributorWire(path: '/proxy-groups/0'),
            'kind': 'unknown',
          },
        ]),
      ]) {
        expect(
          () => StrategySnapshot.fromMap(_wire(provenance: raw)),
          throwsFormatException,
        );
      }
      expect(StrategySnapshot.fromMap(_wire()).find('出口')!.provenance, isNull);
    },
  );

  testWidgets(
    'popup keeps ordered captured names in its existing details across disk rename',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = 'Z loaded local plugin / 本地插件名称' * 3;
      final second = 'A lower-priority remote plugin / 远程插件';
      final bridge = StrategyBridgeFake()
        ..data = StrategySnapshot.fromMap(
          _wire(provenance: _sources(first, second: second)),
        );
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: StrategyPopup(
              controller: controller,
              name: '出口',
              generation: 7,
              storageEpoch: app.storageEpoch,
            ),
          ),
        ),
      );
      await tester.pump();
      final title = find.byKey(const ValueKey('strategy-popup-title'));
      final titleRect = tester.getRect(title);
      final popupRect = tester.getRect(find.byType(StrategyPopup));
      expect(find.textContaining('2 contributing plugins'), findsOneWidget);
      app.overrides = const [
        OverrideEntry(
          id: 'first',
          name: 'Latest disk rename',
          kind: ConfigKind.local,
          revision: 3,
          body: '{}',
          role: OverrideRole.localCustom,
        ),
      ];
      app.overridesLoaded = true;
      app.changed();
      await tester.pump();
      expect(find.textContaining('Latest disk rename'), findsNothing);
      expect(tester.getRect(title), titleRect);
      expect(tester.getRect(find.byType(StrategyPopup)), popupRect);
      await tester.tap(title);
      await tester.pumpAndSettle();
      final message = tester
          .widget<SelectableText>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(SelectableText),
            ),
          )
          .data!;
      expect(message, contains(first));
      expect(message, contains(second));
      expect(message.indexOf(first), lessThan(message.indexOf(second)));
      expect(message, contains('Local customizations'));
      expect(message, isNot(contains('Main without extra label')));
      expect(message, isNot(contains('Latest disk rename')));
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'source text does not resize popup on read failure/recovery or replace expired input',
    (tester) async {
      final source = _sources('Actually loaded plugin');
      final bridge = StrategyBridgeFake()
        ..data = StrategySnapshot.fromMap(_wire(provenance: source));
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app)..setVisible(true);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StrategyPopup(
              controller: controller,
              name: '出口',
              generation: 7,
            ),
          ),
        ),
      );
      await tester.pump();
      final popup = find.byType(StrategyPopup);
      final title = find.byKey(const ValueKey('strategy-popup-title'));
      final popupRect = tester.getRect(popup);
      final titleRect = tester.getRect(title);
      void unchanged() {
        expect(tester.getRect(popup), popupRect);
        expect(tester.getRect(title), titleRect);
        expect(tester.takeException(), isNull);
      }

      bridge.pendingRead = Completer<StrategySnapshot>();
      await tester.pump(const Duration(seconds: 5));
      unchanged();
      bridge.pendingRead!.completeError(
        StateError('controlled source read failure'),
      );
      for (final duration in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 100),
      ]) {
        await tester.pump(duration);
        unchanged();
      }
      bridge.pendingRead = null;
      bridge.data = StrategySnapshot.fromMap(
        _wire(provenance: source, now: 'B'),
      );
      await controller.retry();
      for (final duration in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 100),
      ]) {
        await tester.pump(duration);
        unchanged();
      }
      const newer = CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'PREVIEW',
        configId: 'one',
        revision: 1,
        composition: '["one",1,[8]]',
      );
      bridge.data = StrategySnapshot.fromMap(
        _wire(core: newer, provenance: _sources('New composition name')),
      );
      app.state = const AppSnapshot(phase: 'STOPPED', core: newer);
      app.changed();
      await tester.pump();
      unchanged();
      expect(find.textContaining('New composition name'), findsNothing);
      await tester.tap(title);
      await tester.pumpAndSettle();
      final message = tester
          .widget<SelectableText>(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(SelectableText),
            ),
          )
          .data!;
      expect(message, contains('Actually loaded plugin'));
      expect(message, isNot(contains('New composition name')));
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
