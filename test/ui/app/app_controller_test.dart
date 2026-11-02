import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_controller.dart';
import 'package:clash_pseudo/src/ui/strategies/strategy_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/preferences_fakes.dart';
import '../../support/readonly_override_store.dart';
import '../diagnostics/nodes/node_fakes.dart' as fixtures;

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
  bool missingReceipt = false;

  @override
  Future<AppSnapshot> snapshot() {
    reads++;
    return read();
  }

  int pathReads = 0;
  Future<Map<String, dynamic>> Function() readPaths = () async => {
    'storageEpoch': 0,
  };

  @override
  Future<Map<String, dynamic>> paths() {
    pathReads++;
    return readPaths();
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
  Future<StrategySnapshot> strategies(CoreSnapshot coreIdentity) async {
    strategyReads++;
    return strategyData!;
  }

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    await submitResult?.call();
    if (missingReceipt) return null;
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

class _RefreshEntryController extends AppController {
  _RefreshEntryController(super.platform);

  int refreshCalls = 0;

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }
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

  void seedFiles(String body, {int revision = 1}) {
    store.readResult = () async => ConfigCollection(
      selectedId: 'main',
      entries: [
        ConfigEntry(
          id: 'main',
          name: '  原名 🌐\t',
          kind: ConfigKind.local,
          revision: revision,
          body: body,
        ),
      ],
    );
    (controller.overrideStore! as _ControlledOverrideStore).entries = [
      OverrideEntry(
        id: 'part',
        name: '  插件 🌐\t',
        kind: ConfigKind.local,
        revision: revision,
        body: body,
      ),
    ];
    final settings = controller.preferencesStore! as MemoryPreferencesStore;
    settings.value = settings.value.withAppearance('language', 'en');
  }

  testWidgets('composition keeps the controller refresh entry point', (
    tester,
  ) async {
    final composed = _RefreshEntryController(bridge);
    addTearDown(composed.dispose);
    await composed.initialize();
    expect(composed.refreshCalls, 1);
    composed.setForeground(false);
    expect(composed.foreground, isFalse);
    expect(composed.refreshCalls, 1);
    composed.setForeground(true);
    expect(composed.foreground, isTrue);
    expect(composed.refreshCalls, 2);
    expect(bridge.reads, 0);
    expect(bridge.uiReadiness, 0);
  });

  testWidgets('running Stop remains available after UI readiness fails', (
    tester,
  ) async {
    seedFiles('original body');
    final failure = StateError(
      'readiness failed 原文🙂\nCaused by: channel closed\nSuppressed: cleanup failed',
    );
    bridge.readyResult = () async => throw failure;
    bridge.read = () async =>
        const AppSnapshot(phase: 'RUNNING', generation: 9);
    await controller.initialize();
    expect(controller.state.confirmed, isTrue);
    expect(controller.state.running, isTrue);
    expect(controller.platformErrorMessage?.detail, failure.toString());
    expect(controller.commandErrorMessage, isNull);
    expect(controller.canEdit, isTrue);
    expect(controller.canEditOverrides, isTrue);
    expect(controller.canChangePreferences, isTrue);
    expect(controller.canStopBackground, isTrue);
    expect(controller.canToggle, isTrue);
    expect(await controller.submit({'action': 'stop'}), 'operation-1');
    expect(bridge.commands.single, {'action': 'stop'});
    expect(controller.platformErrorMessage?.detail, failure.toString());
    controller.setForeground(false);
  });

  for (final resourceBusy in [true, false]) {
    testWidgets(
      'stopped work rejects select and local edits but admits Stop until drain resourceBusy=$resourceBusy writerBusy=${!resourceBusy}',
      (tester) async {
        seedFiles('original body');
        var drained = false;
        bridge.read = () async => AppSnapshot(
          phase: 'STOPPED',
          resourceBusy: !drained && resourceBusy,
          writerBusy: !drained && !resourceBusy,
        );
        await controller.refresh();
        expect(controller.state.stale, isFalse);
        expect(controller.state.operationMessage, isNull);
        expect(controller.state.resourceBusy, resourceBusy);
        expect(controller.state.writerBusy, !resourceBusy);
        expect(controller.configsCurrent, isTrue);
        expect(controller.overridesCurrent, isTrue);
        expect(controller.preferencesLoaded, isTrue);
        expect(controller.canEdit, isFalse);
        expect(controller.canEditOverrides, isFalse);
        expect(controller.canChangePreferences, isFalse);
        expect(controller.canManageStoredData, isFalse);
        expect(controller.canStopBackground, resourceBusy);
        expect(controller.canToggle, resourceBusy);
        expect(
          await controller.submit({'action': 'select', 'id': 'main'}),
          isNull,
        );
        expect(
          await controller.submit({'action': 'renameConfig', 'id': 'main'}),
          isNull,
        );
        expect(bridge.commands, isEmpty);

        expect(await controller.submit({'action': 'stop'}), 'operation-1');
        expect(bridge.commands.single, {'action': 'stop'});
        expect(controller.dispatching, isFalse);
        expect(controller.state.resourceBusy, resourceBusy);
        expect(controller.state.writerBusy, !resourceBusy);
        expect(controller.busy, isTrue);
        expect(controller.canEdit, isFalse);
        expect(controller.canEditOverrides, isFalse);
        expect(controller.canChangePreferences, isFalse);
        expect(controller.canManageStoredData, isFalse);
        expect(
          await controller.submit({'action': 'select', 'id': 'main'}),
          isNull,
        );
        expect(
          await controller.submit({'action': 'renameConfig', 'id': 'main'}),
          isNull,
        );
        expect(bridge.commands, hasLength(1));

        drained = true;
        await controller.refresh();
        expect(controller.state.resourceBusy, isFalse);
        expect(controller.state.writerBusy, isFalse);
        expect(controller.busy, isFalse);
        expect(controller.canEdit, isTrue);
        expect(controller.canEditOverrides, isTrue);
        expect(controller.canChangePreferences, isTrue);
        expect(controller.canManageStoredData, isTrue);
        expect(
          await controller.submit({'action': 'select', 'id': 'main'}),
          'operation-2',
        );
        expect(
          await controller.submit({'action': 'renameConfig', 'id': 'main'}),
          'operation-3',
        );
        expect(bridge.commands.map((command) => command['action']), [
          'stop',
          'select',
          'renameConfig',
        ]);
      },
    );
  }

  testWidgets('stale busy flags do not block independent local file edits', (
    tester,
  ) async {
    seedFiles('original body');
    bridge.read = () async => const AppSnapshot(
      phase: 'RUNNING',
      resourceBusy: true,
      writerBusy: true,
      operation: AppMessage('stageStoppingOld'),
    );
    await controller.refresh();
    expect(controller.canEdit, isFalse);
    final failure = StateError('snapshot unavailable 原文🙂');
    bridge.read = () async => throw failure;
    await controller.refresh();
    expect(controller.state.stale, isTrue);
    expect(controller.state.resourceBusy, isTrue);
    expect(controller.state.writerBusy, isTrue);
    expect(
      controller.state.operationMessage,
      const AppMessage('stageStoppingOld'),
    );
    expect(controller.platformErrorMessage?.detail, failure.toString());
    expect(controller.canEdit, isTrue);
    expect(controller.canEditOverrides, isTrue);
    expect(controller.canChangePreferences, isTrue);
    expect(controller.canManageStoredData, isTrue);
    expect(controller.canStopBackground, isTrue);
    expect(controller.canToggle, isTrue);
    expect(
      await controller.submit({'action': 'select', 'id': 'main'}),
      'operation-1',
    );
    expect(
      await controller.submit({'action': 'renameConfig', 'id': 'main'}),
      'operation-2',
    );
    expect(await controller.submit({'action': 'stop'}), 'operation-3');
    expect(bridge.commands.map((command) => command['action']), [
      'select',
      'renameConfig',
      'stop',
    ]);
    expect(controller.state.resourceBusy, isTrue);
    expect(controller.state.writerBusy, isTrue);
    controller.setForeground(false);
  });

  for (final writerBusy in [false, true]) {
    testWidgets(
      'running Stop does not wait for local writer drain writerBusy=$writerBusy',
      (tester) async {
        seedFiles('original body');
        bridge.read = () async => AppSnapshot(
          phase: 'RUNNING',
          generation: 9,
          writerBusy: writerBusy,
          operation: writerBusy ? null : const AppMessage('stageStoppingOld'),
        );
        await controller.refresh();
        expect(controller.state.confirmed, isTrue);
        expect(controller.state.busy, isTrue);
        expect(controller.canEdit, isFalse);
        expect(controller.canEditOverrides, isFalse);
        expect(controller.canChangePreferences, isFalse);
        expect(controller.canManageStoredData, isFalse);
        expect(controller.canStopBackground, isTrue);
        expect(controller.canToggle, isTrue);
        expect(await controller.submit({'action': 'stop'}), 'operation-1');
        expect(bridge.commands.single, {'action': 'stop'});
        // Stop admission does not pretend the actual writer has drained.
        expect(controller.state.busy, isTrue);
        expect(controller.canEdit, isFalse);
        expect(
          await controller.submit({'action': 'renameConfig', 'id': 'main'}),
          isNull,
        );
        expect(bridge.commands, hasLength(1));
      },
    );
  }

  testWidgets('running Stop can supersede a local submission readback', (
    tester,
  ) async {
    seedFiles('original body');
    bridge.read = () async =>
        const AppSnapshot(phase: 'RUNNING', generation: 9);
    await controller.refresh();
    final readback = Completer<AppSnapshot>();
    bridge.read = () => readback.future;
    final first = controller.submit({
      'action': 'renameConfig',
      'id': 'main',
      'name': 'original name',
    });
    await tester.pump();
    expect(controller.dispatching, isFalse);
    expect(controller.busy, isTrue);
    expect(controller.state.busy, isFalse);
    expect(controller.canEdit, isFalse);
    expect(controller.canStopBackground, isTrue);
    expect(controller.canToggle, isTrue);

    final stopReceipt = Completer<void>();
    bridge.submitResult = () => stopReceipt.future;
    final stopped = controller.submit({'action': 'stop'});
    await tester.pump();
    expect(controller.dispatching, isTrue);
    expect(controller.canStopBackground, isFalse);
    expect(await controller.submit({'action': 'stop'}), isNull);
    expect(bridge.commands, hasLength(2));
    expect(bridge.commands.last, {'action': 'stop'});

    bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
    readback.complete(const AppSnapshot(phase: 'RUNNING', generation: 9));
    expect(await first, 'operation-1');
    // The older readback must not release the newer Stop admission.
    expect(controller.dispatching, isTrue);
    expect(controller.lastCommand, {'action': 'stop'});
    expect(controller.canEdit, isFalse);
    stopReceipt.complete();
    expect(await stopped, 'operation-2');
    expect(controller.dispatching, isFalse);
    expect(controller.busy, isFalse);
    expect(controller.canEdit, isTrue);
    expect(controller.canStopBackground, isFalse);
  });

  testWidgets(
    'storage recovery preserves its original error while Stop stays available',
    (tester) async {
      seedFiles('retained original');
      await controller.refresh();
      final before = controller.collection;
      final reads = store.reads;
      const failure = AppMessage(
        'storageUnavailable',
        detail: 'java.io.EOFException\noriginal journal cause 原文🙂',
      );
      bridge.read = () async => const AppSnapshot(
        phase: 'RUNNING',
        generation: 9,
        storageReady: false,
        storageEpoch: 2,
        storageError: failure,
      );
      await controller.refresh();
      expect(controller.platformErrorMessage, failure);
      expect(controller.state.storageError, failure);
      expect(controller.collection, same(before));
      expect(store.reads, reads);
      expect(controller.canEdit, isFalse);
      expect(controller.canStopBackground, isTrue);
      expect(await controller.submit({'action': 'stop'}), isNotNull);
      expect(bridge.commands.single, {'action': 'stop'});
      controller.setForeground(false);
    },
  );

  testWidgets(
    'orphan cleanup warning does not close recovered local editing or core start',
    (tester) async {
      seedFiles('saved original');
      const failure = AppMessage(
        'storageCleanupFailed',
        detail: 'original cleanup cause 原文🙂',
      );
      bridge.read = () async =>
          const AppSnapshot(phase: 'STOPPED', storageError: failure);
      await controller.refresh();
      expect(controller.state.storageError, failure);
      expect(controller.platformErrorMessage, isNull);
      expect(controller.canEdit, isTrue);
      expect(controller.canEditOverrides, isTrue);
      expect(controller.canChangePreferences, isTrue);
      expect(controller.canToggle, isTrue);
      controller.setForeground(false);
    },
  );

  for (final status in ['initializing', 'scheduled', 'failed']) {
    testWidgets(
      'core cleanup $status blocks starts but not local work or Stop',
      (tester) async {
        seedFiles('original body');
        bridge.read = () async => AppSnapshot(
          phase: 'STOPPED',
          coreCleanup: {
            'ready': false,
            'status': status,
            if (status == 'failed')
              'error': const AppMessage(
                'coreCleanupFailed',
                detail: 'delete failed https://user:password@fixture.test/?token=原文🙂',
              ).toMap(),
          },
        );
        await controller.refresh();
        expect(controller.configsCurrent, isTrue);
        expect(controller.overridesCurrent, isTrue);
        expect(controller.canEdit, isTrue);
        expect(controller.canEditOverrides, isTrue);
        expect(controller.canChangePreferences, isTrue);
        expect(controller.canManageStoredData, isTrue);
        expect(controller.busy, isFalse);
        expect(controller.canToggle, isFalse);
        expect(
          controller.errorMessage?.id,
          status == 'failed'
              ? 'coreCleanupFailed'
              : status == 'initializing'
              ? 'coreCleanupInitializing'
              : 'coreCleanupRequired',
        );
        if (status == 'failed') {
          expect(
            controller.errorMessage?.detail,
            contains('https://user:password@fixture.test/?token=原文🙂'),
          );
        }
        for (final action in [
          'renameConfig',
          'setPreference',
          'clearOverrides',
          'scheduleCoreCleanup',
        ]) {
          expect(await controller.submit({'action': action}), isNotNull);
        }
        expect(bridge.commands.map((value) => value['action']), [
          'renameConfig',
          'setPreference',
          'clearOverrides',
          'scheduleCoreCleanup',
        ]);
        final cleanup = controller.state.coreCleanup;
        bridge.read = () async =>
            AppSnapshot(phase: 'RUNNING', coreCleanup: cleanup);
        await controller.refresh();
        expect(controller.canToggle, isTrue);
        expect(await controller.submit({'action': 'stop'}), isNotNull);
        expect(bridge.commands.last, {'action': 'stop'});
        controller.setForeground(false);
      },
    );
  }

  const originalFailure =
      'https://user:password@fixture.test/path?token=完整原文#section\n'
      'Authorization: Bearer 原文🙂';

  for (final failedFile in [
    null,
    'configurations',
    'overrides',
    'preferences',
  ]) {
    testWidgets(
      'first native failure still publishes independent files, failed=$failedFile',
      (tester) async {
        seedFiles('\u{feff}rules:\r\n  - MATCH,DIRECT\n');
        bridge.read = () async => throw StateError(originalFailure);
        bridge.readPaths = () async => {'storageEpoch': 7};
        final fileFailure = StateError('$failedFile: $originalFailure');
        switch (failedFile) {
          case 'configurations':
            store.readResult = () async => throw fileFailure;
          case 'overrides':
            (controller.overrideStore! as _ControlledOverrideStore).readResult =
                () async => throw fileFailure;
          case 'preferences':
            (controller.preferencesStore! as MemoryPreferencesStore)
                .readResult = () async =>
                throw fileFailure;
        }
        await controller.initialize();
        expect(bridge.uiReadiness, 1);
        expect(bridge.reads, 1);
        expect(bridge.pathReads, 2);
        expect(controller.loading, isFalse);
        expect(controller.state.phase, 'UNKNOWN');
        expect(controller.state.stale, isTrue);
        expect(controller.state.confirmed, isFalse);
        expect(
          controller.platformErrorMessage?.detail,
          StateError(originalFailure).toString(),
        );
        expect(controller.state.storageReady, isTrue);
        expect(controller.state.storageEpoch, 7);
        expect(controller.storageEpoch, 7);
        expect(controller.configsLoaded, failedFile != 'configurations');
        expect(controller.overridesLoaded, failedFile != 'overrides');
        expect(controller.preferencesLoaded, failedFile != 'preferences');
        expect(controller.configsCurrent, failedFile != 'configurations');
        expect(controller.overridesCurrent, failedFile != 'overrides');
        expect(controller.canEdit, failedFile != 'configurations');
        expect(controller.canEditOverrides, failedFile != 'overrides');
        expect(controller.canChangePreferences, failedFile != 'preferences');
        if (failedFile != 'configurations') {
          expect(controller.collection.selected!.name, '  原名 🌐\t');
          expect(
            controller.collection.selected!.body,
            '\u{feff}rules:\r\n  - MATCH,DIRECT\n',
          );
        } else {
          expect(controller.configErrorMessage?.detail, fileFailure.toString());
        }
        if (failedFile != 'overrides') {
          expect(controller.overrides.single.name, '  插件 🌐\t');
          expect(
            controller.overrides.single.body,
            '\u{feff}rules:\r\n  - MATCH,DIRECT\n',
          );
        } else {
          expect(
            controller.overrideErrorMessage?.detail,
            fileFailure.toString(),
          );
        }
        if (failedFile != 'preferences') {
          expect(controller.preferences.language.name, 'en');
        } else {
          expect(
            controller.preferencesErrorMessage?.detail,
            fileFailure.toString(),
          );
        }
        expect(controller.canToggle, isTrue);
        expect(controller.canStopBackground, isTrue);
        expect(bridge.commands, isEmpty);
        controller.setForeground(false);
      },
    );
  }

  testWidgets(
    'failed native readback does not discard successfully read files',
    (tester) async {
      const known = AppSnapshot(
        phase: 'RUNNING',
        generation: 9,
        configId: 'running-original',
        revision: 3,
        storageEpoch: 4,
        mode: TunnelMode.direct,
      );
      seedFiles('old');
      bridge.read = () async => known;
      await controller.refresh();
      seedFiles('new', revision: 2);
      var reads = 0;
      bridge.read = () async {
        if (reads++ == 0) return known;
        throw StateError(originalFailure);
      };
      bridge.readPaths = () async => {'storageEpoch': 4};
      await controller.refresh();
      expect(controller.collection.selected!.body, 'new');
      expect(controller.collection.selected!.revision, 2);
      expect(controller.overrides.single.body, 'new');
      expect(controller.overrides.single.revision, 2);
      expect(controller.preferences.language.name, 'en');
      expect(controller.storageEpoch, 4);
      expect(controller.state.storageEpoch, 4);
      expect(controller.state.phase, known.phase);
      expect(controller.state.generation, known.generation);
      expect(controller.state.configId, known.configId);
      expect(controller.state.revision, known.revision);
      expect(controller.state.mode, known.mode);
      expect(controller.state.stale, isTrue);
      expect(
        controller.platformErrorMessage?.detail,
        StateError(originalFailure).toString(),
      );
      expect(controller.canEdit, isTrue);
      expect(controller.canEditOverrides, isTrue);
      expect(controller.canChangePreferences, isTrue);
      expect(bridge.pathReads, 1);
      controller.setForeground(false);
    },
  );

  testWidgets('storage fallback still rejects reads crossing a restore', (
    tester,
  ) async {
    var epoch = 1;
    bridge.read = () async => throw StateError(originalFailure);
    bridge.readPaths = () async => {'storageEpoch': epoch};
    seedFiles('old');
    await controller.refresh();
    final projections = <String>[];
    controller.addListener(
      () => projections.add(
        '${controller.collection.selected?.body}/${controller.overrides.firstOrNull?.body}/${controller.storageEpoch}',
      ),
    );
    final oldRead = Completer<ConfigCollection>();
    final oldCollection = controller.collection;
    store.readResult = () => oldRead.future;
    final refreshing = controller.refresh();
    await tester.pump();
    epoch = 2;
    seedFiles('restored');
    oldRead.complete(oldCollection);
    await refreshing;
    expect(controller.collection.selected!.body, 'restored');
    expect(controller.overrides.single.body, 'restored');
    expect(controller.storageEpoch, 2);
    expect(controller.state.storageEpoch, 2);
    expect(controller.state.stale, isTrue);
    expect(store.reads, 3);
    expect(projections, contains('restored/restored/2'));
    expect(
      projections.every(
        (value) => value == 'old/old/1' || value == 'restored/restored/2',
      ),
      isTrue,
    );
    expect(bridge.commands, isEmpty);
    controller.setForeground(false);
  });

  testWidgets('unavailable storage fallback retains files and allows Stop', (
    tester,
  ) async {
    seedFiles('retained');
    bridge.read = () async =>
        const AppSnapshot(phase: 'RUNNING', generation: 3, storageEpoch: 1);
    await controller.refresh();
    final before = controller.collection;
    final beforeParts = controller.overrides;
    final reads = store.reads;
    bridge.read = () async => throw StateError(originalFailure);
    bridge.readPaths = () async => throw PlatformFailure(
      code: 'storage',
      details: messages.storageUnavailable.toMap(),
    );
    await controller.refresh();
    expect(controller.collection, same(before));
    expect(controller.overrides, same(beforeParts));
    expect(store.reads, reads);
    expect(controller.storageEpoch, 1);
    expect(controller.state.phase, 'RUNNING');
    expect(controller.state.generation, 3);
    expect(controller.state.stale, isTrue);
    expect(controller.state.storageReady, isFalse);
    expect(controller.canEdit, isFalse);
    expect(controller.canChangePreferences, isFalse);
    expect(controller.platformErrorMessage?.detail, contains(originalFailure));
    expect(
      controller.platformErrorMessage?.detail,
      contains('storageUnavailable'),
    );
    expect(await controller.submit({'action': 'stop'}), 'operation-1');
    expect(bridge.commands.single, {'action': 'stop'});
    bridge.readPaths = () async => {'storageEpoch': 2};
    seedFiles('restored');
    await controller.refresh();
    expect(controller.collection.selected!.body, 'restored');
    expect(controller.overrides.single.body, 'restored');
    expect(controller.storageEpoch, 2);
    expect(controller.state.storageEpoch, 2);
    expect(controller.state.stale, isTrue);
    expect(controller.canEdit, isTrue);
    expect(controller.canChangePreferences, isTrue);
    expect(
      controller.platformErrorMessage?.detail,
      StateError(originalFailure).toString(),
    );
    controller.setForeground(false);
  });

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
    expect(controller.canEdit, isTrue);
    expect(controller.state.stale, isTrue);
    expect(controller.state.confirmed, isFalse);
    expect(controller.platformErrorMessage?.id, 'temporaryStatusUnavailable');
    expect(
      controller.platformErrorMessage?.detail,
      contains('TimeoutException'),
    );
    readback.complete(const AppSnapshot(phase: 'STOPPED'));
    await tester.pump();
    expect(controller.state.stale, isTrue);
    expect(
      controller.platformErrorMessage?.detail,
      contains('TimeoutException'),
    );
    controller.setForeground(false);
  });

  testWidgets(
    'snapshot failure retains running projection and permits local commands',
    (tester) async {
      const known = AppSnapshot(
        phase: 'RUNNING',
        generation: 9,
        configId: 'running original',
        revision: 3,
        mode: TunnelMode.direct,
        logSource: CoreSnapshot(generation: 7, logWindow: 'original logs'),
      );
      bridge.read = () async => known;
      await controller.refresh();
      bridge.read = () async =>
          throw StateError('https://user:pass@fixture.test/?token=原文');
      await controller.refresh();
      expect(controller.state.phase, 'RUNNING');
      expect(controller.state.generation, 9);
      expect(controller.state.configId, 'running original');
      expect(controller.state.revision, 3);
      expect(controller.state.mode, TunnelMode.direct);
      expect(controller.state.logSource, same(known.logSource));
      expect(controller.state.confirmed, isFalse);
      expect(controller.state.stale, isTrue);
      expect(
        controller.platformErrorMessage?.detail,
        contains('https://user:pass@fixture.test/?token=原文'),
      );
      expect(controller.canEdit, isTrue);
      expect(controller.canEditOverrides, isTrue);
      expect(controller.canChangePreferences, isTrue);
      expect(controller.canStopBackground, isTrue);
      expect(
        await controller.submit({
          'action': 'renameConfig',
          'id': 'local',
          'name': '原名',
        }),
        'operation-1',
      );
      expect(bridge.commands.single['action'], 'renameConfig');
      expect(await controller.submit({'action': 'stop'}), 'operation-2');
      expect(bridge.commands.last, {'action': 'stop'});
      controller.setForeground(false);
    },
  );

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

  test('interaction waits through loss of focus and actual hiding', () async {
    controller.setInteractive(false);
    var ready = false;
    final pending = controller.waitUntilInteractive().then(
      (value) => ready = value,
    );
    controller.setForeground(false);
    controller.setInteractive(true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    controller.setForeground(true);
    await pending;
    expect(ready, isTrue);
    expect(await controller.waitUntilInteractive(), isTrue);
  });

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
    expect(controller.state.phase, 'STOPPED');
    expect(bridge.reads, 2);
    expect(controller.configsLoaded, isTrue);
    expect(controller.overridesLoaded, isTrue);
    expect(controller.preferencesLoaded, isTrue);
    expect(controller.canEdit, isTrue);
    expect(controller.canEditOverrides, isTrue);
    expect(controller.canChangePreferences, isTrue);
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
    testWidgets('only $failedStore stays noncurrent after its read failure', (
      tester,
    ) async {
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
      expect(
        controller.collection,
        same(failedStore == 'configurations' ? before : fresh),
      );
      if (failedStore == 'overrides') {
        expect(controller.overrides, same(beforeParts));
      } else {
        expect(controller.overrides.single.body, 'new');
      }
      if (failedStore == 'preferences') {
        expect(controller.preferences, same(beforeSettings));
      } else {
        expect(controller.preferences.language.name, 'en');
      }
      expect(controller.configsCurrent, failedStore != 'configurations');
      expect(controller.canEdit, failedStore != 'configurations');
      expect(controller.canEditOverrides, failedStore != 'overrides');
      expect(controller.canChangePreferences, failedStore != 'preferences');
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
    });
  }

  testWidgets('each store recovers without waiting for another failed store', (
    tester,
  ) async {
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
    expect(controller.canChangePreferences, isTrue);
    store.readResult = () async => fresh;
    await controller.refresh();
    expect(controller.configErrorMessage, isNull);
    expect(
      controller.overrideErrorMessage,
      messages.temporaryOverridesUnreadable,
    );
    expect(controller.collection, same(fresh));
    expect(controller.configsCurrent, isTrue);
    expect(controller.canChangePreferences, isTrue);
    expect(controller.canEditOverrides, isFalse);
    parts.readResult = null;
    await controller.refresh();
    expect(controller.collection, same(fresh));
    expect(controller.configsCurrent, isTrue);
    expect(controller.canChangePreferences, isTrue);
  });

  testWidgets(
    'initial override read failure does not close other stores or storage',
    (tester) async {
      final parts = controller.overrideStore! as _ControlledOverrideStore;
      parts.readResult = () async =>
          throw ConfigFailure(messages.temporaryOverridesUnreadable);
      await controller.refresh();
      expect(controller.configsLoaded, isTrue);
      expect(controller.preferencesLoaded, isTrue);
      expect(controller.errorMessage, messages.temporaryOverridesUnreadable);
      expect(controller.configsCurrent, isTrue);
      expect(controller.canChangePreferences, isTrue);
      expect(controller.canEditOverrides, isFalse);
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

  testWidgets(
    'receipt feedback ownership precedes submission notifications and survives rejection until acknowledgement',
    (tester) async {
      await controller.refresh();
      final owner = ValueNotifier(true);
      addTearDown(() {
        owner.value = false;
        owner.dispose();
      });
      const original = AppMessage(
        'androidErrorBusy',
        detail:
            '原文🙂\nCaused by: original failure\nSuppressed: cleanup failure',
      );
      final failure = PlatformFailure(
        code: 'busy',
        message: 'channel 原文',
        details: original.toMap(),
      );
      final expected = original.withDetail(failure);
      bridge.submitResult = () async => throw failure;
      final observations =
          <({bool dispatching, bool owned, AppMessage? error})>[];
      void observe() => observations.add((
        dispatching: controller.dispatching,
        owned: controller.hasLocalFeedbackOwner,
        error: controller.commandErrorMessage,
      ));
      controller.addListener(observe);
      addTearDown(() => controller.removeListener(observe));
      final submitting = controller.submitForReceipt({
        'action': 'renameConfig',
        'id': 'main',
        'name': '原名',
      }, feedbackOwner: owner);
      final command = controller.lastCommand;
      expect(command, same(bridge.commands.single));
      expect(controller.dispatching, isTrue);
      expect(controller.hasLocalFeedbackOwner, isTrue);
      final receipt = await submitting;
      expect(receipt.command, same(command));
      expect(receipt.operationId, isNull);
      expect(receipt.error, expected);
      expect(receipt.error?.detail, '${original.detail}\n$failure');
      expect(controller.commandErrorMessage, expected);
      expect(observations.first.dispatching, isTrue);
      expect(observations.every((value) => value.owned), isTrue);
      expect(observations.any((value) => value.error == expected), isTrue);
      expect(controller.hasLocalFeedbackOwner, isTrue);
      expect(
        controller.feedbackHandledLocally(command!, submissionFailed: true),
        isFalse,
      );
      // This explicitly simulates the caller's acknowledgment, not widget paint.
      controller.acknowledgeLocalFeedback(owner);
      expect(controller.hasLocalFeedbackOwner, isFalse);
      expect(
        controller.feedbackHandledLocally(command, submissionFailed: true),
        isTrue,
      );
    },
  );

  testWidgets(
    'accepted receipt returns before the final result and retains feedback until owner retirement',
    (tester) async {
      await controller.refresh();
      final owner = ValueNotifier(true);
      addTearDown(() {
        owner.value = false;
        owner.dispose();
      });
      final admission = Completer<void>();
      final readback = Completer<ConfigCollection>();
      bridge.submitResult = () => admission.future;
      store.readResult = () => readback.future;
      bridge.read = () async =>
          const AppSnapshot(phase: 'STOPPED', resourceBusy: true);
      var settled = false;
      final submitting = controller
          .submitForReceipt({
            'action': 'changeOverrideSource',
            'id': 'part',
          }, feedbackOwner: owner)
          .then((receipt) {
            settled = true;
            return receipt;
          });
      expect(controller.hasLocalFeedbackOwner, isTrue);
      expect(controller.dispatching, isTrue);
      admission.complete();
      await tester.pump();
      expect(controller.dispatching, isFalse);
      expect(controller.busy, isTrue);
      expect(controller.canEdit, isFalse);
      expect(settled, isFalse);
      store.readResult = () async => ConfigCollection(entries: []);
      readback.complete(ConfigCollection(entries: []));
      final receipt = await submitting;
      expect(receipt.operationId, 'operation-1');
      expect(receipt.error, isNull);
      expect(receipt.command, same(controller.lastCommand));
      expect(controller.state.resourceBusy, isTrue);
      expect(controller.state.resultId, isNull);
      expect(controller.hasLocalFeedbackOwner, isTrue);
      bridge.read = () async => const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'operation-1',
        resultSuccess: false,
        resultMessage: AppMessage('operationNotCompletedRetry'),
      );
      await controller.refresh();
      expect(controller.busy, isFalse);
      expect(controller.hasLocalFeedbackOwner, isTrue);
      expect(
        controller.feedbackHandledLocally(
          receipt.command!,
          submissionFailed: false,
          resultId: 'operation-1',
        ),
        isFalse,
      );
      controller.acknowledgeLocalFeedback(
        owner,
        result: const AppSnapshot(resultId: 'unrelated-operation'),
      );
      expect(controller.hasLocalFeedbackOwner, isTrue);
      owner.value = false;
      expect(controller.hasLocalFeedbackOwner, isFalse);
      expect(
        controller.feedbackHandledLocally(
          receipt.command!,
          submissionFailed: false,
          resultId: 'operation-1',
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'departed receipt owner is not reattached by a late submission reply',
    (tester) async {
      await controller.refresh();
      final owner = ValueNotifier(true);
      addTearDown(() {
        owner.value = false;
        owner.dispose();
      });
      final admission = Completer<void>();
      bridge.submitResult = () => admission.future;
      final submitting = controller.submitForReceipt({
        'action': 'renameConfig',
        'id': 'main',
      }, feedbackOwner: owner);
      final command = controller.lastCommand;
      expect(controller.hasLocalFeedbackOwner, isTrue);
      owner.value = false;
      expect(controller.hasLocalFeedbackOwner, isFalse);
      expect(controller.dispatching, isTrue);
      expect(controller.busy, isTrue);
      expect(await controller.submit({'action': 'stop'}), isNull);
      expect(bridge.commands, hasLength(1));
      final failure = StateError(
        'late 原文🙂\nSuppressed: actual worker failure',
      );
      admission.completeError(failure);
      final receipt = await submitting;
      expect(receipt.command, same(command));
      expect(receipt.operationId, isNull);
      expect(receipt.error?.detail, failure.toString());
      expect(controller.commandErrorMessage, receipt.error);
      expect(controller.hasLocalFeedbackOwner, isFalse);
      expect(controller.dispatching, isFalse);
      expect(controller.busy, isFalse);
      expect(
        controller.feedbackHandledLocally(command!, submissionFailed: true),
        isFalse,
      );
      expect(bridge.commands, hasLength(1));
    },
  );

  testWidgets(
    'superseded receipt keeps its own outcome without releasing the newer Stop submission',
    (tester) async {
      await controller.refresh();
      final firstOwner = ValueNotifier(true);
      final stopOwner = ValueNotifier(true);
      addTearDown(() {
        firstOwner.value = false;
        stopOwner.value = false;
        firstOwner.dispose();
        stopOwner.dispose();
      });
      const failure = AppMessage(
        'androidErrorBusy',
        detail: 'original refusal 原文🙂',
      );
      bridge.submitResult = () async =>
          throw PlatformFailure(code: 'busy', details: failure.toMap());
      final oldReadback = Completer<ConfigCollection>();
      store.readResult = () => oldReadback.future;
      final first = controller.submitForReceipt({
        'action': 'renameConfig',
        'id': 'main',
      }, feedbackOwner: firstOwner);
      final firstCommand = controller.lastCommand;
      await tester.pump();
      expect(controller.dispatching, isFalse);
      expect(
        controller.commandErrorMessage,
        failure.withDetail(
          PlatformFailure(code: 'busy', details: failure.toMap()),
        ),
      );
      final stopAdmission = Completer<void>();
      bridge.submitResult = () => stopAdmission.future;
      final stopped = controller.submitForReceipt({
        'action': 'stop',
      }, feedbackOwner: stopOwner);
      final stopCommand = controller.lastCommand;
      expect(stopCommand, isNot(same(firstCommand)));
      expect(controller.hasLocalFeedbackOwner, isTrue);
      store.readResult = () async => ConfigCollection(entries: []);
      oldReadback.complete(ConfigCollection(entries: []));
      final oldReceipt = await first;
      expect(oldReceipt.command, same(firstCommand));
      expect(oldReceipt.operationId, isNull);
      expect(
        oldReceipt.error,
        failure.withDetail(
          PlatformFailure(code: 'busy', details: failure.toMap()),
        ),
      );
      expect(controller.commandErrorMessage, isNull);
      expect(controller.lastCommand, same(stopCommand));
      expect(controller.dispatching, isTrue);
      controller.acknowledgeLocalFeedback(firstOwner);
      firstOwner.value = false;
      expect(controller.hasLocalFeedbackOwner, isTrue);
      final stopReadback = Completer<AppSnapshot>();
      bridge.read = () => stopReadback.future;
      stopAdmission.complete();
      await tester.pump();
      expect(controller.dispatching, isFalse);
      expect(controller.state.busy, isFalse);
      expect(controller.busy, isTrue);
      expect(controller.canEdit, isFalse);
      expect(controller.hasLocalFeedbackOwner, isTrue);
      stopReadback.complete(
        const AppSnapshot(phase: 'STOPPED', resultId: 'operation-2'),
      );
      final stopReceipt = await stopped;
      expect(stopReceipt.command, same(stopCommand));
      expect(stopReceipt.operationId, 'operation-2');
      expect(stopReceipt.error, isNull);
      expect(controller.busy, isFalse);
      expect(controller.hasLocalFeedbackOwner, isTrue);
      expect(
        controller.feedbackHandledLocally(
          stopCommand!,
          submissionFailed: false,
          resultId: 'operation-2',
        ),
        isFalse,
      );
      expect(bridge.commands, hasLength(2));
      stopOwner.value = false;
    },
  );

  for (final refusal in ['blocked', 'missing']) {
    testWidgets(
      'refused and missing receipts neither succeed nor consume previous feedback refusal=$refusal',
      (tester) async {
        await controller.refresh();
        final previousOwner = ValueNotifier(true);
        final nextOwner = ValueNotifier(true);
        addTearDown(() {
          previousOwner.value = false;
          nextOwner.value = false;
          previousOwner.dispose();
          nextOwner.dispose();
        });
        const failure = AppMessage('androidErrorBusy', detail: 'previous 原文🙂');
        bridge.submitResult = () async =>
            throw PlatformFailure(code: 'busy', details: failure.toMap());
        final previous = await controller.submitForReceipt({
          'action': 'renameConfig',
          'id': 'main',
        }, feedbackOwner: previousOwner);
        final previousCommand = previous.command!;
        expect(
          previous.error,
          failure.withDetail(
            PlatformFailure(code: 'busy', details: failure.toMap()),
          ),
        );
        if (refusal == 'blocked') {
          bridge.read = () async =>
              const AppSnapshot(phase: 'STOPPED', resourceBusy: true);
          await controller.refresh();
        } else {
          bridge.submitResult = null;
          bridge.missingReceipt = true;
        }
        final receipt = await controller.submitForReceipt({
          'action': 'renameConfig',
          'id': 'next',
        }, feedbackOwner: nextOwner);
        expect(receipt.operationId, isNull);
        expect(receipt.error, isNull);
        expect(controller.hasLocalFeedbackOwner, isTrue);
        expect(
          controller.feedbackHandledLocally(
            previousCommand,
            submissionFailed: true,
          ),
          isFalse,
        );
        if (refusal == 'blocked') {
          expect(receipt.command, isNull);
          expect(controller.lastCommand, same(previousCommand));
          expect(
            controller.commandErrorMessage,
            failure.withDetail(
              PlatformFailure(code: 'busy', details: failure.toMap()),
            ),
          );
          nextOwner.value = false;
          expect(controller.hasLocalFeedbackOwner, isTrue);
          expect(bridge.commands, hasLength(1));
          previousOwner.value = false;
        } else {
          expect(receipt.command, same(controller.lastCommand));
          expect(receipt.command, isNot(same(previousCommand)));
          expect(controller.commandErrorMessage, isNull);
          controller.acknowledgeLocalFeedback(previousOwner);
          previousOwner.value = false;
          expect(controller.hasLocalFeedbackOwner, isTrue);
          expect(
            controller.feedbackHandledLocally(
              receipt.command!,
              submissionFailed: true,
            ),
            isFalse,
          );
          expect(bridge.commands, hasLength(2));
          nextOwner.value = false;
        }
        expect(controller.hasLocalFeedbackOwner, isFalse);
      },
    );
  }

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
    'stopped unknown actual mode permits saved preselection changes',
    (tester) async {
      store.readResult = () async =>
          ConfigCollection(entries: [], mode: TunnelMode.global);
      bridge.read = () async => const AppSnapshot(phase: 'STOPPED');
      await controller.refresh();
      expect(controller.state.mode, isNull);
      expect(controller.collection.mode, TunnelMode.global);
      expect(controller.canEdit, isTrue);
      expect(controller.canChangeMode, isTrue);
      expect(bridge.commands, isEmpty);
    },
  );

  testWidgets(
    'known running mode stays changeable despite mode and preference read errors',
    (tester) async {
      const modeFailure = AppMessage('androidErrorModeUnconfirmed');
      const preferencesFailure = AppMessage('temporarySettingsUnreadable');
      (controller.preferencesStore! as MemoryPreferencesStore).readResult =
          () async => throw ConfigFailure(preferencesFailure);
      bridge.read = () async => const AppSnapshot(
        phase: 'RUNNING',
        mode: TunnelMode.direct,
        modeError: modeFailure,
      );
      await controller.refresh();
      expect(controller.state.mode, TunnelMode.direct);
      expect(controller.state.modeErrorMessage, modeFailure);
      expect(controller.preferencesErrorMessage, preferencesFailure);
      expect(controller.canChangePreferences, isFalse);
      expect(controller.canEdit, isTrue);
      expect(controller.canChangeMode, isTrue);
      expect(controller.canStopBackground, isTrue);
      expect(controller.canToggle, isTrue);
      expect(bridge.commands, isEmpty);
      controller.setForeground(false);
    },
  );

  testWidgets(
    'mode read failure retries without losing running or issuing commands',
    (tester) async {
      bridge.read = () async => const AppSnapshot(
        phase: 'RUNNING',
        modeError: AppMessage('androidErrorModeUnconfirmed'),
      );
      await controller.refresh();
      expect(controller.canToggle, isTrue);
      expect(controller.canStopBackground, isTrue);
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
    expect(controller.canStopBackground, isTrue);
    expect(controller.canToggle, isTrue);
    expect(controller.canEdit, isTrue);
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
      bridge.submitResult = () async => throw PlatformFailure(
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
      expect(
        controller.commandErrorMessage,
        messages.requestNotAccepted.withDetail(
          PlatformFailure(
            code: 'unavailable',
            details: messages.requestNotAccepted.toMap(),
          ),
        ),
      );
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
