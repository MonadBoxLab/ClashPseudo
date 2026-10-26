import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/features/diagnostics/nodes_controller.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_controller.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/mode/tunnel_mode.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/diagnostics/node_fakes.dart' as fixtures;
import '../features/settings/preferences_fakes.dart';
import '../support/readonly_override_store.dart';

class SnapshotBridge extends AppBridge {
  int reads = 0;
  int uiReadiness = 0;
  Future<void> Function()? readyResult;
  @override
  Future<void> uiReady() async {
    uiReadiness++;
    await readyResult?.call();
  }

  final commands = <Map<String, Object?>>[];
  Future<AppSnapshot> Function() read = () async =>
      const AppSnapshot(phase: 'STOPPED');
  Future<void> Function()? submitResult;

  @override
  Future<AppSnapshot> snapshot() {
    reads++;
    return read();
  }

  int nodeReads = 0;
  @override
  Future<Map<String, dynamic>> nodes(
    CoreSnapshot source,
    Map<String, Object?> query,
  ) async {
    nodeReads++;
    return {
      ...fixtures.page(generation: source.generation),
      'configId': source.configId,
      'revision': source.revision,
      'composition': source.composition,
      'purpose': source.purpose,
    };
  }

  StrategySnapshot? strategyData;
  int strategyReads = 0;
  @override
  Future<StrategySnapshot> strategies(int generation) async {
    strategyReads++;
    return strategyData!;
  }

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    await submitResult?.call();
    return OperationAdmission(
      operationId: 'operation-${commands.length}',
      remaining: const Duration(seconds: 120),
    );
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

class _ControlledOverrideStore extends ReadOnlyOverrideStore {
  Future<List<OverrideEntry>> Function()? readResult;

  @override
  Future<List<OverrideEntry>> read() => readResult?.call() ?? super.read();
}

void main() {
  late SnapshotBridge bridge;
  late MemoryStore store;
  late AppController controller;
  setUp(() {
    bridge = SnapshotBridge();
    store = MemoryStore();
    controller = AppController(
      bridge,
      store: store,
      preferencesStore: MemoryPreferencesStore(),
      overrideStore: _ControlledOverrideStore(),
    );
  });
  tearDown(() => controller.dispose());

  testWidgets('preview admission stays busy through its first state readback', (
    tester,
  ) async {
    store.readResult = () async => ConfigCollection(
      selectedId: 'main',
      entries: const [
        ConfigEntry(
          id: 'main',
          name: 'Controlled',
          kind: ConfigKind.local,
          revision: 1,
          body: 'rules:\n  - MATCH,DIRECT\n',
        ),
      ],
    );
    await controller.refresh();
    final readback = Completer<AppSnapshot>();
    bridge.read = () => readback.future;
    final reader = NodesController(controller);
    addTearDown(reader.dispose);
    reader.setVisible(true);
    await tester.pump();
    expect(bridge.commands.single['action'], 'prepareStrategies');
    expect(controller.dispatching, isFalse);
    expect(controller.state.busy, isFalse);
    expect(controller.busy, isTrue);
    expect(controller.canEdit, isFalse);
    expect(reader.failed, isFalse);
    expect(bridge.nodeReads, 0);
    await controller.submit({
      'action': 'prepareStrategies',
      'id': 'main',
      'revision': 1,
    });
    expect(bridge.commands, hasLength(1));
    readback.complete(
      const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'operation-1',
        resultSuccess: true,
        core: CoreSnapshot(
          generation: 1,
          phase: 'READY',
          purpose: 'PREVIEW',
          configId: 'main',
          revision: 1,
          composition: 'controlled-composition',
        ),
      ),
    );
    await tester.pump();
    expect(controller.busy, isFalse);
    expect(controller.canEdit, isTrue);
    expect(reader.current, isTrue);
    expect(reader.failed, isFalse);
    expect(bridge.nodeReads, 1);
  });

