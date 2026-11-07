import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:re_editor/re_editor.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/ui/configs/editor/config_text_page.dart';
import 'package:clash_pseudo/src/ui/configs/configs_page.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/ui/overrides/overrides_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/preferences_fakes.dart';
import '../../support/readonly_override_store.dart';

class _SaveBridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  int submitted = 0;
  final commands = <Map<String, Object?>>[];
  bool reject = false;
  String? receiptId = 'save-operation';
  Duration remaining = const Duration(seconds: 120);
  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    submitted++;
    commands.add(Map.of(command));
    if (reject) {
      throw PlatformFailure(
        code: 'busy',
        details: messages.androidErrorBusy.toMap(),
      );
    }
    return receiptId == null
        ? null
        : OperationAdmission(operationId: receiptId!, remaining: remaining);
  }
}

class _SaveStore extends ConfigStore {
  _SaveStore() : super(Directory.systemTemp);
  int reads = 0;
  ConfigCollection collection = ConfigCollection(entries: []);
  Future<ConfigCollection> Function()? readResult;
  @override
  Future<ConfigCollection> read() async {
    reads++;
    return readResult == null ? collection : await readResult!();
  }
}

class _FeedbackOwner extends ValueNotifier<bool> {
  _FeedbackOwner() : super(true);
  bool get observed => hasListeners;
}

AppController _controller(_SaveBridge bridge) => AppController(
  bridge,
  store: _SaveStore()..collection = ConfigCollection(entries: [_local]),
  preferencesStore: MemoryPreferencesStore(),
  overrideStore: ReadOnlyOverrideStore(),
);

// A successful receipt and the refreshed store are independent inputs.
void _publishSavedEditorStore(AppController app, {required bool fragment}) {
  if (fragment) {
    (app.overrideStore! as ReadOnlyOverrideStore).entries = [
      OverrideEntry(
        id: _local.id,
        name: _local.name,
        kind: ConfigKind.local,
        revision: 2,
        body: _local.body,
      ),
    ];
  } else {
    (app.store! as _SaveStore).collection = ConfigCollection(
      entries: [
        ConfigEntry.fromJson({..._local.toJson(), 'revision': 2}),
      ],
    );
  }
}

