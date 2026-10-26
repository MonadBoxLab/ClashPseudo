import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';

import 'dart:async';

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/connections/connection_controller.dart';
import 'package:clash_pseudo/src/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/src/features/connections/connections_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_fakes.dart';

class _TestClock implements Stopwatch {
  @override
  int elapsedMilliseconds = 0;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ConnectionBridgeFake bridge;
  late ConnectionAppFake app;
  late ConnectionController controller;
  late _TestClock clock;
  setUp(() {
    setMessageLanguage(AppLanguage.zh);
    bridge = ConnectionBridgeFake();
    app = ConnectionAppFake(bridge);
    clock = _TestClock();
    controller = ConnectionController(app, clock: clock);
  });
  tearDown(() {
    controller.dispose();
    app.dispose();
    setMessageLanguage(AppLanguage.system);
  });

  test(
    'snapshot preserves unknowns, IPv6, path order and filters only Inner',
    () {
      final data = snapshot([
        row('inner', type: 'Inner'),
        row('unknown', type: 'Future'),
        {'id': 'empty'},
      ]);
      expect(data.records.length, 2);
      expect(data.matches(core), isTrue);
      expect(data.records.first.path, '出口 → node');
      expect(ConnectionRecord.endpoint('::1', '80'), '[::1]:80');
      expect(data.records.last.upload, isNull);
      expect(data.records.last.start, isNull);
      expect(data.records.last.target, '未提供');
      expect(data.records.last.ruleLabel, '未提供');
      expect(() => snapshot([row('one'), row('one')]), throwsFormatException);
      expect(
        () => ConnectionSnapshot.fromMap({
          'generation': 7,
          'configId': 'one',
          'revision': 1,
        }),
        throwsA(anything),
      );
    },
  );

