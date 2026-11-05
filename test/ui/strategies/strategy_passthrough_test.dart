import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/strategies/strategies_page.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/strategy_fakes.dart';

const _original =
    'https://user:pass@fixture.test/?token=原文🙂\n'
    'Authorization: Bearer fixture';
const _replacement = CoreSnapshot(
  generation: 8,
  phase: 'READY',
  purpose: 'PREVIEW',
  configId: 'one',
  revision: 1,
  composition: '["replacement",1]',
);

Map<String, dynamic> _wire({
  CoreSnapshot source = previewCore,
  bool stale = false,
}) => {
  'generation': source.generation,
  'configId': source.configId,
  'revision': source.revision,
  'composition': source.composition,
  'purpose': source.purpose,
  'mode': 'rule',
  'globalReferenced': false,
  'stale': stale,
  'groups': [
    {
      'name': '出口',
      'type': 'select',
      'hidden': false,
      'now': _original,
      'currentIdentity': 'member-identity',
      'fixed': '',
      'icon': '',
      'members': [
        {
          'name': _original,
          'type': 'Socks5',
          'future': [false, null],
        },
      ],
      'future': {'Authorization': _original},
    },
  ],
  'unrestored': <Object?>[],
  'future': {
    'values': [false, null, _original],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final background in [false, true]) {
    for (final changed in [false, true]) {
      testWidgets(
        'actual success survives the read deadline: background=$background/source=$changed',
        (tester) async {
          final pending = Completer<StrategySnapshot>();
          final bridge = StrategyBridgeFake()..pendingRead = pending;
          final app = StrategyAppFake(bridge);
          final controller = StrategyController(app);
          addTearDown(() {
            controller.dispose();
            app.dispose();
          });
          controller.setVisible(true);
          await tester.pump(const Duration(seconds: 5));
          expect(
            controller.readErrorMessage!.detail,
            contains('TimeoutException'),
          );
          expect(controller.loading, isTrue);
          expect(controller.canChoose, isFalse);
          await tester.pump(const Duration(seconds: 30));
          expect(bridge.reads, 1);
          if (background) app.setForeground(false);
          if (changed) {
            app.state = const AppSnapshot(phase: 'STOPPED');
            app.changed();
          }
          final actual = StrategySnapshot.fromMap(_wire());
          pending.complete(actual);
          await tester.pump();
          expect(controller.data, same(actual));
          expect(controller.data!.groups.single.now, _original);
          expect(controller.data!.generation, previewCore.generation);
          expect(controller.readErrorMessage, isNull);
          expect(controller.loading, isFalse);
          expect(controller.current, !background && !changed);
          expect(controller.canChoose, !background && !changed);
          controller.setVisible(false);
        },
      );
    }
  }

  for (final platformError in [false, true]) {
    for (final background in [false, true]) {
      testWidgets(
        'actual read error replaces only the deadline: platform=$platformError/background=$background',
        (tester) async {
          final pending = Completer<StrategySnapshot>();
          final bridge = StrategyBridgeFake()..pendingRead = pending;
          final app = StrategyAppFake(bridge);
          final controller = StrategyController(app);
          addTearDown(() {
            controller.dispose();
            app.dispose();
          });
          controller.setVisible(true);
          await tester.pump(const Duration(seconds: 5));
          expect(controller.loading, isTrue);
          app.state = const AppSnapshot(phase: 'STOPPED');
          app.changed();
          if (background) app.setForeground(false);
          final failure = platformError
              ? PlatformFailure(
                  code: 'fixture',
                  message: _original,
                  details: {
                    'future': [false, null, _original],
                  },
                )
              : StateError(_original);
          pending.completeError(failure);
          await tester.pump();
          expect(controller.loading, isFalse);
          expect(
            controller.readErrorMessage!.detail,
            contains(failure.toString()),
          );
          expect(
            controller.readErrorMessage!.detail,
            isNot(contains('TimeoutException')),
          );
          expect(controller.canChoose, isFalse);
          expect(bridge.reads, 1);
          controller.setVisible(false);
        },
      );
    }
  }

  testWidgets(
    'a changed source waits for the actual read and retains it until replacement completes',
    (tester) async {
      final old = Completer<StrategySnapshot>();
      final next = Completer<StrategySnapshot>();
      final bridge = StrategyBridgeFake()..pendingRead = old;
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      controller.setVisible(true);
      await tester.pump();
      app.state = const AppSnapshot(phase: 'STOPPED', core: _replacement);
      bridge.pendingRead = next;
      bridge.data = strategyData(core: _replacement);
      app.changed();
      await tester.pump();
      expect(bridge.reads, 1);
      expect(controller.loading, isTrue);
      old.complete(StrategySnapshot.fromMap(_wire()));
      await tester.pump();
      expect(controller.data!.groups.single.now, _original);
      expect(controller.data!.generation, previewCore.generation);
      expect(controller.current, isFalse);
      expect(controller.canChoose, isFalse);
      expect(controller.loading, isTrue);
      expect(bridge.reads, 2);
      next.complete(StrategySnapshot.fromMap(_wire(source: _replacement)));
      await tester.pump();
      expect(controller.data!.generation, _replacement.generation);
      expect(controller.data!.groups.single.now, _original);
      expect(controller.canChoose, isTrue);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'a native stale flag cannot authorize choices even when identity still matches',
    (tester) async {
      final bridge = StrategyBridgeFake()
        ..data = StrategySnapshot.fromMap(_wire(stale: true));
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      controller.setVisible(true);
      await tester.pump();
      expect(controller.data!.stale, isTrue);
      expect(controller.current, isFalse);
      expect(controller.canChoose, isFalse);
      controller.setVisible(false);
    },
  );

  for (final language in ['en', 'zh']) {
    testWidgets('策略来源过期后保留页面和阅读位置，不显示原始数据入口：$language', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);
      final wire = _wire();
      final bridge = StrategyBridgeFake()
        ..data = StrategySnapshot.fromMap(wire);
      final app = StrategyAppFake(bridge);
      final controller = StrategyController(app);
      addTearDown(() {
        controller.dispose();
        app.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.forBrightness(Brightness.light),
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: StrategiesPage(controller: controller, active: true),
        ),
      );
      await tester.pumpAndSettle();
      final pageState = tester.state(find.byType(StrategiesPage));
      final data = controller.data;
      final reading = find.byKey(const PageStorageKey('strategies-scroll'));
      final readingRect = tester.getRect(reading);
      expect(find.byIcon(Icons.data_object), findsNothing);
      expect(controller.current, isTrue);
      expect(controller.canChoose, isTrue);
      app.state = const AppSnapshot(phase: 'STOPPED');
      app.changed();
      await tester.pump();
      expect(controller.current, isFalse);
      expect(controller.canChoose, isFalse);
      expect(controller.data, same(data));
      expect(tester.state(find.byType(StrategiesPage)), same(pageState));
      expect(tester.getRect(reading), readingRect);
      expect(controller.data!.groups.single.now, _original);
      expect(find.byIcon(Icons.data_object), findsNothing);
      expect(tester.takeException(), isNull);
      controller.setVisible(false);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