Future<void> _showFeedback(
  WidgetTester tester,
  AppController app, {
  Widget? page,
}) async {
  final rootObserver = AppTaskNavigatorObserver();
  final businessObserver = AppTaskNavigatorObserver();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [rootObserver],
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppTaskScope(
        task: AppTask.configurations,
        owner: app,
        open: (_) => fail('This fixture does not switch tasks.'),
        child: OperationNoticeHost(
          child: OperationFeedback(
            controller: app,
            child: Scaffold(
              body: Navigator(
                observers: [businessObserver],
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: page == null
                          ? null
                          : () => unawaited(
                              Navigator.of(context).push<void>(
                                MaterialPageRoute(builder: (_) => page),
                              ),
                            ),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final readerRoute = ModalRoute.of(
    tester.element(find.byType(OperationFeedback)),
  )!;
  expect(rootObserver.stack.single, same(readerRoute));
  expect(
    businessObserver.stack.single.navigator,
    isNot(same(readerRoute.navigator)),
  );
  if (page != null) {
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(businessObserver.stack, hasLength(2));
    expect(readerRoute.isCurrent, isTrue);
    expect(businessObserver.stack.first.isCurrent, isFalse);
    expect(businessObserver.stack.last.isCurrent, isTrue);
  }
}

const _local = ConfigEntry(
  id: 'local',
  name: 'Local',
  kind: ConfigKind.local,
  revision: 1,
  body: 'mixed-port: 0\n',
);

ConfigTextPage _editor(AppController app, {required bool fragment}) =>
    ConfigTextPage(
      app: app,
      entry: fragment ? null : _local,
      initialName: _local.name,
      initialText: _local.body,
      onSave: fragment
          ? (command, owner) => app.saveOverride({
              ...command,
              'id': command['id'] ?? _local.id,
              'revision': command['revision'] ?? _local.revision,
            }, feedbackOwner: owner)
          : null,
    );

Future<void> _openFileImport(
  WidgetTester tester,
  AppController app, {
  required bool fragment,
}) async {
  Future<XFile?> selectFile() async => XFile.fromData(
    Uint8List.fromList(utf8.encode(_local.body)),
    path: 'Imported.yaml',
  );

  await _showFeedback(
    tester,
    app,
    page: fragment
        ? OverridesPage(app: app, selectFile: selectFile)
        : ConfigsPage(controller: app, selectFile: selectFile),
  );
  await tester.tap(find.byIcon(Icons.add).first);
  await tester.pumpAndSettle();
  await tester.tap(
    find.text(lookupAppLocalizations(const Locale('en')).importFromFile),
  );
  await tester.pump();
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  for (final replaceEpoch in [false, true]) {
    testWidgets(
      'details remain available after feedback acknowledgement and old details close on source replacement epoch=$replaceEpoch',
      (tester) async {
        final bridge = _SaveBridge();
        final app = _controller(bridge);
        addTearDown(app.dispose);
        await app.refresh();
        await _showFeedback(tester, app, page: _editor(app, fragment: false));
        final editor = tester.state(find.byType(ConfigTextPage));
        await tester.tap(find.text(en.save));
        await tester.pump();
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-operation',
          resultMessage: messages.configSaveFailed.withDetail(
            'controlled save failure',
          ),
          configStatus: 'notSaved',
        );
        await app.refresh();
        await tester.pumpAndSettle();
        expect(app.hasLocalFeedbackOwner, isFalse);
        final details = find.widgetWithText(TextButton, en.errorDetails);
        final oldDetails = tester.widget<TextButton>(details).onPressed!;
        final oldRetry = tester
            .widget<TextButton>(find.widgetWithText(TextButton, en.retry))
            .onPressed!;
        await tester.tap(details);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.state(find.byType(ConfigTextPage)), same(editor));
        if (replaceEpoch) {
          bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
        } else {
          (app.store! as _SaveStore).collection = ConfigCollection(
            entries: [
              ConfigEntry.fromJson({..._local.toJson(), 'revision': 2}),
            ],
          );
        }
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        oldDetails();
        oldRetry();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(bridge.submitted, 1);
        expect(tester.state(find.byType(ConfigTextPage)), same(editor));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'source text save failure acknowledges feedback only after SnackBar actually appears',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final bridge = _SaveBridge();
      final app = _controller(bridge);
      addTearDown(app.dispose);
      await app.refresh();
      await _showFeedback(tester, app, page: _editor(app, fragment: false));
      await tester.tap(find.text(en.save));
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 460);
      await tester.pumpAndSettle();
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'save-operation',
        resultMessage: messages.configSaveFailed,
        configStatus: 'notSaved',
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(bridge.submitted, 1);
      expect(app.hasLocalFeedbackOwner, isTrue);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester.widget<CodeEditor>(find.byType(CodeEditor)).readOnly,
        isFalse,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, en.save))
            .onPressed,
        isNotNull,
      );
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(en.configSaveFailed), findsOneWidget);
      expect(app.hasLocalFeedbackOwner, isFalse);
      final notice = tester.element(find.byType(SnackBar));
      await app.refresh();
      await tester.pumpAndSettle();
      expect(tester.element(find.byType(SnackBar)), same(notice));
      expect(bridge.submitted, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final fragment in [false, true]) {
    testWidgets(
      'covering leave confirmation retains the local saved-warning reader fragment=$fragment',
      (tester) async {
        final bridge = _SaveBridge();
        final app = _controller(bridge);
        addTearDown(app.dispose);
        await app.refresh();
        await _showFeedback(
          tester,
          app,
          page: _editor(app, fragment: fragment),
        );
        await tester.tap(find.text(en.save));
        await tester.pump();
        expect(app.hasLocalFeedbackOwner, isTrue);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        final confirmation = tester.element(find.byType(AlertDialog));
        final warning = messages.storageSyncWarning(
          fragment ? messages.overrideSavedApplyLater : messages.configSaved,
        );
        _publishSavedEditorStore(app, fragment: fragment);
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-operation',
          resultSuccess: false,
          resultMessage: warning,
          targetId: 'local',
          savedRevision: 2,
          configStatus: fragment ? null : 'saved',
          overrideStatus: fragment ? 'saved' : null,
        );
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.element(find.byType(AlertDialog)), same(confirmation));
        expect(app.hasLocalFeedbackOwner, isTrue);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(en.cancel),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(warning.resolve(en)), findsOneWidget);
        expect(app.hasLocalFeedbackOwner, isFalse);
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(IconButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(app.hasLocalFeedbackOwner, isFalse);
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        bridge.receiptId = 'save-next';
        bridge.state = const AppSnapshot(phase: 'STOPPED');
        await tester.tap(find.text(en.save));
        await tester.pump();
        expect(bridge.commands.last['id'], 'local');
        expect(bridge.commands.last['revision'], 2);
        expect(bridge.commands.last['storageEpoch'], 0);
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-next',
          resultSuccess: true,
          targetId: 'local',
          savedRevision: 2,
          configStatus: fragment ? null : 'saved',
          overrideStatus: fragment ? 'saved' : null,
        );
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(ConfigTextPage), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final unknown in [false, true]) {
    testWidgets(
      'inactive mounted editor returns unshown feedback globally once unknown=$unknown',
      (tester) async {
        final bridge = _SaveBridge();
        final app = _controller(bridge);
        addTearDown(app.dispose);
        await app.refresh();
        await _showFeedback(tester, app, page: _editor(app, fragment: false));
        final finder = find.byType(ConfigTextPage);
        final editorState = tester.state(finder);
        final route = ModalRoute.of(tester.element(finder))!;
        await tester.tap(find.text(en.save));
        await tester.pump();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(en.leave),
          ),
        );
        await tester.pump();
        expect(route.isActive, isFalse);
        expect(editorState.mounted, isTrue);
        final message = unknown
            ? messages.saveUnconfirmed
            : messages.configSaveFailed;
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-operation',
          resultMessage: message,
          targetId: 'local',
          configStatus: unknown ? 'unconfirmed' : 'notSaved',
        );
        await app.refresh();
        await tester.pump();
        expect(app.hasLocalFeedbackOwner, isFalse);
        await tester.pumpAndSettle();
        expect(find.byType(ConfigTextPage), findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(message.resolve(en)), findsOneWidget);
        expect(bridge.submitted, 1);
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(IconButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final fragment in [false, true]) {
    testWidgets(
      'saved sync warning stays visible and retains retry identity fragment=$fragment',
      (tester) async {
        final bridge = _SaveBridge();
        final app = _controller(bridge);
        addTearDown(app.dispose);
        await app.refresh();
        await _showFeedback(
          tester,
          app,
          page: _editor(app, fragment: fragment),
        );
        await tester.tap(find.text(en.save));
        await tester.pump();
        final warning = messages.storageSyncWarning(
          fragment ? messages.overrideSavedApplyLater : messages.configSaved,
        );
        _publishSavedEditorStore(app, fragment: fragment);
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-operation',
          resultSuccess: false,
          resultMessage: warning,
          targetId: 'local',
          savedRevision: 2,
          configStatus: fragment ? null : 'saved',
          overrideStatus: fragment ? 'saved' : null,
        );
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(ConfigTextPage), findsOneWidget);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(warning.resolve(en)), findsOneWidget);
        expect(find.text(en.savedApplyFailed), findsNothing);
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(IconButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        bridge.receiptId = 'save-next';
        await tester.tap(find.text(en.save));
        await tester.pump();
        expect(bridge.commands.last['id'], 'local');
        expect(bridge.commands.last['revision'], 2);
        expect(bridge.commands.last['storageEpoch'], 0);
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-next',
          resultSuccess: true,
          targetId: 'local',
          savedRevision: 2,
          configStatus: fragment ? null : 'saved',
          overrideStatus: fragment ? 'saved' : null,
        );
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(ConfigTextPage), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }

  testWidgets(
    'local acknowledgement releases its marker without global replay',
    (tester) async {
      final bridge = _SaveBridge();
      final app = _controller(bridge);
      final owner = _FeedbackOwner();
      addTearDown(app.dispose);
      await app.refresh();
      await _showFeedback(tester, app);
      final pending = app.saveLocal({'body': 'new'}, feedbackOwner: owner);
      await tester.pump();
      expect(owner.observed, isTrue);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'save-operation',
        resultMessage: messages.androidErrorBusy,
        configStatus: 'notSaved',
      );
      await app.refresh();
      final result = await pending;
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.hasLocalFeedbackOwner, isTrue);
      app.acknowledgeLocalFeedback(owner, result: result);
      expect(owner.observed, isFalse);
      expect(app.hasLocalFeedbackOwner, isFalse);
      owner.value = false;
      owner.dispose();
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(bridge.submitted, 1);
    },
  );

  for (final completedBeforeLeave in [false, true]) {
    testWidgets(
      'owner departure ${completedBeforeLeave ? 'after' : 'before'} completion '
      'returns the unshown failure globally once',
      (tester) async {
        final bridge = _SaveBridge();
        final app = _controller(bridge);
        final owner = _FeedbackOwner();
        addTearDown(app.dispose);
        await app.refresh();
        await _showFeedback(tester, app);
        final pending = app.saveLocal({'body': 'new'}, feedbackOwner: owner);
        await tester.pump();
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-operation',
          resultMessage: messages.androidErrorBusy,
          configStatus: 'notSaved',
        );
        if (completedBeforeLeave) {
          await app.refresh();
          await pending;
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        }
        owner.value = false;
        expect(owner.observed, isFalse);
        owner.dispose();
        expect(app.hasLocalFeedbackOwner, isFalse);
        await app.refresh();
        final result = await pending;
        app.acknowledgeLocalFeedback(owner, result: result);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(en.androidErrorBusy), findsOneWidget);
        expect(bridge.submitted, 1);
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(IconButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final leave in [false, true]) {
    testWidgets(
      'rejected submission has one ${leave ? 'global' : 'local'} reader',
      (tester) async {
        final bridge = _SaveBridge()..reject = true;
        final app = _controller(bridge);
        final owner = _FeedbackOwner();
        addTearDown(app.dispose);
        await app.refresh();
        await _showFeedback(tester, app);
        final pending = app.saveOverride({'body': '{}'}, feedbackOwner: owner);
        if (leave) {
          owner.value = false;
          expect(owner.observed, isFalse);
          owner.dispose();
        }
        await tester.pump();
        expect(await pending, isNull);
        expect(
          app.commandErrorMessage,
          messages.androidErrorBusy.withDetail(
            PlatformFailure(
              code: 'busy',
              details: messages.androidErrorBusy.toMap(),
            ),
          ),
        );
        if (!leave) {
          expect(app.hasLocalFeedbackOwner, isTrue);
          expect(find.byType(AlertDialog), findsNothing);
          app.acknowledgeLocalFeedback(owner);
          expect(owner.observed, isFalse);
          owner.dispose();
        }
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), leave ? findsOneWidget : findsNothing);
        if (leave) {
          expect(find.text(en.androidErrorBusy), findsOneWidget);
          await tester.tap(
            find
                .descendant(
                  of: find.byType(SnackBar),
                  matching: find.byType(IconButton),
                )
                .last,
          );
          await tester.pumpAndSettle();
        }
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(bridge.submitted, 1);
      },
    );
  }

  for (final action in ['saveLocal', 'restoreBackup']) {
    testWidgets('$action uses admission time through slow state readback', (
      tester,
    ) async {
      final bridge = _SaveBridge()..remaining = const Duration(seconds: 1);
      final app = _controller(bridge);
      addTearDown(app.dispose);
      await app.refresh();
      final store = app.store! as _SaveStore;
      final reading = Completer<ConfigCollection>();
      store.readResult = () => reading.future;
      var finished = false;
      final pending = app.submitAndWait({'action': action}).then((result) {
        finished = true;
        return result;
      });
      await tester.pump();
      expect(app.busy, isTrue);
      await tester.pump(const Duration(seconds: 4));
      expect(finished, isFalse);
      store.readResult = null;
      reading.complete(store.collection);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1999));
      expect(finished, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(finished, isTrue);
      expect(await pending, isNull);
      expect(bridge.submitted, 1);
    });
  }

  testWidgets(
    'timeout releases ownership without hiding the eventual failure',
    (tester) async {
      final bridge = _SaveBridge();
      final app = _controller(bridge);
      final owner = _FeedbackOwner();
      addTearDown(app.dispose);
      await app.refresh();
      await _showFeedback(tester, app);
      final pending = app.saveLocal({'body': 'new'}, feedbackOwner: owner);
      await tester.pump();
      await tester.pump(const Duration(seconds: 126));
      expect(await pending, isNull);
      app.acknowledgeLocalFeedback(owner);
      expect(owner.observed, isFalse);
      owner.dispose();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'save-operation',
        resultMessage: messages.androidErrorBusy,
        configStatus: 'notSaved',
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(en.androidErrorBusy), findsOneWidget);
      expect(bridge.submitted, 1);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'old acknowledgements cannot release a reused owner or next command',
    (tester) async {
      final bridge = _SaveBridge();
      final app = _controller(bridge);
      final owner = _FeedbackOwner();
      addTearDown(app.dispose);
      await app.refresh();
      await _showFeedback(tester, app);
      final first = app.saveLocal({'body': 'new'}, feedbackOwner: owner);
      await tester.pump();
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'save-operation',
        resultSuccess: true,
        resultMessage: messages.configSaved,
        configStatus: 'saved',
      );
      await app.refresh();
      final earlier = await first;
      bridge.receiptId = 'policy-operation';
      final second = app.submitAndWait({
        'action': 'setConfigUpdate',
        'id': 'local',
      }, feedbackOwner: owner);
      await tester.pump();
      app.acknowledgeLocalFeedback(owner, result: earlier);
      expect(app.hasLocalFeedbackOwner, isTrue);
      expect(owner.observed, isTrue);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'policy-operation',
        resultMessage: messages.preferencesSaveFailed,
      );
      await app.refresh();
      final current = await second;
      app.acknowledgeLocalFeedback(owner, result: earlier);
      expect(app.hasLocalFeedbackOwner, isTrue);
      app.acknowledgeLocalFeedback(owner, result: current);
      expect(owner.observed, isFalse);
      owner.dispose();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      bridge.receiptId = 'next-operation';
      await app.submit({'action': 'updateOverride', 'id': 'next'});
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'next-operation',
        resultMessage: messages.downloadFailed,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(en.downloadFailed), findsOneWidget);
      expect(bridge.submitted, 3);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
    },
  );

  for (final blockSubmissionRefresh in [false, true]) {
    testWidgets('accepted Stop releases its waiter before '
        '${blockSubmissionRefresh ? 'submission' : 'later'} refresh finishes', (
      tester,
    ) async {
      final bridge = _SaveBridge()..receiptId = 'resource-operation';
      final store = _SaveStore();
      final app = AppController(
        bridge,
        store: store,
        preferencesStore: MemoryPreferencesStore(),
        overrideStore: ReadOnlyOverrideStore(),
      );
      addTearDown(app.dispose);
      await app.refresh();
      final read = Completer<ConfigCollection>();
      if (blockSubmissionRefresh) store.readResult = () => read.future;
      bridge.state = const AppSnapshot(phase: 'STOPPED', resourceBusy: true);
      var finished = false;
      final pending = app
          .submitAndWait({'action': 'updateResource', 'name': 'GeoIP.dat'})
          .then((value) {
            finished = true;
            return value;
          });
      await tester.pump();
      Future<void>? refreshing;
      if (!blockSubmissionRefresh) {
        store.readResult = () => read.future;
        refreshing = app.refresh();
        await tester.pump();
      }
      expect(app.state.resourceBusy, isTrue);
      expect(app.canStopBackground, isTrue);
      bridge.receiptId = 'stop-operation';
      var stopFinished = false;
      final stopping = app.submit({'action': 'stop'}).then((value) {
        stopFinished = true;
        return value;
      });
      try {
        await tester.pump();
        expect(finished, isTrue);
        expect(await pending, isNull);
        expect(stopFinished, isFalse);
        expect(app.busy, isTrue);
        expect(app.state.resourceBusy, isTrue);
        expect(bridge.commands, [
          {'action': 'updateResource', 'name': 'GeoIP.dat', 'storageEpoch': 0},
          {'action': 'stop'},
        ]);
      } finally {
        store.readResult = null;
        read.complete(ConfigCollection(entries: []));
        expect(await stopping, 'stop-operation');
        await refreshing;
        await pending;
      }
    });
  }

  for (final receipt in ['accepted', 'rejected', 'same', 'missing']) {
    testWidgets('$receipt Stop only cancels a differently accepted waiter', (
      tester,
    ) async {
      final bridge = _SaveBridge()..receiptId = 'resource-operation';
      final app = _controller(bridge);
      addTearDown(app.dispose);
      await app.refresh();
      var finished = false;
      final pending = app
          .submitAndWait({'action': 'updateResource', 'name': 'GeoIP.dat'})
          .then((value) {
            finished = true;
            return value;
          });
      await tester.pump();
      bridge.state = const AppSnapshot(phase: 'STOPPED', resourceBusy: true);
      await app.refresh();
      expect(app.busy, isTrue);
      expect(app.canStopBackground, isTrue);
      bridge.reject = receipt == 'rejected';
      bridge.receiptId = switch (receipt) {
        'same' => 'resource-operation',
        'missing' => null,
        _ => 'stop-operation',
      };
      final stop = await app.submit({'action': 'stop'});
      await tester.pump();
      expect(app.state.resourceBusy, isTrue);
      expect(app.busy, isTrue);
      expect(bridge.submitted, 2);
      if (receipt != 'accepted') {
        expect(finished, isFalse);
        expect(stop, receipt == 'same' ? 'resource-operation' : null);
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'resource-operation',
          resultMessage: messages.resourceUpdateFailed,
        );
        await app.refresh();
        expect((await pending)!.resultId, 'resource-operation');
        expect(bridge.submitted, 2);
        return;
      }
      expect(stop, 'stop-operation');
      expect(await pending, isNull);
      expect(await app.submitAndWait({'action': 'updateResource'}), isNull);
      expect(bridge.submitted, 2);
      // Cancelling the UI waiter retains native writer admission through actual
      // execution.
      bridge.state = const AppSnapshot(phase: 'STOPPED');
      await app.refresh();
      bridge.receiptId = 'next-operation';
      var nextFinished = false;
      final next = app.submitAndWait({'action': 'updateResource'}).then((
        value,
      ) {
        nextFinished = true;
        return value;
      });
      await tester.pump();
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'resource-operation',
        resultMessage: messages.resourceUpdateStopped,
      );
      await app.refresh();
      expect(nextFinished, isFalse);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'next-operation',
        resultSuccess: true,
        resultMessage: messages.resourceUpdateSuccess,
      );
      await app.refresh();
      expect((await next)!.resultId, 'next-operation');
      expect(bridge.submitted, 3);
    });
  }

  for (final fragment in [false, true]) {
    final kind = fragment ? 'plugin' : 'config';
    for (final status in ['notSaved', 'applyFailed']) {
      testWidgets('$kind editor $status has one real feedback reader', (
        tester,
      ) async {
        final bridge = _SaveBridge();
        final app = _controller(bridge);
        addTearDown(app.dispose);
        await app.refresh();
        await _showFeedback(
          tester,
          app,
          page: _editor(app, fragment: fragment),
        );
        await tester.tap(find.text(en.save));
        await tester.pump();
        expect(app.hasLocalFeedbackOwner, isTrue);
        final message = status == 'notSaved'
            ? messages.androidErrorBusy
            : fragment
            ? messages.overrideSavedReconnectIncomplete
            : messages.configSavedApplyReleasePending;
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'save-operation',
          resultMessage: message,
          configStatus: fragment ? null : status,
          overrideStatus: fragment ? status : null,
          targetId: status == 'applyFailed' ? 'local' : null,
          savedRevision: status == 'applyFailed' ? 2 : null,
        );
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(message.resolve(en)), findsOneWidget);
        expect(find.byType(ConfigTextPage), findsOneWidget);
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(bridge.commands.single, {
          'action': fragment ? 'saveOverride' : 'saveLocal',
          'id': 'local',
          'revision': 1,
          'name': 'Local',
          'body': _local.body,
          'storageEpoch': 0,
        });
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(IconButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(bridge.submitted, 1);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$kind editor late failure survives confirmed departure', (
      tester,
    ) async {
      final bridge = _SaveBridge();
      final app = _controller(bridge);
      addTearDown(app.dispose);
      await app.refresh();
      await _showFeedback(tester, app, page: _editor(app, fragment: fragment));
      await tester.tap(find.text(en.save));
      await tester.pump();
      expect(app.hasLocalFeedbackOwner, isTrue);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(en.leaveBodyTitle), findsOneWidget);
      await tester.tap(find.text(en.leave));
      await tester.pumpAndSettle();
      expect(find.byType(ConfigTextPage), findsNothing);
      expect(app.hasLocalFeedbackOwner, isFalse);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'save-operation',
        resultMessage: messages.androidErrorBusy,
        configStatus: fragment ? null : 'notSaved',
        overrideStatus: fragment ? 'notSaved' : null,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(en.androidErrorBusy), findsOneWidget);
      expect(bridge.submitted, 1);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final reject in [false, true]) {
      testWidgets('$kind file import ${reject ? 'rejection' : 'failure'} '
          'has one real feedback reader', (tester) async {
        final bridge = _SaveBridge()..reject = reject;
        final app = _controller(bridge);
        addTearDown(app.dispose);
        await app.refresh();
        await _openFileImport(tester, app, fragment: fragment);
        if (!reject) {
          bridge.state = AppSnapshot(
            phase: 'STOPPED',
            resultId: 'save-operation',
            resultMessage: messages.androidErrorBusy,
            configStatus: fragment ? null : 'notSaved',
            overrideStatus: fragment ? 'notSaved' : null,
          );
          await app.refresh();
        }
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(en.androidErrorBusy), findsOneWidget);
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(bridge.commands.single, {
          'action': fragment ? 'saveOverride' : 'saveLocal',
          'name': 'Imported',
          'body': _local.body,
          'storageEpoch': 0,
        });
        final notice = tester.element(find.byType(SnackBar));
        await app.refresh();
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(SnackBar)), same(notice));
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(IconButton),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(bridge.submitted, 1);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('$kind file import late failure survives leaving its page', (
      tester,
    ) async {
      final bridge = _SaveBridge();
      final app = _controller(bridge);
      addTearDown(app.dispose);
      await app.refresh();
      await _openFileImport(tester, app, fragment: fragment);
      expect(app.hasLocalFeedbackOwner, isTrue);
      final page = fragment
          ? find.byType(OverridesPage)
          : find.byType(ConfigsPage);
      final pageState = tester.state(page);
      final pageRoute = ModalRoute.of(tester.element(page))!;
      final businessNavigator = Navigator.of(tester.element(page));
      final readerRoute = ModalRoute.of(
        tester.element(find.byType(OperationFeedback)),
      )!;
      expect(pageRoute.navigator, same(businessNavigator));
      expect(businessNavigator, isNot(same(readerRoute.navigator)));
      expect(pageRoute.isCurrent, isTrue);
      expect(readerRoute.isCurrent, isTrue);
      // The post-frame reverse needs its first tick, then strictly over 150 ms.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(microseconds: 1));
      final menus = tester.widgetList<MenuAnchor>(
        find.descendant(of: page, matching: find.byType(MenuAnchor)),
      );
      expect(menus, isNotEmpty);
      for (final menu in menus) {
        expect(menu.controller!.isOpen, isFalse);
      }
      expect(pageRoute.willHandlePopInternally, isFalse);
      expect(businessNavigator.canPop(), isTrue);
      expect(app.hasLocalFeedbackOwner, isTrue);
      expect(bridge.submitted, 1);
      final back = find.descendant(of: page, matching: find.byType(BackButton));
      expect(Navigator.of(tester.element(back)), same(businessNavigator));
      await tester.tap(back);
      await tester.pump();
      expect(pageRoute.isActive, isFalse);
      expect(pageState.mounted, isTrue);
      expect(readerRoute.isCurrent, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(ConfigsPage), findsNothing);
      expect(find.byType(OverridesPage), findsNothing);
      expect(app.hasLocalFeedbackOwner, isFalse);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'save-operation',
        resultMessage: messages.androidErrorBusy,
        configStatus: fragment ? null : 'notSaved',
        overrideStatus: fragment ? 'notSaved' : null,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(en.androidErrorBusy), findsOneWidget);
      expect(bridge.submitted, 1);
      await tester.tap(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.byType(IconButton),
            )
            .last,
      );
      await tester.pumpAndSettle();
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'save waits for matching operation and forwards structured result',
    (tester) async {
      final bridge = _SaveBridge();
      final store = _SaveStore();
      final app = AppController(
        bridge,
        store: store,
        preferencesStore: MemoryPreferencesStore(),
        overrideStore: ReadOnlyOverrideStore(),
      );
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
        'storageReady': true,
        'storageEpoch': 0,
        'resultId': 'save-operation',
        'configStatus': 'applyFailed',
        'targetId': 'local',
        'savedRevision': 2,
        'resultMessage': messages.configSavedApplyReleasePending.toMap(),
        'resultSuccess': false,
      });
      await app.refresh();
      final result = await pending;
      expect(result!.configStatus, 'applyFailed');
      expect(result.targetId, 'local');
      expect(result.savedRevision, 2);
      expect(result.resultSuccess, isFalse);
      expect(result.resultId, 'save-operation');
      expect(
        result.resultMessageDescription,
        messages.configSavedApplyReleasePending,
      );
      for (final locale in const [Locale('en'), Locale('zh')]) {
        final strings = lookupAppLocalizations(locale);
        expect(
          result.resultMessageDescription!.resolve(strings),
          strings.configSavedApplyReleasePending,
        );
      }
      expect(bridge.submitted, 1);
    },
  );

  testWidgets('saved result waits for the coalesced collection reread', (
    tester,
  ) async {
    final bridge = _SaveBridge();
    final store = _SaveStore();
    final app = AppController(
      bridge,
      store: store,
      preferencesStore: MemoryPreferencesStore(),
      overrideStore: ReadOnlyOverrideStore(),
    );
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
    final app = AppController(
      bridge,
      store: store,
      preferencesStore: MemoryPreferencesStore(),
      overrideStore: ReadOnlyOverrideStore(),
    );
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
    final app = AppController(
      _SaveBridge(),
      store: _SaveStore(),
      preferencesStore: MemoryPreferencesStore(),
      overrideStore: ReadOnlyOverrideStore(),
    );
    await app.refresh();
    final owner = _FeedbackOwner();
    final pending = app.saveLocal({'body': ''}, feedbackOwner: owner);
    await tester.pump();
    expect(owner.observed, isTrue);
    app.dispose();
    expect(owner.observed, isFalse);
    owner.dispose();
    await tester.pump();
    expect(await pending, isNull);
  });
}
