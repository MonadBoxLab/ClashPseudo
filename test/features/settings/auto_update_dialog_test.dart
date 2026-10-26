import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/settings/auto_update_dialog.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/readonly_override_store.dart';
import 'preferences_fakes.dart';
import 'application_fakes.dart';

const _config = ConfigEntry(
  id: 'one',
  name: 'Remote',
  source: 'https://fixture.test/config',
  revision: 1,
  body: '{}',
  update: UpdatePolicy(enabled: true),
);

const _override = OverrideEntry(
  id: 'plugin',
  name: 'Plugin',
  kind: ConfigKind.remote,
  source: 'https://fixture.test/plugin',
  revision: 1,
  body: '{}',
  update: UpdatePolicy(enabled: true),
);

class _Configs extends ConfigStore {
  _Configs() : super(Directory.systemTemp);
  @override
  Future<ConfigCollection> read() async =>
      ConfigCollection(entries: [_config], selectedId: 'one');
}

class _Bridge extends AppBridge {
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  final commands = <Map<String, Object?>>[];
  bool reject = false;
  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    if (command['storageEpoch'] != state.storageEpoch) {
      throw PlatformException(
        code: 'expired',
        details: messages.storageContextChanged.toMap(),
      );
    }
    if (reject) throw PlatformException(code: 'busy');
    return OperationAdmission(
      operationId: 'policy-${commands.length}',
      remaining: const Duration(seconds: 120),
    );
  }
}

