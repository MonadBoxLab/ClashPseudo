import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/logic/overrides/lan_proxy_settings.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/settings/lan_proxy_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/preferences_fakes.dart';
import '../../support/readonly_override_store.dart';

class _Configs extends ConfigStore {
  _Configs() : super(Directory.systemTemp);

  @override
  Future<ConfigCollection> read() async => ConfigCollection(entries: const []);
}

class _Bridge extends AppBridge {
  _Bridge(this.overrides);

  final ReadOnlyOverrideStore overrides;
  final commands = <Map<String, Object?>>[];
  Object? interfaceFailure;
  int interfaceCalls = 0;
  Completer<Map<String, dynamic>>? interfacePending;
  Map<String, dynamic> value = {
    'phase': 'STOPPED',
    'storageReady': true,
    'storageEpoch': 0,
  };

  @override
  Future<AppSnapshot> snapshot() async => AppSnapshot.fromMap(value);

  @override
  Future<Map<String, dynamic>> localInterfaces() async {
    interfaceCalls++;
    if (interfacePending case final pending?) return pending.future;
    if (interfaceFailure case final failure?) throw failure;
    return {
      'addresses': [
        {
          'address': '10.0.2.16',
          'interfaceName': 'wlan0',
          'interfaceIndex': 7,
          'kind': 'wifi',
          'available': true,
          'selectable': true,
        },
      ],
    };
  }

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    return OperationAdmission(
      operationId: 'lan-${commands.length}',
      remaining: const Duration(seconds: 120),
    );
  }

  void complete({
    required bool success,
    required String status,
    required AppMessage message,
  }) {
    final command = commands.last;
    if (status != 'notSaved') {
      if (command['action'] == 'saveLanProxy') {
        overrides.entries = [
          OverrideEntry(
            id: 'lan-plugin',
            name: 'Local network proxy',
            kind: ConfigKind.local,
            role: OverrideRole.lanProxy,
            enabled: false,
            revision: 1,
            body: LanProxySettings(
              addresses: (command['addresses'] as List).cast<String>(),
              interfaces: Map<String, String>.from(
                command['interfaces'] as Map,
              ),
              port: command['port'] as int,
              udp: command['udp'] as bool,
            ).applyTo('{}\n'),
          ),
        ];
      } else {
        overrides.entries = [
          overrides.entries.single.changed(enabled: command['enabled'] as bool),
        ];
      }
    }
    value = {
      ...value,
      'resultId': 'lan-${commands.length}',
      'resultSuccess': success,
      'overrideStatus': status,
      'resultMessage': message.toMap(),
      'targetId': status == 'notSaved' ? null : overrides.entries.single.id,
      'savedRevision': status == 'notSaved' ? null : 1,
    };
  }
}

