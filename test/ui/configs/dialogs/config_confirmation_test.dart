import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

import 'dart:convert';

import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/ui/components/feedback/confirm_action.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/import_dialog.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImportApp extends AppController {
  _ImportApp(AppSnapshot snapshot, String selected) : super(AppBridge()) {
    loading = false;
    configsLoaded = true;
    state = snapshot;
    collection = ConfigCollection(
      entries: const [
        ConfigEntry(
          id: 'target',
          name: '包含中文与 English 的长配置名称',
          source: 'https://fixture.test/config',
          revision: 1,
          body: 'rules: []',
        ),
        ConfigEntry(
          id: 'other',
          name: 'Other',
          source: 'https://fixture.test/other',
          revision: 1,
          body: '',
        ),
      ],
      selectedId: selected,
    );
  }
  final commands = <Map<String, Object?>>[];
  @override
  Future<String?> submit(
    Map<String, Object?> command, {
    bool automatic = false,
  }) async {
    commands.add(command);
    return 'accepted';
  }
}

void main() {
  for (final departure in ['task', 'background', 'pop']) {
    testWidgets(
      'openImport rejects cached overview-style submission after $departure before a frame',
      (tester) async {
        final app = _ImportApp(const AppSnapshot(phase: 'STOPPED'), 'target');
        addTearDown(app.dispose);
        var active = true;
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) => AppTaskActivity(
              active: true,
              isActiveNow: () => active,
              isActiveWithPopup: (_) => active,
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openImport(
                    context,
                    app,
                    source: 'https://fixture.test/config',
                  ),
                  child: const Text('Open import'),
                ),
              ),
            ),
          ),
        );
        final origin = ModalRoute.of(tester.element(find.text('Open import')))!;
        await tester.tap(find.text('Open import'));
        await tester.pumpAndSettle();
        final cached = tester
            .widget<FilledButton>(find.byType(FilledButton))
            .onPressed!;
        if (departure == 'task') {
          active = false;
        } else if (departure == 'background') {
          app.setForeground(false);
        } else {
          ModalRoute.of(tester.element(find.byType(ImportDialog)))!.navigator!
              .pop();
        }
        cached();
        expect(app.commands, isEmpty);
        expect(origin.isActive, isTrue);
        await tester.pump(const Duration(milliseconds: 16));
        cached();
        expect(app.commands, isEmpty);
        expect(origin.isActive, isTrue);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (confirm, timing) in [
    (false, 'cached'),
    (true, 'cached'),
    (false, 'frame'),
    (true, 'frame'),
    (true, 'after-accept'),
  ]) {
    testWidgets(
      'confirmation source expiry returns false without submission confirm=$confirm timing=$timing',
      (tester) async {
        final app = _ImportApp(
          const AppSnapshot(phase: 'STOPPED', storageEpoch: 1),
          'target',
        );
        addTearDown(app.dispose);
        final sourceEpoch = app.state.storageEpoch;
        bool? answer;
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    answer = await confirmAction(
                      context,
                      title: (strings) => strings.deleteConfigTitle,
                      message: (strings) => strings.deleteLocalBody,
                      confirmLabel: (strings) => strings.delete,
                      isCurrent: () => app.state.storageEpoch == sourceEpoch,
                    );
                    if (answer == true) {
                      await app.submit({
                        'action': 'delete',
                        'id': 'target',
                        'storageEpoch': sourceEpoch,
                      });
                    }
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        final owner = ModalRoute.of(tester.element(find.text('Open')))!;
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final button = find.descendant(
          of: find.byType(AlertDialog),
          matching: confirm
              ? find.byType(FilledButton)
              : find.byType(TextButton),
        );
        final cached = confirm
            ? tester.widget<FilledButton>(button).onPressed!
            : tester.widget<TextButton>(button).onPressed!;
        if (timing == 'after-accept') {
          cached();
          app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
        } else {
          app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 2);
          if (timing == 'frame') {
            await tester.pump(const Duration(milliseconds: 16));
            await tester.tap(button);
          } else {
            cached();
          }
        }
        await tester.pumpAndSettle();
        expect(answer, isFalse);
        expect(app.commands, isEmpty);
        expect(app.collection.find('target')!.body, 'rules: []');
        expect(owner.isActive, isTrue);
        expect(owner.isCurrent, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (
      const AppSnapshot(phase: 'RUNNING', configId: 'target'),
      'other',
      '更新成功后，若运行内容改变，将重新连接此配置的接管。',
    ),
    (
      const AppSnapshot(phase: 'RUNNING', configId: 'other'),
      'target',
      '不会切换或停止其他配置的接管。',
    ),
    (const AppSnapshot(phase: 'STOPPED'), 'target', '更新后不会自动启动接管。'),
    (const AppSnapshot(), 'target', '连接状态尚未确认；更新将按实际运行状态处理。'),
  ]) {
    testWidgets(
      'same-source import does not replace an existing ID ${scenario.$1.phase}/${scenario.$2}',
      (tester) async {
        final app = _ImportApp(scenario.$1, scenario.$2);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          MaterialApp(
            navigatorObservers: [AppTaskNavigatorObserver()],
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            theme: AppTheme.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openImport(
                    context,
                    app,
                    source: 'https://fixture.test/config',
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载并保存'));
        await tester.pumpAndSettle();
        expect(find.text('覆盖更新配置？'), findsNothing);
        expect(app.commands, hasLength(1));
        expect(app.commands.single['action'], 'import');
        expect(app.commands.single['source'], 'https://fixture.test/config');
        expect(app.commands.single.containsKey('id'), isFalse);
        expect(app.commands.single.containsKey('replace'), isFalse);
        expect(app.collection.find('target')!.body, 'rules: []');
        expect(app.collection.entries, hasLength(2));
        expect(find.byType(ImportDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('import validation preserves anchors $language/$scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final strings = lookupAppLocalizations(Locale(language));
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
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<Map<String, Object?>>(
                    context: context,
                    builder: (dialogContext) => OperationNoticeHost(
                      onDismiss: () => Navigator.of(dialogContext).maybePop(),
                      child: const ImportDialog(),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final source = find.byType(TextField).first;
        final sourceDecoration = tester.widget<TextField>(source).decoration!;
        expect(sourceDecoration.helper, isNull);
        expect(sourceDecoration.helperText, isNull);
        expect(sourceDecoration.error, isNull);
        expect(sourceDecoration.errorText, isNull);
        final controller = tester.widget<TextField>(source).controller!;
        final state = tester.state(source);
        await tester.enterText(source, 'ftp://fixture.test/config');
        await tester.pumpAndSettle();
        final anchors = [
          find.text(strings.importFullConfig),
          source,
          find.byType(TextField).last,
          find.widgetWithText(FilledButton, strings.downloadAndSave),
          find.widgetWithText(TextButton, strings.cancel),
        ];
        final rects = anchors.map(tester.getRect).toList();
        Future<void> expectStableFrames() async {
          for (var frame = 0; frame < 16; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            for (var i = 0; i < anchors.length; i++) {
              expect(tester.getRect(anchors[i]), rects[i]);
            }
            expect(
              tester.widget<TextField>(source).controller,
              same(controller),
            );
            expect(tester.state(source), same(state));
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        }

        await tester.tap(anchors[3]);
        await expectStableFrames();
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.byType(ImportDialog), findsOneWidget);
        expect(
          tester.widget<TextField>(source).controller!.text,
          'ftp://fixture.test/config',
        );
        await tester.enterText(source, 'http://fixture.test/config');
        await expectStableFrames();
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(find.byTooltip(strings.showUrl));
        await expectStableFrames();
        expect(tester.widget<TextField>(source).obscureText, isFalse);
        await tester.tap(anchors.last);
        await tester.pumpAndSettle();
      });
    }
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'import validation locates the first error and preserves input and actual submission $language/$scale',
        (tester) async {
          tester.view.physicalSize = const Size(800, 1400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final submitted = <Map<String, Object?>>[];
          final strings = lookupAppLocalizations(Locale(language));
          await tester.pumpWidget(
            MaterialApp(
              navigatorObservers: [AppTaskNavigatorObserver()],
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: AppTheme.light,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (dialogContext) => OperationNoticeHost(
                        onDismiss: () => Navigator.of(dialogContext).maybePop(),
                        child: ImportDialog(
                          source: 'ftp://fixture.test/config#section',
                          fragment: true,
                          proxyName: 'invalid,target',
                          storageEpoch: 17,
                          onSubmit: (input) async {
                            submitted.add(input);
                            return false;
                          },
                        ),
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final source = find.byKey(const ValueKey('import-source'));
          final proxy = find.byKey(const ValueKey('loon-proxy-name'));
          final name = find.byType(TextField).at(1);
          final fields = [source, name, proxy];
          final controllers = fields
              .map((field) => tester.widget<TextField>(field).controller!)
              .toList();
          final states = fields.map(tester.state).toList();
          final formState = tester.state(find.byType(ImportDialog));
          final save = find.widgetWithText(
            FilledButton,
            strings.downloadAndSave,
          );
          final cancel = find.widgetWithText(TextButton, strings.cancel);
          final anchors = [
            find.text(strings.remoteOverride),
            ...fields,
            find.byKey(const ValueKey('loon-no-resolve')),
            save,
            cancel,
          ];
          final sourceDecoration = tester.widget<TextField>(source).decoration!;
          expect(sourceDecoration.helper, isNull);
          expect(sourceDecoration.helperText, isNull);
          final proxyDecoration = tester.widget<TextField>(proxy).decoration!;
          expect(
            (proxyDecoration.helper! as Text).data,
            strings.loonProxyNameHint,
          );
          expect(proxyDecoration.helper, isNot(isA<SizedBox>()));
          expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(cancel).height, greaterThanOrEqualTo(48));
          await tester.showKeyboard(source);
          controllers[0].value = TextEditingValue(
            text: controllers[0].text,
            selection: const TextSelection(baseOffset: 6, extentOffset: 13),
            composing: const TextRange(start: 6, end: 13),
          );
          await tester.pumpAndSettle();
          var rectangles = anchors.map(tester.getRect).toList();
          Future<void> unchanged(
            int index,
            TextEditingValue value,
            List<Rect> expected,
          ) async {
            final focus = tester.widget<TextField>(fields[index]).focusNode!;
            for (final milliseconds in [0, 16, 100, 200]) {
              await tester.pump(Duration(milliseconds: milliseconds));
              expect(anchors.map(tester.getRect).toList(), expected);
              expect(fields.map(tester.state).toList(), states);
              expect(tester.state(find.byType(ImportDialog)), same(formState));
              expect(
                fields
                    .map((field) => tester.widget<TextField>(field).controller)
                    .toList(),
                controllers,
              );
              expect(controllers[index].value, same(value));
              expect(controllers[index].selection, value.selection);
              expect(controllers[index].value.composing, value.composing);
              expect(focus.hasFocus, isTrue);
              expect(find.byType(AlertDialog), findsOneWidget);
              expect(tester.takeException(), isNull);
            }
          }

          final sourceValue = controllers[0].value;
          tester.widget<FilledButton>(save).onPressed!();
          await unchanged(0, sourceValue, rectangles);
          await tester.pumpAndSettle();
          final notice = find.byType(SnackBar);
          expect(notice, findsOneWidget);
          expect(
            tester.getSemantics(source).getSemanticsData().validationResult,
            SemanticsValidationResult.invalid,
          );
          expect(
            tester.getSemantics(proxy).getSemanticsData().validationResult,
            SemanticsValidationResult.none,
          );
          expect(tester.widget<TextField>(proxy).focusNode!.hasFocus, isFalse);
          expect(
            find.descendant(of: notice, matching: find.byType(TextButton)),
            findsNothing,
          );
          final oldClose = tester
              .widget<IconButton>(
                find.descendant(of: notice, matching: find.byType(IconButton)),
              )
              .onPressed!;
          await tester.tap(
            find.descendant(of: notice, matching: find.byIcon(Icons.close)),
          );
          await unchanged(0, sourceValue, rectangles);
          await tester.pumpAndSettle();
          expect(notice, findsNothing);
          const validSource = 'https://fixture.test/config#section';
          await tester.enterText(source, validSource);
          await tester.pumpAndSettle();
          expect(
            tester.getSemantics(source).getSemanticsData().validationResult,
            SemanticsValidationResult.none,
          );
          tester.widget<FilledButton>(save).onPressed!();
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(proxy).focusNode!.hasFocus, isTrue);
          expect(tester.widget<TextField>(source).focusNode!.hasFocus, isFalse);
          expect(
            tester.getSemantics(proxy).getSemanticsData().validationResult,
            SemanticsValidationResult.invalid,
          );
          expect(notice, findsOneWidget);
          final currentNotice = tester.element(notice);
          oldClose();
          await tester.pumpAndSettle();
          expect(tester.element(notice), same(currentNotice));
          final decoration = tester.widget<TextField>(proxy).decoration!;
          expect((decoration.helper! as Text).data, strings.loonProxyNameHint);
          expect(decoration.error, isNull);
          expect(decoration.errorText, isNull);
          expect(
            decoration.focusedBorder!.borderSide.color,
            AppTheme.light.colorScheme.error,
          );
          controllers[2].value = TextEditingValue(
            text: controllers[2].text,
            selection: const TextSelection(baseOffset: 1, extentOffset: 5),
            composing: const TextRange(start: 1, end: 5),
          );
          await tester.pumpAndSettle();
          final proxyValue = controllers[2].value;
          rectangles = anchors.map(tester.getRect).toList();
          await tester.tap(
            find.descendant(of: notice, matching: find.byIcon(Icons.close)),
          );
          await unchanged(2, proxyValue, rectangles);
          await tester.pumpAndSettle();
          tester.widget<FilledButton>(save).onPressed!();
          await unchanged(2, proxyValue, rectangles);
          await tester.pumpAndSettle();
          expect(notice, findsOneWidget);
          expect(submitted, isEmpty);
          const validProxy = '策略 🙂';
          const validName = '导入配置 🌐';
          await tester.enterText(proxy, validProxy);
          await tester.pumpAndSettle();
          expect(notice, findsNothing);
          expect(
            tester.getSemantics(proxy).getSemanticsData().validationResult,
            SemanticsValidationResult.none,
          );
          await tester.enterText(name, validName);
          await tester.tap(find.byKey(const ValueKey('loon-no-resolve')));
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(submitted, [
            {
              'source': validSource,
              'name': validName,
              'proxyName': validProxy,
              'addNoResolve': true,
              'storageEpoch': 17,
            },
          ]);
          expect(fields.map(tester.state).toList(), states);
          expect(controllers.map((controller) => controller.text).toList(), [
            validSource,
            validName,
            validProxy,
          ]);
          await tester.tap(cancel);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(tester.takeException(), isNull);
        },
        semanticsEnabled: true,
      );
    }
  }

  testWidgets('optional import name uses business length without truncation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: ImportDialog()),
      ),
    );
    final field = find.byType(TextField).last;
    final boundary = '${'👨‍👩‍👧‍👦' * 3}abcde';
    expect(utf8.encode(boundary).length, 80);
    for (final name in [
      boundary,
      '$boundary🌐',
      '${'👨‍👩‍👧‍👦' * 11}abc',
      '',
    ]) {
      await tester.enterText(field, name);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, name);
      expect(find.text('${utf8.encode(name).length}/80 B'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
            null,
        utf8.encode(name).length <= 80,
      );
    }
  });
}
