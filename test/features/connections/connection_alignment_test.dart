import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/connections/connections_page.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_icon.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_fakes.dart' as fixtures;

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      for (final width in [320.0, 411.0]) {
        for (final initiallyLong in [false, true]) {
          testWidgets(
            'detail alignment stays stable $dark $scale $width $initiallyLong',
            (tester) async {
              tester.view.physicalSize = Size(width, 1800);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final bridge = fixtures.ConnectionBridgeFake();
              final app = fixtures.ConnectionAppFake(bridge);
              addTearDown(app.dispose);
              Map<String, dynamic> record(List<String> chains) => {
                ...fixtures.row('one'),
                'chains': chains,
              };
              final initialPath = initiallyLong
                  ? '很长的中文路径🌐 English node ' * 20
                  : 'DIRECT';
              bridge.data = fixtures.snapshot([
                record([initialPath]),
              ]);
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
                  home: ConnectionsPage(app: app),
                ),
              );
              await tester.pumpAndSettle();
              await tester.tap(find.text('one.fixture.test'));
              await tester.pumpAndSettle();
              Finder value(String text) => find.byWidgetPredicate(
                (widget) => widget is SelectableText && widget.data == text,
              );
              final icon = tester.getRect(find.byType(StrategyIcon));
              final path = tester.getRect(value(initialPath));
              if (!initiallyLong) {
                expect(path.center.dy, closeTo(icon.center.dy, 0.5));
              } else {
                expect(path.top, lessThan(icon.bottom));
                expect(path.height, greaterThan(icon.height));
              }
              final rule = tester.getRect(find.text('命中规则'));
              final time = tester.getRect(find.text('开始时间'));
              final source = tester.getRect(find.text('源地址'));
              if (width == 411 && scale == 1) {
                expect(
                  tester.getRect(value('[::1]:1234')).center.dy,
                  closeTo(source.center.dy, 0.5),
                );
              }
              for (final chains in [
                ['很长的中文路径🌐 English node ' * 20],
                ['DIRECT'],
                <String>[],
              ]) {
                bridge.data = fixtures.snapshot([record(chains)]);
                await tester.pump(const Duration(seconds: 1));
                for (final ms in [0, 16, 80, 180]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(tester.getRect(find.text('命中规则')), rule);
                  expect(tester.getRect(find.text('开始时间')), time);
                  expect(tester.getRect(find.text('源地址')), source);
                  expect(tester.takeException(), isNull);
                }
              }
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }
}