  testWidgets('strategy preview resumes after submission state readback', (
    tester,
  ) async {
    store.readResult = () async => ConfigCollection(
      selectedId: 'main',
      entries: const [
        ConfigEntry(
          id: 'main',
          name: 'Controlled',
          kind: ConfigKind.local,
          revision: 1,
          body: 'rules:\n  - MATCH,DIRECT\n',
        ),
      ],
    );
    bridge.strategyData = StrategySnapshot(
      generation: 1,
      configId: 'main',
      revision: 1,
      purpose: 'PREVIEW',
      composition: 'controlled-composition',
      mode: TunnelMode.rule,
      globalReferenced: false,
      groups: const [],
      unrestored: const {},
    );
    await controller.refresh();
    final readback = Completer<AppSnapshot>();
    bridge.read = () => readback.future;
    final reader = StrategyController(controller);
    try {
      reader.setVisible(true);
      await tester.pump();
      expect(bridge.commands.single['action'], 'prepareStrategies');
      expect(controller.dispatching, isFalse);
      expect(controller.state.busy, isFalse);
      expect(controller.busy, isTrue);
      expect(reader.current, isFalse);
      expect(bridge.strategyReads, 0);
      readback.complete(
        const AppSnapshot(
          phase: 'STOPPED',
          resultId: 'operation-1',
          resultSuccess: true,
          core: CoreSnapshot(
            generation: 1,
            phase: 'READY',
            purpose: 'PREVIEW',
            configId: 'main',
            revision: 1,
            composition: 'controlled-composition',
          ),
        ),
      );
      await tester.pump();
      expect(controller.busy, isFalse);
      expect(reader.current, isTrue);
      expect(reader.readErrorMessage, isNull);
      expect(bridge.strategyReads, 1);
    } finally {
      reader.dispose();
    }
  });

  testWidgets('an old readback keeps the newer Stop submission identity', (
    tester,
  ) async {
    await controller.refresh();
    var resourceBusy = true;
    bridge.read = () async =>
        AppSnapshot(phase: 'STOPPED', resourceBusy: resourceBusy);
    final oldStoreRead = Completer<ConfigCollection>();
    store.readResult = () => oldStoreRead.future;
    final first = controller.submit({'action': 'updateResource'});
    await tester.pump();
    expect(controller.dispatching, isFalse);
    expect(controller.canStopBackground, isTrue);
    final stopReceipt = Completer<void>();
    bridge.submitResult = () => stopReceipt.future;
    final stopped = controller.submit({'action': 'stop'});
    await tester.pump();
    expect(bridge.commands, hasLength(2));
    resourceBusy = false;
    store.readResult = () async => ConfigCollection(entries: []);
    oldStoreRead.complete(ConfigCollection(entries: []));
    await tester.pump();
    await first;
    expect(controller.dispatching, isTrue);
    await controller.refresh();
    expect(controller.state.busy, isFalse);
    final stopReadback = Completer<AppSnapshot>();
    bridge.read = () => stopReadback.future;
    stopReceipt.complete();
    await tester.pump();
    expect(controller.dispatching, isFalse);
    expect(controller.state.busy, isFalse);
    expect(controller.busy, isTrue);
    expect(controller.canEdit, isFalse);
    stopReadback.complete(
      const AppSnapshot(phase: 'STOPPED', resultId: 'operation-2'),
    );
    await stopped;
    expect(controller.busy, isFalse);
    expect(controller.canEdit, isTrue);
  });

  testWidgets('a failed state readback releases its submission wait', (
    tester,
  ) async {
    await controller.refresh();
    final readback = Completer<AppSnapshot>();
    bridge.read = () => readback.future;
    final submitted = controller.submit({
      'action': 'prepareStrategies',
      'id': 'main',
      'revision': 1,
    });
    await tester.pump();
    expect(controller.busy, isTrue);
    await tester.pump(const Duration(seconds: 5));
    await submitted;
    expect(controller.dispatching, isFalse);
    expect(controller.busy, isFalse);
    expect(controller.canEdit, isFalse);
    expect(
      controller.platformErrorMessage,
      messages.temporaryStatusUnavailable,
    );
    readback.complete(const AppSnapshot(phase: 'STOPPED'));
    await tester.pump();
    expect(
      controller.platformErrorMessage,
      messages.temporaryStatusUnavailable,
    );
    controller.setForeground(false);
  });

  test(
    'visible unfocused keeps reads while feedback waits for interaction',
    () async {
      await controller.initialize();
      final before = bridge.reads;
      controller.setInteractive(false);
      expect(controller.foreground, isTrue);
      expect(controller.interactive, isFalse);
      var ready = false;
      final pending = controller.waitUntilInteractive().then(
        (value) => ready = value,
      );
      await controller.refresh();
      expect(bridge.reads, greaterThan(before));
      expect(ready, isFalse);
      controller.setInteractive(true);
      await pending;
      expect(ready, isTrue);
    },
  );

  test(
    'interaction waits through unsupported window and actual hiding',
    () async {
      controller.setWindowSupported(false);
      var ready = false;
      final pending = controller.waitUntilInteractive().then(
        (value) => ready = value,
      );
      controller.setForeground(false);
      controller.setWindowSupported(true);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      controller.setForeground(true);
      await pending;
      expect(ready, isTrue);
      expect(await controller.waitUntilInteractive(), isTrue);
    },
  );

