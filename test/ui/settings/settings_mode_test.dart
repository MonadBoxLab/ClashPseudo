import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/strategies/mode_sheet.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart' show AppMessage;
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../strategies/mode_sheet_test.dart' show ModeController;

import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

Future<Finder> _showEntry(
  WidgetTester tester,
  ModeController app, {
  bool active = true,
}) async {
  final observer =
      tester
          .widgetList<MaterialApp>(find.byType(MaterialApp))
          .firstOrNull
          ?.navigatorObservers
          ?.whereType<AppTaskNavigatorObserver>()
          .firstOrNull ??
      AppTaskNavigatorObserver();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [observer],
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsPage(app: app, active: active),
    ),
  );
  await tester.pumpAndSettle();
  final entry = find.byKey(const ValueKey('settings-mode'));
  await tester.scrollUntilVisible(
    entry,
    150,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(entry);
  await tester.pumpAndSettle();
  return entry;
}

void main() {
  for (final invalidation in [
    'epoch',
    'inactive',
    'background',
    'owner',
    'covered',
    'busy',
    'restoring',
  ]) {
    testWidgets('settings mode rejects an obsolete entry: $invalidation', (
      tester,
    ) async {
      final app = ModeController()..preferencesLoaded = true;
      addTearDown(app.dispose);
      final entry = await _showEntry(tester, app);
      final callback = tester.widget<ListTile>(entry).onTap!;
      switch (invalidation) {
        case 'epoch':
          app.epoch++;
          app.state = const AppSnapshot(phase: 'STOPPED');
          app.changed();
        case 'inactive':
          await _showEntry(tester, app, active: false);
        case 'background':
          app.setForeground(false);
        case 'owner':
          final replacement = ModeController()..preferencesLoaded = true;
          addTearDown(replacement.dispose);
          await _showEntry(tester, replacement);
        case 'covered':
          Navigator.of(tester.element(entry)).push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('cover')),
            ),
          );
        case 'busy':
          app.dispatching = true;
          app.changed();
        case 'restoring':
          app.state = const AppSnapshot(
            phase: 'STOPPED',
            storageRestoring: true,
          );
          app.changed();
      }
      await tester.pumpAndSettle();
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsNothing);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'settings mode remains available while stopped with no current mode',
    (tester) async {
      final app = ModeController()..preferencesLoaded = true;
      addTearDown(app.dispose);
      final entry = await _showEntry(tester, app);
      final callback = tester.widget<ListTile>(entry).onTap!;
      app.state = const AppSnapshot(phase: 'STOPPED');
      app.changed();
      await tester.pumpAndSettle();
      expect(app.state.running, isFalse);
      expect(app.state.mode, isNull);
      expect(app.canEdit, isTrue);
      expect(app.canChangeMode, isTrue);
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsOneWidget);
      for (final mode in TunnelMode.values) {
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(ValueKey('mode-${mode.name}')))
              .onPressed,
          isNotNull,
        );
      }
      expect(app.commands, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsNothing);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings mode rejects cached and rebuilt entries when running mode is unknown',
    (tester) async {
      final app = ModeController()..preferencesLoaded = true;
      addTearDown(app.dispose);
      final entry = await _showEntry(tester, app);
      final callback = tester.widget<ListTile>(entry).onTap!;
      app.state = const AppSnapshot(phase: 'RUNNING');
      app.changed();
      await tester.pumpAndSettle();
      expect(app.state.running, isTrue);
      expect(app.state.mode, isNull);
      expect(app.canEdit, isTrue);
      expect(app.canChangeMode, isFalse);
      expect(tester.widget<ListTile>(entry).enabled, isFalse);
      expect(tester.widget<ListTile>(entry).onTap, isNull);
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsNothing);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings mode remains available with a known running mode despite a mode error',
    (tester) async {
      final app = ModeController()..preferencesLoaded = true;
      addTearDown(app.dispose);
      final entry = await _showEntry(tester, app);
      final callback = tester.widget<ListTile>(entry).onTap!;
      app.state = const AppSnapshot(
        phase: 'RUNNING',
        mode: TunnelMode.rule,
        modeError: AppMessage('androidErrorModeUnconfirmed'),
      );
      app.changed();
      await tester.pumpAndSettle();
      expect(app.state.running, isTrue);
      expect(app.state.mode, TunnelMode.rule);
      expect(app.state.modeError, isNotNull);
      expect(app.canEdit, isTrue);
      expect(app.canChangeMode, isTrue);
      callback();
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsOneWidget);
      for (final mode in TunnelMode.values) {
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(ValueKey('mode-${mode.name}')))
              .onPressed,
          isNotNull,
        );
      }
      expect(app.commands, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsNothing);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings mode cancellation preserves the entry and sends no command',
    (tester) async {
      final app = ModeController()..preferencesLoaded = true;
      addTearDown(app.dispose);
      final entry = await _showEntry(tester, app);
      final before = tester.getRect(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ModeSheet), findsNothing);
      expect(tester.getRect(entry), before);
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings mode captures the epoch before the deferred sheet build',
    (tester) async {
      final app = ModeController()
        ..preferencesLoaded = true
        ..epoch = 1
        ..state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      addTearDown(app.dispose);
      final entry = await _showEntry(tester, app);
      await tester.tap(entry);
      app.epoch = 2;
      app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
      app.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<ModeSheet>(find.byType(ModeSheet)).storageEpoch, 1);
      expect(app.commands, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'settings mode entry reuses the existing sheet $language/$scale',
        (tester) async {
          tester.view.physicalSize = const Size(390, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final app = ModeController()..preferencesLoaded = true;
          addTearDown(app.dispose);
          final strings = lookupAppLocalizations(Locale(language));
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light,
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: SettingsPage(app: app),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(strings.connectionBehavior),
            180,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          final entry = find.byKey(const ValueKey('settings-mode'));
          expect(entry, findsOneWidget);
          await tester.ensureVisible(entry);
          await tester.pumpAndSettle();
          final before = tester.getRect(entry);
          expect(app.commands, isEmpty);
          await tester.tap(entry);
          await tester.pumpAndSettle();
          expect(find.byType(ModeSheet), findsOneWidget);
          expect(
            tester.widget<ModeSheet>(find.byType(ModeSheet)).storageEpoch,
            app.epoch,
          );
          for (final mode in TunnelMode.values) {
            expect(find.byKey(ValueKey('mode-${mode.name}')), findsOneWidget);
          }
          expect(app.commands, isEmpty);
          await tester.ensureVisible(find.byKey(const ValueKey('mode-global')));
          await tester.tap(find.byKey(const ValueKey('mode-global')));
          await tester.pump();
          expect(app.commands.single, {
            'action': 'setMode',
            'mode': 'global',
            'storageEpoch': app.epoch,
          });
          app.collection = ConfigCollection(
            entries: [],
            mode: TunnelMode.global,
          );
          app.state = const AppSnapshot(
            phase: 'STOPPED',
            resultId: 'saved',
            resultSuccess: true,
          );
          app.changed();
          await tester.pumpAndSettle();
          expect(find.byType(ModeSheet), findsNothing);
          expect(tester.getRect(entry), before);
          expect(app.commands, hasLength(1));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
