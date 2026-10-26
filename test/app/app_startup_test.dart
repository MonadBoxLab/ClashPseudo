import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/app/app.dart';
import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_shell.dart';
import 'package:clash_pseudo/src/features/backup/backup_settings_actions.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overview/widgets/status_text.dart';
import 'package:clash_pseudo/src/features/overview/traffic_window.dart';
import 'package:clash_pseudo/src/features/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/settings/preferences_fakes.dart';
import '../support/readonly_override_store.dart';

class _StartupBridge extends AppBridge {
  bool ready = true;
  bool restoring = false;
  bool failSnapshot = false;
  bool running = false;
  bool pendingRestore = false;
  int snapshots = 0;
  int readiness = 0;
  int imports = 0;
  final commands = <Map<String, Object?>>[];

  @override
  Future<void> uiReady() async {
    readiness++;
  }

  @override
  Future<AppSnapshot> snapshot() async {
    snapshots++;
    if (failSnapshot) throw PlatformException(code: 'snapshotUnavailable');
    return AppSnapshot.fromMap({
      'phase': running ? 'RUNNING' : 'STOPPED',
      'generation': running ? 1 : 0,
      'mode': running ? 'rule' : null,
      'configId': running ? 'running' : null,
      'revision': running ? 1 : null,
      'pendingRestore': pendingRestore,
      'storageReady': ready,
      'storageRestoring': restoring,
      'storageEpoch': 7,
      'networkEpoch': 1,
      'dnsBusy': false,
      'core': running
          ? {
              'phase': 'READY',
              'generation': 17,
              'purpose': 'VPN',
              'configId': 'running',
              'revision': 1,
              'composition': 'running-composition',
            }
          : {'phase': 'EMPTY', 'generation': 0},
    });
  }

  @override
  Future<Map<String, dynamic>> processMemory() async => {
    'valid': false,
    'processRssBytes': null,
    'sampledAt': 1,
    'error': 'unavailable',
  };

  @override
  Future<TrafficSnapshot> traffic() async => TrafficSnapshot.fromMap({
    'phase': 'RUNNING',
    'generation': 17,
    'sessionGeneration': 1,
    'configId': 'running',
    'revision': 1,
    'composition': 'running-composition',
    'elapsedMs': 1,
    'sampledAt': 1,
    'fresh': true,
    'points': [],
  });

  @override
  Future<Map<String, dynamic>> backupPickImport(String requestId) async {
    imports++;
    return {'status': 'cancelled', 'requestId': requestId};
  }

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    throw StateError('Startup must not submit a data mutation');
  }
}

class _StartupConfigs extends ConfigStore {
  _StartupConfigs() : super(Directory.current);
  int reads = 0;
  bool failed = false;
  Completer<ConfigCollection>? pending;

  @override
  Future<ConfigCollection> read() async {
    reads++;
    if (failed) throw ConfigFailure(messages.temporaryConfigsUnreadable);
    return pending == null
        ? ConfigCollection(entries: [])
        : await pending!.future;
  }
}

class _StartupOverrides extends ReadOnlyOverrideStore {
  int reads = 0;
  bool failed = false;

  @override
  Future<List<OverrideEntry>> read() async {
    reads++;
    if (failed) throw ConfigFailure(messages.temporaryOverridesUnreadable);
    return super.read();
  }
}

