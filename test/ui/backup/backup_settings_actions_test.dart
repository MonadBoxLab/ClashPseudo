import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:convert';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/model/backup_data.dart';
import 'package:clash_pseudo/src/ui/backup/backup_settings_actions.dart';
import 'package:clash_pseudo/src/ui/settings/storage_data_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

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
  Completer<void>? pendingCancel;
  Completer<void>? pendingDiscard;

  @override
  Future<Map<String, dynamic>> storageUsage() async => {
    'configurations': {'bytes': 19, 'path': '/fixture/configurations.json'},
    'overrides': {'bytes': 21, 'path': '/fixture/overrides.json'},
    'preferences': {'bytes': 23, 'path': '/fixture/preferences.json'},
    'core': {'bytes': 0, 'path': '/fixture/mihomo'},
  };

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
  Future<void> backupCancel(String requestId) async {
    cancellations.add(requestId);
    await pendingCancel?.future;
  }

  @override
  Future<void> backupDiscard(String token) async {
    discarded.add(token);
    await pendingDiscard?.future;
  }
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
        throw PlatformFailure(
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
  ValueNotifier<AppTask>? task,
  ValueNotifier<Locale>? locale,
  bool storagePage = false,
  bool focusedPage = false,
  ValueNotifier<(double, bool)>? presentation,
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
  final taskRoutes = AppTaskNavigatorObserver();
  Widget application(Locale value) => MaterialApp(
    navigatorObservers: [taskRoutes],
    locale: value,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: dark ? AppTheme.dark : AppTheme.light,
    builder: (context, child) {
      Widget media((double, bool) value) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(value.$1),
          disableAnimations: value.$2,
        ),
        child: child!,
      );
      final content = presentation == null
          ? media((scale, false))
          : ValueListenableBuilder(
              valueListenable: presentation,
              builder: (_, value, _) => media(value),
            );
      final activity = !focusedPage
          ? content
          : ListenableBuilder(
              listenable: app,
              builder: (_, child) => AppTaskActivity(
                active: app.foreground && app.interactive,
                isActiveNow: () => app.foreground && app.interactive,
                isActiveWithPopup: (_) => app.foreground && app.interactive,
                child: child!,
              ),
              child: content,
            );
      return task == null
          ? activity
          : ValueListenableBuilder<AppTask>(
              valueListenable: task,
              builder: (_, value, child) => AppTaskScope(
                open: (_) {},
                task: value,
                owner: app,
                child: child!,
              ),
              child: activity,
            );
    },
    home: focusedPage
        ? null
        : storagePage
        ? StorageDataPage(app: app)
        : page(),
    onGenerateRoute: !focusedPage
        ? null
        : (_) => FocusedPageRoute<void>(
            builder: (_) => storagePage ? StorageDataPage(app: app) : page(),
          ),
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
  expect(
    find.widgetWithText(FilledButton, localized.backupExport),
    findsNothing,
  );
}

