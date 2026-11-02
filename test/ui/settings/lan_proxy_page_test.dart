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

  testWidgets('LAN旧错误详情在状态epoch先变化时立即失效', (tester) async {
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
  });

  testWidgets('LAN接口迟到错误不跨越先变化的状态epoch', (tester) async {
    final strings = await show(tester, 'en');
    final pending = bridge.interfacePending = Completer<Map<String, dynamic>>();
    await tester.tap(find.byTooltip(strings.refresh));
    await tester.pump();
    expect(app.storageEpoch, 0);
    app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
    pending.completeError(StateError('retired interface original'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LAN旧epoch的接口迟到错误不进入当前反馈', (tester) async {
    final strings = await show(tester, 'en');
    final pending = bridge.interfacePending = Completer<Map<String, dynamic>>();
    await tester.tap(find.byTooltip(strings.refresh));
    await tester.pump();
    bridge.value = {...bridge.value, 'storageEpoch': 1};
    await app.refresh();
    pending.completeError(StateError('retired interface original'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('retired interface original'), findsNothing);
    expect(bridge.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final keyboard in [false, true]) {
    testWidgets('LAN 横屏 cutout 与底部安全区不遮挡末项或保存 keyboard=$keyboard', (
      tester,
    ) async {
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
    });
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('LAN端口首错保留输入与几何 $language $scale', (tester) async {
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
      });
    }

    testWidgets('LAN接口失败不插正文且原错误由详情读取 $language', (tester) async {
      final strings = await show(tester, language);
      final raw = find.widgetWithText(SwitchListTile, strings.lanProxyRaw);
      final before = tester.getRect(raw);
      final pending = bridge.interfacePending =
          Completer<Map<String, dynamic>>();
      await tester.tap(find.byTooltip(strings.refresh));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.getRect(raw), before);
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
    });

    testWidgets('LAN raw解析失败不改原文或增加错误正文 $language', (tester) async {
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
    });

    for (final outcome in ['saved', 'applied', 'applyFailed', 'syncWarning']) {
      testWidgets('LAN $outcome 的标题、图标与真实 resultSuccess 一致 $language', (
        tester,
      ) async {
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
          'applyFailed' => messages.overrideSavedReconnectIncomplete.withDetail(
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
            findsOneWidget,
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
      });
    }

    for (final saved in [true, false]) {
      testWidgets(
        'LAN toggle 在真实保存回执后${saved ? '继续 enable' : '保留失败且不 enable'} $language',
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