class _Startup {
  final bridge = _StartupBridge();
  final configs = _StartupConfigs();
  final overrides = _StartupOverrides();
  final preferences = MemoryPreferencesStore()
    ..value = const AppPreferences()
        .withAppearance('language', 'en')
        .withAppearance('brand', 'cobalt');
  late final app = AppController(
    bridge,
    store: configs,
    overrideStore: overrides,
    preferencesStore: preferences,
  );
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> withStartup(
    WidgetTester tester,
    _Startup fixture,
    Future<void> Function() check,
  ) async {
    try {
      await tester.pumpWidget(
        ClashPseudoApp(createController: () => fixture.app),
      );
      await tester.pump();
      await check();
    } finally {
      final pending = fixture.configs.pending;
      if (pending != null && !pending.isCompleted) {
        pending.complete(ConfigCollection(entries: []));
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    expect(fixture.bridge.commands, isEmpty);
    expect(tester.takeException(), isNull);
  }

  Future<void> frame(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
  }

  for (final active in ['running', 'pendingRestore']) {
    testWidgets(
      'startup keeps $active stoppable while store reads are pending',
      (tester) async {
        final fixture = _Startup()
          ..configs.pending = Completer<ConfigCollection>();
        fixture.bridge.running = active == 'running';
        fixture.bridge.pendingRestore = active == 'pendingRestore';
        await withStartup(tester, fixture, () async {
          await frame(tester);
          expect(find.byType(AppShell), findsOneWidget);
          expect(fixture.app.preferencesLoaded, isFalse);
          expect(fixture.app.canToggle, isTrue);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('power-button')),
                )
                .onPressed,
            isNotNull,
          );
          expect(fixture.app.canEdit, isFalse);
          fixture.configs.pending!.complete(ConfigCollection(entries: []));
          await frame(tester);
          expect(fixture.app.preferencesLoaded, isTrue);
        });
      },
    );
  }

  for (final part in [0, 1, 2]) {
    testWidgets(
      'startup store failure $part exposes recovery without publishing defaults',
      (tester) async {
        final fixture = _Startup();
        switch (part) {
          case 0:
            fixture.configs.failed = true;
          case 1:
            fixture.overrides.failed = true;
          case 2:
            fixture.preferences.readResult = () async =>
                throw ConfigFailure(messages.temporarySettingsUnreadable);
        }
        await withStartup(tester, fixture, () async {
          await frame(tester);
          expect(find.byType(AppShell), findsOneWidget);
          final controller = fixture.app;
          expect(fixture.bridge.readiness, 1);
          expect(controller.preferencesLoaded, isFalse);
          expect(controller.configsLoaded, isFalse);
          expect(controller.overridesLoaded, isFalse);
          expect(controller.canEdit, isFalse);
          expect(controller.canChangePreferences, isFalse);
          expect(
            controller.preferences,
            isNot(same(fixture.preferences.value)),
          );
          expect(
            controller.errorMessage,
            [
              messages.temporaryConfigsUnreadable,
              messages.temporaryOverridesUnreadable,
              messages.temporarySettingsUnreadable,
            ][part],
          );
          final issue = find.byKey(const ValueKey('uptime-subtitle'));
          expect(tester.widget<StatusText>(issue).text, en.statusIssue);
          await tester.tap(issue);
          await frame(tester);
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(
            find.text(controller.errorMessage!.resolve(en)),
            findsOneWidget,
          );
          await tester.tap(find.text(en.close));
          await frame(tester);
          await tester.tap(
            find.descendant(
              of: find.byType(NavigationRail),
              matching: find.text(en.settings),
            ),
          );
          await frame(tester);
          final scroll = find
              .descendant(
                of: find.byType(SettingsPage),
                matching: find.byType(Scrollable),
              )
              .first;
          final choose = find.byKey(const ValueKey('backup-import'));
          await tester.scrollUntilVisible(choose, 250, scrollable: scroll);
          await tester.pump();
          expect(find.byType(BackupSettingsActions), findsOneWidget);
          expect(find.byType(SettingsPage), findsOneWidget);
          expect(tester.widget<ListTile>(choose).onTap, isNotNull);
          await tester.tap(choose);
          await tester.pump();
          expect(fixture.bridge.imports, 1);
          expect(controller.preferencesLoaded, isFalse);
          expect(controller.canEdit, isFalse);
        });
      },
    );
  }

  testWidgets(
    'startup closed storage exposes its error and retries without reading stores',
    (tester) async {
      final fixture = _Startup()..bridge.ready = false;
      await withStartup(tester, fixture, () async {
        await frame(tester);
        expect(find.byType(AppShell), findsOneWidget);
        final controller = fixture.app;
        expect(controller.errorMessage, messages.storageUnavailable);
        expect(controller.preferencesLoaded, isFalse);
        expect(controller.canEdit, isFalse);
        expect(fixture.configs.reads, 0);
        expect(fixture.overrides.reads, 0);
        final before = fixture.bridge.snapshots;
        fixture.bridge.ready = true;
        await tester.pump(const Duration(seconds: 1));
        expect(fixture.bridge.snapshots, greaterThan(before));
        await frame(tester);
        expect(controller.preferencesLoaded, isTrue);
        expect(controller.preferences, same(fixture.preferences.value));
        expect(controller.configsCurrent, isTrue);
        expect(controller.errorMessage, isNull);
      });
    },
  );

  testWidgets(
    'startup platform failure remains visible while a successful retry reads stores',
    (tester) async {
      final fixture = _Startup()..bridge.failSnapshot = true;
      await withStartup(tester, fixture, () async {
        await frame(tester);
        expect(find.byType(AppShell), findsOneWidget);
        final element = tester.element(find.byType(AppShell));
        final controller = fixture.app;
        expect(controller.errorMessage, messages.temporaryStatusUnavailable);
        expect(controller.preferencesLoaded, isFalse);
        expect(fixture.configs.reads, 0);
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationRail),
            matching: find.text(en.settings),
          ),
        );
        await frame(tester);
        fixture.bridge.failSnapshot = false;
        fixture.configs.pending = Completer<ConfigCollection>();
        await tester.pump(const Duration(seconds: 1));
        expect(fixture.configs.reads, 1);
        expect(tester.element(find.byType(AppShell)), same(element));
        expect(
          tester
              .widget<NavigationRail>(find.byType(NavigationRail))
              .selectedIndex,
          tester
                  .widget<NavigationRail>(find.byType(NavigationRail))
                  .destinations
                  .length -
              1,
        );
        expect(controller.preferencesLoaded, isFalse);
        fixture.configs.pending!.complete(ConfigCollection(entries: []));
        await frame(tester);
        expect(tester.element(find.byType(AppShell)), same(element));
        expect(controller.preferencesLoaded, isTrue);
        expect(controller.configsCurrent, isTrue);
      });
    },
  );

  testWidgets(
    'startup mechanical recovery keeps its waiting frame and rereads when ready',
    (tester) async {
      final fixture = _Startup()
        ..bridge.ready = false
        ..bridge.restoring = true;
      await withStartup(tester, fixture, () async {
        await frame(tester);
        expect(find.byType(AppShell), findsNothing);
        final waiting = find.byType(CircularProgressIndicator);
        expect(waiting, findsOneWidget);
        final rect = tester.getRect(waiting);
        await tester.pump(const Duration(milliseconds: 180));
        expect(tester.getRect(waiting), rect);
        expect(fixture.configs.reads, 0);
        final before = fixture.bridge.snapshots;
        fixture.bridge.ready = true;
        fixture.bridge.restoring = false;
        await tester.pump(const Duration(seconds: 1));
        expect(fixture.bridge.snapshots, greaterThan(before));
        await frame(tester);
        expect(find.byType(AppShell), findsOneWidget);
        expect(fixture.app.preferencesLoaded, isTrue);
        expect(fixture.app.configsCurrent, isTrue);
      });
    },
  );

  testWidgets('visible loss of focus keeps reads while hiding pauses them', (
    tester,
  ) async {
    final fixture = _Startup();
    fixture.bridge.failSnapshot = true;
    await withStartup(tester, fixture, () async {
      await frame(tester);
      try {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        expect(fixture.app.foreground, isTrue);
        expect(fixture.app.interactive, isFalse);
        final before = fixture.bridge.snapshots;
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(fixture.bridge.snapshots, greaterThan(before));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        await tester.pump();
        expect(fixture.app.foreground, isFalse);
        final hidden = fixture.bridge.snapshots;
        await tester.pump(const Duration(seconds: 3));
        expect(fixture.bridge.snapshots, hidden);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
      }
      expect(fixture.app.foreground, isTrue);
      expect(fixture.app.interactive, isTrue);
    });
  });

  testWidgets(
    'startup does not expose default settings while the initial store read is pending',
    (tester) async {
      final fixture = _Startup()
        ..configs.pending = Completer<ConfigCollection>();
      await withStartup(tester, fixture, () async {
        expect(fixture.configs.reads, 1);
        expect(find.byType(AppShell), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        fixture.configs.pending!.complete(ConfigCollection(entries: []));
        await frame(tester);
        expect(find.byType(AppShell), findsOneWidget);
        expect(fixture.app.preferencesLoaded, isTrue);
        expect(fixture.app.preferences, same(fixture.preferences.value));
      });
    },
  );
}
