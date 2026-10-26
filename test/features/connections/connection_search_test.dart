import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/connections/connections_page.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_fakes.dart' as fixtures;

void main() {
  late fixtures.ConnectionBridgeFake bridge;
  late fixtures.ConnectionAppFake app;
  setUp(() {
    bridge = fixtures.ConnectionBridgeFake();
    app = fixtures.ConnectionAppFake(bridge);
  });
  tearDown(() => app.dispose());

  Future<void> show(
    WidgetTester tester, {
    bool dark = false,
    double scale = 1,
    String language = 'zh',
    BrandColor brand = BrandColor.cinnabar,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale(language),
        theme: AppTheme.forBrightness(
          dark ? Brightness.dark : Brightness.light,
          brand,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ConnectionsPage(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    if (find.byType(TextField).evaluate().isEmpty) {
      await tester.tap(find.byTooltip('搜索连接'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), query);
    await tester.pump();
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final width in [280.0, 1704.0]) {
        for (final brand in BrandColor.values) {
          for (final dark in [false, true]) {
            testWidgets(
              'SDK search targets remain accessible $language/$scale/$width/$brand/$dark',
              (tester) async {
                tester.view.devicePixelRatio = 1;
                tester.view.physicalSize = Size(width, 1000);
                addTearDown(tester.view.reset);
                bridge.data = fixtures.snapshot([]);
                await show(
                  tester,
                  language: language,
                  scale: scale,
                  brand: brand,
                  dark: dark,
                );
                final strings = lookupAppLocalizations(Locale(language));
                final toolbar = tester.getRect(find.byType(AppBar));
                final body = tester.getRect(find.text(strings.allConnections));
                await tester.tap(find.byTooltip(strings.searchConnections));
                for (final ms in [0, 16, 80, 200]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(tester.getRect(find.byType(AppBar)), toolbar);
                  expect(
                    tester.getRect(find.text(strings.allConnections)),
                    body,
                  );
                  expect(tester.takeException(), isNull);
                }
                expect(
                  tester.getCenter(find.byType(EditableText)).dy,
                  closeTo(tester.getCenter(find.byType(TextField)).dy, .01),
                );
                for (final guideline in [
                  androidTapTargetGuideline,
                  labeledTapTargetGuideline,
                  textContrastGuideline,
                ]) {
                  await expectLater(tester, meetsGuideline(guideline));
                }
                await tester.pumpWidget(const SizedBox.shrink());
              },
              semanticsEnabled: true,
            );
          }
        }
      }
    }
  }

  testWidgets(
    'search matches each real field literally without crossing fields',
    (tester) async {
      bridge.data = fixtures.snapshot([
        {
          ...fixtures.row('a', host: 'Example.目标🌐.test'),
          'chains': ['Node[1]', '入口'],
          'rule': 'DomainSuffix',
          'rulePayload': 'example.test',
          'metadata': {
            'host': 'Example.目标🌐.test',
            'destinationIP': '2001:db8::5',
            'destinationPort': '9443',
            'network': 'tcp',
          },
        },
        fixtures.row('b', host: 'other.test'),
      ]);
      await show(tester);
      for (final query in [
        ' EXAMPLE.目标🌐 ',
        '2001:DB8::5',
        '9443',
        '入口 → node[1]',
        'DOMAINsuffix',
        'example.test',
      ]) {
        await search(tester, query);
        expect(find.text('Example.目标🌐.test'), findsOneWidget);
        expect(find.text('other.test'), findsNothing);
      }
      for (final query in [
        'test2001',
        'DomainSuffixexample.test',
        '.*',
        'not-found',
      ]) {
        await search(tester, query);
        expect(find.text('没有匹配的连接'), findsOneWidget);
      }
      await search(tester, '   ');
      expect(find.text('other.test'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('X reads raw input received before the next frame', (
    tester,
  ) async {
    bridge.data = fixtures.snapshot([]);
    await show(tester);
    await search(tester, '');
    final callback = tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '退出搜索',
          ),
        )
        .onPressed!;
    const value = TextEditingValue(
      text: 'raw',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    tester.testTextInput.updateEditingValue(value);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.value,
      value,
    );
    callback();
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('IME composing text is not normalized in the editor', (
    tester,
  ) async {
    bridge.data = fixtures.snapshot([fixtures.row('a', host: '中文🌐.test')]);
    await show(tester);
    await search(tester, '');
    const value = TextEditingValue(
      text: ' 中文🌐 ',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 1, end: 3),
    );
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller!.value, value);
    expect(find.text('中文🌐.test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('query combines with filters and follows latest records', (
    tester,
  ) async {
    bridge.data = fixtures.snapshot([
      fixtures.row('active'),
      {...fixtures.row('inactive'), 'active': false},
      {...fixtures.row('match', rule: 'Match'), 'active': false},
    ]);
    await show(tester);
    await search(tester, 'fixture.test');
    await tester.tap(find.text('全部连接'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    expect(find.byIcon(Icons.link_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('不活跃'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选命中规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Domain · fixture.test'));
    await tester.pumpAndSettle();
    expect(find.text('inactive.fixture.test'), findsOneWidget);
    expect(find.text('active.fixture.test'), findsNothing);
    expect(find.text('match.fixture.test'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isFalse,
    );
    bridge.data = fixtures.snapshot([
      {...fixtures.row('inactive-new'), 'active': false},
      fixtures.row('active-new'),
    ]);
    await tester.pump(const Duration(seconds: 1));
    await search(tester, 'inactive');
    expect(find.text('inactive.fixture.test'), findsNothing);
    expect(find.text('inactive-new.fixture.test'), findsOneWidget);
    expect(find.text('active-new.fixture.test'), findsNothing);
    expect(find.byTooltip('已暂停刷新'), findsNothing);
    expect(find.text('已暂停刷新'), findsNothing);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    await tester.tap(find.byTooltip('退出搜索'));
    await tester.pumpAndSettle();
    expect(find.text('不活跃'), findsOneWidget);
    expect(find.text('Domain · fixture.test'), findsOneWidget);
    expect(find.text('inactive-new.fixture.test'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clear keeps search, focus, filters and live display', (
    tester,
  ) async {
    bridge.data = fixtures.snapshot([
      fixtures.row('active'),
      {...fixtures.row('inactive'), 'active': false},
    ]);
    await show(tester);
    expect(find.text('最近连接'), findsOneWidget);
    expect(find.text('近期记录'), findsNothing);
    await tester.tap(find.text('全部连接'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.link_rounded), findsOneWidget);
    expect(find.byIcon(Icons.link_off_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.tap(find.text('不活跃'));
    await tester.pumpAndSettle();
    final list = tester.getRect(find.byType(CustomScrollView));
    await search(tester, 'missing');
    bridge.data = fixtures.snapshot([
      fixtures.row('active'),
      {...fixtures.row('inactive-new'), 'active': false},
    ]);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip('继续刷新'), findsNothing);
    expect(find.byTooltip('暂停刷新'), findsNothing);
    expect(find.byTooltip('已暂停刷新'), findsNothing);
    expect(find.text('已暂停刷新'), findsNothing);
    final clear = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '清除搜索',
    );
    final clearRect = tester.getRect(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    final bar = tester.widget<TextField>(find.byType(TextField));
    expect(bar.controller!.text, isEmpty);
    expect(bar.focusNode!.hasFocus, isTrue);
    expect(find.text('不活跃'), findsOneWidget);
    expect(find.text('inactive-new.fixture.test'), findsOneWidget);
    expect(find.text('inactive.fixture.test'), findsNothing);
    expect(find.text('active.fixture.test'), findsNothing);
    final exit = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '退出搜索',
    );
    expect(find.byTooltip('清除搜索'), findsNothing);
    expect(tester.getRect(exit), clearRect);
    expect(tester.getRect(find.byType(CustomScrollView)), list);
    expect(tester.widget<IconButton>(exit).onPressed, isNotNull);
    await search(tester, '   ');
    expect(tester.widget<IconButton>(clear).onPressed, isNotNull);
    await tester.tap(clear);
    await tester.pump();
    expect(bar.controller!.text, isEmpty);
    expect(bar.focusNode!.hasFocus, isTrue);
    expect(tester.getRect(exit), clearRect);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
    await tester.tap(exit);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('最近连接'), findsOneWidget);
    expect(bar.focusNode!.hasFocus, isFalse);
    expect(find.byTooltip('继续刷新'), findsNothing);
    expect(find.byTooltip('清除搜索'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rapid toolbar changes leave only current controls mounted', (
    tester,
  ) async {
    await show(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('搜索连接'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byTooltip('搜索连接'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.byTooltip('退出搜索'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('退出搜索'), findsNothing);
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'back hides keyboard before leaving search and failure remains visible',
    (tester) async {
      await show(tester);
      await search(tester, 'missing');
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      await Navigator.of(tester.element(find.byType(TextField))).maybePop();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isFalse,
      );
      tester.view.resetViewInsets();
      await tester.pump();
      bridge.fail = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('刷新失败，正在重试'), findsOneWidget);
      expect(find.text('没有匹配的连接'), findsNothing);
      await Navigator.of(tester.element(find.byType(TextField))).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      for (final width in [320.0, 411.0, 800.0]) {
        testWidgets(
          'compact state badges and search icon stay fixed $dark $scale $width',
          (tester) async {
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await show(tester, dark: dark, scale: scale);
            final badge = find.byKey(const ValueKey('connection-state-one'));
            final initialBadge = tester.getRect(badge);
            final protocol = tester.getRect(find.text('TCP'));
            final list = tester.getRect(find.byType(CustomScrollView));
            final upload = tester.getTopLeft(find.text('↑ 2 B'));
            final download = tester.getTopLeft(find.text('↓ 10 B'));
            expect(upload.dy, download.dy);
            expect(
              upload.dx - download.dx,
              lessThanOrEqualTo(12 * scale * 6.5 + 10),
            );
            expect(find.text('10:00:00'), findsNothing);
            expect(
              tester.widget<Container>(badge).decoration,
              isA<BoxDecoration>(),
            );
            bridge.data = fixtures.snapshot([
              {...fixtures.row('one', download: 999999999999), 'active': false},
            ]);
            await tester.pump(const Duration(seconds: 1));
            for (final ms in [0, 16, 80, 180]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(badge), initialBadge);
              expect(tester.getRect(find.text('TCP')), protocol);
              expect(tester.getTopLeft(find.text('↑ 2 B')), upload);
              expect(tester.getRect(find.byType(CustomScrollView)), list);
              expect(tester.takeException(), isNull);
            }
            expect(find.text('已不活跃'), findsOneWidget);
            await search(tester, 'fixture');
            final indicator = find.byIcon(Icons.search);
            final indicatorRect = tester.getRect(indicator);
            final inputRect = tester.getRect(find.byType(TextField));
            expect(find.byTooltip('暂停刷新'), findsNothing);
            expect(find.byTooltip('继续刷新'), findsNothing);
            expect(find.byTooltip('已暂停刷新'), findsNothing);
            expect(
              find.byIcon(Icons.pause_circle_outline_rounded),
              findsNothing,
            );
            expect(
              find.descendant(of: indicator, matching: find.byType(IconButton)),
              findsNothing,
            );
            bridge.fail = true;
            await tester.pump(const Duration(seconds: 1));
            for (final ms in [0, 16, 80, 180]) {
              await tester.pump(Duration(milliseconds: ms));
              expect(tester.getRect(indicator), indicatorRect);
              expect(tester.getRect(find.byType(TextField)), inputRect);
              expect(tester.getRect(find.byType(CustomScrollView)), list);
              expect(tester.takeException(), isNull);
            }
            expect(find.byIcon(Icons.search), findsOneWidget);
            bridge.fail = false;
            await tester.pump(const Duration(seconds: 2));
            expect(find.byTooltip('已暂停刷新'), findsNothing);
            expect(tester.getRect(find.byType(TextField)), inputRect);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
      testWidgets(
        'search transition preserves toolbar geometry dark=$dark scale=$scale',
        (tester) async {
          tester.view.physicalSize = const Size(320, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await show(tester, dark: dark, scale: scale);
          final filter = tester.getRect(find.text('全部连接'));
          final toolbar = tester.getRect(find.byType(AppBar));
          await tester.tap(find.byTooltip('搜索连接'));
          for (var i = 0; i < 14; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.getRect(find.text('全部连接')), filter);
            expect(tester.getRect(find.byType(AppBar)), toolbar);
            expect(tester.takeException(), isNull);
          }
          expect(
            tester
                .widget<TextField>(find.byType(TextField))
                .focusNode!
                .hasFocus,
            isTrue,
          );
          await tester.tap(find.byTooltip('退出搜索'));
          for (var i = 0; i < 14; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.getRect(find.text('全部连接')), filter);
            expect(tester.getRect(find.byType(AppBar)), toolbar);
            expect(tester.takeException(), isNull);
          }
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'effective query changes reset position; equivalent input and detail return preserve it',
    (tester) async {
      bridge.data = fixtures.snapshot(
        List.generate(1500, (i) => fixtures.row(i.toString().padLeft(4, '0'))),
      );
      await show(tester);
      await search(tester, 'fixture.test');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final offset = scroll.offset;
      await search(tester, ' FIXTURE.TEST ');
      expect(scroll.offset, offset);
      final top = tester.getTopLeft(find.byType(CustomScrollView)).dy;
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere(
            (text) =>
                (text.data?.endsWith('fixture.test') ?? false) &&
                tester.getTopLeft(find.text(text.data!)).dy >= top,
          )
          .data!;
      final position = tester.getTopLeft(find.text(text));
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton).last);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(text)), position);
      final bar = tester.widget<TextField>(find.byType(TextField));
      expect(bar.controller!.text, ' FIXTURE.TEST ');
      expect(bar.focusNode!.hasFocus, isFalse);
      await search(tester, '1499');
      expect(find.text('1499.fixture.test'), findsOneWidget);
      expect(scroll.offset, 0);
      await Navigator.of(tester.element(find.byType(TextField))).maybePop();
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(find.byType(TextField));
      expect(input.controller!.text, '1499');
      expect(input.focusNode!.hasFocus, isFalse);
      expect(scroll.offset, 0);
      await Navigator.of(tester.element(find.byType(TextField))).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('搜索连接'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