  test('disposing the owner completes pending interaction waits', () async {
    final owner = AppController(bridge);
    owner.setInteractive(false);
    final pending = owner.waitUntilInteractive();
    owner.dispose();
    expect(await pending, isFalse);
    expect(await owner.waitUntilInteractive(), isFalse);
  });

  testWidgets('readiness failure is retried as initialization, not a command', (
    tester,
  ) async {
    bridge.readyResult = () => Future.error(StateError('not ready'));
    await controller.initialize();
    expect(controller.commandErrorMessage, isNull);
    expect(controller.platformError, isNotNull);
    expect(controller.state.phase, 'UNKNOWN');
    expect(bridge.reads, 0);
    expect(bridge.commands, isEmpty);
    bridge.readyResult = null;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(bridge.uiReadiness, 2);
    expect(controller.platformError, isNull);
    expect(controller.error, isNull);
    expect(controller.state.phase, 'STOPPED');
    expect(bridge.commands, isEmpty);
  });

  testWidgets('late readiness never leaves a rejected-command status behind', (
    tester,
  ) async {
    final readiness = Completer<void>();
    bridge.readyResult = () => readiness.future;
    final initialized = controller.initialize();
    await tester.pump(const Duration(seconds: 5));
    await initialized;
    expect(controller.commandErrorMessage, isNull);
    expect(controller.platformError, isNotNull);
    controller.commandErrorMessage = messages.operationNotCompletedRetry;
    readiness.complete();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(controller.platformError, isNull);
    expect(controller.commandErrorMessage, messages.operationNotCompletedRetry);
    expect(bridge.commands, isEmpty);
  });

  for (final failedStore in ['configurations', 'overrides', 'preferences']) {
    testWidgets(
      'whole projection stays noncurrent after $failedStore read failure',
      (tester) async {
        final parts = controller.overrideStore! as _ControlledOverrideStore;
        final settings = controller.preferencesStore! as MemoryPreferencesStore;
        store.readResult = () async => ConfigCollection(
          entries: const [
            ConfigEntry(
              id: 'same',
              name: 'Same',
              kind: ConfigKind.local,
              revision: 1,
              body: 'old',
            ),
          ],
          selectedId: 'same',
        );
        parts.entries = const [
          OverrideEntry(
            id: 'part',
            name: 'Part',
            kind: ConfigKind.local,
            revision: 1,
            body: 'old',
          ),
        ];
        await controller.refresh();
        final before = controller.collection;
        final beforeParts = controller.overrides;
        final beforeSettings = controller.preferences;
        expect(controller.configsCurrent, isTrue);
        expect(controller.canEdit, isTrue);
        expect(controller.canChangePreferences, isTrue);
        final fresh = ConfigCollection(
          entries: const [
            ConfigEntry(
              id: 'same',
              name: 'Same',
              kind: ConfigKind.local,
              revision: 2,
              body: 'new',
            ),
          ],
          selectedId: 'same',
        );
        store.readResult = () async => fresh;
        parts.entries = const [
          OverrideEntry(
            id: 'part',
            name: 'Part',
            kind: ConfigKind.local,
            revision: 2,
            body: 'new',
          ),
        ];
        settings.value = settings.value.withAppearance('language', 'en');
        final failure = switch (failedStore) {
          'configurations' => messages.temporaryConfigsUnreadable,
          'overrides' => messages.temporaryOverridesUnreadable,
          _ => messages.temporarySettingsUnreadable,
        };
        switch (failedStore) {
          case 'configurations':
            store.readResult = () async => throw ConfigFailure(failure);
          case 'overrides':
            parts.readResult = () async => throw ConfigFailure(failure);
          case 'preferences':
            settings.readResult = () async => throw ConfigFailure(failure);
        }
        await controller.refresh();
        expect(controller.collection, same(before));
        expect(controller.overrides, same(beforeParts));
        expect(controller.preferences, same(beforeSettings));
        expect(controller.configsCurrent, isFalse);
        expect(controller.canEdit, isFalse);
        expect(controller.canChangePreferences, isFalse);
        expect(controller.errorMessage, failure);
        expect(controller.state.storageReady, isTrue);
        expect(controller.state.busy, isFalse);
        store.readResult = () async => fresh;
        parts.readResult = null;
        settings.readResult = null;
        await controller.refresh();
        expect(controller.collection, same(fresh));
        expect(controller.overrides.single.body, 'new');
        expect(controller.preferences.language.name, 'en');
        expect(controller.configsCurrent, isTrue);
        expect(controller.canEdit, isTrue);
        expect(controller.canChangePreferences, isTrue);
        expect(controller.errorMessage, isNull);
      },
    );
  }

