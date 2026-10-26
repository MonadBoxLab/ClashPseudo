import 'dart:async';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/backup/backup_data.dart';
import 'package:clash_pseudo/src/features/backup/backup_settings_actions.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = '12345678-1234-1234-1234-123456789abc';
const _second = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

class _Documents extends AppBridge {
  final picks = <String>[];
  final saves = <Map<String, Object?>>[];
  final cancellations = <String>[];
  final discarded = <String>[];
  final pickedResults = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? pendingPick;
  Completer<Map<String, dynamic>>? pendingSave;

  @override
  Future<Map<String, dynamic>> backupPickImport(String requestId) async {
    picks.add(requestId);
    final pending = pendingPick;
    final value = pending != null
        ? await pending.future
        : pickedResults.isNotEmpty
        ? pickedResults.removeAt(0)
        : {'status': 'ready', 'token': _first};
    return {'requestId': requestId, ...value};
  }

  @override
  Future<Map<String, dynamic>> backupSaveExport({
    required String requestId,
    required String token,
    required String title,
  }) async {
    saves.add({'requestId': requestId, 'token': token, 'title': title});
    final pending = pendingSave;
    return {
      'requestId': requestId,
      ...(pending == null ? {'status': 'saved'} : await pending.future),
    };
  }

  @override
  Future<void> backupCancel(String requestId) async =>
      cancellations.add(requestId);

  @override
  Future<void> backupDiscard(String token) async => discarded.add(token);
}

/// UI submission is controllable; actual Stores and native transactions have
/// independent tests. The stale projection epoch deliberately differs from native.
class _BackupApp extends AppController {
  _BackupApp(this.documents) : super(documents) {
    loading = false;
    state = const AppSnapshot(
      phase: 'STOPPED',
      storageReady: true,
      storageEpoch: 41,
    );
    configErrorMessage = messages.configStoreUnreadable;
    overrideErrorMessage = messages.overridesUnreadable;
    preferencesErrorMessage = messages.preferencesUnreadable;
  }

  final _Documents documents;
  final commands = <Map<String, Object?>>[];
  final acknowledgements = <String?>[];
  final owners = <ValueListenable<bool>?>[];
  final pending = <String, Completer<AppSnapshot?>>{};
  String selectedName = 'Restored configuration';
  bool empty = false;
  bool inspectValid = true;
  bool throwRestore = false;
  bool returnUnknownRestore = false;
  bool refuseRestore = false;
  bool isForeground = true;
  Map<String, Object?>? restoreDetails;

  @override
  int get storageEpoch => 7;
  @override
  bool get foreground => isForeground;
  void changed() => notifyListeners();

  AppSnapshot outcome(
    Map<String, Object?> command, {
    bool? success,
    Map<String, dynamic>? backup,
    AppMessage? message,
  }) {
    final action = command['action'];
    final token = command['token'] as String? ?? _first;
    final normal = action == 'restoreBackup'
        ? <String, dynamic>{
            'status': 'restored',
            'token': token,
            'requestId': command['requestId'],
            'committed': true,
            'rolledBack': false,
            'ready': true,
            'epoch': 42,
            'settingsStatus': 'done',
            'scheduleStatus': 'done',
            'connectionStatus': 'notStarted',
            ...?restoreDetails,
          }
        : <String, dynamic>{
            'status': action == 'prepareBackup' ? 'prepared' : 'inspected',
            'token': token,
            'requestId': command['requestId'],
            'createdAtMillis': 1760000000123,
            'summary': BackupSummary(
              configurations: empty ? 0 : 1,
              overrides: empty ? 0 : 2,
              hasSelection: !empty,
              selectedName: empty ? null : selectedName,
            ).toMap(),
          };
    return AppSnapshot(
      phase: 'STOPPED',
      storageReady: true,
      storageEpoch: state.storageEpoch,
      resultId: 'result-${commands.length}',
      resultSuccess: success ?? true,
      resultMessage: message,
      backupResult: backup ?? normal,
    );
  }