void main() {
  late ReadOnlyOverrideStore overrides;
  late _Bridge bridge;
  late AppController app;

  setUp(() {
    overrides = ReadOnlyOverrideStore();
    bridge = _Bridge(overrides);
    app = AppController(
      bridge,
      store: _Configs(),
      overrideStore: overrides,
      preferencesStore: MemoryPreferencesStore(),
    );
  });
  tearDown(() => app.dispose());

  Future<AppLocalizations> show(
    WidgetTester tester,
    String language, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await app.refresh();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: OperationFeedback(
          controller: app,
          child: LanProxyPage(app: app),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final address = find.byKey(
      const ValueKey(('lan-address', 'wlan0', '10.0.2.16')),
    );
    await tester.scrollUntilVisible(
      address,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    final checkbox = find.descendant(
      of: address,
      matching: find.byType(Checkbox),
    );
    await tester.ensureVisible(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(address).value, isTrue);
    return AppLocalizations.of(tester.element(find.byType(LanProxyPage)));
  }

  Future<void> interfaceChanged() async {
    app.localInterfacesRevision = (app.localInterfacesRevision ?? 0) + 1;
    await app.refresh();
  }

  Future<void> closeFeedback(
    WidgetTester tester,
    AppLocalizations strings,
  ) async {
    final dialog = find.byType(AlertDialog);
    await tester.tap(
      find.descendant(
        of: dialog.evaluate().isEmpty ? find.byType(SnackBar) : dialog,
        matching: dialog.evaluate().isEmpty
            ? find.byIcon(Icons.close)
            : find.text(strings.close),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }

  testWidgets('LAN error details retain completed interface reads while open', (
    tester,
  ) async {
    final strings = await show(tester, 'en');
    final pending = bridge.interfacePending = Completer<Map<String, dynamic>>();
    await interfaceChanged();
    await tester.pump();
    final port = find.widgetWithText(TextField, strings.lanProxyPort);
    await tester.enterText(port, '0');
    await tester.tap(find.text(strings.save));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(strings.errorDetails),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    bridge.interfacePending = null;
    pending.complete({
      'addresses': [
        {
          'address': '10.0.2.17',
          'interfaceName': 'wlan0',
          'interfaceIndex': 7,
          'kind': 'wifi',
          'available': true,
          'selectable': true,
        },
      ],
    });
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await closeFeedback(tester, strings);
    expect(find.text('10.0.2.17'), findsOneWidget);
    expect(bridge.interfaceCalls, 2);
  });

  testWidgets('LAN shows actual timed-out read failure after details close', (
    tester,
  ) async {
    final strings = await show(tester, 'en');
    final pending = bridge.interfacePending = Completer<Map<String, dynamic>>();
    await interfaceChanged();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(strings.errorDetails),
      ),
    );
    await tester.pumpAndSettle();
    bridge.interfacePending = null;
    pending.completeError(StateError('late actual interface error'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await closeFeedback(tester, strings);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(strings.errorDetails),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
    await tester.pumpAndSettle();
    expect(find.textContaining('late actual interface error'), findsOneWidget);
  });

  testWidgets(
    'old LAN error details expire immediately when state epoch changes first',
    (tester) async {
      final strings = await show(tester, 'en');
      final port = find.widgetWithText(TextField, strings.lanProxyPort);
      await tester.enterText(port, '0');
      await tester.tap(find.text(strings.save));
      await tester.pumpAndSettle();
      final details = find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.errorDetails),
      );
      final oldDetails = tester.widget<TextButton>(details).onPressed!;
      expect(app.storageEpoch, 0);
      app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      oldDetails();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late LAN interface errors do not cross an earlier state epoch change',
    (tester) async {
      await show(tester, 'en');
      final pending = bridge.interfacePending =
          Completer<Map<String, dynamic>>();
      await interfaceChanged();
      await tester.pump();
      expect(app.storageEpoch, 0);
      app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      pending.completeError(StateError('retired interface original'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.commands, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late LAN interface errors from an old epoch do not enter current feedback',
    (tester) async {
      await show(tester, 'en');
      final pending = bridge.interfacePending =
          Completer<Map<String, dynamic>>();
      await interfaceChanged();
      await tester.pump();
      bridge.value = {...bridge.value, 'storageEpoch': 1};
      await app.refresh();
      bridge.interfacePending = null;
      pending.completeError(StateError('retired interface original'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('retired interface original'), findsNothing);
      expect(bridge.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'LAN timeout retry waits for the old read to exit and retains the new error',
    (tester) async {
      final strings = await show(tester, 'en');
      final pending = bridge.interfacePending =
          Completer<Map<String, dynamic>>();
      await interfaceChanged();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(bridge.interfaceCalls, 2);
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(strings.retry),
        ),
      );
      await tester.pumpAndSettle();
      expect(bridge.interfaceCalls, 2);
      bridge.interfacePending = null;
      bridge.interfaceFailure = StateError('new interface failure');
      pending.completeError(StateError('old interface failure'));
      await tester.pumpAndSettle();
      expect(bridge.interfaceCalls, 3);
      final notice = find.byType(SnackBar);
      expect(notice, findsOneWidget);
      await tester.tap(
        find.descendant(of: notice, matching: find.text(strings.errorDetails)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('new interface failure'), findsOneWidget);
      expect(find.textContaining('old interface failure'), findsNothing);
      expect(bridge.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'LAN listener state shows only business fields and aggregates actual errors',
    (tester) async {
      bridge.value = {
        ...bridge.value,
        'generation': 4,
        'lanListeners': [
          {
            'name': 'lan-tcp',
            'network': 'tcp',
            'address': '10.0.2.16:7890',
            'state': 'bound',
            'extra': 'unrelated raw payload',
          },
          {
            'name': 'lan-udp',
            'network': 'udp',
            'address': '10.0.2.16:7890',
            'state': 'failed',
            'error': 'original bind error',
          },
          {
            'name': 'old-tcp',
            'network': 'tcp',
            'address': '10.0.2.17:7890',
            'state': 'closeFailed',
            'error': 'original close error',
          },
          {
            'name': 'closed-tcp',
            'network': 'tcp',
            'address': '10.0.2.18:7890',
            'state': 'closed',
          },
        ],
      };
      final strings = await show(tester, 'en');
      expect(find.text('lan-tcp'), findsOneWidget);
      expect(
        find.textContaining(
          'tcp · 10.0.2.16:7890 · ${strings.lanProxySocketBound}',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(strings.lanProxySocketFailed), findsOneWidget);
      expect(
        find.textContaining(strings.lanProxySocketCloseFailed),
        findsOneWidget,
      );
      expect(find.textContaining(strings.lanProxySocketClosed), findsOneWidget);
      expect(find.textContaining('unrelated raw payload'), findsNothing);
      expect(find.textContaining('original bind error'), findsNothing);
      expect(find.text(strings.lanProxyListenerFailed), findsOneWidget);
      final calls = bridge.interfaceCalls;
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(strings.errorDetails),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('lan-udp · udp · 10.0.2.16:7890'),
        findsOneWidget,
      );
      expect(find.textContaining('original bind error'), findsOneWidget);
      expect(find.textContaining('original close error'), findsOneWidget);
      expect(find.textContaining('unrelated raw payload'), findsNothing);
      await closeFeedback(tester, strings);
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(bridge.interfaceCalls, calls);
      expect(bridge.commands, isEmpty);
    },
  );

  testWidgets('old LAN listener error details expire after source changes', (
    tester,
  ) async {
    bridge.value = {
      ...bridge.value,
      'lanListeners': [
        {
          'name': 'lan-tcp',
          'network': 'tcp',
          'address': '10.0.2.16:7890',
          'state': 'failed',
          'error': 'old listener error',
        },
      ],
    };
    final strings = await show(tester, 'en');
    final action = tester
        .widget<TextButton>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, strings.errorDetails),
          ),
        )
        .onPressed!;
    bridge.value = {...bridge.value, 'lanListeners': <Object>[]};
    await app.refresh();
    action();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('old listener error'), findsNothing);
    expect(bridge.commands, isEmpty);
  });

  for (final keyboard in [false, true]) {
    testWidgets(
      'LAN landscape cutout and bottom safe area do not cover the last item or Save keyboard=$keyboard',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(840, 500);
        tester.view.viewPadding = const FakeViewPadding(
          left: 44,
          right: 32,
          bottom: 24,
        );
        tester.view.padding = FakeViewPadding(
          left: 44,
          right: 32,
          bottom: keyboard ? 0 : 24,
        );
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard ? 200 : 0);
        addTearDown(tester.view.reset);
        await app.refresh();
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LanProxyPage(app: app),
          ),
        );
        await tester.pumpAndSettle();
        final strings = AppLocalizations.of(
          tester.element(find.byType(LanProxyPage)),
        );
        final viewport = tester.getRect(find.byType(ListView));
        expect(viewport.left, 44);
        expect(viewport.right, 808);
        expect(viewport.bottom, keyboard ? 300 : 476);
        final last = find.text(strings.lanProxyNotRunning);
        await tester.scrollUntilVisible(
          last,
          150,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(last).bottom,
          lessThanOrEqualTo(viewport.bottom - 16),
        );
        final save = find.widgetWithText(TextButton, strings.save);
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.getRect(save).right, lessThanOrEqualTo(808));
        expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'first LAN port error preserves input and geometry $language $scale',
        (tester) async {
          final strings = await show(tester, language, scale: scale);
          final port = find.widgetWithText(TextField, strings.lanProxyPort);
          await tester.scrollUntilVisible(
            port,
            150,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.enterText(port, '0');
          await tester.pumpAndSettle();
          final save = find.widgetWithText(TextButton, strings.save);
          final udp = find.widgetWithText(SwitchListTile, strings.lanProxyUdp);
          final before = (
            tester.getRect(port),
            tester.getRect(udp),
            tester.getRect(save),
          );
          final state = tester.state(find.byType(LanProxyPage));
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(bridge.commands, isEmpty);
          expect(find.byType(AlertDialog), findsNothing);
          expect(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.text(strings.lanProxyInvalidPort),
            ),
            findsOneWidget,
          );
          expect((
            tester.getRect(port),
            tester.getRect(udp),
            tester.getRect(save),
          ), before);
          final field = tester.widget<TextField>(port);
          expect(field.controller!.text, '0');
          expect(field.focusNode!.hasFocus, isTrue);
          expect(
            field.decoration!.focusedBorder!.borderSide.color,
            Theme.of(tester.element(port)).colorScheme.error,
          );
          expect(
            find.ancestor(
              of: port,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics &&
                    widget.properties.hint == strings.lanProxyInvalidPort,
              ),
            ),
            findsOneWidget,
          );
          await tester.enterText(port, '7891');
          await tester.pumpAndSettle();
          expect(find.byType(SnackBar), findsNothing);
          expect(tester.widget<TextField>(port).decoration!.errorText, isNull);
          expect(tester.state(find.byType(LanProxyPage)), same(state));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets(
      'LAN interface failure does not insert content and details expose the original error $language',
      (tester) async {
        final strings = await show(tester, language);
        final raw = find.widgetWithText(SwitchListTile, strings.lanProxyRaw);
        final before = tester.getRect(raw);
        final pending = bridge.interfacePending =
            Completer<Map<String, dynamic>>();
        await interfaceChanged();
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.getRect(raw), before);
        bridge.interfacePending = null;
        pending.completeError(
          StateError('interface original\nCaused by: original'),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(raw), before);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.textContaining('interface original'), findsNothing);
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.errorDetails),
          ),
        );
        await tester.pumpAndSettle();
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
          'Bad state: interface original\nCaused by: original',
        );
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'LAN raw parsing failure neither changes source text nor adds error content $language',
      (tester) async {
        final strings = await show(tester, language);
        final rawSwitch = find.widgetWithText(
          SwitchListTile,
          strings.lanProxyRaw,
        );
        await tester.tap(rawSwitch);
        await tester.pumpAndSettle();
        final raw = find.widgetWithText(TextField, strings.lanProxyRaw);
        await tester.enterText(raw, '{original invalid');
        await tester.pumpAndSettle();
        final before = (tester.getRect(rawSwitch), tester.getRect(raw));
        await tester.ensureVisible(rawSwitch);
        await tester.tap(rawSwitch);
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(rawSwitch).value, isTrue);
        expect(
          tester.widget<TextField>(raw).controller!.text,
          '{original invalid',
        );
        expect((tester.getRect(rawSwitch), tester.getRect(raw)), before);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.lanProxyFormUnavailable),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextField>(raw)
              .decoration!
              .enabledBorder!
              .borderSide
              .color,
          Theme.of(tester.element(raw)).colorScheme.error,
        );
        expect(bridge.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );

    for (final outcome in ['saved', 'applied', 'applyFailed', 'syncWarning']) {
      testWidgets(
        'LAN $outcome title and icon match actual resultSuccess $language',
        (tester) async {
          final strings = await show(tester, language);
          await tester.tap(find.text(strings.save));
          await tester.pumpAndSettle();
          expect(bridge.commands.single['action'], 'saveLanProxy');
          expect(bridge.commands.single['addresses'], ['10.0.2.16']);
          expect(bridge.commands.single['interfaces'], {'10.0.2.16': 'wlan0'});
          expect(bridge.commands.single['storageEpoch'], 0);
          final success = outcome == 'saved' || outcome == 'applied';
          final status = outcome == 'syncWarning' ? 'saved' : outcome;
          final message = switch (outcome) {
            'applied' => messages.overridesAppliedReconnected,
            'applyFailed' =>
              messages.overrideSavedReconnectIncomplete.withDetail(
                '原始 reconnect failure\nCaused by: 原始 cause\nSuppressed: 原始 suppressed',
              ),
            'syncWarning' =>
              messages
                  .storageSyncWarning(messages.overrideSettingsSaved)
                  .withDetail('原始 directory sync failure'),
            _ => messages.overrideSettingsSaved,
          };
          bridge.complete(success: success, status: status, message: message);
          await app.refresh();
          await tester.pumpAndSettle();
          expect(app.state.resultSuccess, success);
          expect(app.state.overrideStatus, status);
          expect(app.state.resultMessageDescription!.toMap(), message.toMap());
          final snack = find.byType(SnackBar);
          expect(find.byType(AlertDialog), findsNothing);
          expect(snack, findsOneWidget);
          expect(
            tester.widget<SnackBar>(snack).behavior,
            SnackBarBehavior.floating,
          );
          expect(tester.widget<SnackBar>(snack).persist, !success);
          expect(find.text(message.summary(strings)), findsOneWidget);
          if (!success) {
            await tester.tap(
              find.descendant(
                of: snack,
                matching: find.text(strings.errorDetails),
              ),
            );
            await tester.pumpAndSettle();
            final dialog = find.byType(AlertDialog);
            expect(dialog, findsOneWidget);
            expect(
              find.descendant(
                of: dialog,
                matching: find.text(strings.errorDetails),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: dialog,
                matching: find.byIcon(Icons.error_outline),
              ),
              findsNothing,
            );
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
              message.technicalDetail(strings),
            );
          }
          expect(overrides.entries.single.enabled, isFalse);
          await closeFeedback(tester, strings);
          expect(bridge.commands, hasLength(1));
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    for (final saved in [true, false]) {
      testWidgets(
        'LAN toggle ${saved ? 'continues enable' : 'retains failure without enabling'} after the actual save receipt $language',
        (tester) async {
          final strings = await show(tester, language);
          final enabled = find.widgetWithText(
            SwitchListTile,
            strings.lanProxyEnabled,
          );
          await tester.ensureVisible(enabled);
          await tester.tap(enabled);
          await tester.pumpAndSettle();
          expect(bridge.commands.map((command) => command['action']), [
            'saveLanProxy',
          ]);
          bridge.complete(
            success: saved,
            status: saved ? 'saved' : 'notSaved',
            message: saved
                ? messages.overrideSettingsSaved
                : messages.overrideChangedReopen.withDetail('原始保存失败'),
          );
          await app.refresh();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(
            find.text(
              (saved
                      ? messages.overrideSettingsSaved
                      : messages.overrideChangedReopen)
                  .summary(strings),
            ),
            findsOneWidget,
          );
          expect(bridge.commands, hasLength(saved ? 2 : 1));
          await closeFeedback(tester, strings);
          if (saved) {
            expect(bridge.commands.map((command) => command['action']), [
              'saveLanProxy',
              'setLanProxyEnabled',
            ]);
            expect(bridge.commands.last['id'], 'lan-plugin');
            expect(bridge.commands.last['revision'], 1);
            expect(bridge.commands.last['enabled'], isTrue);
            expect(bridge.commands.last['storageEpoch'], 0);
            bridge.complete(
              success: true,
              status: 'applied',
              message: messages.overridesAppliedReconnected,
            );
            await app.refresh();
            await tester.pumpAndSettle();
            expect(overrides.entries.single.enabled, isTrue);
            expect(
              find.text(messages.overridesAppliedReconnected.summary(strings)),
              findsOneWidget,
            );
            expect(find.byType(AlertDialog), findsNothing);
            await closeFeedback(tester, strings);
            expect(tester.widget<SwitchListTile>(enabled).value, isTrue);
          } else {
            expect(bridge.commands, hasLength(1));
            expect(overrides.entries, isEmpty);
            expect(tester.widget<SwitchListTile>(enabled).value, isFalse);
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
