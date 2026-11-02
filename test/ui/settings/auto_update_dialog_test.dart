import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';

import 'dart:async';
import 'dart:io';

import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/ui/settings/auto_update_dialog.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/readonly_override_store.dart';
import '../../support/preferences_fakes.dart';
import 'application_fakes.dart';

import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

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
      throw PlatformFailure(
        code: 'expired',
        details: messages.storageContextChanged.toMap(),
      );
    }
    if (reject) throw PlatformFailure(code: 'busy');
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
        navigatorObservers: [AppTaskNavigatorObserver()],
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
    final strings = lookupAppLocalizations(const Locale('en'));
    for (final target in [
      find.byKey(const ValueKey('auto-update-enabled')),
      find.byKey(const ValueKey('auto-update-interval')),
      find.byKey(const ValueKey('auto-update-save')),
      find.widgetWithText(TextButton, strings.cancel),
    ]) {
      expect(
        tester.getRect(target).size.shortestSide,
        greaterThanOrEqualTo(48),
      );
    }
  }

  Future<void> selectInterval(WidgetTester tester, int hours) async {
    final interval = find.byKey(const ValueKey('auto-update-interval'));
    final anchor = tester.getRect(interval);
    final direction = Directionality.of(tester.element(interval));
    final media = MediaQueryData.fromView(View.of(tester.element(interval)));
    final workspace = (media.padding + media.viewInsets).deflateRect(
      Offset.zero & media.size,
    );
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
      final rect = tester.getRect(surface);
      final desiredLeft = switch (direction) {
        TextDirection.ltr => anchor.right - rect.width,
        TextDirection.rtl => anchor.left,
      };
      expect(rect.top, greaterThanOrEqualTo(anchor.bottom));
      expect(rect.top, greaterThanOrEqualTo(workspace.top));
      expect(rect.bottom, lessThanOrEqualTo(workspace.bottom));
      expect(
        rect.left,
        closeTo(
          desiredLeft.clamp(workspace.left, workspace.right - rect.width),
          .01,
        ),
      );
      expect(rect.right, lessThanOrEqualTo(workspace.right));
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

  Finder noticeAction() => find.descendant(
    of: find.byType(SnackBar),
    matching: find.byType(TextButton),
  );

  Finder noticeText() => find
      .descendant(of: find.byType(SnackBar), matching: find.byType(Text))
      .first;

  Future<void> openNoticeDetails(WidgetTester tester) async {
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    final details = noticeAction();
    expect(details.hitTestable(), findsOneWidget);
    expect(tester.getRect(details).size.shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNWidgets(2));
  }

  Future<void> closeNotice(WidgetTester tester) async {
    final close = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byType(IconButton),
    );
    expect(close.hitTestable(), findsOneWidget);
    expect(tester.getRect(close).size.shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(close);
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
          final routes = AppTaskNavigatorObserver();
          addTearDown(locale.dispose);
          final policy = UpdatePolicy(
            lastAttempt: DateTime(2026, 10, 18),
            lastResult: status,
          );
          await tester.pumpWidget(
            ValueListenableBuilder<Locale>(
              valueListenable: locale,
              builder: (_, value, _) => MaterialApp(
                navigatorObservers: [routes],
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
        unorderedEquals([
          'action',
          'id',
          'revision',
          'expectedSource',
          'enabled',
          'hours',
          'storageEpoch',
        ]),
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
    'dismissed update dialog rejects a cached Save before its next frame',
    (tester) async {
      await open(tester);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('auto-update-save')),
      );
      final route = ModalRoute.of(tester.element(find.byType(AlertDialog)))!;
      route.navigator!.pop();
      button.onPressed!();
      expect(bridge.commands, isEmpty);
      await tester.pump(const Duration(milliseconds: 16));
      expect(bridge.commands, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('更新 Dialog 退出首帧拒绝旧 SnackBar 详情操作', (tester) async {
    await open(tester);
    bridge.reject = true;
    await tester.tap(find.byKey(const ValueKey('auto-update-save')));
    await tester.pumpAndSettle();
    final details = tester.widget<TextButton>(noticeAction()).onPressed!;
    expect(app.hasLocalFeedbackOwner, isFalse);
    await tester.binding.handlePopRoute();
    details();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(bridge.commands, hasLength(1));
    await app.refresh();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('storageEpoch 改变撤销技术详情并拒绝旧复制操作', (tester) async {
    var copied = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = true;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await open(tester);
    await selectInterval(tester, 12);
    final save = find.byKey(const ValueKey('auto-update-save'));
    final before = tester.getRect(save);
    await tester.tap(save);
    await tester.pump();
    bridge.state = AppSnapshot(
      phase: 'STOPPED',
      resultId: 'policy-1',
      resultMessage: messages.preferencesSaveFailed.withDetail('原始错误'),
    );
    await app.refresh();
    await tester.pumpAndSettle();
    await openNoticeDetails(tester);
    await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
    await tester.pumpAndSettle();
    final copy = tester
        .widget<TextButton>(
          find.byKey(const ValueKey('operation-technical-copy')),
        )
        .onPressed!;
    bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
    await app.refresh();
    copy();
    await tester.pumpAndSettle();
    expect(copied, isFalse);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.byKey(const ValueKey('operation-technical-text')),
      findsNothing,
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.getRect(save), before);
    await expectInterval(tester, 12);
    expect(bridge.commands, hasLength(1));
    expect(tester.takeException(), isNull);
  });

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
    testWidgets('${fragment ? 'plugin' : 'config'} 提交拒绝先显示 SnackBar，用户打开原文', (
      tester,
    ) async {
      final strings = lookupAppLocalizations(const Locale('en'));
      await open(tester, fragment: fragment);
      bridge.reject = true;
      await selectInterval(tester, 6);
      await tester.tap(find.byKey(const ValueKey('auto-update-save')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final summary = tester.widget<Text>(noticeText()).data;
      expect(summary, strings.requestNotAccepted);
      final original = PlatformFailure(code: 'busy').toString();
      expect(find.text(original), findsNothing);
      await openNoticeDetails(tester);
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      final technical = tester.widget<SelectableText>(
        find.byKey(const ValueKey('operation-technical-text')),
      );
      expect(
        '$summary\n${technical.data}',
        '${strings.requestNotAccepted}\n$original',
      );
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
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
    });

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
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(SnackBar), findsOneWidget);
          expect(find.text(strings.preferencesSaveFailed), findsOneWidget);
          expect(find.byKey(const ValueKey('auto-update-save')), findsNothing);
          expect(bridge.commands, hasLength(1));
          await closeNotice(tester);
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
      await closeNotice(tester);
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
    testWidgets('长错误由用户打开完整内容，表单位置保持不变 $width/$scale', (tester) async {
      await open(tester, width: width, scale: scale);
      await selectInterval(tester, 12);
      final anchors = [
        find.byKey(const ValueKey('auto-update-enabled')),
        find.byKey(const ValueKey('auto-update-interval')),
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
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-update-error')), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(app.hasLocalFeedbackOwner, isTrue);
      tester.view.physicalSize = Size(width, 8192);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(noticeText()).data,
        error.resolve(lookupAppLocalizations(const Locale('en'))),
      );
      expect(app.hasLocalFeedbackOwner, isFalse);
      await openNoticeDetails(tester);
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      await expectStableFrames();
      final reader = find.byType(AlertDialog).last;
      final text = find.descendant(
        of: reader,
        matching: find.byType(SelectableText),
      );
      expect(
        tester.widget<SelectableText>(text).data,
        error.resolve(lookupAppLocalizations(const Locale('en'))),
      );
      final scrollable = find
          .descendant(of: reader, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(scrollable.hitTestable(), findsOneWidget);
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.drag(scrollable, const Offset(0, -2000));
      await expectStableFrames();
      expect(position.pixels, greaterThan(0));
      expect(bridge.commands, hasLength(1));
      await tester.tap(
        find.widgetWithText(
          TextButton,
          lookupAppLocalizations(const Locale('en')).close,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(anchors.last);
      await expectStableFrames();
      expect(find.byType(SnackBar), findsNothing);
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
      expect(find.byType(SnackBar), findsOneWidget);
      await expectInterval(tester, 12);
      await closeNotice(tester);
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
        unorderedEquals([
          'action',
          'id',
          'revision',
          'expectedSource',
          'enabled',
          'hours',
          'storageEpoch',
        ]),
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
      expect(find.byType(SnackBar), findsOneWidget);
      await closeNotice(tester);
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

  group('auto-update draft and feedback roles', () {
    for (final fragment in [false, true]) {
      testWidgets('${fragment ? 'plugin' : 'config'} 无常驻草稿提示，取消不提交', (
        tester,
      ) async {
        await open(tester, fragment: fragment);
        final strings = lookupAppLocalizations(const Locale('en'));
        expect(
          find.byKey(const ValueKey('auto-update-draft-notice')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('auto-update-error')), findsNothing);
        final dialog = tester.element(find.byType(AlertDialog));
        await selectInterval(tester, 6);
        await tester.tap(find.byKey(const ValueKey('auto-update-enabled')));
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(AlertDialog)), same(dialog));
        expect(bridge.commands, isEmpty);
        expect(_config.update.hours, 24);
        expect(_override.update.hours, 24);
        await tester.tap(find.widgetWithText(TextButton, strings.cancel));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(bridge.commands, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
      });
    }

    testWidgets(
      'save failure preserves the draft while original details copy from its owned reader',
      (tester) async {
        const original = 'disk error 原文🙂\ncleanup did not finish';
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
        await open(tester);
        final strings = lookupAppLocalizations(const Locale('en'));
        await selectInterval(tester, 12);
        final dialogElement = tester.element(find.byType(AlertDialog));
        final save = find.byKey(const ValueKey('auto-update-save'));
        final saveBounds = tester.getRect(save);
        await tester.tap(save);
        await tester.pump();
        bridge.state = AppSnapshot(
          phase: 'STOPPED',
          resultId: 'policy-1',
          resultSuccess: false,
          resultMessage: messages.preferencesSaveFailed.withDetail(original),
        );
        await app.refresh();
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(noticeText()).data,
          strings.preferencesSaveFailed,
        );
        expect(find.text(original), findsNothing);
        expect(tester.getRect(save), saveBounds);
        await openNoticeDetails(tester);
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
          original,
        );
        final copy = find.byKey(const ValueKey('operation-technical-copy'));
        await tester.ensureVisible(copy);
        expect(tester.getSemantics(copy).label, strings.copyTechnicalDetails);
        expect(
          tester.getRect(copy).size.shortestSide,
          greaterThanOrEqualTo(48),
        );
        final copyElement = tester.element(copy);
        bool copyHasFocus() {
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused == null) return false;
          var found = identical(focused, copyElement);
          focused.visitAncestorElements((element) {
            found = found || identical(element, copyElement);
            return !found;
          });
          return found;
        }

        for (var tab = 0; tab < 20 && !copyHasFocus(); tab++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(copyHasFocus(), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(copied, original);
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
        expect(tester.element(find.byType(AlertDialog)), same(dialogElement));
        await expectInterval(tester, 12);
        expect(bridge.commands, hasLength(1));
        expect(tester.getRect(save), saveBounds);
        expect(tester.takeException(), isNull);
      },
      semanticsEnabled: true,
    );
  });
}