  testWidgets('reads only visible running VPN and stops in background', (
    tester,
  ) async {
    await tester.pump(const Duration(seconds: 10));
    expect(bridge.reads, 0);
    controller.setVisible(true);
    await tester.pump();
    expect(bridge.reads, 1);
    app.changed();
    await tester.pump();
    expect(bridge.reads, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.reads, 2);
    app.setForeground(false);
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.reads, 2);
    app.setForeground(true);
    await tester.pump();
    expect(bridge.reads, 3);
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 30));
    expect(bridge.reads, 3);
    app.state = const AppSnapshot(
      phase: 'STOPPED',
      core: CoreSnapshot(phase: 'READY', purpose: 'PREVIEW'),
    );
    app.changed();
    controller.setVisible(true);
    await tester.pump();
    expect(bridge.reads, 4);
    expect(controller.data, isNotNull);
    expect(controller.status, ConnectionViewStatus.stopped);
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets(
    'inflight read is not duplicated and late result cannot repopulate page',
    (tester) async {
      final pending = Completer<ConnectionSnapshot>();
      bridge.pending = pending;
      controller.setVisible(true);
      controller.setVisible(false);
      controller.setVisible(true);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, 1);
      bridge.pending = null;
      pending.complete(snapshot([row('late')]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.data?.find('late'), isNull);
      expect(controller.data?.find('one'), isNotNull);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'failure is stale not absent; successful missing snapshot retains detail only',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.detailStatus, ConnectionViewStatus.failed);
      expect(controller.data!.records.length, 1);
      bridge.fail = false;
      bridge.data = snapshot([], detail: {...row('one'), 'active': false});
      await tester.pump(const Duration(seconds: 1));
      expect(controller.data!.records, isEmpty);
      expect(controller.detail!.id, 'one');
      expect(controller.detailStatus, ConnectionViewStatus.inactive);
      controller.setVisible(false);
    },
  );

  testWidgets(
    'steady reads notify once on completion, not before unchanged data',
    (tester) async {
      controller.setVisible(true);
      await tester.pump();
      var notifications = 0;
      controller.addListener(() => notifications++);
      bridge.pending = Completer<ConnectionSnapshot>();
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, 0);
      bridge.pending!.complete(snapshot([row('one', download: 30)]));
      await tester.pump();
      expect(notifications, 1);
      expect(controller.data!.records.single.download, 30);
      bridge.pending = null;
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, 2);
      expect(controller.status, ConnectionViewStatus.failed);
      controller.setVisible(false);
    },
  );

  testWidgets('sample expires during pending query', (tester) async {
    bridge.data = snapshot([row('one')], sampleAgeMs: 3500);
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    expect(controller.canClose, isTrue);
    final beforeRead = controller.data;
    bridge.pending = Completer<ConnectionSnapshot>();
    clock.elapsedMilliseconds = 1000;
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.reads, 2);
    var notifications = 0;
    controller.addListener(() => notifications++);
    clock.elapsedMilliseconds = 1501;
    await tester.pump(const Duration(milliseconds: 501));
    expect(controller.current, isFalse);
    expect(controller.detailActive, isFalse);
    expect(controller.canClose, isFalse);
    expect(controller.detailStatus, ConnectionViewStatus.updating);
    expect(controller.error, isNull);
    expect(controller.detail!.active, isTrue);
    expect(controller.data, same(beforeRead));
    expect(notifications, 1);
    controller.setVisible(false);
    bridge.pending!.complete(snapshot([row('late')]));
    await tester.pump();
    expect(controller.data!.find('late'), isNull);
  });

  testWidgets('repeated samples keep their age and include query latency', (
    tester,
  ) async {
    bridge.data = snapshot([row('one')], sampleAgeMs: 3000);
    controller.setVisible(true);
    await tester.pump();
    bridge.pending = Completer<ConnectionSnapshot>();
    clock.elapsedMilliseconds = 1000;
    await tester.pump(const Duration(seconds: 1));
    clock.elapsedMilliseconds = 1500;
    await tester.pump(const Duration(milliseconds: 500));
    bridge.pending!.complete(snapshot([row('one')], sampleAgeMs: 4000));
    await tester.pump();
    expect(controller.current, isTrue);
    bridge.pending = Completer<ConnectionSnapshot>();
    clock.elapsedMilliseconds = 2001;
    await tester.pump(const Duration(milliseconds: 501));
    expect(controller.current, isFalse);
    expect(controller.status, ConnectionViewStatus.updating);
    controller.setVisible(false);
  });

  for (final age in <Object?>[null, -1, '0', 5001]) {
    testWidgets('missing, invalid or expired sample age is not fresh ($age)', (
      tester,
    ) async {
      bridge.data = snapshot([row('one')], sampleAgeMs: age);
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      expect(controller.current, isFalse);
      expect(controller.canClose, isFalse);
      expect(controller.status, ConnectionViewStatus.updating);
      controller.setVisible(false);
    });
  }

  testWidgets('list and detail follow observations and retain stop state', (
    tester,
  ) async {
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    bridge.data = snapshot([row('one', download: 20)]);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.data!.records.single.download, 20);
    expect(controller.detail!.download, 20);
    expect(controller.data!.records.single.download, 20);
    app.state = const AppSnapshot(phase: 'STOPPED');
    app.changed();
    expect(controller.data, isNotNull);
    expect(controller.detailStatus, ConnectionViewStatus.stopped);
    expect(controller.detail!.download, 20);
    controller.setVisible(false);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('timeout and replacement cannot confirm old connection data', (
    tester,
  ) async {
    bridge.pending = Completer<ConnectionSnapshot>();
    controller.setVisible(true);
    await tester.pump(const Duration(seconds: 5));
    expect(controller.error, isNotNull);
    expect(app.state.running, isTrue);
    app.state = const AppSnapshot(
      phase: 'RUNNING',
      generation: 1,
      core: CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'VPN',
        configId: 'one',
        revision: 1,
      ),
    );
    app.changed();
    final old = bridge.pending!;
    bridge.pending = null;
    old.complete(snapshot([row('old')]));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(controller.current, isFalse);
    expect(controller.data, isNull);
    controller.setVisible(false);
  });

  for (final outcome in ['closed', 'absent', 'failed', 'unconfirmed']) {
    testWidgets('single close correlates $outcome during live updates', (
      tester,
    ) async {
      controller.setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      expect(controller.canClose, isTrue);
      await controller.disconnect();
      await controller.disconnect();
      expect(app.commands.length, 1);
      expect(app.commands.single['connectionId'], 'one');
      expect(app.commands.single['generation'], 7);
      expect(controller.closing, isTrue);
      app.state = AppSnapshot(
        phase: 'RUNNING',
        core: core,
        resultId: 'another-operation',
        connectionStatus: outcome,
      );
      app.changed();
      expect(controller.closing, isTrue);
      app.state = AppSnapshot(
        phase: 'RUNNING',
        core: core,
        resultId: 'close-1',
        connectionStatus: outcome,
      );
      app.changed();
      expect(controller.closing, isFalse);
      if (outcome == 'closed') {
        expect(controller.detailStatus, ConnectionViewStatus.closed);
        expect(controller.canClose, isFalse);
      } else if (outcome == 'absent') {
        expect(controller.detailStatus, ConnectionViewStatus.inactive);
        expect(controller.canClose, isFalse);
      } else {
        expect(controller.closeMessage, isNotNull);
        bridge.data = snapshot([], detail: {...row('one'), 'active': false});
        await tester.pump(const Duration(seconds: 1));
        expect(
          controller.closeMessage,
          outcome == 'failed' ? '断开失败' : '断开结果未确认',
        );
      }
      controller.setVisible(false);
      await tester.pump();
    });
  }

  testWidgets('late close result cannot attach to another detail', (
    tester,
  ) async {
    bridge.data = snapshot([row('one'), row('two')]);
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.first);
    await controller.disconnect();
    controller.closeDetail();
    controller.openDetail(controller.data!.records.last);
    app.state = const AppSnapshot(
      phase: 'RUNNING',
      core: core,
      resultId: 'close-1',
      connectionStatus: 'closed',
    );
    app.changed();
    expect(controller.detail!.id, 'two');
    expect(controller.detailStatus, ConnectionViewStatus.active);
    expect(controller.closeMessage, isNull);
    controller.setVisible(false);
    await tester.pump();
  });

  testWidgets('missing detail is unknown unless explicitly confirmed absent', (
    tester,
  ) async {
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    bridge.data = snapshot([]);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.detailStatus, ConnectionViewStatus.unknown);
    expect(controller.canClose, isFalse);
    bridge.data = ConnectionSnapshot.fromMap({
      'generation': 7,
      'configId': 'one',
      'revision': 1,
      'connections': [],
      'sampleAgeMs': 0,
      'missingDetailId': 'one',
    });
    await tester.pump(const Duration(seconds: 1));
    expect(controller.detailStatus, ConnectionViewStatus.inactive);
    controller.setVisible(false);
    await tester.pump();
  });

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ConnectionsPage(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    testWidgets('stale row loses active color without reflow (dark=$dark)', (
      tester,
    ) async {
      bridge.data = snapshot([
        row('one'),
        {...row('inactive'), 'active': false},
      ]);
      await show(tester, dark: dark);
      final target = find.text('one.fixture.test');
      final before = tester.getRect(target);
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('待确认'), findsOneWidget);
      expect(find.text('已不活跃'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('待确认')).style!.color,
        ConnectionPalette(dark).warning,
      );
      expect(tester.getRect(target), before);
      bridge.fail = false;
      bridge.data = snapshot([row('new')]);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('待确认'), findsNothing);
      expect(find.text('new.fixture.test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'detail reads continue, disappearing connection stays readable, pop releases polling',
    (tester) async {
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('分流结果'), findsOneWidget);
      final count = bridge.reads;
      bridge.data = snapshot([], detail: {...row('one'), 'active': false});
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, count + 1);
      expect(find.text('已不活跃'), findsOneWidget);
      expect(find.text('one.fixture.test'), findsOneWidget);
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      expect(find.text('暂无连接'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final stopped = bridge.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, stopped);
    },
  );

  for (final (width, scale) in [(390.0, 1.0), (320.0, 2.0)]) {
    testWidgets(
      'live detail field identities survive zh-en-zh and missing values '
      '$width/$scale',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final locale = ValueNotifier(const Locale('zh'));
        addTearDown(locale.dispose);
        final page = ConnectionsPage(app: app);
        await tester.pumpWidget(
          ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (context, value, _) => MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: value,
              theme: AppTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: page,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('one.fixture.test'));
        await tester.pumpAndSettle();
        final scroll = find.byKey(const ValueKey('connection-detail-scroll'));
        final route = ModalRoute.of(tester.element(scroll));
        final fields = find.descendant(
          of: scroll,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is KeyedSubtree &&
                widget.key != null &&
                widget.child is Padding,
          ),
        );
        expect(fields, findsNWidgets(3));
        final keys = tester
            .widgetList<KeyedSubtree>(fields)
            .map((widget) => widget.key!)
            .toList();
        final elements = [
          for (final key in keys) tester.element(find.byKey(key)),
        ];
        final values = ['127.0.0.1', '[::1]:1234', 'Tun'];

        void expectFields(Locale value, List<String> expectedValues) {
          final strings = lookupAppLocalizations(value);
          expect(ModalRoute.of(tester.element(scroll)), same(route));
          expect(fields, findsNWidgets(3));
          expect(
            tester.widgetList<KeyedSubtree>(fields).map((widget) => widget.key),
            keys,
          );
          final labels = [
            strings.targetIp,
            strings.sourceAddress,
            strings.inbound,
          ];
          for (var index = 0; index < keys.length; index++) {
            final field = find.byKey(keys[index]);
            expect(tester.element(field), same(elements[index]));
            expect(
              find.descendant(of: field, matching: find.text(labels[index])),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: field,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is SelectableText &&
                      widget.data == expectedValues[index],
                ),
              ),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        }

        expectFields(locale.value, values);
        for (final value in [const Locale('en'), const Locale('zh')]) {
          setMessageLanguage(
            value.languageCode == 'en' ? AppLanguage.en : AppLanguage.zh,
          );
          locale.value = value;
          await tester.pumpAndSettle();
          expectFields(value, values);
        }

        await tester.drag(scroll, const Offset(0, -1500));
        await tester.pumpAndSettle();
        final before = [
          for (final key in keys) tester.getRect(find.byKey(key)),
        ];
        final missing = row('one');
        missing['metadata'] = {
          ...missing['metadata'] as Map<String, dynamic>,
          'destinationIP': '',
          'sourceIP': '',
          'type': '',
        };
        bridge.data = snapshot([missing]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        final strings = lookupAppLocalizations(locale.value);
        expectFields(locale.value, List.filled(3, strings.notProvided));
        expect([
          for (final key in keys) tester.getRect(find.byKey(key)),
        ], before);

        final restored = row('one');
        restored['metadata'] = {
          ...restored['metadata'] as Map<String, dynamic>,
          'destinationIP': '192.0.2.1',
          'sourceIP': '::2',
          'sourcePort': '4321',
          'type': 'HTTP',
        };
        bridge.data = snapshot([restored]);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expectFields(locale.value, ['192.0.2.1', '[::2]:4321', 'HTTP']);
        expect([
          for (final key in keys) tester.getRect(find.byKey(key)),
        ], before);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('rule filter survives details and follows new observations', (
    tester,
  ) async {
    bridge.data = snapshot([row('one'), row('two', rule: 'Match')]);
    await show(tester);
    await tester.tap(find.byTooltip('筛选命中规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Domain · fixture.test'));
    await tester.pumpAndSettle();
    expect(find.text('one.fixture.test'), findsOneWidget);
    expect(find.text('two.fixture.test'), findsNothing);
    await tester.tap(find.text('one.fixture.test'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    expect(find.text('two.fixture.test'), findsNothing);
    bridge.data = snapshot([row('new')]);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('one.fixture.test'), findsNothing);
    expect(find.text('new.fixture.test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('insertions and removals preserve a surviving reading anchor', (
    tester,
  ) async {
    bridge.data = snapshot(
      List.generate(30, (i) => row(i.toString().padLeft(2, '0'))),
    );
    await show(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    final anchor = find.text('10.fixture.test');
    final before = tester.getTopLeft(anchor);
    bridge.data = snapshot([
      row('00-new'),
      ...List.generate(
        30,
        (i) => row(i.toString().padLeft(2, '0'), download: 9999),
      ),
    ]);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect((tester.getTopLeft(anchor).dy - before.dy).abs(), lessThan(1));
    bridge.data = snapshot(
      List.generate(28, (i) => row((i + 2).toString().padLeft(2, '0'))),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect((tester.getTopLeft(anchor).dy - before.dy).abs(), lessThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unrelated route covering details suspends reads and return resumes',
    (tester) async {
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      final navigator = Navigator.of(tester.element(find.text('连接详情')));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('covered')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = bridge.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, before);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(bridge.reads, greaterThan(before));
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      final listReads = bridge.reads;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, listReads + 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('status distinguishes updating, failure and replaced sessions', (
    tester,
  ) async {
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    expect(controller.detailStatus, ConnectionViewStatus.active);
    bridge.fail = true;
    await tester.pump(const Duration(seconds: 1));
    expect(controller.detailStatus, ConnectionViewStatus.failed);
    app.setForeground(false);
    expect(controller.detailStatus, ConnectionViewStatus.updating);
    app.state = const AppSnapshot(
      phase: 'RUNNING',
      generation: 1,
      core: CoreSnapshot(
        generation: 8,
        phase: 'READY',
        purpose: 'VPN',
        configId: 'one',
        revision: 1,
      ),
    );
    app.changed();
    expect(controller.detailStatus, ConnectionViewStatus.replaced);
    app.state = const AppSnapshot(phase: 'UNKNOWN');
    app.changed();
    expect(controller.detailStatus, ConnectionViewStatus.unknown);
    expect(controller.data, isNull);
    controller.setVisible(false);
  });

  testWidgets('empty failure has one message and no technical explanation', (
    tester,
  ) async {
    bridge.fail = true;
    await show(tester);
    expect(find.text('刷新失败，正在重试'), findsOneWidget);
    expect(find.text('数据来源'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'missing fields omit optional rows and do not invent zero traffic',
    (tester) async {
      bridge.data = snapshot([
        {
          'id': 'empty',
          'metadata': {
            'destinationIP': '::1',
            'destinationPort': '853',
            'network': 'tcp',
          },
        },
      ]);
      await show(tester);
      await tester.tap(find.text('[::1]:853'));
      await tester.pumpAndSettle();
      expect(find.text('端口 853'), findsNothing);
      expect(find.text('源地址'), findsNothing);
      expect(find.text('连接信息'), findsNothing);
      expect(find.text('数据来源'), findsNothing);
      expect(find.text('0 B'), findsNothing);
      expect(find.text('—'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'disconnect color follows enabled, pending and closed state $dark',
      (tester) async {
        await show(tester, dark: dark);
        await tester.tap(find.text('one.fixture.test'));
        await tester.pumpAndSettle();
        final button = find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              (widget.tooltip == '断开连接' || widget.tooltip == '正在断开'),
        );
        final before = tester.getRect(button);
        final error = Theme.of(tester.element(button)).colorScheme.error;
        final icon = find.descendant(
          of: button,
          matching: find.byIcon(Icons.link_off_rounded),
        );
        expect(IconTheme.of(tester.element(icon)).color, error);
        await tester.tap(button);
        await tester.pump();
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator),
              )
              .color,
          error,
        );
        expect(tester.getRect(button), before);
        app.state = const AppSnapshot(
          phase: 'RUNNING',
          core: core,
          resultId: 'close-1',
          connectionStatus: 'closed',
        );
        app.changed();
        await tester.pumpAndSettle();
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(IconTheme.of(tester.element(icon)).color, isNot(error));
        expect(tester.getRect(button), before);
        expect(find.text('已断开'), findsOneWidget);
        expect(app.commands, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('semantic colors distinguish status and traffic, dark=$dark', (
      tester,
    ) async {
      await show(tester, dark: dark);
      final palette = ConnectionPalette(dark);
      expect(
        tester.widget<Text>(find.text('↓ 10 B')).style!.color,
        palette.download,
      );
      expect(
        tester.widget<Text>(find.text('↑ 2 B')).style!.color,
        palette.upload,
      );
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.text('活跃')).style!.color, palette.active);
      expect(find.byTooltip('暂停刷新'), findsNothing);
      expect(find.byTooltip('断开连接'), findsOneWidget);
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('暂停刷新'), findsNothing);
      expect(find.byTooltip('继续刷新'), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.text('已暂停刷新'), findsNothing);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停刷新'), findsNothing);
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester.widget<Text>(find.text('刷新失败')).style!.color,
        palette.warning,
      );
      expect(find.text('数据来源'), findsNothing);
      final surface =
          (dark ? AppTheme.dark : AppTheme.light).colorScheme.surface;
      for (final color in [
        palette.active,
        palette.warning,
        palette.upload,
        palette.download,
      ]) {
        final a = color.computeLuminance();
        final b = surface.computeLuminance();
        final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'long connection fields remain usable at large text, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = 'very-long-目标🌐-${'segment-' * 12}.fixture.test';
        bridge.data = snapshot([
          {
            ...row('long', host: host),
            'chains': ['very-long-node-${'name-' * 12}', '出口🌐'],
            'rulePayload': 'long-rule-${'segment-' * 12}.fixture.test',
          },
        ]);
        await show(tester, dark: dark, scale: 2);
        expect(tester.takeException(), isNull);
        await tester.tapAt(
          tester.getTopLeft(find.text(host)) + const Offset(12, 12),
        );
        await tester.pumpAndSettle();
        expect(find.text('连接详情'), findsOneWidget);
        await tester.drag(
          find.byKey(const ValueKey('connection-detail-scroll')),
          const Offset(0, -1500),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