  @override
  Future<AppSnapshot?> submitAndWait(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    final copy = Map<String, Object?>.of(command);
    commands.add(copy);
    owners.add(feedbackOwner);
    lastCommand = copy;
    final pendingResult = pending[command['action']];
    if (pendingResult != null) return pendingResult.future;
    if (command['action'] == 'inspectBackup' && !inspectValid) {
      return outcome(
        copy,
        success: false,
        message: const AppMessage('backupInvalid'),
      );
    }
    if (command['action'] == 'restoreBackup') {
      if (throwRestore) {
        throw PlatformException(
          code: 'transport',
          message: 'private credential content://fixture',
        );
      }
      if (returnUnknownRestore) return null;
      if (refuseRestore || command['storageEpoch'] != state.storageEpoch) {
        return outcome(
          copy,
          success: false,
          message: messages.storageContextChanged,
          backup: {
            'token': command['token'],
            'committed': false,
            'status': 'notRestored',
          },
        );
      }
    }
    return outcome(copy);
  }

  @override
  void acknowledgeLocalFeedback(
    ValueListenable<bool> owner, {
    AppSnapshot? result,
  }) => acknowledgements.add(result?.resultId);
}

Future<void> _show(
  WidgetTester tester,
  _BackupApp app, {
  String language = 'en',
  double scale = 1,
  bool dark = false,
  Size size = const Size(400, 1100),
  ValueNotifier<bool>? active,
  ValueNotifier<Locale>? locale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Widget page() => Scaffold(
    body: SingleChildScrollView(
      child: Column(
        children: [
          if (active == null)
            BackupSettingsActions(app: app)
          else
            ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, value, _) =>
                  BackupSettingsActions(app: app, active: value),
            ),
          const SizedBox(
            key: ValueKey('following-settings'),
            height: 48,
            child: Text('Following settings'),
          ),
        ],
      ),
    ),
  );
  Widget application(Locale value) => MaterialApp(
    locale: value,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: dark ? AppTheme.dark : AppTheme.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: page(),
  );
  await tester.pumpWidget(
    locale == null
        ? application(Locale(language))
        : ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (_, value, _) => application(value),
          ),
  );
  await tester.pumpAndSettle();
}

Finder _key(String suffix) => find.byKey(ValueKey('backup-$suffix'));
final _strings = lookupAppLocalizations(const Locale('en'));

