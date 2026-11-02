import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_message.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<BuildContext> _host(
  WidgetTester tester, {
  double width = 390,
  double scale = 1,
  ValueNotifier<double>? height,
  FocusNode? focus,
  TextEditingController? editor,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);
  final available = height ?? ValueNotifier(700.0);
  if (height == null) addTearDown(available.dispose);
  late BuildContext origin;
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
      home: Scaffold(
        bottomNavigationBar: const SizedBox(
          key: ValueKey('navigation'),
          height: 80,
        ),
        body: Row(
          children: [
            if (width >= 600) const SizedBox(width: 80),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ValueListenableBuilder(
                  valueListenable: available,
                  builder: (_, value, child) =>
                      SizedBox(height: value, child: child),
                  child: OperationNoticeHost(
                    child: Builder(
                      builder: (context) {
                        origin = context;
                        return Scaffold(
                          body: ListView(
                            children: [
                              TextField(
                                key: const ValueKey('editor'),
                                controller: editor,
                                focusNode: focus,
                              ),
                              const Text('正文', key: ValueKey('body')),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return origin;
}

void main() {
  for (final width in [320.0, 960.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('SnackBar 不移动正文或抢占输入焦点 width=$width scale=$scale', (
        tester,
      ) async {
        final focus = FocusNode();
        final editor = TextEditingController(text: 'draft');
        addTearDown(focus.dispose);
        addTearDown(editor.dispose);
        final origin = await _host(
          tester,
          width: width,
          scale: scale,
          focus: focus,
          editor: editor,
        );
        focus.requestFocus();
        await tester.pumpAndSettle();
        editor.value = const TextEditingValue(
          text: 'draft',
          selection: TextSelection(baseOffset: 1, extentOffset: 3),
          composing: TextRange(start: 1, end: 4),
        );
        final value = editor.value;
        final body = tester.getRect(find.byKey(const ValueKey('body')));
        final input = tester.getRect(find.byKey(const ValueKey('editor')));
        var acknowledgements = 0;
        final result = showLocalizedOperationNotice(
          origin,
          (_) => '读取失败',
          onPresented: () => acknowledgements++,
        );
        expect(acknowledgements, 0);
        await tester.pumpAndSettle();
        expect(await result, isTrue);
        expect(acknowledgements, 1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.getRect(find.byKey(const ValueKey('body'))), body);
        expect(tester.getRect(find.byKey(const ValueKey('editor'))), input);
        expect(editor.value, value);
        expect(focus.hasFocus, isTrue);
        final notice = tester.getRect(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(notice.width, lessThanOrEqualTo(560));
        expect(
          notice.bottom,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byKey(const ValueKey('navigation'))).dy,
          ),
        );
        if (width >= 600) expect(notice.left, greaterThanOrEqualTo(80));
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.getRect(find.byKey(const ValueKey('body'))), body);
        expect(editor.value, value);
        expect(focus.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('空间不足时暂缓显示，实际呈现后仅确认一次', (tester) async {
    final height = ValueNotifier(64.0);
    addTearDown(height.dispose);
    final origin = await _host(tester, height: height);
    var acknowledgements = 0;
    bool? completed;
    final result = showLocalizedOperationNotice(
      origin,
      (_) => '读取失败',
      onPresented: () => acknowledgements++,
    ).then((value) => completed = value);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(completed, isNull);
    expect(acknowledgements, 0);
    height.value = 700;
    await tester.pumpAndSettle();
    await result;
    expect(completed, isTrue);
    expect(acknowledgements, 1);
    height.value = 650;
    await tester.pumpAndSettle();
    expect(acknowledgements, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('等待显示的来源同帧失效再恢复也不确认或显示', (tester) async {
    final height = ValueNotifier(64.0);
    final eligible = ValueNotifier(true);
    addTearDown(height.dispose);
    addTearDown(eligible.dispose);
    final origin = await _host(tester, height: height);
    var acknowledgements = 0;
    final result = showLocalizedOperationNotice(
      origin,
      (_) => '旧错误',
      isCurrent: () => eligible.value,
      eligibilityChanges: eligible,
      onPresented: () => acknowledgements++,
    );
    await tester.pumpAndSettle();
    eligible.value = false;
    eligible.value = true;
    height.value = 700;
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(acknowledgements, 0);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('显示前被替换的结果不确认，旧回调不能重试或关闭新提示', (tester) async {
    final origin = await _host(tester);
    var oldAcknowledgements = 0;
    final old = showLocalizedOperationNotice(
      origin,
      (_) => '未显示的旧错误',
      onPresented: () => oldAcknowledgements++,
    );
    var retries = 0;
    final shown = showLocalizedOperationNotice(
      origin,
      (_) => '可以重试的错误',
      onRetry: () async {
        retries++;
      },
    );
    await tester.pumpAndSettle();
    expect(await old, isFalse);
    expect(oldAcknowledgements, 0);
    expect(await shown, isTrue);
    final retry = tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Retry'))
        .onPressed!;
    final close = tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'Close',
          ),
        )
        .onPressed!;
    final next = showLocalizedOperationNotice(origin, (_) => '新的错误');
    await tester.pumpAndSettle();
    expect(await next, isTrue);
    retry();
    close();
    await tester.pumpAndSettle();
    expect(retries, 0);
    expect(find.text('新的错误'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('独立页面替换提示并退出时关闭回调保持幂等', (tester) async {
    final eligible = ValueNotifier(true);
    addTearDown(eligible.dispose);
    late BuildContext origin;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              origin = context;
              return const Text('正文');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = showLocalizedOperationNotice(
      origin,
      (_) => '第一条错误',
      isCurrent: () => eligible.value,
      eligibilityChanges: eligible,
    );
    await tester.pumpAndSettle();
    expect(await first, isTrue);
    final next = showLocalizedOperationNotice(
      origin,
      (_) => '第二条错误',
      isCurrent: () => eligible.value,
      eligibilityChanges: eligible,
    );
    eligible.value = false;
    eligible.value = true;
    Navigator.of(origin).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('另一页')),
      ),
    );
    await tester.pumpAndSettle();
    expect(await next, isFalse);
    expect(find.text('另一页'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('旧提示的延后关闭不能关闭同一 Messenger 的新提示', (tester) async {
    final eligible = ValueNotifier(true);
    addTearDown(eligible.dispose);
    late BuildContext origin;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              origin = context;
              return const Text('正文');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = showLocalizedOperationNotice(
      origin,
      (_) => '旧来源错误',
      isCurrent: () => eligible.value,
      eligibilityChanges: eligible,
    );
    await tester.pumpAndSettle();
    expect(await first, isTrue);
    eligible.value = false;
    final next = showLocalizedOperationNotice(origin, (_) => '新来源错误');
    await tester.pumpAndSettle();
    expect(await next, isTrue);
    expect(find.text('新来源错误'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nested Navigator 中的 SnackBar 可真实点击且详情不随退场关闭', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    late BuildContext origin;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [AppTaskNavigatorObserver()],
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: OperationNoticeHost(
          child: Scaffold(
            body: Navigator(
              observers: [AppTaskNavigatorObserver()],
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (context) {
                  origin = context;
                  return Scaffold(
                    appBar: AppBar(title: const Text('分类')),
                    body: ListView(children: const [Text('正文')]),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final body = tester.getRect(find.text('正文'));
    final shown = showLocalizedOperationNotice(
      origin,
      (_) => '保存失败',
      technicalDetail: (_) => 'original failure',
    );
    await tester.pumpAndSettle();
    expect(await shown, isTrue);
    expect(tester.getRect(find.text('正文')), body);
    await tester.tap(find.widgetWithText(TextButton, 'Error details'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('保存失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (error, detail) in <(bool, String?)>[
    (false, null),
    (false, ''),
    (false, 'cause\r\n原始错误\nsuppressed: close failed'),
    (true, null),
  ]) {
    testWidgets('详情入口按实际原文和错误状态显示 error=$error detail=$detail', (tester) async {
      final origin = await _host(tester);
      final body = tester.getRect(find.byKey(const ValueKey('body')));
      final strings = AppLocalizations.of(origin);
      final shown = showAppNotice(
        origin,
        AppMessage('configSaved', detail: detail),
        error: error,
        persist: true,
      );
      await tester.pumpAndSettle();
      expect(await shown, isTrue);
      expect(tester.getRect(find.byKey(const ValueKey('body'))), body);
      final action = find.widgetWithText(TextButton, strings.errorDetails);
      if (error || detail?.isNotEmpty == true) {
        expect(action, findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(strings.configSaved), findsOneWidget);
        if (detail?.isNotEmpty == true) {
          await tester.tap(
            find.byKey(const ValueKey('operation-technical-details')),
          );
          await tester.pumpAndSettle();
          expect(find.text(detail!), findsOneWidget);
        }
      } else {
        expect(action, findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.getRect(find.byKey(const ValueKey('body'))), body);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('显式详情操作不需要技术原文', (tester) async {
    final origin = await _host(tester);
    var opened = 0;
    final shown = showLocalizedOperationNotice(
      origin,
      (_) => '操作完成',
      error: false,
      onDetails: () async => opened++,
    );
    await tester.pumpAndSettle();
    expect(await shown, isTrue);
    await tester.tap(find.widgetWithText(TextButton, 'Error details'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('完整技术错误只在用户打开详情后显示', (tester) async {
    final origin = await _host(tester);
    const raw = 'cause\r\n原始错误\nsuppressed: close failed';
    final result = showLocalizedOperationNotice(
      origin,
      (_) => '保存失败',
      technicalDetail: (_) => raw,
    );
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    final details = AppLocalizations.of(origin).errorDetails;
    await tester.tap(find.widgetWithText(TextButton, details));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
    await tester.pumpAndSettle();
    expect(find.text(raw), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
