import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/ui/overview/widgets/status_hero.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Configs extends ConfigStore {
  _Configs() : super(Directory.systemTemp);
  @override
  Future<ConfigCollection> read() async => ConfigCollection(entries: const []);
}

class _Overrides extends OverrideStore {
  _Overrides() : super(Directory.systemTemp);
  @override
  Future<List<OverrideEntry>> read() async => [];
}

class _Preferences extends PreferencesStore {
  _Preferences() : super(Directory.systemTemp);
  @override
  Future<AppPreferences> read() async => const AppPreferences();
}

class _Bridge extends AppBridge {
  _Bridge(this.state);
  AppSnapshot state;
  final commands = <Map<String, Object?>>[];
  final accepted = Completer<String?>();
  int settingsOpens = 0;
  bool settingsFail = false;
  @override
  Future<void> openVpnSettings() async {
    settingsOpens++;
    if (settingsFail) throw StateError('settings unavailable');
  }

  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    final id = await accepted.future;
    return id == null
        ? null
        : OperationAdmission(
            operationId: id,
            remaining: const Duration(seconds: 120),
          );
  }
}

void main() {
  for (final alwaysOn in [true, false, null]) {
    testWidgets('power action preserves nullable Always-on state $alwaysOn', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final initial = AppSnapshot(phase: 'RUNNING', alwaysOn: alwaysOn);
      final bridge = _Bridge(initial);
      final app =
          AppController(
              bridge,
              store: _Configs(),
              overrideStore: _Overrides(),
              preferencesStore: _Preferences(),
            )
            ..loading = false
            ..configsLoaded = true
            ..state = initial;
      addTearDown(app.dispose);
      final taskRoutes = AppTaskNavigatorObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [taskRoutes],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: StatusHero(
              controller: app,
              runningProgress: app.state.running ? 1 : 0,
              visible: true,
              onManage: () {},
              onImport: () {},
              onMode: () {},
            ),
          ),
        ),
      );
      final power = find.byKey(const ValueKey('power-button'));
      final rect = tester.getRect(power);
      await tester.tap(power);
      await tester.pumpAndSettle();
      if (alwaysOn == true) {
        expect(bridge.commands, isEmpty);
        expect(bridge.settingsOpens, 0);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.textContaining('managed by Android'), findsOneWidget);
        expect(tester.getRect(power), rect);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Cancel'),
          ),
        );
        await tester.pumpAndSettle();
        expect(bridge.settingsOpens, 0);
        await tester.tap(power);
        await tester.pumpAndSettle();
        bridge.settingsFail = true;
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Open system VPN settings'),
          ),
        );
        await tester.pumpAndSettle();
        expect(bridge.settingsOpens, 1);
        expect(bridge.commands, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        final notice = find.byType(SnackBar);
        expect(notice, findsOneWidget);
        final strings = AppLocalizations.of(tester.element(notice));
        expect(find.text(strings.alwaysOnOpenFailed), findsOneWidget);
        expect(tester.getRect(power), rect);
        await tester.tap(
          find.descendant(
            of: notice,
            matching: find.widgetWithText(TextButton, strings.errorDetails),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        final technical = find.byKey(
          const ValueKey('operation-technical-details'),
        );
        await tester.ensureVisible(technical);
        await tester.pumpAndSettle();
        await tester.tap(technical);
        await tester.pumpAndSettle();
        expect(find.text('Bad state: settings unavailable'), findsOneWidget);
        Navigator.of(tester.element(find.byType(AlertDialog))).pop();
        await tester.pumpAndSettle();
        bridge.settingsFail = false;
        await tester.tap(power);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Open system VPN settings'),
          ),
        );
        await tester.pumpAndSettle();
        expect(bridge.settingsOpens, 2);
        expect(bridge.commands, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.getRect(power), rect);
      } else {
        expect(bridge.commands.single['action'], 'stop');
        expect(bridge.settingsOpens, 0);
        bridge.accepted.complete('stop-owner');
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final initial in const [
    AppSnapshot(phase: 'RUNNING', resourceBusy: true, writerBusy: true),
    AppSnapshot(phase: 'STOPPED', resourceBusy: true),
    AppSnapshot(phase: 'RUNNING', scheduleBusy: true, writerBusy: true),
    AppSnapshot(phase: 'STOPPED', scheduleBusy: true, writerBusy: true),
    AppSnapshot(phase: 'STOPPING', scheduleBusy: true, writerBusy: true),
    AppSnapshot(phase: 'STOPPED', pendingSystemStart: true, writerBusy: true),
    AppSnapshot(phase: 'STOPPED', pendingStart: true, writerBusy: true),
    AppSnapshot(phase: 'RUNNING', pendingStart: true, writerBusy: true),
    AppSnapshot(phase: 'STARTING', writerBusy: true),
  ]) {
    testWidgets(
      'power button accepts stop for ${initial.phase}, schedule=${initial.scheduleBusy}, resource=${initial.resourceBusy}, system=${initial.pendingSystemStart}, start=${initial.pendingStart}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final bridge = _Bridge(initial);
        final app = AppController(
          bridge,
          store: _Configs(),
          overrideStore: _Overrides(),
          preferencesStore: _Preferences(),
        );
        app.loading = false;
        app.configsLoaded = true;
        app.state = initial;
        addTearDown(app.dispose);
        expect(app.busy, isTrue);
        expect(app.canEdit, isFalse);
        expect(app.canToggle, isTrue);
        await app.submit({'action': 'select', 'id': 'pending'});
        expect(bridge.commands, isEmpty);
        final taskRoutes = AppTaskNavigatorObserver();
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [taskRoutes],
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            theme: AppTheme.light,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: app,
                builder: (context, _) => StatusHero(
                  controller: app,
                  runningProgress: app.state.running ? 1 : 0,
                  visible: true,
                  onManage: () {},
                  onMode: () {},
                  onImport: () {},
                ),
              ),
            ),
          ),
        );
        final power = find.byKey(const ValueKey('power-button'));
        final rect = tester.getRect(power);
        expect(tester.widget<FilledButton>(power).onPressed, isNotNull);
        await tester.tap(power);
        await tester.pump();
        expect(bridge.commands.single['action'], 'stop');
        expect(app.dispatching, isTrue);
        expect(app.canToggle, isFalse);
        expect(tester.getRect(power), rect);
        bridge.state = const AppSnapshot(phase: 'STOPPED', writerBusy: true);
        bridge.accepted.complete('stop-operation');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 160));
        expect(app.state.writerBusy, isTrue);
        expect(app.canEdit, isFalse);
        expect(app.canToggle, isFalse);
        expect(tester.getRect(power), rect);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
