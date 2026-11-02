import 'dart:convert';

import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/configs/dialogs/config_field_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'cached field confirmation and cancel cannot pop the page during reverse',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Open'),
                onPressed: () => showDialog<String>(
                  context: context,
                  builder: (_) => const ConfigFieldDialog(initial: 'Original'),
                ),
              ),
            ),
          ),
        ),
      );
      final owner = ModalRoute.of(tester.element(find.text('Open')))!;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(const Locale('en'));
      final save = tester
          .widget<TextButton>(find.widgetWithText(TextButton, strings.save))
          .onPressed!;
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, strings.cancel))
          .onPressed!;
      navigator.currentState!.pop();
      save();
      cancel();
      expect(owner.isActive, isTrue);
      expect(owner.isCurrent, isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      save();
      cancel();
      expect(owner.isActive, isTrue);
      final dialog = find.byType(ConfigFieldDialog, skipOffstage: false);
      expect(
        tester
            .widgetList<IgnorePointer>(
              find.descendant(of: dialog, matching: find.byType(IgnorePointer)),
            )
            .any((widget) => widget.ignoring),
        isTrue,
      );
      expect(
        tester
            .widgetList<ExcludeFocus>(
              find.descendant(of: dialog, matching: find.byType(ExcludeFocus)),
            )
            .any((widget) => widget.excluding),
        isTrue,
      );
      expect(
        tester
            .widgetList<ExcludeSemantics>(
              find.descendant(
                of: dialog,
                matching: find.byType(ExcludeSemantics),
              ),
            )
            .any((widget) => widget.excluding),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('URL 校验提示开合保留输入状态与动作位置 $language/$scale', (tester) async {
        final submitted = <String>[];
        await tester.pumpWidget(
          MaterialApp(
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
                      child: ConfigFieldDialog(
                        source: true,
                        initial: 'ftp://fixture.test/config#section',
                        onSubmit: (value) async {
                          submitted.add(value);
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
        final strings = lookupAppLocalizations(Locale(language));
        final field = find.byType(TextField);
        final controller = tester.widget<TextField>(field).controller!;
        final input = tester.widget<EditableText>(find.byType(EditableText));
        await tester.showKeyboard(field);
        controller.value = TextEditingValue(
          text: controller.text,
          selection: const TextSelection(baseOffset: 6, extentOffset: 13),
          composing: const TextRange(start: 6, end: 13),
        );
        await tester.pump();
        final value = controller.value;
        final state = tester.state(field);
        final dialogState = tester.state(find.byType(ConfigFieldDialog));
        final save = find.widgetWithText(TextButton, strings.saveAndUpdate);
        final targets = [
          field,
          save,
          find.widgetWithText(TextButton, strings.cancel),
          find.text(strings.changeConfigSource),
          find.byTooltip(strings.showUrl),
        ];
        final rectangles = targets.map(tester.getRect).toList();
        expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
        expect(input.focusNode.hasFocus, isTrue);
        Future<void> unchanged() async {
          for (final milliseconds in [0, 16, 100, 200]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(targets.map(tester.getRect).toList(), rectangles);
            expect(tester.state(field), same(state));
            expect(
              tester.state(find.byType(ConfigFieldDialog)),
              same(dialogState),
            );
            expect(
              tester.widget<TextField>(field).controller,
              same(controller),
            );
            expect(controller.value, same(value));
            expect(controller.selection, value.selection);
            expect(controller.value.composing, value.composing);
            expect(input.focusNode.hasFocus, isTrue);
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        }

        tester.widget<TextButton>(save).onPressed!();
        await unchanged();
        await tester.pumpAndSettle();
        final notice = find.byType(SnackBar);
        expect(notice, findsOneWidget);
        expect(
          find.descendant(of: notice, matching: find.byType(TextButton)),
          findsNothing,
        );
        expect(
          tester.getSemantics(field).getSemanticsData().validationResult,
          SemanticsValidationResult.invalid,
        );
        final decoration = tester.widget<TextField>(field).decoration!;
        expect(decoration.helper, isNull);
        expect(decoration.error, isNull);
        expect(decoration.errorText, isNull);
        expect(
          decoration.focusedBorder!.borderSide.color,
          AppTheme.light.colorScheme.error,
        );
        final close = find.descendant(
          of: notice,
          matching: find.byIcon(Icons.close),
        );
        final oldClose = tester
            .widget<IconButton>(
              find.ancestor(of: close, matching: find.byType(IconButton)),
            )
            .onPressed!;
        await tester.tap(close);
        await unchanged();
        await tester.pumpAndSettle();
        expect(notice, findsNothing);
        tester.widget<TextButton>(save).onPressed!();
        await tester.pumpAndSettle();
        final current = tester.element(notice);
        oldClose();
        await tester.pumpAndSettle();
        expect(tester.element(notice), same(current));
        expect(controller.value, same(value));
        expect(submitted, isEmpty);
        const valid = 'https://fixture.test/config#section';
        await tester.enterText(field, valid);
        await tester.pumpAndSettle();
        expect(notice, findsNothing);
        expect(targets.map(tester.getRect).toList(), rectangles);
        expect(
          tester.getSemantics(field).getSemanticsData().validationResult,
          SemanticsValidationResult.none,
        );
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(submitted, [valid]);
        expect(controller.text, valid);
        expect(find.byType(ConfigFieldDialog), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, strings.cancel));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      }, semanticsEnabled: true);
    }
  }

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      for (final width in [320.0, 411.0, 800.0]) {
        for (final source in [false, true]) {
          testWidgets(
            'field validation and geometry $dark $scale $width source=$source',
            (tester) async {
              tester.view.physicalSize = Size(width, 800);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              String? result;
              await tester.pumpWidget(
                MaterialApp(
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  locale: const Locale('zh'),
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () async {
                          result = await showDialog<String>(
                            context: context,
                            builder: (dialogContext) => OperationNoticeHost(
                              onDismiss: () =>
                                  Navigator.of(dialogContext).maybePop(),
                              child: ConfigFieldDialog(
                                initial: source
                                    ? 'https://fixture.test/a'
                                    : 'Local',
                                source: source,
                              ),
                            ),
                          );
                        },
                        child: const Text('打开'),
                      ),
                    ),
                  ),
                ),
              );
              await tester.tap(find.text('打开'));
              await tester.pumpAndSettle();
              final field = find.byType(TextField);
              final controller = tester.widget<TextField>(field).controller!;
              final fieldState = tester.state(field);
              if (source) {
                final decoration = tester.widget<TextField>(field).decoration!;
                expect(decoration.helper, isNull);
                expect(decoration.helperText, isNull);
                expect(decoration.error, isNull);
                expect(decoration.errorText, isNull);
                expect(find.text('请输入完整的 HTTP 或 HTTPS 配置 URL。'), findsNothing);
              }
              final button = find.widgetWithText(
                TextButton,
                source ? '保存并更新' : '保存',
              );
              final rect = tester.getRect(button);
              final fieldRect = tester.getRect(field);
              final cancelRect = tester.getRect(find.text('取消'));
              final title = find.text(source ? '修改配置来源' : '重命名配置');
              final titleRect = tester.getRect(title);
              final originalLong = '${'👨‍👩‍👧‍👦' * 11}abc';
              expect(originalLong.runes.length, 80);
              final boundary = '${'👨‍👩‍👧‍👦' * 3}abcde';
              expect(utf8.encode(boundary).length, 80);
              final values = source
                  ? [
                      '',
                      'https://fixture.test/${'long-path/' * 30}',
                      'https://fixture.test/b',
                    ]
                  : [
                      ' ',
                      'closeout-remote-final-renamed',
                      boundary,
                      '$boundary🌐',
                      originalLong,
                      '${'中' * 26}ab',
                      '中' * 27,
                      boundary,
                    ];
              for (final value in values) {
                await tester.enterText(field, value);
                if (source && value.isEmpty) {
                  await tester.tap(button);
                  await tester.pump();
                  expect(result, isNull);
                  expect(find.byType(ConfigFieldDialog), findsOneWidget);
                  expect(
                    tester.widget<TextField>(field).controller!.text,
                    value,
                  );
                }
                for (var frame = 0; frame < 14; frame++) {
                  await tester.pump(const Duration(milliseconds: 16));
                  expect(tester.getRect(button), rect);
                  expect(tester.getRect(field), fieldRect);
                  expect(tester.getRect(find.text('取消')), cancelRect);
                  expect(tester.getRect(title), titleRect);
                  expect(tester.state(field), same(fieldState));
                  expect(
                    tester.widget<TextField>(field).controller,
                    same(controller),
                  );
                  expect(find.byType(AlertDialog), findsOneWidget);
                  expect(tester.takeException(), isNull);
                }
                if (source && value.isEmpty) {
                  expect(find.byType(SnackBar), findsOneWidget);
                }
                final length = utf8.encode(value).length;
                if (!source) expect(find.text('$length/80 B'), findsOneWidget);
                expect(tester.widget<TextField>(field).controller!.text, value);
                expect(
                  tester.widget<TextButton>(button).onPressed != null,
                  source || (value.trim().isNotEmpty && length <= 80),
                );
              }
              await tester.tap(button);
              await tester.pumpAndSettle();
              expect(result, values.last);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }
}
