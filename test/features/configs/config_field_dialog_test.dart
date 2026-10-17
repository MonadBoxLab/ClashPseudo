import 'package:clash_pseudo/app/app_theme.dart';
import 'package:clash_pseudo/features/configs/widgets/config_field_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
                            builder: (_) => ConfigFieldDialog(
                              initial: source
                                  ? 'https://fixture.test/a'
                                  : 'Local',
                              source: source,
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
              final button = find.widgetWithText(
                TextButton,
                source ? '保存并更新' : '保存',
              );
              final rect = tester.getRect(button);
              final fieldRect = tester.getRect(field);
              final cancelRect = tester.getRect(find.text('取消'));
              final title = find.text(source ? '修改配置来源' : '重命名配置');
              final titleRect = tester.getRect(title);
              final boundary = '${'👨‍👩‍👧‍👦' * 11}abc';
              expect(boundary.runes.length, 80);
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
                      boundary,
                    ];
              for (final value in values) {
                await tester.enterText(field, value);
                for (var frame = 0; frame < 14; frame++) {
                  await tester.pump(const Duration(milliseconds: 16));
                  expect(tester.getRect(button), rect);
                  expect(tester.getRect(field), fieldRect);
                  expect(tester.getRect(find.text('取消')), cancelRect);
                  expect(tester.getRect(title), titleRect);
                  expect(tester.takeException(), isNull);
                }
                final length = value.trim().runes.length;
                if (!source) expect(find.text('$length/80'), findsOneWidget);
                expect(tester.widget<TextField>(field).controller!.text, value);
                expect(
                  tester.widget<TextButton>(button).onPressed != null,
                  source || (length > 0 && length <= 80),
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
