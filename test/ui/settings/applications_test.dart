import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/settings/applications_page.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:clash_pseudo/src/model/app_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'application_fakes.dart';

class _EpochAccessApp extends AccessApp {
  _EpochAccessApp(super.platform) {
    state = AppSnapshot(
      phase: state.phase,
      generation: state.generation,
      core: state.core,
      runningApplicationAccess: state.runningApplicationAccess,
      storageEpoch: epoch,
    );
  }
  int epoch = 1;
  @override
  int get storageEpoch => epoch;

  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(Map.of(command));
    lastCommand = Map.of(command);
    lastCommandAutomatic = automatic;
    if (command['storageEpoch'] != epoch) {
      commandErrorMessage = messages.storageUnavailable;
      notifyListeners();
      return null;
    }
    commandErrorMessage = null;
    return 'operation-${commands.length}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'capacity split has real intermediate geometry and retains one composing editor through reversal',
    (tester) async {
      tester.view.physicalSize = const Size(780, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = AccessApp(AccessBridge());
      addTearDown(app.dispose);
      await show(tester, ApplicationsPage(app: app));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      await tester.showKeyboard(field);
      const editing = TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      tester.testTextInput.updateEditingValue(editing);
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      final editor = tester.state<EditableTextState>(find.byType(EditableText));
      final reads = (app.platform as AccessBridge).listCalls;
      tester.view.physicalSize = const Size(1000, 900);
      await tester.pump();
      final initial = tester.getRect(field);
      await tester.pump(const Duration(milliseconds: 90));
      final middle = tester.getRect(field);
      expect(middle.width, greaterThan(320 - 32));
      expect(middle.width, lessThan(initial.width));
      final split = tester.getTopLeft(find.byType(CustomScrollView)).dx;
      expect(split, greaterThan(0));
      expect(split, lessThan(320));
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editor),
      );
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.value, editing);
      expect(find.byType(TextField), findsOneWidget);

      tester.view.physicalSize = const Size(780, 900);
      await tester.pump();
      final reversing = tester.getTopLeft(find.byType(CustomScrollView)).dx;
      await tester.pump(const Duration(milliseconds: 16));
      final reversed = tester.getTopLeft(find.byType(CustomScrollView)).dx;
      expect(reversed, greaterThan(0));
      expect(reversed, lessThan(reversing));
      for (final width in [1000.0, 960.0, 900.0, 1000.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.state<EditableTextState>(find.byType(EditableText)),
          same(editor),
        );
        expect(controller.value, editing);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(field).width, closeTo(320 - 32, 0.01));
      expect((app.platform as AccessBridge).listCalls, reads);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'capacity split preserves the visible row anchor and reduces motion immediately',
    (tester) async {
      tester.view.physicalSize = const Size(780, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = AccessApp(
        AccessBridge()
          ..installed = [
            for (var i = 0; i < 80; i++)
              {
                'package': 'motion.$i',
                'label': 'Application ${i.toString().padLeft(2, '0')}',
                'system': false,
              },
          ],
      );
      addTearDown(app.dispose);
      var reduce = false;
      Widget page() => MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(disableAnimations: reduce),
        child: ApplicationsPage(app: app),
      );
      await show(tester, page());
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('application-motion.40'));
      await tester.scrollUntilVisible(
        row,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(row), alignment: 0.05);
      await tester.pumpAndSettle();
      final top = tester.getTopLeft(row).dy;
      tester.view.physicalSize = const Size(1000, 900);
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(row).dy, closeTo(top, 0.01));
      }
      reduce = true;
      await show(tester, page());
      await tester.pump();
      expect(
        tester.getTopLeft(find.byType(CustomScrollView)).dx,
        closeTo(320, 0.01),
      );
      expect(tester.getTopLeft(row).dy, closeTo(top, 0.01));
      tester.view.physicalSize = const Size(780, 900);
      await tester.pump();
      expect(tester.getTopLeft(find.byType(CustomScrollView)).dx, 0);
      expect(tester.getTopLeft(row).dy, closeTo(top, 0.01));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cached access actions cannot run after live task authority is revoked',
    (tester) async {
      final bridge = AccessBridge();
      final app = AccessApp(bridge)
        ..state = const AppSnapshot(phase: 'STOPPED');
      addTearDown(app.dispose);
      var active = true;
      await show(
        tester,
        AppTaskActivity(
          active: true,
          isActiveNow: () => active,
          child: ApplicationsPage(app: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('access-except')));
      await tester.pumpAndSettle();
      final save = tester
          .widget<TextButton>(find.byKey(const ValueKey('applications-save')))
          .onPressed!;
      final toggle = tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('application-app.alpha')),
          )
          .onChanged!;
      final refreshButton = find.ancestor(
        of: find.byIcon(Icons.refresh),
        matching: find.byType(IconButton),
      );
      expect(refreshButton, findsOneWidget);
      final refresh = tester.widget<IconButton>(refreshButton).onPressed!;
      final reads = bridge.listCalls;
      active = false;
      toggle(true);
      save();
      refresh();
      await tester.pumpAndSettle();
      expect(app.commands, isEmpty);
      expect(bridge.listCalls, reads);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('application-app.alpha')),
            )
            .value,
        isFalse,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an access confirmation owns only its popup and cannot resurrect an older session',
    (tester) async {
      final app = AccessApp(AccessBridge());
      addTearDown(app.dispose);
      await show(
        tester,
        AppTaskActivity(
          active: true,
          isActiveNow: () => true,
          isActiveWithPopup: (_) => true,
          child: ApplicationsPage(app: app),
        ),
      );
      await tester.pumpAndSettle();
      final page = find.byType(ApplicationsPage);
      final pageState = tester.state(page);
      final source = ModalRoute.of(tester.element(page))!;
      final preferences = app.preferences;
      expect(source.isActive, isTrue);
      expect(source.isCurrent, isTrue);
      final selection = find.byKey(const ValueKey('access-except'));
      await tester.tap(selection);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(selection).selected, isTrue);
      await tester.tap(find.byKey(const ValueKey('applications-save')));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      final popup = ModalRoute.of(tester.element(dialog))!;
      expect(popup, isA<PopupRoute<dynamic>>());
      expect(popup, isNot(same(source)));
      expect(popup.isActive, isTrue);
      expect(popup.isCurrent, isTrue);
      expect(popup.animation!.status, isNot(AnimationStatus.reverse));
      final confirm = tester
          .widget<FilledButton>(
            find.descendant(of: dialog, matching: find.byType(FilledButton)),
          )
          .onPressed!;
      app.publish(const AppSnapshot(phase: 'STOPPED', generation: 9));
      // Exercise the captured callback before any rebuild can disable the button.
      confirm();
      expect(popup.animation!.status, AnimationStatus.reverse);
      expect(popup.isActive, isFalse);
      expect(popup.isCurrent, isFalse);
      expect(source.isActive, isTrue);
      expect(source.isCurrent, isTrue);
      expect(app.commands, isEmpty);
      await tester.pumpAndSettle();
      expect(app.commands, isEmpty);
      expect(dialog, findsNothing);
      expect(tester.state(page), same(pageState));
      expect(ModalRoute.of(tester.element(page)), same(source));
      expect(source.isActive, isTrue);
      expect(source.isCurrent, isTrue);
      expect(tester.widget<ChoiceChip>(selection).selected, isTrue);
      expect(app.preferences, same(preferences));
      expect(app.state.generation, 9);
      expect(app.state.phase, 'STOPPED');
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final listFailure in [true, false]) {
    testWidgets('Applications旧错误详情在状态epoch先变化时失效 $listFailure', (tester) async {
      final bridge = AccessBridge()..fail = listFailure;
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(tester, ApplicationsPage(app: app));
      await tester.pumpAndSettle();
      if (!listFailure) {
        await tester.tap(find.byKey(const ValueKey('access-only')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('applications-save')));
        await tester.pumpAndSettle();
      }
      final strings = AppLocalizations.of(
        tester.element(find.byType(ApplicationsPage)),
      );
      final details = find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.errorDetails),
      );
      final oldDetails = tester.widget<TextButton>(details).onPressed!;
      final previous = app.state;
      app.state = AppSnapshot(
        phase: previous.phase,
        generation: previous.generation,
        core: previous.core,
        storageEpoch: previous.storageEpoch + 1,
      );
      oldDetails();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Applications列表迟到错误不跨越先变化的状态epoch', (tester) async {
    final pending = Completer<List<Map<String, dynamic>>>();
    final bridge = AccessBridge()..listReply = pending;
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pump();
    expect(bridge.listCalls, 1);
    final previous = app.state;
    app.state = AppSnapshot(
      phase: previous.phase,
      generation: previous.generation,
      core: previous.core,
      storageEpoch: previous.storageEpoch + 1,
    );
    pending.completeError(StateError('retired applications original'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a list failure feedback is readable and closable through its own popup',
    (tester) async {
      final bridge = AccessBridge()..fail = true;
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(tester, ApplicationsPage(app: app));
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(ApplicationsPage)),
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(strings.errorDetails),
        ),
      );
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(find.text('Bad state: list failed'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Bad state: list failed'), findsOneWidget);
      await tester.tap(
        find.descendant(of: dialog, matching: find.text(strings.close)),
      );
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('save shortcuts follow the actual access save button', (
    tester,
  ) async {
    final app = AccessApp(AccessBridge())
      ..state = const AppSnapshot(phase: 'STOPPED');
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    Future<void> save(LogicalKeyboardKey modifier) async {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    final button = find.byKey(const ValueKey('applications-save'));
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    await save(LogicalKeyboardKey.controlLeft);
    expect(app.commands, isEmpty);
    app.publish(const AppSnapshot(phase: 'STOPPED', writerBusy: true));
    await tester.pump();
    await save(LogicalKeyboardKey.metaLeft);
    expect(app.commands, isEmpty);
    app.publish(const AppSnapshot(phase: 'STOPPED'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('access-except')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await save(LogicalKeyboardKey.metaLeft);
    expect(app.commands.single['action'], 'setApplicationAccess');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'settings captures the access form epoch before its route builder runs',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = _EpochAccessApp(AccessBridge());
      addTearDown(app.dispose);
      await show(
        tester,
        OperationFeedback(
          controller: app,
          child: SettingsPage(app: app),
        ),
        locale: const Locale('en'),
      );
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(SettingsPage)),
      );
      final open = find.text(strings.applicationAccess);
      await tester.scrollUntilVisible(
        open,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(open);
      app.epoch = 2;
      app.publish(
        AppSnapshot(
          phase: app.state.phase,
          generation: app.state.generation,
          core: app.state.core,
          runningApplicationAccess: app.state.runningApplicationAccess,
          storageEpoch: app.epoch,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ApplicationsPage>(find.byType(ApplicationsPage))
            .storageEpoch,
        1,
      );
      final only = find.byKey(const ValueKey('access-only'));
      final alpha = find.byKey(const ValueKey('application-app.alpha'));
      expect(tester.widget<ChoiceChip>(only).onSelected, isNull);
      expect(tester.widget<CheckboxListTile>(alpha).onChanged, isNull);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('applications-save')))
            .onPressed,
        isNull,
      );
      expect(app.commands, isEmpty);
      expect(app.preferences.access, ApplicationAccess.all);
      expect(tester.widget<CheckboxListTile>(alpha).value, isFalse);
      expect(find.byTooltip(strings.storageContextChanged), findsOneWidget);
    },
  );

  for (final duringConfirmation in [false, true]) {
    testWidgets(
      'access draft keeps its original epoch and selections after restore duringConfirmation=$duringConfirmation',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final app = _EpochAccessApp(AccessBridge());
        addTearDown(app.dispose);
        await show(
          tester,
          MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: OperationFeedback(
              controller: app,
              child: ApplicationsPage(app: app),
            ),
          ),
          locale: const Locale('en'),
        );
        await tester.pumpAndSettle();
        final strings = AppLocalizations.of(
          tester.element(find.byType(ApplicationsPage)),
        );
        final save = find.byKey(const ValueKey('applications-save'));
        final alpha = find.byKey(const ValueKey('application-app.alpha'));
        final only = find.byKey(const ValueKey('access-only'));
        await tester.tap(only);
        await tester.pumpAndSettle();
        await tester.ensureVisible(alpha);
        await tester.tap(alpha);
        await tester.pumpAndSettle();
        final saveRect = tester.getRect(save);
        final rowRect = tester.getRect(alpha);
        void restore() {
          app.epoch = 2;
          app.preferences = const AppPreferences();
          app.publish(
            AppSnapshot(
              phase: app.state.phase,
              generation: app.state.generation,
              core: app.state.core,
              runningApplicationAccess: app.state.runningApplicationAccess,
              storageEpoch: app.epoch,
            ),
          );
        }

        VoidCallback? oldConfirm;
        if (duringConfirmation) {
          await tester.tap(save);
          await tester.pumpAndSettle();
          oldConfirm = tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, strings.applicationReconnect),
              )
              .onPressed!;
        }
        restore();
        expect(app.canChangePreferences, isTrue);
        for (final elapsed in [
          Duration.zero,
          const Duration(milliseconds: 16),
          const Duration(milliseconds: 80),
        ]) {
          await tester.pump(elapsed);
          expect(tester.getRect(save), saveRect);
          expect(tester.getRect(alpha), rowRect);
          expect(tester.widget<CheckboxListTile>(alpha).value, isTrue);
          expect(tester.widget<ChoiceChip>(only).selected, isTrue);
        }
        if (duringConfirmation) {
          // storageEpoch 变化已关闭旧弹窗，缓存的确认回调仍不能提交。
          oldConfirm!();
          await tester.pumpAndSettle();
        }
        expect(app.commands, isEmpty);
        expect(app.preferences.access, ApplicationAccess.all);
        expect(app.preferences.packages, isEmpty);
        expect(find.byTooltip(strings.storageContextChanged), findsOneWidget);
        expect(tester.widget<CheckboxListTile>(alpha).value, isTrue);
        expect(tester.widget<CheckboxListTile>(alpha).onChanged, isNull);
        expect(tester.widget<ChoiceChip>(only).selected, isTrue);
        expect(tester.widget<ChoiceChip>(only).onSelected, isNull);
        expect(tester.widget<TextButton>(save).onPressed, isNull);
        expect(tester.getRect(save), saveRect);
        expect(tester.getRect(alpha), rowRect);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(app.commands, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final locale in const [Locale('zh'), Locale('en')]) {
    for (final dark in const [false, true]) {
      testWidgets(
        'application list keeps controls stable locale=$locale dark=$dark',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final bridge = AccessBridge();
          final app = AccessApp(bridge);
          addTearDown(app.dispose);
          await show(
            tester,
            MediaQuery(
              data: MediaQueryData.fromView(tester.view)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: ApplicationsPage(app: app),
            ),
            locale: locale,
            dark: dark,
          );
          await tester.pumpAndSettle();
          // Verify the search row stays fixed while the system app is hidden.
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('application-app.alpha')),
            120,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.byKey(const ValueKey('application-app.alpha')), findsOne);
          expect(
            find.byKey(const ValueKey('application-android.system')),
            findsNothing,
          );
          final save = tester.getRect(
            find.byKey(const ValueKey('applications-save')),
          );
          await tester.tap(find.byKey(const ValueKey('access-only')));
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.byKey(const ValueKey('applications-save'))),
            save,
          );
          await tester.tap(find.byKey(const ValueKey('application-app.alpha')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const ValueKey('applications-save')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(
              AppLocalizations.of(tester.element(find.byType(ApplicationsPage)))
                  .applicationReconnect,
            ),
          );
          await tester.pumpAndSettle();
          expect(app.commands.single['action'], 'setApplicationAccess');
          expect(app.commands.single['access'], 'only');
          expect(app.commands.single['packages'], ['app.alpha']);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final language in ['zh', 'en']) {
    testWidgets(
      'saved access can retry without edits and status stays fixed $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final app = AccessApp(AccessBridge())
          ..preferences = const AppPreferences(
            access: ApplicationAccess.except,
            packages: ['app.alpha'],
          );
        addTearDown(app.dispose);
        await show(
          tester,
          MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: ApplicationsPage(app: app),
          ),
          locale: Locale(language),
        );
        await tester.pumpAndSettle();
        final strings = AppLocalizations.of(
          tester.element(find.byType(ApplicationsPage)),
        );
        final save = find.byKey(const ValueKey('applications-save'));
        final status = find.byKey(const ValueKey('applications-policy-status'));
        final search = find.byType(TextField);
        final row = find.byKey(const ValueKey('application-app.alpha'));
        final geometry = [
          tester.getRect(save),
          tester.getRect(status),
          tester.getRect(search),
          tester.getRect(row),
        ];
        void stable() {
          expect([
            tester.getRect(save),
            tester.getRect(status),
            tester.getRect(search),
            tester.getRect(row),
          ], geometry);
          expect(tester.takeException(), isNull);
        }

        expect(
          find.text(strings.applicationPolicyPendingShort),
          findsOneWidget,
        );
        expect(tester.widget<TextButton>(save).onPressed, isNotNull);
        await tester.tap(save);
        await tester.pumpAndSettle();
        stable();
        await tester.tap(find.text(strings.applicationReconnect));
        await tester.pumpAndSettle();
        expect(app.commands.single, {
          'action': 'setApplicationAccess',
          'storageEpoch': 0,
          'access': 'except',
          'packages': ['app.alpha'],
        });
        app.publish(const AppSnapshot(phase: 'RUNNING', writerBusy: true));
        await tester.pump();
        stable();
        expect(tester.widget<TextButton>(save).onPressed, isNull);
        app.publish(
          const AppSnapshot(
            phase: 'RUNNING',
            resultId: 'operation-1',
            resultSuccess: false,
          ),
        );
        await tester.pump();
        stable();
        expect(
          find.text(strings.applicationPolicyUnknownShort),
          findsOneWidget,
        );
        expect(tester.widget<TextButton>(save).onPressed, isNotNull);
        await tester.tap(save);
        await tester.pumpAndSettle();
        stable();
        await tester.tap(find.text(strings.applicationReconnect));
        await tester.pumpAndSettle();
        expect(app.commands, hasLength(2));
        expect(app.commands[1], app.commands[0]);
        app.publish(
          AppSnapshot(
            phase: 'RUNNING',
            generation: 1,
            runningApplicationAccess: RunningApplicationAccess(
              generation: 1,
              access: ApplicationAccess.except,
              packages: ['app.alpha'],
            ),
          ),
        );
        await tester.pump();
        stable();
        expect(
          find.text(strings.applicationPolicyAppliedShort),
          findsOneWidget,
        );
        expect(tester.widget<TextButton>(save).onPressed, isNull);
        app.publish(const AppSnapshot());
        await tester.pump();
        stable();
        expect(
          find.text(strings.applicationPolicyUnknownShort),
          findsOneWidget,
        );
        app.publish(const AppSnapshot(phase: 'STOPPED'));
        await tester.pump();
        stable();
        expect(
          find.text(strings.applicationPolicyNextConnectionShort),
          findsOneWidget,
        );
        expect(tester.widget<TextButton>(save).onPressed, isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final language in ['zh', 'en']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('应用范围读取进度和失败保持行与控件几何 $language $scale', (tester) async {
        tester.view.physicalSize = const Size(390, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final bridge = AccessBridge();
        final app = AccessApp(bridge);
        addTearDown(app.dispose);
        await show(
          tester,
          MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: ApplicationsPage(app: app),
          ),
          locale: Locale(language),
        );
        await tester.pumpAndSettle();
        final strings = AppLocalizations.of(
          tester.element(find.byType(ApplicationsPage)),
        );
        final row = find.byKey(const ValueKey('application-app.alpha'));
        final search = find.byType(TextField);
        final refresh = find.byKey(const ValueKey('applications-refresh'));
        final policy = find.byKey(const ValueKey('applications-policy-status'));
        final save = find.byKey(const ValueKey('applications-save'));
        final before = [
          tester.getRect(row),
          tester.getRect(search),
          tester.getRect(refresh),
          tester.getRect(policy),
          tester.getRect(save),
        ];
        final state = tester.state(find.byType(ApplicationsPage));
        void stable() {
          expect([
            tester.getRect(row),
            tester.getRect(search),
            tester.getRect(refresh),
            tester.getRect(policy),
            tester.getRect(save),
          ], before);
          expect(tester.state(find.byType(ApplicationsPage)), same(state));
          expect(tester.takeException(), isNull);
        }

        final pending = bridge.listReply =
            Completer<List<Map<String, dynamic>>>();
        await tester.tap(refresh);
        await tester.pump();
        stable();
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        pending.completeError(StateError('list original cause'));
        bridge.listReply = null;
        await tester.pumpAndSettle();
        stable();
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.applicationListFailed),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byIcon(Icons.close),
          ),
        );
        await tester.pumpAndSettle();
        bridge.fail = true;
        app.setForeground(false);
        app.setForeground(true);
        await tester.pumpAndSettle();
        stable();
        expect(find.byType(SnackBar), findsNothing);
        expect(app.commands, isEmpty);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('empty allow list is refused before submitting', (tester) async {
    final bridge = AccessBridge();
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('access-only')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('applications-save')));
    await tester.pumpAndSettle();
    expect(app.commands, isEmpty);
    expect(find.textContaining('至少需要选择一个'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed application list explains and retries', (tester) async {
    final bridge = AccessBridge()..fail = true;
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法读取'), findsOneWidget);
    bridge.fail = false;
    await tester.tap(find.byTooltip('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('application-app.alpha')), findsOne);
    await tester.pumpWidget(const SizedBox());
  });

  for (final failure in ['empty allow list', 'application list']) {
    testWidgets('an open $failure error follows the UI locale', (tester) async {
      final bridge = AccessBridge()..fail = failure == 'application list';
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      Widget page() => ApplicationsPage(app: app);
      String message(AppLocalizations strings) => switch (failure) {
        'empty allow list' => strings.applicationAllowEmpty,
        'application list' => strings.applicationListFailed,
        _ => strings.applicationListFailed,
      };
      await show(tester, page());
      await tester.pumpAndSettle();
      var strings = AppLocalizations.of(tester.element(find.byType(Scaffold)));
      switch (failure) {
        case 'empty allow list':
          await tester.tap(find.byKey(const ValueKey('access-only')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('applications-save')));
        case 'application list':
          break;
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(message(strings)),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(strings.errorDetails),
        ),
      );
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text(message(strings))),
        findsOneWidget,
      );
      await show(tester, page(), locale: const Locale('en'));
      await tester.pumpAndSettle();
      strings = AppLocalizations.of(tester.element(dialog));
      expect(
        find.descendant(of: dialog, matching: find.text(message(strings))),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('an accepted save never claims that reconnect has completed', (
    tester,
  ) async {
    final bridge = AccessBridge();
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('access-except')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('applications-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并重新连接'));
    await tester.pumpAndSettle();
    expect(app.commands.single['action'], 'setApplicationAccess');
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected save has one feedback owner and follows the locale', (
    tester,
  ) async {
    final app = AccessApp(AccessBridge())
      ..reject = true
      ..state = const AppSnapshot(phase: 'STOPPED');
    addTearDown(app.dispose);
    Widget page() => OperationFeedback(
      controller: app,
      child: ApplicationsPage(app: app),
    );
    await show(tester, page());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('access-except')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('applications-save')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    var strings = AppLocalizations.of(
      tester.element(find.byType(ApplicationsPage)),
    );
    expect(find.text(strings.requestNotAccepted), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(strings.errorDetails),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
    await show(tester, page(), locale: const Locale('en'));
    await tester.pumpAndSettle();
    strings = AppLocalizations.of(
      tester.element(find.byType(ApplicationsPage)),
    );
    expect(find.text(strings.requestNotAccepted), findsOneWidget);
    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
    await tester.tap(find.text(strings.close));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    expect(app.commands, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shared UID selections include hidden members as one group', (
    tester,
  ) async {
    final bridge = AccessBridge()
      ..installed = [
        {
          'package': 'shared.alpha',
          'label': 'Alpha',
          'system': false,
          'uid': 41,
        },
        {'package': 'shared.beta', 'label': 'Beta', 'system': false, 'uid': 41},
        {
          'package': 'shared.system',
          'label': 'System',
          'system': true,
          'uid': 41,
        },
      ];
    final app = AccessApp(bridge)..state = const AppSnapshot(phase: 'STOPPED');
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('access-only')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('application-shared.alpha')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('application-shared.beta')),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('applications-save')));
    await tester.pumpAndSettle();
    expect(app.commands.single['packages'], [
      'shared.alpha',
      'shared.beta',
      'shared.system',
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a saved shared UID group is not treated as an unsaved edit', (
    tester,
  ) async {
    final bridge = AccessBridge()
      ..installed = [
        {
          'package': 'shared.alpha',
          'label': 'Alpha',
          'system': false,
          'uid': 41,
        },
        {'package': 'shared.beta', 'label': 'Beta', 'system': false, 'uid': 41},
      ];
    final app = AccessApp(bridge)
      ..state = AppSnapshot(
        phase: 'RUNNING',
        runningApplicationAccess: RunningApplicationAccess(
          generation: 0,
          access: ApplicationAccess.only,
          packages: ['shared.alpha'],
        ),
      )
      ..preferences = const AppPreferences(
        access: ApplicationAccess.only,
        packages: ['shared.alpha'],
      );
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    for (final package in ['shared.alpha', 'shared.beta']) {
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(ValueKey('application-$package')),
            )
            .value,
        isTrue,
      );
    }
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('applications-save')))
          .onPressed,
      isNull,
    );
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'an uninstalled shared UID member does not expand a saved choice',
    (tester) async {
      final bridge = AccessBridge()
        ..installed = [
          {
            'package': 'shared.alpha',
            'label': 'Alpha',
            'system': false,
            'uid': 41,
          },
          {
            'package': 'shared.beta',
            'label': 'Beta',
            'system': false,
            'uid': 41,
          },
        ];
      final app = AccessApp(bridge)
        ..state = const AppSnapshot(phase: 'STOPPED')
        ..preferences = const AppPreferences(
          access: ApplicationAccess.only,
          packages: ['shared.alpha'],
        );
      addTearDown(app.dispose);
      await show(tester, ApplicationsPage(app: app));
      await tester.pumpAndSettle();
      bridge.installed = [bridge.installed.last];
      app.setForeground(false);
      app.setForeground(true);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('application-shared.beta')),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('applications-save')))
            .onPressed,
        isNull,
      );
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'uninstalled saved packages stay labelled and can be deselected',
    (tester) async {
      final bridge = AccessBridge();
      final app = AccessApp(bridge)
        ..state = const AppSnapshot(phase: 'STOPPED')
        ..preferences = const AppPreferences(
          access: ApplicationAccess.only,
          packages: ['app.alpha', 'gone.app'],
        );
      addTearDown(app.dispose);
      await show(tester, ApplicationsPage(app: app));
      await tester.pumpAndSettle();
      final missing = find.byKey(const ValueKey('application-gone.app'));
      expect(missing, findsOneWidget);
      expect(
        find.descendant(of: missing, matching: find.text('未安装')),
        findsOneWidget,
      );
      expect(tester.widget<CheckboxListTile>(missing).value, isTrue);
      expect(bridge.icons, isNot(contains('gone.app')));
      await tester.tap(find.byKey(const ValueKey('access-except')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('applications-save')));
      await tester.pumpAndSettle();
      expect(app.commands.last['packages'], ['app.alpha', 'gone.app']);
      final anchor = tester.getRect(missing);
      await tester.tap(missing);
      await tester.pump();
      expect(tester.getRect(missing), anchor);
      expect(tester.widget<CheckboxListTile>(missing).value, isFalse);
      await tester.pumpAndSettle();
      expect(tester.getRect(missing), anchor);
      await tester.tap(find.byKey(const ValueKey('applications-save')));
      await tester.pumpAndSettle();
      expect(app.commands.last['packages'], ['app.alpha']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recovered preferences initialize a draft that was not editable',
    (tester) async {
      final app = AccessApp(AccessBridge())
        ..state = const AppSnapshot(phase: 'STOPPED')
        ..preferencesLoaded = false;
      addTearDown(app.dispose);
      await show(tester, ApplicationsPage(app: app));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('access-only')))
            .onSelected,
        isNull,
      );
      app.preferences = const AppPreferences(
        access: ApplicationAccess.only,
        packages: ['app.alpha'],
      );
      app.preferencesLoaded = true;
      app.publish(app.state);
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('access-only')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('applications-save')))
            .onPressed,
        isNull,
      );
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a timed-out list cannot overwrite a successful retry', (
    tester,
  ) async {
    final late = Completer<List<Map<String, dynamic>>>();
    final bridge = AccessBridge()..listReply = late;
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.textContaining('无法读取'), findsOneWidget);
    bridge.listReply = null;
    bridge.installed = [
      {'package': 'current.app', 'label': 'Current', 'system': false},
    ];
    await tester.tap(find.byTooltip('重试'));
    await tester.pumpAndSettle();
    late.complete([
      {'package': 'obsolete.app', 'label': 'Obsolete', 'system': false},
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('application-current.app')), findsOne);
    expect(
      find.byKey(const ValueKey('application-obsolete.app')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('installation changes keep a surviving application anchored', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = [
      for (var index = 0; index < 80; index++)
        {
          'package': 'installed.$index',
          'label': 'Application ${index.toString().padLeft(2, '0')}',
          'system': false,
        },
    ];
    final bridge = AccessBridge()..installed = original;
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('application-installed.40'));
    await tester.scrollUntilVisible(
      row,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final anchor = tester.getRect(row);
    bridge.installed = [
      {'package': 'new.first', 'label': 'A new app', 'system': false},
      ...original,
    ];
    app.setForeground(false);
    app.setForeground(true);
    await tester.pump();
    expect(tester.getRect(row), anchor);
    await tester.pumpAndSettle();
    expect(tester.getRect(row), anchor);
    bridge.installed = original.sublist(5);
    app.setForeground(false);
    app.setForeground(true);
    await tester.pump();
    expect(tester.getRect(row), anchor);
    await tester.pumpAndSettle();
    expect(tester.getRect(row), anchor);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reading an application survives font and window adaptation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = AccessBridge()
      ..installed = [
        for (var index = 0; index < 80; index++)
          {
            'package': 'adaptation.$index',
            'label': 'Application ${index.toString().padLeft(2, '0')}',
            'system': false,
          },
      ];
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    Future<void> render(double scale, {Locale locale = const Locale('zh')}) =>
        show(
          tester,
          MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: ApplicationsPage(app: app),
          ),
          locale: locale,
        );
    await render(1);
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('application-adaptation.40'));
    await tester.scrollUntilVisible(
      row,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(row), alignment: 0.02);
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(row).dy;
    await render(2);
    await tester.pump();
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, closeTo(top, 0.01));
    tester.view.physicalSize = const Size(320, 700);
    await tester.pump();
    expect(tester.getTopLeft(row).dy, closeTo(top, 0.01));
    await render(2, locale: const Locale('en'));
    await tester.pump();
    expect(tester.getTopLeft(row).dy, closeTo(top, 0.01));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(row).dy, closeTo(top, 0.01));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 20000));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(TextField)).dy,
      greaterThanOrEqualTo(56),
    );
    await tester.showKeyboard(find.byType(TextField));
    await tester.pumpAndSettle();
    final search = tester.getRect(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Application 40');
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(TextField)), search);
    await tester.scrollUntilVisible(
      row,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(row, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search and selected chip states do not resize their controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AccessApp(AccessBridge());
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    final searchRect = tester.getRect(find.byType(TextField));
    final chipRect = tester.getRect(find.byKey(const ValueKey('access-only')));
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(TextField)), searchRect);
    await tester.tap(find.byKey(const ValueKey('access-only')));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('access-only'))), chipRect);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('application refresh failure retains rows and offers retry', (
    tester,
  ) async {
    final bridge = AccessBridge();
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('application-app.alpha'));
    final rowRect = tester.getRect(row);
    bridge.fail = true;
    app.setForeground(false);
    app.setForeground(true);
    await tester.pumpAndSettle();
    expect(bridge.listCalls, 2);
    expect(tester.getRect(row), rowRect);
    expect(find.textContaining('无法读取'), findsOneWidget);
    bridge.fail = false;
    await tester.tap(find.byTooltip('重试'));
    await tester.pumpAndSettle();
    expect(bridge.listCalls, 3);
    expect(tester.getRect(row), rowRect);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('icons are released with their page instead of cached globally', (
    tester,
  ) async {
    final png = (await tester.runAsync(createApplicationPng))!;
    final bridge = AccessBridge()
      ..installed = [
        {'package': 'icon.page.test', 'label': 'Page icon', 'system': false},
      ]
      ..iconReply = (_) async => png;
    final app = AccessApp(bridge);
    addTearDown(app.dispose);
    await show(tester, ApplicationsPage(app: app));
    await tester.runAsync(
      () => precacheImage(
        MemoryImage(png),
        tester.element(find.byType(ApplicationsPage)),
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.icons, ['icon.page.test']);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 2);
    await tester.pumpWidget(const SizedBox());
    await show(tester, ApplicationsPage(app: app));
    await tester.pumpAndSettle();
    expect(bridge.icons, ['icon.page.test', 'icon.page.test']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final valid in [true, false]) {
    testWidgets(
      'icon bytes keep both rows and 32px slots stable valid=$valid',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final png = (await tester.runAsync(createApplicationPng))!;
        final first = Completer<Uint8List?>();
        final second = Completer<Uint8List?>();
        final bridge = AccessBridge()
          ..installed = [
            {
              'package': 'icon.first',
              'label': 'First application',
              'system': false,
            },
            {
              'package': 'icon.next',
              'label': 'Next application',
              'system': false,
            },
          ]
          ..iconReply = (package) =>
              package == 'icon.first' ? first.future : second.future;
        final app = AccessApp(bridge);
        addTearDown(app.dispose);
        await show(
          tester,
          MediaQuery(
            data: MediaQueryData.fromView(tester.view)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: ApplicationsPage(app: app),
          ),
          dark: !valid,
        );
        await tester.pumpAndSettle();
        final row = find.byKey(const ValueKey('application-icon.first'));
        final next = find.byKey(const ValueKey('application-icon.next'));
        final icon = find.descendant(
          of: row,
          matching: find.byType(ApplicationIcon),
        );
        final nextIcon = find.descendant(
          of: next,
          matching: find.byType(ApplicationIcon),
        );
        final controls = [icon, row, nextIcon, next];
        final before = controls.map(tester.getRect).toList();
        expect(before[0].size, const Size(32, 32));
        expect(before[2].size, const Size(32, 32));
        expect(
          find.descendant(of: icon, matching: find.byIcon(Icons.apps)),
          findsOneWidget,
        );
        await tester.runAsync(
          () => precacheImage(MemoryImage(png), tester.element(row)),
        );
        first.complete(valid ? png : Uint8List.fromList([0, 1, 2, 3]));
        second.complete(png);
        for (final elapsed in [
          Duration.zero,
          const Duration(milliseconds: 16),
          const Duration(milliseconds: 80),
        ]) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(elapsed);
          for (var i = 0; i < controls.length; i++) {
            expect(tester.getRect(controls[i]), before[i]);
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        if (valid) {
          final image = find.descendant(
            of: icon,
            matching: find.byType(RawImage),
          );
          expect(tester.widget<RawImage>(image).image!.width, 2);
          expect(tester.widget<RawImage>(image).image!.height, 2);
        } else {
          expect(
            find.descendant(of: icon, matching: find.byIcon(Icons.apps)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: icon, matching: find.byType(RawImage)),
            findsNothing,
          );
        }
        expect(bridge.icons, ['icon.first', 'icon.next']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'obsolete and disposed icon futures cannot replace the current PNG',
    (tester) async {
      final png = (await tester.runAsync(createApplicationPng))!;
      final old = Completer<Uint8List?>();
      final fresh = Completer<Uint8List?>();
      final disposed = Completer<Uint8List?>();
      final source = ValueNotifier<Future<Uint8List?>>(old.future);
      addTearDown(source.dispose);
      const iconKey = ValueKey('late-application-icon');
      const rowKey = ValueKey('late-application-row');
      const nextKey = ValueKey('late-application-next-row');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ListTile(
                  key: rowKey,
                  leading: ValueListenableBuilder<Future<Uint8List?>>(
                    valueListenable: source,
                    builder: (_, value, _) => ApplicationIcon(
                      key: iconKey,
                      icon: value,
                      fallback: Icons.apps,
                      color: Colors.blue,
                    ),
                  ),
                  title: const Text('Current row'),
                ),
                const ListTile(key: nextKey, title: Text('Next row')),
              ],
            ),
          ),
        ),
      );
      final controls = [
        find.byKey(iconKey),
        find.byKey(rowKey),
        find.byKey(nextKey),
      ];
      final before = controls.map(tester.getRect).toList();
      expect(before[0].size, const Size(32, 32));
      await tester.runAsync(
        () =>
            precacheImage(MemoryImage(png), tester.element(find.byKey(rowKey))),
      );
      source.value = fresh.future;
      await tester.pump();
      fresh.complete(png);
      await tester.pumpAndSettle();
      final raw = find.descendant(
        of: find.byKey(iconKey),
        matching: find.byType(RawImage),
      );
      expect(tester.widget<RawImage>(raw).image!.width, 2);
      old.complete(Uint8List.fromList([0, 1, 2, 3]));
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 80),
      ]) {
        await tester.pump(elapsed);
        for (var i = 0; i < controls.length; i++) {
          expect(tester.getRect(controls[i]), before[i]);
        }
        expect(tester.widget<RawImage>(raw).image!.width, 2);
        expect(find.byIcon(Icons.apps), findsNothing);
        expect(tester.takeException(), isNull);
      }
      source.value = disposed.future;
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      disposed.complete(Uint8List.fromList([0, 1, 2, 3]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'icon cache hits recent entries and evicts only after its 32-entry capacity',
    (tester) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final png = (await tester.runAsync(createApplicationPng))!;
      final listed = Completer<List<Map<String, dynamic>>>();
      final bridge = AccessBridge()
        ..listReply = listed
        ..iconReply = (_) async => png;
      final app = AccessApp(bridge);
      addTearDown(app.dispose);
      await show(tester, ApplicationsPage(app: app));
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(png),
          tester.element(find.byType(ApplicationsPage)),
        ),
      );
      final search = find.byType(TextField);
      String package(int index) => 'icon.bounded.$index.item';
      await tester.enterText(search, package(0));
      listed.complete([
        for (var index = 0; index < 40; index++)
          {
            'package': package(index),
            'label': 'Application $index',
            'system': false,
          },
      ]);
      await tester.pumpAndSettle();
      expect(bridge.icons, [package(0)]);
      final row = find.byKey(ValueKey('application-${package(0)}'));
      final slot = find.descendant(
        of: row,
        matching: find.byType(ApplicationIcon),
      );
      final rowRect = tester.getRect(row);
      final slotRect = tester.getRect(slot);
      expect(slotRect.size, const Size(32, 32));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 2);
      await tester.enterText(search, '');
      await tester.pumpAndSettle();
      final next = find.byKey(ValueKey('application-${package(1)}'));
      final nextSlot = find.descendant(
        of: next,
        matching: find.byType(ApplicationIcon),
      );
      final nextRect = tester.getRect(next);
      final nextSlotRect = tester.getRect(nextSlot);
      expect(tester.getRect(row), rowRect);
      expect(tester.getRect(slot), slotRect);
      expect(nextSlotRect.size, const Size(32, 32));
      Future<void> filter(int index) async {
        await tester.enterText(search, package(index));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('application-${package(index)}')),
          findsOneWidget,
        );
      }

      int calls(int index) =>
          bridge.icons.where((name) => name == package(index)).length;
      for (var index = 1; index < 32; index++) {
        await filter(index);
      }
      expect(bridge.icons, [
        for (var index = 0; index < 32; index++) package(index),
      ]);
      await filter(0);
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 80),
      ]) {
        await tester.pump(elapsed);
        expect(tester.getRect(row), rowRect);
        expect(tester.getRect(slot), slotRect);
        expect(calls(0), 1);
      }
      await filter(1);
      expect(calls(1), 1);
      expect(bridge.icons, hasLength(32));
      await filter(32);
      expect(bridge.icons, hasLength(33));
      expect(calls(32), 1);
      await filter(0);
      await filter(1);
      expect(calls(0), 1);
      expect(calls(1), 1);
      await filter(2);
      expect(calls(2), 2);
      expect(bridge.icons, hasLength(34));
      await tester.enterText(search, '');
      for (final elapsed in [
        Duration.zero,
        const Duration(milliseconds: 16),
        const Duration(milliseconds: 80),
      ]) {
        await tester.pump(elapsed);
        expect(tester.getRect(row), rowRect);
        expect(tester.getRect(slot), slotRect);
        expect(tester.getRect(next), nextRect);
        expect(tester.getRect(nextSlot), nextSlotRect);
        expect(calls(0), 1);
        expect(calls(1), 1);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