void main() {
  late _Bridge bridge;
  late AppController app;
  setUp(() {
    bridge = _Bridge();
    app = AppController(
      bridge,
      store: _Configs(),
      overrideStore: ReadOnlyOverrideStore(),
      preferencesStore: MemoryPreferencesStore(),
    );
  });
  tearDown(() => app.dispose());

  Future<void> open(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
    bool fragment = false,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await app.refresh();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: OperationFeedback(
          controller: app,
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  showAutoUpdateDialog(
                    context,
                    app,
                    config: fragment ? null : _config,
                    override: fragment ? _override : null,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> selectInterval(WidgetTester tester, int hours) async {
    final interval = find.byKey(const ValueKey('auto-update-interval'));
    final anchor = tester.getRect(interval);
    await tester.tap(interval);
    for (final elapsed in [0, 16, 80, 250]) {
      await tester.pump(Duration(milliseconds: elapsed));
      final surface = find
          .ancestor(
            of: find.byType(MenuItemButton).first,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Material && widget.type == MaterialType.canvas,
            ),
          )
          .first;
      expect(tester.getRect(surface).top, greaterThanOrEqualTo(anchor.bottom));
      expect(tester.getRect(surface).right, closeTo(anchor.right, .01));
      expect(tester.getRect(interval), anchor);
      expect(tester.takeException(), isNull);
    }
    final item = find.byKey(ValueKey(hours));
    expect(tester.widget(item), isA<MenuItemButton>());
    await tester.ensureVisible(item);
    await tester.pumpAndSettle();
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  Future<void> expectInterval(WidgetTester tester, int hours) async {
    await tester.tap(find.byKey(const ValueKey('auto-update-interval')));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(3));
    for (final option in UpdatePolicy.intervals) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey(option)),
          matching: find.byIcon(Icons.check),
        ),
        option == hours ? findsOneWidget : findsNothing,
      );
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  for (final fragment in [false, true]) {
    for (final status in <String?>[
      null,
      'saved',
      'updated',
      'applied',
      'applyFailed',
      'failed',
      'unchanged',
      'unexpected-result',
    ]) {
      testWidgets(
        'auto update result $status is localized fragment=$fragment',
        (tester) async {
          final locale = ValueNotifier(const Locale('en'));
          addTearDown(locale.dispose);
          final policy = UpdatePolicy(
            lastAttempt: DateTime(2026, 10, 18),
            lastResult: status,
          );
          await tester.pumpWidget(
            ValueListenableBuilder<Locale>(
              valueListenable: locale,
              builder: (_, value, _) => MaterialApp(
                locale: value,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      child: const Text('Open'),
                      onPressed: () => showAutoUpdateDialog(
                        context,
                        app,
                        config: fragment
                            ? null
                            : ConfigEntry(
                                id: 'one',
                                name: '用户配置',
                                source: _config.source,
                                revision: 1,
                                body: '{}',
                                update: policy,
                              ),
                        override: fragment
                            ? OverrideEntry(
                                id: 'plugin',
                                name: '用户插件',
                                kind: ConfigKind.remote,
                                source: _override.source,
                                revision: 1,
                                body: '{}',
                                update: policy,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final dialog = tester.element(find.byType(AlertDialog));
          for (final language in ['en', 'zh', 'en']) {
            locale.value = Locale(language);
            await tester.pumpAndSettle();
            final strings = lookupAppLocalizations(Locale(language));
            final expected = switch (status) {
              null => strings.autoUpdateNever,
              'saved' || 'updated' => strings.autoUpdateSaved,
              'applied' => strings.autoUpdateApplied,
              'applyFailed' => strings.autoUpdateApplyFailed,
              'failed' => strings.autoUpdateFailed,
              'unchanged' => strings.autoUpdateUnchanged,
              _ => strings.resultUnconfirmed,
            };
            expect(tester.element(find.byType(AlertDialog)), same(dialog));
            expect(find.text(expected), findsOneWidget);
            if (status != null) {
              expect(find.text(strings.autoUpdateNever), findsNothing);
            }
            expect(find.text('unexpected-result'), findsNothing);
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }

  for (final (width, scale) in [(390.0, 1.0), (320.0, 2.0)]) {
    testWidgets('disabled schedule preserves anchors $width/$scale', (
      tester,
    ) async {
      await open(tester, width: width, scale: scale);
      final interval = find.byKey(const ValueKey('auto-update-interval'));
      final enabled = find.byKey(const ValueKey('auto-update-enabled'));
      final save = find.byKey(const ValueKey('auto-update-save'));
      final anchors = [interval, enabled, save];
      final rects = anchors.map(tester.getRect).toList();
      await tester.tap(enabled);
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (var i = 0; i < anchors.length; i++) {
          expect(tester.getRect(anchors[i]), rects[i]);
        }
        expect(tester.takeException(), isNull);
      }
      expect(tester.widget<ChoiceMenuButton<int>>(interval).enabled, isFalse);
      await tester.tap(interval);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.tap(enabled);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceMenuButton<int>>(interval).enabled, isTrue);
      await expectInterval(tester, 24);
      await selectInterval(tester, 6);
      await tester.tap(save);
      await tester.pump();
      expect(
        bridge.commands.single.keys,
        unorderedEquals(['action', 'id', 'enabled', 'hours', 'storageEpoch']),
      );
      bridge.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'policy-1',
        resultSuccess: true,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets(
    'restore invalidates an open schedule draft without replacing its values',
    (tester) async {
      bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      await open(tester);
      await selectInterval(tester, 6);
      final save = find.byKey(const ValueKey('auto-update-save'));
      final before = tester.getRect(save);
      bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
      await app.refresh();
      await tester.pumpAndSettle();
      expect(app.storageEpoch, 2);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(bridge.commands.single['storageEpoch'], 1);
      expect(bridge.commands.single['hours'], 6);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text(
          lookupAppLocalizations(const Locale('en')).storageContextChanged,
        ),
        findsOneWidget,
      );
      expect(tester.getRect(save), before);
      await expectInterval(tester, 6);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    },
  );

  testWidgets(
    'receipt and unrelated result never dismiss; final success does',
    (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('auto-update-save')));
      await tester.pump();
      expect(bridge.commands.single['action'], 'setConfigUpdate');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('auto-update-save')),
            )
            .onPressed,
        isNull,
      );
      bridge.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'unrelated',
        resultSuccess: true,
      );
      await app.refresh();
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      bridge.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'policy-1',
        resultSuccess: true,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.commands, hasLength(1));
    },
  );

  for (final fragment in [false, true]) {
    testWidgets(
      '${fragment ? 'plugin' : 'config'} rejection has only the inline reader',
      (tester) async {
        final strings = lookupAppLocalizations(const Locale('en'));
        await open(tester, fragment: fragment);
        bridge.reject = true;
        await selectInterval(tester, 6);
        await tester.tap(find.byKey(const ValueKey('auto-update-save')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(strings.requestNotAccepted), findsOneWidget);
        await expectInterval(tester, 6);
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(
          bridge.commands.single['action'],
          fragment ? 'setOverrideUpdate' : 'setConfigUpdate',
        );
        expect(bridge.commands.single['hours'], 6);
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(bridge.commands, hasLength(1));
        await tester.tap(find.text(strings.cancel));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );

    for (final barrier in [false, true]) {
      testWidgets(
        '${fragment ? 'plugin' : 'config'} late failure returns globally '
        'after ${barrier ? 'barrier' : 'Back'} dismissal',
        (tester) async {
          final strings = lookupAppLocalizations(const Locale('en'));
          await open(tester, fragment: fragment);
          await tester.tap(find.byKey(const ValueKey('auto-update-save')));
          await tester.pump();
          expect(app.hasLocalFeedbackOwner, isTrue);
          if (barrier) {
            await tester.tapAt(const Offset(4, 4));
          } else {
            await tester.binding.handlePopRoute();
          }
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(app.hasLocalFeedbackOwner, isFalse);
          bridge.state = AppSnapshot(
            phase: 'STOPPED',
            resultId: 'policy-1',
            resultSuccess: false,
            resultMessage: messages.preferencesSaveFailed,
          );
          await app.refresh();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(find.text(strings.preferencesSaveFailed), findsOneWidget);
          expect(find.byKey(const ValueKey('auto-update-save')), findsNothing);
          expect(bridge.commands, hasLength(1));
          await tester.tap(find.text(strings.close));
          await tester.pumpAndSettle();
          await app.refresh();
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(SnackBar), findsNothing);
          expect(bridge.commands, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final (width, scale, fragment) in [
    (390.0, 1.0, false),
    (320.0, 1.5, false),
    (320.0, 1.5, true),
  ]) {
    testWidgets('failure preserves draft and stable anchors at $width/$scale '
        '${fragment ? 'plugin' : 'config'}', (tester) async {
      await open(tester, width: width, scale: scale, fragment: fragment);
      await selectInterval(tester, 6);
      await tester.pump();
      final save = find.byKey(const ValueKey('auto-update-save'));
      final enabled = find.byKey(const ValueKey('auto-update-enabled'));
      final beforeSave = tester.getRect(save);
      final beforeEnabled = tester.getRect(enabled);
      await tester.tap(save);
      await tester.pump();
      expect(tester.getRect(save), beforeSave);
      expect(tester.getRect(enabled), beforeEnabled);
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'policy-1',
        resultSuccess: false,
        resultMessage: messages.preferencesSaveFailed,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await expectInterval(tester, 6);
      expect(tester.getRect(save), beforeSave);
      expect(tester.getRect(enabled), beforeEnabled);
      expect(
        find.text(
          lookupAppLocalizations(const Locale('en')).preferencesSaveFailed,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(save);
      await tester.pump();
      expect(bridge.commands.last['hours'], 6);
      expect(tester.getRect(save), beforeSave);
      bridge.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'policy-2',
        resultSuccess: true,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  for (final (width, scale) in [(390.0, 1.0), (320.0, 2.0)]) {
    testWidgets('long errors stay selectable in a stable slot $width/$scale', (
      tester,
    ) async {
      await open(tester, width: width, scale: scale);
      await selectInterval(tester, 12);
      final anchors = [
        find.byKey(const ValueKey('auto-update-enabled')),
        find.byKey(const ValueKey('auto-update-interval')),
        find.byKey(const ValueKey('auto-update-error')),
        find.byKey(const ValueKey('auto-update-save')),
      ];
      final rects = anchors.map(tester.getRect).toList();
      Future<void> expectStableFrames() async {
        for (var frame = 0; frame < 16; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          for (var i = 0; i < anchors.length; i++) {
            expect(tester.getRect(anchors[i]), rects[i]);
          }
          expect(tester.takeException(), isNull);
        }
      }

      await tester.tap(anchors.last);
      await expectStableFrames();
      final error = messages.sourceUsedBy(
        'Long readable configuration 🌐 ' * 24,
      );
      bridge.state = AppSnapshot(
        phase: 'STOPPED',
        resultId: 'policy-1',
        resultMessage: error,
      );
      await app.refresh();
      await expectStableFrames();
      final text = find.descendant(
        of: anchors[2],
        matching: find.byType(SelectableText),
      );
      expect(
        tester.widget<SelectableText>(text).data,
        error.resolve(lookupAppLocalizations(const Locale('en'))),
      );
      // SelectableText also owns an inner Scrollable; inspect the outer slot.
      final scrollable = find
          .descendant(of: anchors[2], matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.drag(scrollable, const Offset(0, -2000));
      await expectStableFrames();
      expect(position.pixels, greaterThan(0));
      expect(bridge.commands, hasLength(1));
      await tester.tap(anchors.last);
      await expectStableFrames();
      expect(
        find.descendant(of: anchors[2], matching: find.byType(SelectableText)),
        findsNothing,
      );
      expect(bridge.commands, hasLength(2));
      expect(bridge.commands.last['hours'], 12);
      bridge.state = const AppSnapshot(
        phase: 'STOPPED',
        resultId: 'policy-2',
        resultSuccess: true,
      );
      await app.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets(
    'timeout and rejected submission retain editable draft without resending',
    (tester) async {
      await open(tester);
      await selectInterval(tester, 12);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('auto-update-save')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 126));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(bridge.commands, hasLength(1));
      await expectInterval(tester, 12);
      bridge.reject = true;
      await tester.tap(find.byKey(const ValueKey('auto-update-save')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(bridge.commands, hasLength(2));
      await expectInterval(tester, 12);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('auto-update-save')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'auto-update dialog waits for its final save result without starting',
    (tester) async {
      final bridge = AccessBridge();
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      const entry = ConfigEntry(
        id: 'remote',
        name: 'Remote',
        source: 'https://example.test/c',
        revision: 1,
        body: 'rules: []',
      );
      await show(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAutoUpdateDialog(
                context,
                app,
                config: entry,
                override: null,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-update-enabled')));
      await tester.pumpAndSettle();
      await selectInterval(tester, 12);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('auto-update-save')));
      await tester.pumpAndSettle();
      expect(app.commands.single['action'], 'setConfigUpdate');
      expect(app.commands.single['enabled'], isTrue);
      expect(app.commands.single['hours'], 12);
      expect(
        app.commands.single.keys,
        unorderedEquals(['action', 'id', 'enabled', 'hours', 'storageEpoch']),
      );
      final save = find.byKey(const ValueKey('auto-update-save'));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      app.publish(
        const AppSnapshot(
          phase: 'RUNNING',
          resultId: 'unrelated-operation',
          resultSuccess: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      app.publish(
        const AppSnapshot(
          phase: 'RUNNING',
          resultId: 'operation-1',
          resultSuccess: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(app.commands, hasLength(2));
      expect(
        app.commands.every((command) => command['action'] == 'setConfigUpdate'),
        isTrue,
      );
      app.publish(
        const AppSnapshot(
          phase: 'RUNNING',
          resultId: 'operation-1',
          resultSuccess: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      app.publish(
        const AppSnapshot(
          phase: 'RUNNING',
          resultId: 'operation-2',
          resultSuccess: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
