import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class SnapshotBridge extends AppBridge {
  int reads = 0;
  final commands = <Map<String, Object?>>[];
  Future<AppSnapshot> Function() read = () async =>
      const AppSnapshot(phase: 'STOPPED');
  Future<void> Function()? submitResult;

  @override
  Future<AppSnapshot> snapshot() {
    reads++;
    return read();
  }

  @override
  Future<String?> submit(Map<String, Object?> command) async {
    commands.add(command);
    await submitResult?.call();
    return 'operation-${commands.length}';
  }
}

class MemoryStore extends ConfigStore {
  MemoryStore() : super(Directory.systemTemp);
  int reads = 0;
  Future<ConfigCollection> Function() readResult = () async =>
      ConfigCollection(entries: []);
  @override
  Future<ConfigCollection> read() {
    reads++;
    return readResult();
  }
}

void main() {
  late SnapshotBridge bridge;
  late MemoryStore store;
  late AppController controller;
  setUp(() {
    bridge = SnapshotBridge();
    store = MemoryStore();
    controller = AppController(bridge, store: store);
  });
  tearDown(() => controller.dispose());

  testWidgets('submission and platform work reject repeated commands', (
    tester,
  ) async {
    await controller.refresh();
    final accepted = Completer<void>();
    bridge.submitResult = () => accepted.future;
    const command = {'action': 'select', 'id': 'second'};
    final first = controller.submit(command);
    expect(controller.dispatching, isTrue);
    expect(controller.canEdit, isFalse);
    expect(await controller.submit(command), isNull);
    expect(bridge.commands, [command]);

    bridge.read = () async =>
        const AppSnapshot(phase: 'RUNNING', operation: '正在停止旧接管');
    accepted.complete();
    expect(await first, 'operation-1');
    expect(controller.dispatching, isFalse);
    expect(controller.busy, isTrue);
    expect(await controller.submit(command), isNull);
    expect(bridge.commands, [command]);

    bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
    await controller.refresh();
    expect(controller.canEdit, isTrue);
    expect(await controller.submit(command), 'operation-2');
    expect(bridge.commands, [command, command]);
  });

  for (final automatic in [false, true]) {
    testWidgets('rejected commands retain feedback ownership ($automatic)', (
      tester,
    ) async {
      await controller.refresh();
      final accepted = Completer<void>();
      bridge.submitResult = () => accepted.future;
      const command = {'action': 'prepareStrategies', 'id': 'first'};
      final pending = controller.submit(command, automatic: automatic);
      final owner = controller.lastCommand;
      expect(
        await controller.submit({'action': 'start'}, automatic: !automatic),
        isNull,
      );
      expect(controller.lastCommand, same(owner));
      expect(controller.lastCommandAutomatic, automatic);
      expect(bridge.commands, [command]);
      accepted.complete();
      await pending;
      expect(controller.lastCommandAutomatic, automatic);
    });
  }

  testWidgets(
    'mode read failure retries without losing running or issuing commands',
    (tester) async {
      bridge.read = () async =>
          const AppSnapshot(phase: 'RUNNING', modeError: 'mode unavailable');
      await controller.refresh();
      expect(controller.canToggle, isTrue);
      expect(controller.canChangeMode, isFalse);
      expect(controller.platformError, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.reads, 2);
      controller.setForeground(false);
      await tester.pump(const Duration(seconds: 60));
      expect(bridge.reads, 2);
      bridge.read = () async =>
          const AppSnapshot(phase: 'RUNNING', mode: TunnelMode.direct);
      controller.setForeground(true);
      await tester.pump();
      expect(controller.state.mode, TunnelMode.direct);
      expect(controller.canChangeMode, isTrue);
      final count = bridge.reads;
      await tester.pump(const Duration(seconds: 60));
      expect(bridge.reads, count);
      expect(bridge.commands, isEmpty);
    },
  );

  testWidgets('first read, silent success and native unknown never submit', (
    tester,
  ) async {
    expect(controller.loading, isTrue);
    await controller.initialize();
    expect(controller.loading, isFalse);
    expect(controller.configsCurrent, isTrue);
    final pending = Completer<AppSnapshot>();
    bridge.read = () => pending.future;
    final future = controller.refresh();
    expect(controller.loading, isFalse);
    expect(controller.state.phase, 'STOPPED');
    pending.complete(
      const AppSnapshot(phase: 'UNKNOWN', error: 'cleanup failed'),
    );
    await future;
    expect(controller.platformError, isNull);
    expect(controller.canToggle, isFalse);
    final reads = bridge.reads;
    await tester.pump(const Duration(seconds: 60));
    expect(bridge.reads, reads);
    expect(bridge.commands, isEmpty);
  });

  testWidgets(
    'read failures retry with capped backoff, success stops polling',
    (tester) async {
      bridge.read = () async => throw StateError('unavailable');
      await controller.refresh();
      expect(controller.platformError, isNotNull);
      expect(controller.state.phase, 'UNKNOWN');
      for (final seconds in [1, 2, 5, 10, 30, 30]) {
        final before = bridge.reads;
        await tester.pump(Duration(milliseconds: seconds * 1000 - 1));
        expect(bridge.reads, before);
        await tester.pump(const Duration(milliseconds: 1));
        expect(bridge.reads, before + 1);
      }
      bridge.read = () async => const AppSnapshot(phase: 'RUNNING');
      await tester.pump(const Duration(seconds: 30));
      expect(controller.state.running, isTrue);
      expect(controller.platformError, isNull);
      final count = bridge.reads;
      await tester.pump(const Duration(seconds: 60));
      expect(bridge.reads, count);
      expect(bridge.commands, isEmpty);
    },
  );

  testWidgets(
    'background cancels retry; resume immediately reads without startup',
    (tester) async {
      bridge.read = () async => throw StateError('offline');
      await controller.refresh();
      controller.setForeground(false);
      await tester.pump(const Duration(minutes: 2));
      expect(bridge.reads, 1);
      bridge.read = () async => const AppSnapshot(phase: 'RUNNING');
      controller.setForeground(true);
      await tester.pump();
      expect(bridge.reads, 2);
      expect(controller.state.running, isTrue);
      expect(bridge.commands, isEmpty);
    },
  );

  testWidgets('platform timeout ignores its late success', (tester) async {
    final old = Completer<AppSnapshot>();
    bridge.read = () => old.future;
    final first = controller.refresh();
    await tester.pump(const Duration(seconds: 5));
    await first;
    expect(controller.loading, isFalse);
    expect(controller.platformError, isNotNull);
    bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
    await tester.pump(const Duration(seconds: 1));
    old.complete(const AppSnapshot(phase: 'RUNNING'));
    await tester.pump();
    expect(controller.state.phase, 'STOPPED');
    expect(controller.platformError, isNull);
  });

  testWidgets(
    'configuration timeout preserves confirmed service and ignores late data',
    (tester) async {
      bridge.read = () async => const AppSnapshot(phase: 'RUNNING');
      final old = Completer<ConfigCollection>();
      store.readResult = () => old.future;
      final first = controller.refresh();
      await tester.pump();
      expect(controller.state.running, isTrue);
      expect(controller.canToggle, isTrue);
      await tester.pump(const Duration(seconds: 5));
      await first;
      expect(controller.configError, isNotNull);
      expect(controller.configsLoaded, isFalse);
      expect(controller.canEdit, isFalse);
      expect(controller.canToggle, isTrue);
      store.readResult = () async => ConfigCollection(entries: []);
      await tester.pump(const Duration(seconds: 1));
      old.complete(
        ConfigCollection(
          entries: [
            ConfigEntry(
              id: 'old',
              name: 'Old',
              source: 'https://example.test',
              revision: 1,
              body: 'data',
            ),
          ],
        ),
      );
      await tester.pump();
      expect(controller.collection.entries, isEmpty);
      expect(controller.configsCurrent, isTrue);
    },
  );

  testWidgets(
    'damaged configuration retains labelled old records and permits stop',
    (tester) async {
      final configs = ConfigCollection(
        entries: [
          ConfigEntry(
            id: 'one',
            name: 'One',
            source: 'https://example.test',
            revision: 1,
            body: 'data',
          ),
        ],
        selectedId: 'one',
      );
      store.readResult = () async => configs;
      bridge.read = () async =>
          const AppSnapshot(phase: 'RUNNING', configId: 'one');
      await controller.refresh();
      store.readResult = () async => throw const ConfigFailure('损坏的配置');
      await controller.refresh();
      expect(controller.collection, same(configs));
      expect(controller.configsLoaded, isTrue);
      expect(controller.configsCurrent, isFalse);
      expect(controller.canEdit, isFalse);
      expect(controller.canToggle, isTrue);
      expect(controller.state.running, isTrue);
      controller.setForeground(false);
    },
  );

  testWidgets('overlapping refreshes coalesce and invalidate old snapshot', (
    tester,
  ) async {
    final old = Completer<AppSnapshot>();
    bridge.read = () => old.future;
    final first = controller.refresh();
    await controller.refresh();
    await controller.refresh();
    bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
    old.complete(const AppSnapshot(phase: 'RUNNING'));
    await first;
    expect(bridge.reads, 2);
    expect(controller.state.phase, 'STOPPED');
    expect(store.reads, 1);
  });

  testWidgets(
    'new command invalidates old read and read success retains submission error',
    (tester) async {
      await controller.refresh();
      final old = Completer<AppSnapshot>();
      bridge.read = () => old.future;
      final read = controller.refresh();
      bridge.submitResult = () async =>
          throw PlatformException(code: 'unavailable', message: '未被受理');
      await controller.submit({'action': 'start'});
      bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
      old.complete(const AppSnapshot(phase: 'RUNNING'));
      await read;
      expect(controller.state.phase, 'STOPPED');
      expect(controller.commandError, '未被受理');
      expect(bridge.commands, hasLength(1));
    },
  );

  testWidgets('background invalidates pending read without blocking resume', (
    tester,
  ) async {
    final old = Completer<AppSnapshot>();
    bridge.read = () => old.future;
    final first = controller.refresh();
    controller.setForeground(false);
    bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
    controller.setForeground(true);
    await tester.pump();
    expect(controller.state.phase, 'STOPPED');
    old.complete(const AppSnapshot(phase: 'RUNNING'));
    await first;
    expect(controller.state.phase, 'STOPPED');
  });

  testWidgets('dispose ignores pending completion and releases retry timer', (
    tester,
  ) async {
    final local = AppController(bridge, store: store);
    final old = Completer<AppSnapshot>();
    bridge.read = () => old.future;
    var notifications = 0;
    local.addListener(() => notifications++);
    final read = local.refresh();
    local.dispose();
    old.complete(const AppSnapshot(phase: 'RUNNING'));
    await read;
    await tester.pump(const Duration(minutes: 1));
    expect(notifications, 0);
    expect(local.state.phase, 'UNKNOWN');
  });
}