  testWidgets(
    'whole projection recovers only when every failed store reads successfully',
    (tester) async {
      final parts = controller.overrideStore! as _ControlledOverrideStore;
      await controller.refresh();
      final before = controller.collection;
      final fresh = ConfigCollection(
        entries: const [
          ConfigEntry(
            id: 'new',
            name: 'New',
            kind: ConfigKind.local,
            revision: 1,
            body: '{}',
          ),
        ],
      );
      store.readResult = () async =>
          throw ConfigFailure(messages.temporaryConfigsUnreadable);
      parts.readResult = () async =>
          throw ConfigFailure(messages.temporaryOverridesUnreadable);
      await controller.refresh();
      expect(controller.collection, same(before));
      expect(controller.canChangePreferences, isFalse);
      store.readResult = () async => fresh;
      await controller.refresh();
      expect(controller.configErrorMessage, isNull);
      expect(
        controller.overrideErrorMessage,
        messages.temporaryOverridesUnreadable,
      );
      expect(controller.collection, same(before));
      expect(controller.configsCurrent, isFalse);
      expect(controller.canChangePreferences, isFalse);
      parts.readResult = null;
      await controller.refresh();
      expect(controller.collection, same(fresh));
      expect(controller.configsCurrent, isTrue);
      expect(controller.canChangePreferences, isTrue);
    },
  );

  testWidgets(
    'whole projection exposes an initial override read error without closing storage',
    (tester) async {
      final parts = controller.overrideStore! as _ControlledOverrideStore;
      parts.readResult = () async =>
          throw ConfigFailure(messages.temporaryOverridesUnreadable);
      await controller.refresh();
      expect(controller.configsLoaded, isFalse);
      expect(controller.preferencesLoaded, isFalse);
      expect(controller.errorMessage, messages.temporaryOverridesUnreadable);
      expect(controller.configsCurrent, isFalse);
      expect(controller.canChangePreferences, isFalse);
      expect(controller.state.storageReady, isTrue);
      expect(controller.state.storageRestoring, isFalse);
      expect(controller.state.busy, isFalse);
      controller.setForeground(false);
    },
  );

  testWidgets('reads crossing a restore publish only complete same-epoch data', (
    tester,
  ) async {
    ConfigCollection config(String body) => ConfigCollection(
      entries: [
        ConfigEntry(
          id: 'same',
          name: 'Same',
          kind: ConfigKind.local,
          revision: 1,
          body: body,
        ),
      ],
      selectedId: 'same',
    );
    OverrideEntry part(String body) => OverrideEntry(
      id: 'same-part',
      name: 'Same part',
      kind: ConfigKind.local,
      revision: 1,
      body: body,
    );
    var epoch = 1;
    bridge.read = () async =>
        AppSnapshot(phase: 'STOPPED', storageEpoch: epoch);
    final parts = controller.overrideStore! as ReadOnlyOverrideStore;
    final settings = controller.preferencesStore! as MemoryPreferencesStore;
    store.readResult = () async => config('old');
    parts.entries = [part('old')];
    settings.value = settings.value.withAppearance('language', 'zh');
    await controller.refresh();
    expect(controller.storageEpoch, 1);
    final projections = <String>[];
    controller.addListener(
      () => projections.add(
        '${controller.collection.selected?.body}/${controller.overrides.firstOrNull?.body}/'
        '${controller.preferences.language.name}/${controller.storageEpoch}',
      ),
    );
    final oldRead = Completer<ConfigCollection>();
    store.readResult = () => oldRead.future;
    final refreshing = controller.refresh();
    await tester.pump();
    epoch = 2;
    store.readResult = () async => config('restored');
    parts.entries = [part('restored')];
    settings.value = settings.value.withAppearance('language', 'en');
    oldRead.complete(config('old'));
    await refreshing;
    expect(controller.collection.selected!.body, 'restored');
    expect(controller.overrides.single.body, 'restored');
    expect(controller.preferences.language.name, 'en');
    expect(controller.storageEpoch, 2);
    expect(store.reads, 3);
    expect(projections, contains('restored/restored/en/2'));
    expect(
      projections.every(
        (value) => value == 'old/old/zh/1' || value == 'restored/restored/en/2',
      ),
      isTrue,
    );
  });