Future<void> _choose(WidgetTester tester) async {
  await tester.ensureVisible(_key('import'));
  await tester.tap(_key('import'));
  // Keep the settings busy indicator through outstanding actual I/O.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _confirmRestore(
  WidgetTester tester, [
  AppLocalizations? strings,
]) async {
  final localized = strings ?? _strings;
  expect(find.text(localized.backupConfirmTitle), findsOneWidget);
  await tester.tap(
    find.widgetWithText(FilledButton, localized.backupRestore).hitTestable(),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _export(WidgetTester tester, [AppLocalizations? strings]) async {
  final localized = strings ?? _strings;
  await tester.tap(_key('export'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.textContaining(localized.backupSensitiveNotice), findsOneWidget);
  await tester.tap(
    find.widgetWithText(FilledButton, localized.backupExport).hitTestable(),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

String _resultText(WidgetTester tester) {
  final dialog = find.byType(AlertDialog);
  if (dialog.evaluate().isNotEmpty) {
    return tester
        .widget<SelectableText>(
          find
              .descendant(of: dialog, matching: find.byType(SelectableText))
              .last,
        )
        .data!;
  }
  return tester
      .widget<Text>(
        find
            .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
            .first,
      )
      .data!;
}

Future<void> _close(WidgetTester tester, [AppLocalizations? strings]) async {
  await tester.tap(
    find.widgetWithText(TextButton, (strings ?? _strings).close).hitTestable(),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _Documents documents;
  late _BackupApp app;
  setUp(() {
    documents = _Documents();
    app = _BackupApp(documents);
    addTearDown(app.dispose);
  });

  testWidgets(
    'only two settings actions; no candidate page, notice pane or third step',
    (tester) async {
      await _show(tester, app);
      expect(find.byType(ListTile), findsNWidgets(2));
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text(_strings.backupTitle), findsNothing);
      expect(find.text(_strings.backupSensitiveNotice), findsNothing);
      expect(find.text(_strings.backupRestore), findsNothing);
      expect(app.commands, isEmpty);
      expect(documents.picks, isEmpty);
      expect(documents.saves, isEmpty);
    },
  );

  testWidgets('progress covers I/O, not confirmation or result reading', (
    tester,
  ) async {
    final inspect = Completer<AppSnapshot?>();
    final restore = Completer<AppSnapshot?>();
    app.pending['inspectBackup'] = inspect;
    app.pending['restoreBackup'] = restore;
    app.restoreDetails = {'connectionStatus': 'failed'};
    await _show(tester, app);
    final actions = find.byType(BackupSettingsActions);
    final bounds = {
      for (final key in ['import', 'export']) key: tester.getRect(_key(key)),
    };
    Future<void> stable(bool waiting) async {
      for (final ms in [0, 16, 80, 200]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(
          find.descendant(
            of: actions,
            matching: find.byType(CircularProgressIndicator),
          ),
          waiting ? findsOneWidget : findsNothing,
        );
        for (final entry in bounds.entries) {
          expect(tester.getRect(_key(entry.key)), entry.value);
        }
        expect(tester.takeException(), isNull);
      }
    }

    await _choose(tester);
    await stable(true);
    expect(tester.widget<ListTile>(_key('export')).onTap, isNull);
    inspect.complete(app.outcome(app.commands.single));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(_strings.backupConfirmTitle), findsOneWidget);
    await stable(false);
    expect(tester.widget<ListTile>(_key('import')).onTap, isNull);
    await _confirmRestore(tester);
    await stable(true);
    restore.complete(app.outcome(app.commands.last));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(_resultText(tester), contains(_strings.backupRestored));
    await stable(false);
    expect(documents.discarded, isEmpty);
    await _close(tester);
    expect(documents.discarded, [_first]);
    expect(app.commands.map((command) => command['action']), [
      'inspectBackup',
      'restoreBackup',
    ]);
  });

  testWidgets('export risk confirmation is not a running backup', (
    tester,
  ) async {
    await _show(tester, app);
    final before = tester.getRect(_key('export'));
    await tester.tap(_key('export'));
    for (final ms in [0, 16, 80, 200]) {
      await tester.pump(Duration(milliseconds: ms));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.getRect(_key('export')), before);
      expect(app.commands, isEmpty);
    }
    expect(find.textContaining(_strings.backupSensitiveNotice), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, _strings.cancel));
    await tester.pumpAndSettle();
    expect(documents.saves, isEmpty);
    expect(tester.widget<ListTile>(_key('export')).onTap, isNotNull);
  });

  testWidgets(
    'damaged old Stores retain recovery using native epoch and one immutable token',
    (tester) async {
      await _show(tester, app);
      expect(app.canEdit, isFalse);
      expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
      await _choose(tester);
      expect(app.commands.single['action'], 'inspectBackup');
      expect(app.commands.single['storageEpoch'], 41);
      expect(app.storageEpoch, 7);
      expect(app.commands.single.keys, isNot(contains('paths')));
      expect(app.commands.single.keys, isNot(contains('uri')));
      expect(find.text(_strings.backupCounts(1, 2)), findsOneWidget);
      expect(documents.saves, isEmpty);
      expect(
        app.owners.single!.value,
        isTrue,
        reason: 'Own confirmation is not leaving settings.',
      );
      await _confirmRestore(tester);
      expect(app.commands.map((command) => command['action']), [
        'inspectBackup',
        'restoreBackup',
      ]);
      expect(app.commands.last['token'], _first);
      expect(app.commands.last['storageEpoch'], 41);
      expect(documents.picks, hasLength(1));
      expect(_resultText(tester), contains(_strings.backupRestored));
      expect(documents.discarded, [_first]);
    },
  );

  testWidgets(
    'inspection must finish before counts or overwrite confirmation appear',
    (tester) async {
      final pending = Completer<AppSnapshot?>();
      app.pending['inspectBackup'] = pending;
      await _show(tester, app);
      await _choose(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_strings.backupCounts(1, 2)), findsNothing);
      expect(tester.widget<ListTile>(_key('import')).onTap, isNull);
      expect(documents.discarded, isEmpty);
      pending.complete(app.outcome(app.commands.single));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_strings.backupCounts(1, 2)), findsOneWidget);
      expect(app.acknowledgements, hasLength(1));
    },
  );

  testWidgets(
    'empty collections and connection effect appear in the single cancellable confirmation',
    (tester) async {
      app.empty = true;
      await _show(tester, app);
      await _choose(tester);
      expect(find.text(_strings.backupCounts(0, 0)), findsOneWidget);
      expect(
        find.textContaining(_strings.backupConfirmMessage),
        findsOneWidget,
      );
      expect(find.textContaining(_strings.backupNoSelection), findsOneWidget);
      expect(
        find.textContaining(_strings.backupConfirmStopped),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, _strings.cancel));
      await tester.pumpAndSettle();
      expect(app.commands, hasLength(1));
      expect(documents.discarded, [_first]);
      expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
    },
  );

  testWidgets(
    'cancelled picker submits nothing and keeps no candidate to restore later',
    (tester) async {
      documents.pickedResults.add({'status': 'cancelled'});
      await _show(tester, app);
      await _choose(tester);
      expect(app.commands, isEmpty);
      expect(documents.discarded, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
    },
  );

  testWidgets(
    'bad candidate is retired and a fresh import may validate a different token',
    (tester) async {
      app.inspectValid = false;
      await _show(tester, app);
      await _choose(tester);
      expect(_resultText(tester), _strings.backupInvalid);
      expect(find.text(_strings.backupConfirmTitle), findsNothing);
      await _close(tester);
      expect(documents.discarded, [_first]);
      app.inspectValid = true;
      documents.pickedResults.add({'status': 'ready', 'token': _second});
      await _choose(tester);
      await _confirmRestore(tester);
      expect(app.commands.last['token'], _second);
      expect(documents.discarded, [_first, _second]);
    },
  );

  testWidgets('retired request cannot promote a different import candidate', (
    tester,
  ) async {
    documents.pickedResults.add({
      'status': 'ready',
      'token': _first,
      'requestId': 'retired-request',
    });
    await _show(tester, app);
    await _choose(tester);
    expect(app.commands, isEmpty);
    expect(find.text(_strings.backupConfirmTitle), findsNothing);
    expect(_resultText(tester), _strings.backupInvalid);
    await _close(tester);
    expect(documents.discarded, [_first]);
  });

  testWidgets('open confirmation cannot retarget new storage epoch', (
    tester,
  ) async {
    await _show(tester, app);
    await _choose(tester);
    app.state = const AppSnapshot(
      phase: 'STOPPED',
      storageReady: true,
      storageEpoch: 42,
    );
    app.changed();
    await tester.pump();
    await _confirmRestore(tester);
    expect(app.commands.last['storageEpoch'], 41);
    expect(app.commands.last['token'], _first);
    expect(_resultText(tester), contains(_strings.backupNotRestored));
    expect(_resultText(tester), contains(_strings.storageContextChanged));
    await _close(tester);
    expect(documents.discarded, [_first]);
    documents.pickedResults.add({'status': 'ready', 'token': _second});
    await _choose(tester);
    expect(app.commands.last['storageEpoch'], 42);
    expect(app.commands.last['token'], _second);
  });

  for (final mode in ['missing-commit', 'transport', 'no-reply']) {
    testWidgets(
      'restore $mode remains unconfirmed without automatic replay or secret text',
      (tester) async {
        final pending = Completer<AppSnapshot?>();
        if (mode == 'missing-commit') app.pending['restoreBackup'] = pending;
        app.throwRestore = mode == 'transport';
        app.returnUnknownRestore = mode == 'no-reply';
        await _show(tester, app);
        await _choose(tester);
        await _confirmRestore(tester);
        if (mode == 'missing-commit') {
          pending.complete(
            app.outcome(
              app.commands.last,
              backup: {'token': _first, 'status': 'restored'},
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(
          _resultText(tester),
          contains(_strings.backupRestoreUnconfirmed),
        );
        expect(_resultText(tester), isNot(contains('credential')));
        expect(
          app.commands.where((command) => command['action'] == 'restoreBackup'),
          hasLength(1),
        );
        if (mode != 'missing-commit') {
          expect(
            documents.cancellations,
            contains(app.commands.last['requestId']),
          );
        }
        expect(
          find.widgetWithText(FilledButton, _strings.backupRestore),
          findsNothing,
        );
        await _close(tester);
        expect(documents.discarded, [_first]);
      },
    );
  }

  testWidgets(
    'cancel waits for actual restore and preserves committed data and partial followups',
    (tester) async {
      final pending = Completer<AppSnapshot?>();
      app.pending['restoreBackup'] = pending;
      await _show(tester, app);
      await _choose(tester);
      await _confirmRestore(tester);
      await tester.tap(_key('cancel'));
      await tester.pump();
      expect(documents.cancellations, [app.commands.last['requestId']]);
      expect(tester.widget<ListTile>(_key('import')).onTap, isNull);
      expect(
        documents.discarded,
        isEmpty,
        reason: 'Cancellation is not I/O completion.',
      );
      pending.complete(
        app.outcome(
          app.commands.last,
          success: false,
          backup: {
            'token': _first,
            'committed': true,
            'ready': true,
            'settingsStatus': 'failed',
            'scheduleStatus': 'cancelled',
            'connectionStatus': 'cancelled',
          },
          message: const AppMessage('backupConnectionCancelled'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final text = _resultText(tester);
      expect(text, contains(_strings.backupRestored));
      expect(text, contains(_strings.backupSettingsRefreshFailed));
      expect(text, contains(_strings.backupSchedulesFailed));
      expect(text, contains(_strings.backupConnectionCancelled));
      expect(text, isNot(contains(_strings.backupNotRestored)));
      await _close(tester);
      expect(documents.discarded, [_first]);
    },
  );

  testWidgets(
    'structured causes remain readable but raw native strings do not escape',
    (tester) async {
      app.restoreDetails = {
        'connectionStatus': 'failed',
        'connectionMessage': messages.importAndSelectFirst.toMap(),
        'settingsStatus': 'failed',
        'settingsMessage': 'private credential content://fixture',
      };
      await _show(tester, app);
      await _choose(tester);
      await _confirmRestore(tester);
      expect(
        _resultText(tester),
        contains(messages.importAndSelectFirst.resolve(_strings)),
      );
      expect(_resultText(tester), isNot(contains('private credential')));
      await _close(tester);
    },
  );

  testWidgets(
    'export adopts preparation before SAF, but only actual close success is saved',
    (tester) async {
      documents.pendingSave = Completer<Map<String, dynamic>>();
      await _show(tester, app);
      await _export(tester);
      expect(app.commands.single['action'], 'prepareBackup');
      expect(app.commands.single['storageEpoch'], 41);
      expect(documents.saves.single['token'], _first);
      expect(
        documents.saves.single['requestId'],
        isNot(app.commands.single['requestId']),
      );
      expect(app.acknowledgements, hasLength(1));
      expect(find.text(_strings.backupExportSaved), findsNothing);
      expect(documents.discarded, isEmpty);
      documents.pendingSave!.complete({'status': 'saved'});
      await tester.pumpAndSettle();
      expect(_resultText(tester), _strings.backupExportSaved);
      expect(documents.discarded, [_first]);
      expect(documents.cancellations, isEmpty);
    },
  );

  for (final status in ['failed', 'expired', 'cancelled']) {
    testWidgets('partial external $status is never saved and exposes no URI', (
      tester,
    ) async {
      documents.pendingSave = Completer<Map<String, dynamic>>();
      await _show(tester, app);
      await _export(tester);
      documents.pendingSave!.complete({
        'status': status,
        'externalMayBePartial': true,
        'uri': 'content://private-credential-fixture',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_resultText(tester), _strings.backupDocumentWriteUnconfirmed);
      expect(_resultText(tester), isNot(contains(_strings.backupExportSaved)));
      expect(_resultText(tester), isNot(contains('content://')));
      await _close(tester);
      expect(documents.discarded, [_first]);
    });
  }

  testWidgets(
    'provider close failure cannot report saved or delete a user document',
    (tester) async {
      documents.pendingSave = Completer<Map<String, dynamic>>();
      await _show(tester, app);
      await _export(tester);
      documents.pendingSave!.complete({
        'status': 'failed',
        'errorCode': 'private-provider-error',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_resultText(tester), _strings.backupFailed);
      await _close(tester);
      expect(documents.discarded, [_first]);
      expect(app.commands, hasLength(1));
    },
  );

  testWidgets('late cancellation cannot erase an actually saved document', (
    tester,
  ) async {
    documents.pendingSave = Completer<Map<String, dynamic>>();
    await _show(tester, app);
    await _export(tester);
    await tester.tap(_key('cancel'));
    await tester.pump();
    expect(documents.cancellations, [documents.saves.single['requestId']]);
    expect(documents.discarded, isEmpty);
    documents.pendingSave!.complete({'status': 'saved'});
    await tester.pumpAndSettle();
    expect(_resultText(tester), _strings.backupExportSaved);
    expect(documents.discarded, [_first]);
  });

  for (final stage in ['pick', 'inspect', 'prepare']) {
    testWidgets(
      'leaving during $stage cancels original identity and retires late token',
      (tester) async {
        final native = Completer<Map<String, dynamic>>();
        final logic = Completer<AppSnapshot?>();
        if (stage == 'pick') documents.pendingPick = native;
        if (stage == 'inspect') app.pending['inspectBackup'] = logic;
        if (stage == 'prepare') app.pending['prepareBackup'] = logic;
        await _show(tester, app);
        if (stage == 'prepare') {
          await _export(tester);
        } else {
          await _choose(tester);
        }
        final command = app.commands.isEmpty ? null : app.commands.last;
        final request = stage == 'pick'
            ? documents.picks.single
            : command!['requestId'];
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(documents.cancellations, contains(request));
        if (stage == 'pick') {
          native.complete({'status': 'ready', 'token': _first});
        } else {
          logic.complete(app.outcome(command!));
        }
        await tester.pump();
        expect(documents.saves, isEmpty);
        expect(documents.discarded, [_first]);
        expect(
          app.commands.where((command) => command['action'] == 'restoreBackup'),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'tab departure permanently retires an import even if settings returns before reply',
    (tester) async {
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final pending = Completer<AppSnapshot?>();
      app.pending['inspectBackup'] = pending;
      await _show(tester, app, active: active);
      await _choose(tester);
      active.value = false;
      await tester.pump();
      expect(app.owners.single!.value, isFalse);
      active.value = true;
      await tester.pump();
      pending.complete(app.outcome(app.commands.single));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.commands, hasLength(1));
      expect(documents.discarded, [_first]);
    },
  );

  testWidgets(
    'another route cancels waiting export and is never popped by its late reply',
    (tester) async {
      documents.pendingSave = Completer<Map<String, dynamic>>();
      await _show(tester, app);
      await _export(tester);
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(BackupSettingsActions)),
          builder: (_) => const AlertDialog(title: Text('Newer result')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(documents.cancellations, [documents.saves.single['requestId']]);
      documents.pendingSave!.complete({'status': 'saved'});
      await tester.pumpAndSettle();
      expect(find.text('Newer result'), findsOneWidget);
      expect(find.text(_strings.backupExportSaved), findsNothing);
      expect(documents.discarded, [_first]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SAF result arriving before resumed waits without cancelling or discarding the candidate',
    (tester) async {
      documents.pendingPick = Completer<Map<String, dynamic>>();
      await _show(tester, app);
      await _choose(tester);
      app.isForeground = false;
      app.changed();
      documents.pendingPick!.complete({'status': 'ready', 'token': _first});
      await tester.pump();
      expect(app.commands, isEmpty);
      expect(documents.discarded, isEmpty);
      expect(documents.cancellations, isEmpty);
      app.isForeground = true;
      app.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_strings.backupConfirmTitle), findsOneWidget);
      await _confirmRestore(tester);
      expect(app.commands.last['action'], 'restoreBackup');
      expect(documents.discarded, [_first]);
    },
  );

  testWidgets('background SAF save completion is reported once after resume', (
    tester,
  ) async {
    documents.pendingSave = Completer<Map<String, dynamic>>();
    await _show(tester, app);
    await _export(tester);
    app.isForeground = false;
    app.changed();
    documents.pendingSave!.complete({'status': 'saved'});
    await tester.pump();
    expect(find.text(_strings.backupExportSaved), findsNothing);
    app.isForeground = true;
    app.changed();
    await tester.pumpAndSettle();
    expect(_resultText(tester), _strings.backupExportSaved);
    expect(documents.discarded, [_first]);
  });

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 320.0, 700.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final dark in [false, true]) {
          testWidgets(
            'two rows stable waiting/error/retry/locale $language/$width/$scale/$dark',
            (tester) async {
              final locale = ValueNotifier(Locale(language));
              addTearDown(locale.dispose);
              await _show(
                tester,
                app,
                language: language,
                scale: scale,
                dark: dark,
                size: Size(width, 1000),
                locale: locale,
              );
              final anchors = [
                _key('import'),
                _key('export'),
                find.byKey(const ValueKey('following-settings')),
              ];
              final before = anchors.map(tester.getRect).toList();
              Future<void> stable() async {
                for (final ms in [0, 16, 80, 300]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(anchors.map(tester.getRect).toList(), before);
                  expect(tester.takeException(), isNull);
                }
              }

              final pending = Completer<AppSnapshot?>();
              app.pending['inspectBackup'] = pending;
              await _choose(tester);
              await stable();
              pending.complete(
                app.outcome(
                  app.commands.last,
                  success: false,
                  message: const AppMessage('backupInvalid'),
                ),
              );
              await stable();
              await _close(tester, lookupAppLocalizations(Locale(language)));
              await stable();
              app.pending.remove('inspectBackup');
              app.selectedName = 'Selected ${'配置🌐' * 7}a';
              await _choose(tester);
              await stable();
              final strings = lookupAppLocalizations(Locale(language));
              expect(find.text(strings.backupCounts(1, 2)), findsOneWidget);
              await tester.tap(
                find.widgetWithText(TextButton, strings.cancel).hitTestable(),
              );
              await tester.pumpAndSettle();
              await stable();
              locale.value = Locale(language == 'en' ? 'zh' : 'en');
              await stable();
              expect(documents.discarded, [_first, _first]);
            },
          );
        }
      }
    }
  }
}
