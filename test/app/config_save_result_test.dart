import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/app/app_controller.dart';
import 'package:clash_pseudo/features/configs/config_entry.dart';
import 'package:clash_pseudo/features/configs/config_store.dart';
import 'package:clash_pseudo/platform/app_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _SaveBridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  int submitted = 0;
  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<String?> submit(Map<String, Object?> command) async {
    submitted++;
    return 'save-operation';
  }
}

class _SaveStore extends ConfigStore {
  _SaveStore() : super(Directory.systemTemp);
  int reads = 0;
  Future<ConfigCollection> Function()? readResult;
  @override
  Future<ConfigCollection> read() async {
    reads++;
    return readResult == null
        ? ConfigCollection(entries: [])
        : await readResult!();
  }
}

void main() {
  testWidgets(
    'save waits for matching operation and forwards structured result',
    (tester) async {
      final bridge = _SaveBridge();
      final store = _SaveStore();
      final app = AppController(bridge, store: store);
      addTearDown(app.dispose);
      await app.refresh();
      var finished = false;
      final pending = app
          .saveLocal({'id': 'local', 'revision': 1, 'body': 'new'})
          .then((value) {
            finished = true;
            return value;
          });
      await tester.pump();
      expect(bridge.submitted, 1);
      expect(finished, isFalse);
      bridge.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'different-operation',
        configStatus: 'saved',
        targetId: 'local',
        savedRevision: 2,
      );
      await app.refresh();
      expect(finished, isFalse);
      bridge.state = AppSnapshot.fromMap({
        'phase': 'STOPPED',
        'resultId': 'save-operation',
        'configStatus': 'applyFailed',
        'targetId': 'local',
        'savedRevision': 2,
        'resultMessage': 'Saved, application failed',
        'resultSuccess': false,
      });
      await app.refresh();
      final result = await pending;
      expect(result!.configStatus, 'applyFailed');
      expect(result.targetId, 'local');
      expect(result.savedRevision, 2);
      expect(result.resultSuccess, isFalse);
      expect(bridge.submitted, 1);
    },
  );

  testWidgets('saved result waits for the coalesced collection reread', (
    tester,
  ) async {
    final bridge = _SaveBridge();
    final store = _SaveStore();
    final app = AppController(bridge, store: store);
    addTearDown(app.dispose);
    await app.refresh();
    var finished = false;
    final saving = app.saveLocal({'body': 'new', 'name': 'Local'}).then((
      value,
    ) {
      finished = true;
      return value;
    });
    await tester.pump();
    final stale = Completer<ConfigCollection>();
    final current = Completer<ConfigCollection>();
    var reads = 0;
    store.readResult = () => ++reads == 1 ? stale.future : current.future;
    bridge.state = const AppSnapshot(
      phase: 'STOPPED',
      resultId: 'save-operation',
      configStatus: 'saved',
      targetId: 'local',
      savedRevision: 1,
    );
    final refreshing = app.refresh();
    await tester.pump();
    expect(finished, isFalse);
    stale.complete(ConfigCollection(entries: []));
    await tester.pump();
    expect(finished, isFalse);
    final saved = ConfigCollection(
      entries: [
        ConfigEntry(
          id: 'local',
          name: 'Local',
          kind: ConfigKind.local,
          revision: 1,
          body: 'new',
        ),
      ],
      selectedId: 'local',
    );
    current.complete(saved);
    await refreshing;
    expect((await saving)!.configStatus, 'saved');
    expect(app.collection, same(saved));
    expect(bridge.submitted, 1);
  });

  testWidgets('unconfirmed save rereads after deadline without resubmitting', (
    tester,
  ) async {
    final bridge = _SaveBridge();
    final store = _SaveStore();
    final app = AppController(bridge, store: store);
    addTearDown(app.dispose);
    await app.refresh();
    final pending = app.saveLocal({'body': ''});
    await tester.pump();
    final before = store.reads;
    await tester.pump(const Duration(seconds: 126));
    expect(await pending, isNull);
    expect(store.reads, greaterThan(before));
    expect(bridge.submitted, 1);
  });

  testWidgets('disposing controller resolves waiter and cancels deadline', (
    tester,
  ) async {
    final app = AppController(_SaveBridge(), store: _SaveStore());
    await app.refresh();
    final pending = app.saveLocal({'body': ''});
    await tester.pump();
    app.dispose();
    await tester.pump();
    expect(await pending, isNull);
  });
}