  testWidgets('closed storage keeps the complete projection and permits Stop', (
    tester,
  ) async {
    bridge.read = () async =>
        const AppSnapshot(phase: 'RUNNING', storageEpoch: 1);
    await controller.refresh();
    final reads = store.reads;
    bridge.read = () async => const AppSnapshot(
      phase: 'RUNNING',
      storageReady: false,
      storageRestoring: true,
      storageEpoch: 2,
    );
    await controller.refresh();
    expect(store.reads, reads);
    expect(controller.storageEpoch, 1);
    expect(controller.canEdit, isFalse);
    expect(controller.canChangePreferences, isFalse);
    expect(controller.canToggle, isTrue);
    expect(await controller.submit({'action': 'stop'}), 'operation-1');
    expect(bridge.commands.single, {'action': 'stop'});
    expect(store.reads, reads);
    controller.setForeground(false);
  });

  testWidgets(
    'submission retains a captured draft epoch instead of relabelling it',
    (tester) async {
      bridge.read = () async =>
          const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      await controller.refresh();
      final draftEpoch = controller.storageEpoch;
      bridge.read = () async =>
          const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
      await controller.refresh();
      await controller.submit({
        'action': 'renameConfig',
        'id': 'same',
        'name': 'Draft',
        'storageEpoch': draftEpoch,
      });
      expect(bridge.commands.single['storageEpoch'], 1);
      await controller.submit({
        'action': 'renameConfig',
        'id': 'same',
        'name': 'Fresh',
      });
      expect(bridge.commands.last['storageEpoch'], 2);
    },
  );

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
    expect(bridge.commands, [
      {...command, 'storageEpoch': 0},
    ]);

    bridge.read = () async => const AppSnapshot(
      phase: 'RUNNING',
      operation: AppMessage('stageStoppingOld'),
    );
    accepted.complete();
    expect(await first, 'operation-1');
    expect(controller.dispatching, isFalse);
    expect(controller.busy, isTrue);
    expect(await controller.submit(command), isNull);
    expect(bridge.commands, [
      {...command, 'storageEpoch': 0},
    ]);

    bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
    await controller.refresh();
    expect(controller.canEdit, isTrue);
    expect(await controller.submit(command), 'operation-2');
    expect(bridge.commands, [
      {...command, 'storageEpoch': 0},
      {...command, 'storageEpoch': 0},
    ]);
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
      expect(bridge.commands, [
        {...command, 'storageEpoch': 0},
      ]);
      accepted.complete();
      await pending;
      expect(controller.lastCommandAutomatic, automatic);
    });
  }

  testWidgets(
    'mode read failure retries without losing running or issuing commands',
    (tester) async {
      bridge.read = () async => const AppSnapshot(
        phase: 'RUNNING',
        modeError: AppMessage('androidErrorModeUnconfirmed'),
      );
      await controller.refresh();
      expect(controller.canToggle, isTrue);
      expect(controller.canChangeMode, isFalse);
      expect(controller.platformError, isNull);
      await tester.pump(const Duration(seconds: 1));
      // Each successful refresh brackets the three stores with two snapshots.
      expect(bridge.reads, 4);
      controller.setForeground(false);
      await tester.pump(const Duration(seconds: 60));
      expect(bridge.reads, 4);
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
    expect(bridge.uiReadiness, 1);
    expect(controller.commandErrorMessage, isNull);
    expect(controller.loading, isFalse);
    expect(controller.configsCurrent, isTrue);
    final pending = Completer<AppSnapshot>();
    bridge.read = () => pending.future;
    final future = controller.refresh();
    expect(controller.loading, isFalse);
    expect(controller.state.phase, 'STOPPED');
    pending.complete(
      const AppSnapshot(
        phase: 'UNKNOWN',
        error: AppMessage('androidErrorReleaseUnconfirmed'),
      ),
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
      expect(bridge.reads, 3);
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
      store.readResult = () async =>
          throw const ConfigFailure(AppMessage('configStoreUnreadable'));
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
    final second = controller.refresh();
    final third = controller.refresh();
    bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
    old.complete(const AppSnapshot(phase: 'RUNNING'));
    await Future.wait([first, second, third]);
    expect(bridge.reads, 3);
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
      bridge.submitResult = () async => throw PlatformException(
        code: 'unavailable',
        details: messages.requestNotAccepted.toMap(),
      );
      final submitted = controller.submit({'action': 'start'});
      await tester.pump();
      bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
      old.complete(const AppSnapshot(phase: 'RUNNING'));
      await read;
      await submitted;
      expect(controller.state.phase, 'STOPPED');
      expect(controller.commandErrorMessage, messages.requestNotAccepted);
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
    final local = AppController(
      bridge,
      store: store,
      preferencesStore: MemoryPreferencesStore(),
      overrideStore: ReadOnlyOverrideStore(),
    );
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