String _resultText(WidgetTester tester) {
  final dialog = find.byType(AlertDialog);
  if (dialog.evaluate().isNotEmpty) {
    final summary = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('backup-result-summary')),
        )
        .data!;
    // The same complete causes now belong to the explicit technical reader.
    // Retain every original result-content assertion independently of expansion.
    final technical = find.byKey(
      const ValueKey('backup-result-technical-content'),
      skipOffstage: false,
    );
    return technical.evaluate().isEmpty
        ? summary
        : '$summary\n\n${tester.widget<OriginalTextView>(technical).text}';
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
    'focused storage page retains its own confirmation and result dialog',
    (tester) async {
      app.refuseRestore = true;
      await _show(tester, app, storagePage: true, focusedPage: true);
      final identity = tester.state(find.byType(BackupSettingsActions));
      await _choose(tester);
      expect(find.text(_strings.backupConfirmTitle), findsOneWidget);
      expect(documents.cancellations, isEmpty);
      await _confirmRestore(tester);
      expect(app.commands.map((command) => command['action']), [
        'inspectBackup',
        'restoreBackup',
      ]);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(documents.cancellations, isEmpty);
      expect(documents.discarded, [_first]);
      expect(tester.state(find.byType(BackupSettingsActions)), same(identity));
      await _close(tester);
      expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unrelated popup retires a focused page request but drains its real pick',
    (tester) async {
      documents.pendingPick = Completer<Map<String, dynamic>>();
      await _show(tester, app, focusedPage: true);
      await _choose(tester);
      final context = tester.element(find.byType(BackupSettingsActions));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('Unrelated popup')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(documents.cancellations, documents.picks);
      expect(documents.discarded, isEmpty);
      documents.pendingPick!.complete({'status': 'ready', 'token': _first});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(documents.discarded, [_first]);
      expect(app.commands, isEmpty);
      expect(find.text('Unrelated popup'), findsOneWidget);
      expect(find.text(_strings.backupConfirmTitle), findsNothing);
      Navigator.of(tester.element(find.text('Unrelated popup'))).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focused SAF request suspends UI qualification until foreground returns',
    (tester) async {
      documents.pendingPick = Completer<Map<String, dynamic>>();
      await _show(tester, app, focusedPage: true);
      await _choose(tester);
      app.isForeground = false;
      app.changed();
      await tester.pump();
      documents.pendingPick!.complete({'status': 'ready', 'token': _first});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(documents.cancellations, isEmpty);
      expect(documents.discarded, isEmpty);
      expect(app.commands, isEmpty);
      app.isForeground = true;
      app.changed();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(_strings.backupConfirmTitle), findsOneWidget);
      expect(app.commands.single['action'], 'inspectBackup');
      expect(documents.cancellations, isEmpty);
      await tester.tap(
        find.widgetWithText(TextButton, _strings.cancel).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(documents.discarded, [_first]);
      expect(app.commands, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final status in ['saved', 'failed']) {
    testWidgets(
      'inactive SAF $status retains actual completion through paused and resumed',
      (tester) async {
        documents.pendingSave = Completer<Map<String, dynamic>>();
        documents.pendingDiscard = Completer<void>();
        await _show(tester, app, focusedPage: true, storagePage: true);
        final identity = tester.state(find.byType(BackupSettingsActions));
        await _export(tester);
        final request = documents.saves.single['requestId'];
        final cancel = tester.widget<IconButton>(_key('cancel')).onPressed!;
        app.setInteractive(false);
        await tester.pump();
        expect(app.foreground, isTrue);
        expect(app.interactive, isFalse);
        expect(app.owners.single!.value, isFalse);
        expect(tester.widget<IconButton>(_key('cancel')).onPressed, isNull);
        cancel();
        await tester.pump();
        expect(documents.cancellations, isEmpty);
        expect(documents.discarded, isEmpty);
        expect(tester.widget<ListTile>(_key('import')).onTap, isNull);
        expect(
          tester.state(find.byType(BackupSettingsActions)),
          same(identity),
        );
        app.isForeground = false;
        app.changed();
        await tester.pump();
        expect(documents.discarded, isEmpty);
        app.isForeground = true;
        app.changed();
        await tester.pump();
        documents.pendingSave!.complete({
          'status': status,
          if (status == 'failed') ...{
            'errorCode': 'backupDocumentIoFailed',
            'errorDetail': const AppMessage('backupFailed')
                .withDetail('original inactive provider close failure')
                .toMap(),
            'externalMayBePartial': true,
          },
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(app.interactive, isFalse);
        expect(documents.cancellations, isEmpty);
        expect(documents.discarded, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        app.setInteractive(true);
        await tester.pump();
        expect(documents.discarded, [_first]);
        expect(tester.widget<ListTile>(_key('import')).onTap, isNull);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        documents.pendingDiscard!.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(documents.saves.single['requestId'], request);
        expect(documents.cancellations, isEmpty);
        expect(documents.discarded, [_first]);
        if (status == 'saved') {
          expect(_resultText(tester), _strings.backupExportSaved);
          expect(find.byType(SnackBar), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          await tester.pump(const Duration(seconds: 5));
          await tester.pump(const Duration(milliseconds: 300));
        } else {
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.byType(SnackBar), findsNothing);
          expect(
            _resultText(tester),
            contains('original inactive provider close failure'),
          );
          expect(_resultText(tester), contains('backupDocumentIoFailed'));
          expect(
            _resultText(tester),
            isNot(contains(_strings.backupExportSaved)),
          );
          await tester.tap(
            find.widgetWithText(TextButton, _strings.close).hitTestable(),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }
        app.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
        expect(
          tester.state(find.byType(BackupSettingsActions)),
          same(identity),
        );
        expect(documents.discarded, [_first]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final paused in [false, true]) {
    testWidgets(
      'inactive ready pick waits for resumed without retiring $paused',
      (tester) async {
        documents.pendingPick = Completer<Map<String, dynamic>>();
        await _show(tester, app, focusedPage: true);
        final identity = tester.state(find.byType(BackupSettingsActions));
        await _choose(tester);
        app.setInteractive(false);
        await tester.pump();
        expect(documents.cancellations, isEmpty);
        if (paused) {
          app.isForeground = false;
          app.changed();
          await tester.pump();
        }
        documents.pendingPick!.complete({'status': 'ready', 'token': _first});
        await tester.pump();
        app.isForeground = true;
        app.changed();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(app.foreground, isTrue);
        expect(app.interactive, isFalse);
        expect(documents.cancellations, isEmpty);
        expect(documents.discarded, isEmpty);
        expect(app.commands, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.widget<IconButton>(_key('cancel')).onPressed, isNull);
        app.setInteractive(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(app.commands.single['action'], 'inspectBackup');
        expect(app.commands.single['token'], _first);
        expect(app.commands.single['storageEpoch'], 41);
        expect(app.owners.single!.value, isTrue);
        expect(find.text(_strings.backupConfirmTitle), findsOneWidget);
        expect(documents.discarded, isEmpty);
        expect(
          tester.state(find.byType(BackupSettingsActions)),
          same(identity),
        );
        await tester.tap(
          find.widgetWithText(TextButton, _strings.cancel).hitTestable(),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(app.commands, hasLength(1));
        expect(documents.cancellations, isEmpty);
        expect(documents.discarded, [_first]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final departure in ['pop', 'dispose', 'cover']) {
    testWidgets(
      'inactive $departure permanently retires the original pick before cleanup',
      (tester) async {
        documents.pendingPick = Completer<Map<String, dynamic>>();
        await _show(tester, app, focusedPage: true);
        final navigator = Navigator.of(
          tester.element(find.byType(BackupSettingsActions)),
        );
        if (departure == 'pop') {
          final route = FocusedPageRoute<void>(
            builder: (_) => Scaffold(body: BackupSettingsActions(app: app)),
          );
          unawaited(navigator.push<void>(route));
          await tester.pump();
          await tester.pump(
            route.transitionDuration + const Duration(microseconds: 1),
          );
          expect(route.isActive, isTrue);
          expect(route.isCurrent, isTrue);
          expect(route.animation!.status, AnimationStatus.completed);
          final actions = find.byElementPredicate(
            (element) =>
                element.widget is BackupSettingsActions &&
                identical(ModalRoute.of(element), route),
          );
          expect(actions, findsOneWidget);
          final importAction = find.descendant(
            of: actions,
            matching: _key('import'),
          );
          expect(importAction, findsOneWidget);
          await tester.ensureVisible(importAction);
          expect(importAction.hitTestable(), findsOneWidget);
          await tester.tap(importAction);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        } else {
          await _choose(tester);
        }
        final request = documents.picks.single;
        app.setInteractive(false);
        await tester.pump();
        expect(documents.cancellations, isEmpty);
        if (departure == 'dispose') {
          await tester.pumpWidget(const SizedBox());
        } else if (departure == 'pop') {
          navigator.pop();
        } else {
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(BackupSettingsActions)),
              builder: (_) =>
                  const AlertDialog(title: Text('Unrelated inactive popup')),
            ),
          );
        }
        await tester.pump();
        expect(documents.cancellations, [request]);
        expect(documents.discarded, isEmpty);
        if (departure == 'cover') {
          await tester.pump(const Duration(milliseconds: 300));
          navigator.pop();
        }
        documents.pendingPick!.complete({'status': 'ready', 'token': _first});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        app.setInteractive(true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(app.commands, isEmpty);
        expect(documents.saves, isEmpty);
        expect(documents.cancellations, [request]);
        expect(documents.discarded, [_first]);
        expect(find.text(_strings.backupConfirmTitle), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'inactive task departure cannot be revived by returning before the real reply',
    (tester) async {
      final task = ValueNotifier(AppTask.settings);
      addTearDown(task.dispose);
      documents.pendingPick = Completer<Map<String, dynamic>>();
      await _show(tester, app, focusedPage: true, task: task);
      await _choose(tester);
      final request = documents.picks.single;
      app.setInteractive(false);
      await tester.pump();
      expect(documents.cancellations, isEmpty);
      task.value = AppTask.overview;
      await tester.pump();
      expect(documents.cancellations, [request]);
      expect(documents.discarded, isEmpty);
      task.value = AppTask.settings;
      await tester.pump();
      app.setInteractive(true);
      documents.pendingPick!.complete({'status': 'ready', 'token': _first});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(app.commands, isEmpty);
      expect(documents.saves, isEmpty);
      expect(documents.cancellations, [request]);
      expect(documents.discarded, [_first]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'overall false keeps committed fact but never presents restored-only success',
    (tester) async {
      final restore = Completer<AppSnapshot?>();
      app.pending['restoreBackup'] = restore;
      await _show(tester, app);
      await _choose(tester);
      await _confirmRestore(tester);
      restore.complete(
        app.outcome(
          app.commands.last,
          success: false,
          message: const AppMessage('backupRestored'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsOneWidget);
      final text = _resultText(tester);
      expect(text, contains(_strings.backupRestored));
      expect(text, contains(_strings.operationNotCompleted));
      expect(find.byType(SnackBar), findsNothing);
      expect(documents.discarded, [_first]);
      await _close(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'backup transitions never delay cancellation or release actual cleanup drain early',
    (tester) async {
      final prepared = Completer<AppSnapshot?>();
      app.pending['prepareBackup'] = prepared;
      documents.pendingCancel = Completer<void>();
      documents.pendingDiscard = Completer<void>();
      final presentation = ValueNotifier((1.0, false));
      addTearDown(presentation.dispose);
      final semantics = tester.ensureSemantics();
      try {
        await _show(tester, app, presentation: presentation);
        final state = tester.state(find.byType(BackupSettingsActions));
        final before = tester.getRect(_key('export'));
        final following = find.byKey(const ValueKey('following-settings'));
        final followingBefore = tester.getRect(following);
        await tester.tap(_key('export'));
        await tester.pump();
        final progress = find.descendant(
          of: _key('export'),
          matching: find.byType(CircularProgressIndicator),
        );
        Animation<double> opacity() => tester
            .widget<FadeTransition>(
              find
                  .ancestor(of: progress, matching: find.byType(FadeTransition))
                  .first,
            )
            .opacity;
        expect(opacity().value, 0);
        expect(_key('cancel').hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 40));
        expect(opacity().value, inExclusiveRange(0, 1));
        await tester.tap(_key('cancel'));
        await tester.pump();
        expect(documents.cancellations, [app.commands.single['requestId']]);
        expect(tester.widget<ListTile>(_key('export')).onTap, isNull);
        expect(documents.discarded, isEmpty);
        prepared.complete(app.outcome(app.commands.single));
        await tester.pump();
        await tester.pump();
        expect(documents.discarded, [_first]);
        expect(documents.saves, isEmpty);
        expect(tester.widget<ListTile>(_key('export')).onTap, isNull);
        documents.pendingCancel!.complete();
        await tester.pump();
        expect(tester.widget<ListTile>(_key('export')).onTap, isNull);
        documents.pendingDiscard!.complete();
        await tester.pump();
        await tester.pump();
        expect(tester.widget<ListTile>(_key('export')).onTap, isNotNull);
        expect(_key('cancel'), findsOneWidget);
        expect(_key('cancel').hitTestable(), findsNothing);
        expect(
          tester.semantics.simulatedAccessibilityTraversal().map(
            (node) => node.getSemanticsData().label,
          ),
          isNot(contains(_strings.cancel)),
        );
        expect(tester.getRect(_key('export')), before);
        expect(tester.getRect(following), followingBefore);
        await tester.pump(const Duration(milliseconds: 10));
        expect(opacity().value, inExclusiveRange(0, 1));
        presentation.value = (1.0, true);
        await tester.pump();
        expect(progress, findsNothing);
        expect(_key('cancel'), findsNothing);
        expect(tester.state(find.byType(BackupSettingsActions)), same(state));
        expect(tester.getRect(_key('export')), before);
        expect(documents.cancellations, hasLength(1));
        expect(documents.discarded, [_first]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'backup action row sizes follow font changes without moving the real task into a new state',
    (tester) async {
      final presentation = ValueNotifier((1.0, false));
      addTearDown(presentation.dispose);
      await _show(
        tester,
        app,
        size: const Size(320, 900),
        presentation: presentation,
      );
      final state = tester.state(find.byType(BackupSettingsActions));
      double extent() => tester
          .getSize(
            find
                .ancestor(
                  of: _key('import'),
                  matching: find.byType(AnimatedSize),
                )
                .first,
          )
          .height;
      final before = extent();
      final exportBefore = tester.getTopLeft(_key('export')).dy;
      final following = find.byKey(const ValueKey('following-settings'));
      final followingBefore = tester.getTopLeft(following).dy;
      presentation.value = (2.0, false);
      await tester.pump();
      expect(extent(), closeTo(before, .01));
      await tester.pump(const Duration(milliseconds: 60));
      final middle = extent();
      expect(middle, greaterThan(before));
      expect(middle, lessThan(tester.getSize(_key('import')).height));
      expect(tester.getTopLeft(_key('export')).dy, greaterThan(exportBefore));
      expect(tester.getTopLeft(following).dy, greaterThan(followingBefore));
      presentation.value = (1.0, false);
      await tester.pump();
      expect(extent(), closeTo(middle, .01));
      await tester.pumpAndSettle();
      expect(extent(), closeTo(before, .01));
      expect(tester.getTopLeft(_key('export')).dy, exportBefore);
      presentation.value = (2.0, true);
      await tester.pump();
      expect(
        find.ancestor(of: _key('import'), matching: find.byType(AnimatedSize)),
        findsNothing,
      );
      expect(tester.getSize(_key('import')).height, greaterThan(before));
      expect(tester.state(find.byType(BackupSettingsActions)), same(state));
      expect(app.commands, isEmpty);
      expect(documents.cancellations, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'storage page retains the export and restore flow $language $scale',
        (tester) async {
          documents.pendingSave = Completer<Map<String, dynamic>>();
          final strings = lookupAppLocalizations(Locale(language));
          await _show(
            tester,
            app,
            language: language,
            scale: scale,
            storagePage: true,
          );
          expect(find.byType(StorageDataPage), findsOneWidget);
          expect(find.byType(BackupSettingsActions), findsOneWidget);
          expect(find.byType(SnackBar), findsOneWidget);
          final readNotice = find.byType(SnackBar);
          await tester.tap(
            find.descendant(
              of: readNotice,
              matching: find.widgetWithIcon(IconButton, Icons.close),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          expect(find.text(strings.backupScopeNotice), findsOneWidget);
          expect(
            tester.getTopLeft(_key('import')).dy,
            lessThan(tester.getTopLeft(_key('export')).dy),
          );
          await _export(tester, strings);
          expect(app.commands.single['action'], 'prepareBackup');
          expect(app.commands.single['storageEpoch'], 41);
          expect(documents.saves.single['token'], _first);
          expect(documents.discarded, isEmpty);
          expect(find.byType(AlertDialog), findsNothing);
          app.isForeground = false;
          app.changed();
          documents.pendingSave!.complete({'status': 'saved'});
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text(strings.backupExportSaved), findsNothing);
          app.isForeground = true;
          app.changed();
          await tester.pumpAndSettle();
          expect(_resultText(tester), strings.backupExportSaved);
          expect(documents.discarded, [_first]);
          expect(documents.cancellations, isEmpty);
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          await _choose(tester);
          expect(app.commands.last['action'], 'inspectBackup');
          expect(app.commands.last['storageEpoch'], 41);
          expect(find.text(strings.backupConfirmTitle), findsOneWidget);
          expect(find.text(strings.backupCounts(1, 2)), findsOneWidget);
          expect(documents.picks, hasLength(1));
          await _confirmRestore(tester, strings);
          expect(app.commands.map((command) => command['action']), [
            'prepareBackup',
            'inspectBackup',
            'restoreBackup',
          ]);
          expect(app.commands.last['token'], _first);
          expect(app.commands.last['storageEpoch'], 41);
          await tester.pumpAndSettle();
          expect(_resultText(tester), contains(strings.backupRestored));
          expect(find.byType(AlertDialog), findsNothing);
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          expect(find.byType(StorageDataPage), findsOneWidget);
          expect(documents.discarded, [_first, _first]);
          expect(documents.saves, hasLength(1));
          expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'only two settings actions; no candidate page, notice pane or third step',
    (tester) async {
      await _show(tester, app);
      expect(find.byType(ListTile), findsNWidgets(2));
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text(_strings.backupTitle), findsNothing);
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
    expect(documents.discarded, [_first]);
    await _close(tester);
    expect(documents.discarded, [_first]);
    expect(app.commands.map((command) => command['action']), [
      'inspectBackup',
      'restoreBackup',
    ]);
  });

  testWidgets(
    'export prepares immediately and keeps cancellation tied to actual completion',
    (tester) async {
      final prepared = Completer<AppSnapshot?>();
      app.pending['prepareBackup'] = prepared;
      await _show(tester, app);
      final before = tester.getRect(_key('export'));
      await tester.tap(_key('export'));
      for (final ms in [0, 16, 80, 200]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(tester.getRect(_key('export')), before);
        expect(find.byType(AlertDialog), findsNothing);
        expect(app.commands.single['action'], 'prepareBackup');
        expect(documents.saves, isEmpty);
      }
      await tester.tap(_key('cancel'));
      await tester.pump();
      expect(documents.cancellations, [app.commands.single['requestId']]);
      expect(documents.discarded, isEmpty);
      expect(tester.widget<ListTile>(_key('export')).onTap, isNull);
      prepared.complete(app.outcome(app.commands.single));
      await tester.pumpAndSettle();
      expect(documents.saves, isEmpty);
      expect(documents.discarded, [_first]);
      expect(tester.widget<ListTile>(_key('export')).onTap, isNotNull);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

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
    expect(_resultText(tester), startsWith(_strings.backupInvalid));
    expect(_resultText(tester), contains('Retired import request'));
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
        if (mode == 'transport') {
          expect(
            _resultText(tester),
            contains(
              PlatformFailure(
                code: 'transport',
                message: 'private credential content://fixture',
              ).toString(),
            ),
          );
        }
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

  testWidgets('structured and original native causes remain readable', (
    tester,
  ) async {
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
    expect(
      _resultText(tester),
      contains('private credential content://fixture'),
    );
    await _close(tester);
  });

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
    testWidgets(
      'partial external $status keeps the complete provider feedback',
      (tester) async {
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
        expect(
          _resultText(tester),
          startsWith(_strings.backupDocumentWriteUnconfirmed),
        );
        expect(
          _resultText(tester),
          isNot(contains(_strings.backupExportSaved)),
        );
        expect(
          _resultText(tester),
          contains('content://private-credential-fixture'),
        );
        await _close(tester);
        expect(documents.discarded, [_first]);
      },
    );
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
      expect(_resultText(tester), contains(_strings.backupFailed));
      expect(_resultText(tester), contains('private-provider-error'));
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

  for (final importing in [false, true]) {
    testWidgets(
      'actual ${importing ? 'restore' : 'save'} survives a real cleanup failure',
      (tester) async {
        documents.pendingDiscard = Completer<void>();
        await _show(tester, app);
        if (importing) {
          await _choose(tester);
          await _confirmRestore(tester);
        } else {
          await _export(tester);
        }
        expect(documents.discarded, [_first]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.widget<ListTile>(_key('import')).onTap, isNull);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        documents.pendingDiscard!.completeError(
          PlatformFailure(
            code: 'backupCleanup',
            details: const AppMessage('backupFailed')
                .withDetail('original cleanup cause: content://credential')
                .toMap(),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final text = _resultText(tester);
        expect(
          text,
          contains(
            importing ? _strings.backupRestored : _strings.backupExportSaved,
          ),
        );
        expect(text, contains('original cleanup cause: content://credential'));
        expect(text, isNot(contains(_strings.backupNotRestored)));
        await tester.tap(find.byKey(const ValueKey('backup-result-raw')));
        await tester.pumpAndSettle();
        final raw = jsonDecode(
          tester.widget<OriginalTextView>(find.byType(OriginalTextView)).text,
        ) as Map;
        expect(
          importing ? raw['committed'] : raw['status'],
          importing ? true : 'saved',
        );
        await _close(tester);
        expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
      },
    );
  }

  testWidgets(
    'cancellation failure settles after actual save without hiding either result',
    (tester) async {
      documents.pendingSave = Completer<Map<String, dynamic>>();
      documents.pendingCancel = Completer<void>();
      await _show(tester, app);
      await _export(tester);
      await tester.tap(_key('cancel'));
      await tester.pump();
      documents.pendingSave!.complete({'status': 'saved'});
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.widget<ListTile>(_key('import')).onTap, isNull);
      documents.pendingCancel!.completeError(
        StateError('original cancellation failure'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_resultText(tester), contains(_strings.backupExportSaved));
      expect(_resultText(tester), contains('original cancellation failure'));
      await _close(tester);
    },
  );

  testWidgets(
    'native error and unknown fields are completely viewable and copyable',
    (tester) async {
      final error = 'provider credential content://fixture/${'原🌐' * 5000}';
      app.restoreDetails = {
        'errorDetail': const AppMessage('backupFailed')
            .withDetail(error)
            .toMap(),
        'unknown': {'false': false, 'zero': 0, 'null': null, 'empty': []},
        'errorCode': null,
      };
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _show(tester, app);
      await _choose(tester);
      await _confirmRestore(tester);
      expect(_resultText(tester), contains(error));
      final expansion = find.byKey(const ValueKey('backup-result-raw'));
      await tester.ensureVisible(expansion);
      await tester.tap(expansion);
      await tester.pumpAndSettle();
      final view = tester.widget<OriginalTextView>(
        find.byType(OriginalTextView),
      );
      final raw = jsonDecode(view.text) as Map;
      expect(raw['errorDetail'], app.restoreDetails!['errorDetail']);
      expect(raw['unknown'], app.restoreDetails!['unknown']);
      expect(raw.containsKey('errorCode'), isTrue);
      final copy = find.byKey(const ValueKey('original-text-copy'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, view.text);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('successful save exposes its full raw provider feedback', (
    tester,
  ) async {
    documents.pendingSave = Completer<Map<String, dynamic>>();
    await _show(tester, app);
    await _export(tester);
    final response = {
      'status': 'saved',
      'unknown': {'null': null, 'empty': []},
      'errorCode': null,
    };
    documents.pendingSave!.complete(response);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SnackBarAction, _strings.rawData));
    await tester.pumpAndSettle();
    final raw = jsonDecode(
      tester.widget<OriginalTextView>(find.byType(OriginalTextView)).text,
    ) as Map;
    for (final key in response.keys) {
      expect(raw[key], response[key]);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired imported feedback cannot authorize Store inspection', (
    tester,
  ) async {
    documents.pickedResults.add({
      'status': 'ready',
      'token': _first,
      'retired': true,
      'unknown': 'captured',
    });
    await _show(tester, app);
    await _choose(tester);
    expect(app.commands, isEmpty);
    expect(find.text(_strings.backupConfirmTitle), findsNothing);
    expect(_resultText(tester), contains('captured'));
    expect(documents.discarded, [_first]);
    await _close(tester);
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

  testWidgets('备份短标签只按当前语言测量', (tester) async {
    await _show(
      tester,
      app,
      language: 'zh',
      scale: 2,
      size: const Size(280, 1000),
    );
    final strings = lookupAppLocalizations(const Locale('zh'));
    for (final label in [strings.backupImport, strings.backupExport]) {
      final finder = find.text(label);
      final text = tester.widget<Text>(finder);
      final context = tester.element(finder);
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(context).style.merge(text.style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.localeOf(context),
      )..layout(maxWidth: tester.getSize(finder).width);
      expect(tester.getSize(finder).height, closeTo(painter.height, 0.1));
      painter.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 320.0, 700.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final dark in [false, true]) {
          testWidgets(
            '备份动作在同一语言内保持位置，切换语言后按当前标签重排 $language/$width/$scale/$dark',
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
              var before = anchors.map(tester.getRect).toList();
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
              await tester.pumpAndSettle();
              final translated = lookupAppLocalizations(locale.value);
              expect(find.text(translated.backupImport), findsOneWidget);
              expect(find.text(translated.backupExport), findsOneWidget);
              before = anchors.map(tester.getRect).toList();
              expect(before[1].top, greaterThanOrEqualTo(before[0].bottom));
              expect(before[2].top, greaterThanOrEqualTo(before[1].bottom));
              await stable();
              expect(documents.discarded, [_first, _first]);
            },
          );
        }
      }
    }
  }

  group('backup result interaction roles', () {
    testWidgets(
      'summary precedes explicit complete technical reading and copying',
      (tester) async {
        const original =
            'provider failure 原文🙂\nclose failure: content://fixture/document';
        app.restoreDetails = {
          'connectionStatus': 'failed',
          'connectionMessage': messages.operationFailed
              .withDetail(original)
              .toMap(),
          'unknown': {'zero': 0, 'false': false, 'null': null},
        };
        String? copied;
        var writes = 0;
        var failCopy = false;
        final copyFailure = PlatformException(
          code: 'clipboard',
          message: 'clipboard unavailable 原文🙂',
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (failCopy) throw copyFailure;
              copied = (call.arguments as Map)['text'] as String;
              writes++;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await _show(tester, app);
        final owner = tester.state(find.byType(BackupSettingsActions));
        await _choose(tester);
        await _confirmRestore(tester);
        final summary = tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('backup-result-summary')),
            )
            .data!;
        expect(summary, contains(_strings.backupRestored));
        expect(summary, contains(_strings.backupConnectionFailed));
        expect(summary, isNot(contains(original)));
        expect(find.text(original), findsNothing);
        final technical = find.byKey(const ValueKey('backup-result-technical'));
        expect(tester.widget<ExpansionTile>(technical).title, isA<Text>());
        expect(
          (tester.widget<ExpansionTile>(technical).title as Text).data,
          _strings.technicalDetails,
        );
        await tester.ensureVisible(technical);
        await tester.tap(find.text(_strings.technicalDetails));
        await tester.pumpAndSettle();
        final viewFinder = find.byKey(
          const ValueKey('backup-result-technical-content'),
        );
        final view = tester.widget<OriginalTextView>(viewFinder);
        expect(view.text, contains(original));
        final copy = find.descendant(
          of: viewFinder,
          matching: find.byKey(const ValueKey('original-text-copy')),
        );
        await tester.ensureVisible(copy);
        await tester.pumpAndSettle();
        expect(
          tester.widget<IconButton>(copy).tooltip,
          _strings.copyOriginalText,
        );
        expect(
          tester.getRect(copy).size.shortestSide,
          greaterThanOrEqualTo(48),
        );
        final copyAction = tester.widget<IconButton>(copy).onPressed!;
        await tester.tap(copy);
        await tester.pump();
        expect(copied, view.text);
        expect(writes, 1);
        final readerState = tester.state(viewFinder);
        failCopy = true;
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(writes, 1);
        expect(tester.state(viewFinder), same(readerState));
        app.changed();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(SnackBar), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, _strings.errorDetails),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNWidgets(2));
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SelectableText>(
                find.byKey(const ValueKey('operation-technical-text')),
              )
              .data,
          copyFailure.toString(),
        );
        await _close(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.state(viewFinder), same(readerState));
        expect(tester.state(find.byType(BackupSettingsActions)), same(owner));
        expect(documents.cancellations, isEmpty);
        failCopy = false;
        await tester.ensureVisible(find.text(_strings.technicalDetails));
        await tester.tap(find.text(_strings.technicalDetails));
        // Collapsing retires cached copy actions before its visual exit finishes.
        copyAction();
        await tester.pump();
        expect(writes, 1);
        await tester.pumpAndSettle();
        final raw = find.byKey(const ValueKey('backup-result-raw'));
        await tester.ensureVisible(raw);
        await tester.tap(raw);
        await tester.pumpAndSettle();
        final document = jsonDecode(
          tester.widget<OriginalTextView>(find.byType(OriginalTextView)).text,
        ) as Map;
        expect(document['unknown'], app.restoreDetails!['unknown']);
        expect(
          document['connectionMessage'],
          app.restoreDetails!['connectionMessage'],
        );
        expect(tester.state(find.byType(BackupSettingsActions)), same(owner));
        expect(app.commands.map((command) => command['action']), [
          'inspectBackup',
          'restoreBackup',
        ]);
        await _close(tester);
        expect(tester.widget<ListTile>(_key('import')).onTap, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
