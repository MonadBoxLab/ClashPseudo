import 'dart:async';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/connections/connection_controller.dart';
import 'package:clash_pseudo/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/features/connections/connections_page.dart';
import 'package:clash_pseudo/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
);
Map<String, dynamic> row(
  String id, {
  int download = 10,
  String type = 'Tun',
  String rule = 'Domain',
  String? host,
}) => {
  'id': id,
  'start': '2026-10-15T10:00:00Z',
  'upload': 2,
  'download': download,
  'chains': ['node', '出口'],
  'rule': rule,
  'rulePayload': 'fixture.test',
  'metadata': {
    'host': host ?? '$id.fixture.test',
    'destinationIP': '127.0.0.1',
    'destinationPort': '18880',
    'sourceIP': '::1',
    'sourcePort': '1234',
    'network': 'tcp',
    'type': type,
  },
};
ConnectionSnapshot snapshot(
  List<Map<String, dynamic>> rows, {
  int generation = 7,
}) => ConnectionSnapshot.fromMap({
  'generation': generation,
  'configId': 'one',
  'revision': 1,
  'connections': rows,
});

class ConnectionBridgeFake extends AppBridge {
  int reads = 0;
  bool fail = false;
  Completer<ConnectionSnapshot>? pending;
  ConnectionSnapshot data = snapshot([row('one')]);
  @override
  Future<ConnectionSnapshot> connections(CoreSnapshot core) {
    reads++;
    if (fail) return Future.error(StateError('unavailable'));
    return pending?.future ?? Future.value(data);
  }
}

class ConnectionAppFake extends AppController {
  ConnectionAppFake(super.platform) {
    loading = false;
    configsLoaded = true;
    state = const AppSnapshot(phase: 'RUNNING', core: core);
  }
  @override
  Future<void> refresh() async {}
  void changed() => notifyListeners();
}

void main() {
  late ConnectionBridgeFake bridge;
  late ConnectionAppFake app;
  late ConnectionController controller;
  setUp(() {
    bridge = ConnectionBridgeFake();
    app = ConnectionAppFake(bridge);
    controller = ConnectionController(app);
  });
  tearDown(() {
    controller.dispose();
    app.dispose();
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
    expect(bridge.reads, 3);
    expect(controller.data, isNull);
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
      expect(controller.detailStatus, '最近观察已过期');
      expect(controller.data!.records.length, 1);
      bridge.fail = false;
      bridge.data = snapshot([]);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.data!.records, isEmpty);
      expect(controller.detail!.id, 'one');
      expect(controller.detailStatus, '已不在当前活动快照中');
      controller.setVisible(false);
    },
  );

  testWidgets('pause freezes display, not observation or stop state', (
    tester,
  ) async {
    controller.setVisible(true);
    await tester.pump();
    controller.openDetail(controller.data!.records.single);
    controller.togglePaused();
    bridge.data = snapshot([row('one', download: 20)]);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.displayed!.records.single.download, 10);
    expect(controller.detail!.download, 10);
    expect(controller.data!.records.single.download, 20);
    controller.togglePaused();
    expect(controller.detail!.download, 20);
    controller.togglePaused();
    app.state = const AppSnapshot(phase: 'STOPPED');
    app.changed();
    expect(controller.displayed, isNull);
    expect(controller.detailStatus, '接管已停止 · 最后观察');
    expect(controller.detail!.download, 20);
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

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
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

  testWidgets(
    'detail reads continue, disappearing connection stays readable, pop releases polling',
    (tester) async {
      await show(tester);
      await tester.tap(find.text('one.fixture.test'));
      await tester.pumpAndSettle();
      expect(find.text('分流结果'), findsOneWidget);
      final count = bridge.reads;
      bridge.data = snapshot([]);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, count + 1);
      expect(find.text('已不在当前活动快照中'), findsOneWidget);
      expect(find.text('one.fixture.test'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('当前未观察到活动连接'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final stopped = bridge.reads;
      await tester.pump(const Duration(seconds: 10));
      expect(bridge.reads, stopped);
    },
  );

  testWidgets(
    'rule filter survives details and pause freezes new observations',
    (tester) async {
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
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('two.fixture.test'), findsNothing);
      await tester.tap(find.text('暂停刷新'));
      bridge.data = snapshot([row('new')]);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('one.fixture.test'), findsOneWidget);
      expect(find.text('new.fixture.test'), findsNothing);
      await tester.tap(find.text('继续刷新'));
      await tester.pump();
      expect(find.text('new.fixture.test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('insertions and removals preserve a surviving reading anchor', (
    tester,
  ) async {
    bridge.data = snapshot(
      List.generate(30, (i) => row(i.toString().padLeft(2, '0'))),
    );
    await show(tester);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -900),
    );
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
      await tester.pageBack();
      await tester.pumpAndSettle();
      final listReads = bridge.reads;
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, listReads + 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'long connection fields remain usable at large text, dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final host = 'very-long-目标🌐-${'segment-' * 12}.fixture.test';
        bridge.data = snapshot([row('long', host: host)]);
        await show(tester, dark: dark, scale: 2);
        expect(tester.takeException(), isNull);
        await tester.tapAt(
          tester.getTopLeft(find.text(host)) + const Offset(12, 12),
        );
        await tester.pumpAndSettle();
        expect(find.text('连接详情'), findsOneWidget);
        await tester.drag(
          find.byType(SingleChildScrollView).last,
          const Offset(0, -1500),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
