import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/input/choice_menu_button.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/diagnostics/dns/dns_controller.dart';
import 'package:clash_pseudo/src/ui/diagnostics/dns/dns_tool.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dns_fakes.dart';
import 'dns_controller_test.dart' show nativeDnsResult, runtimeDnsUiApp;

Finder keyed(String value) => find.byKey(ValueKey(value));
Finder dialogText(String value) => find.descendant(
  of: find.byType(AlertDialog).last,
  matching: find.text(value),
);
Finder selectable(String value) =>
    find.byWidgetPredicate((w) => w is SelectableText && w.data == value);

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.pump();
  if (key == 'dns-query-details' || key == 'dns-cache-details') {
    final tool = tester.widget<DnsTool>(find.byType(DnsTool));
    final controller = tool.controller!;
    final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
    final label = key == 'dns-cache-details'
        ? strings.dnsCacheOperationDetails
        : controller.errorCode != null || controller.cancellationError != null
        ? strings.errorDetails
        : controller.stale
        ? strings.dnsViewPreviousQuery
        : strings.dnsViewQueryResults;
    var item = find.widgetWithText(MenuItemButton, label);
    if (item.evaluate().isEmpty) {
      await tapKey(tester, 'dns-actions');
      await tester.pumpAndSettle();
      item = find.widgetWithText(MenuItemButton, label);
    }
    expect(item.hitTestable(), findsOneWidget);
    await tester.tap(item);
    await tester.pump();
    return;
  }
  if (keyed(key).hitTestable().evaluate().isEmpty) {
    await Scrollable.ensureVisible(tester.element(keyed(key)), alignment: .5);
    await tester.pump();
  }
  expect(keyed(key).hitTestable(), findsOneWidget);
  await tester.tap(keyed(key));
  await tester.pump();
}

Future<void> closeTopDialog(WidgetTester tester, String label) async {
  final dialog = find.byType(AlertDialog).last;
  expect(ModalRoute.of(tester.element(dialog))!.isCurrent, isTrue);
  final close = find.descendant(
    of: dialog,
    matching: find.widgetWithText(TextButton, label),
  );
  await Scrollable.ensureVisible(tester.element(close), alignment: .5);
  await tester.pump();
  expect(close.hitTestable(), findsOneWidget);
  await tester.tap(close);
  await tester.pumpAndSettle();
}

Future<DnsController> openTool(
  WidgetTester tester,
  DnsTestApp app, {
  String language = 'en',
  double scale = 1,
  bool dark = false,
  bool disableAnimations = true,
  ValueNotifier<(double, bool)>? presentation,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(language),
      theme: dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) {
        Widget media((double, bool) value) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(value.$1),
            disableAnimations: value.$2,
          ),
          child: child!,
        );
        return RepaintBoundary(
          key: const ValueKey('dns-paint-boundary'),
          child: presentation == null
              ? media((scale, disableAnimations))
              : ValueListenableBuilder(
                  valueListenable: presentation,
                  builder: (context, value, _) => media(value),
                ),
        );
      },
      home: SettingsPage(app: app),
    ),
  );
  await tester.pumpAndSettle();
  await reopenTool(tester);
  return tester.widget<DnsTool>(find.byType(DnsTool)).controller!;
}

Future<void> reopenTool(WidgetTester tester) async {
  final strings = AppLocalizations.of(
    tester.element(find.byType(SettingsPage)),
  );
  await tester.scrollUntilVisible(
    find.text(strings.dnsTools),
    150,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(strings.dnsTools));
  await tester.pumpAndSettle();
}

Future<void> clear(WidgetTester tester, {bool fakeIp = false}) async {
  final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
  final item = find.widgetWithText(
    MenuItemButton,
    fakeIp ? strings.dnsClearFakeIp : strings.dnsClearCache,
  );
  if (item.evaluate().isEmpty) {
    await tapKey(tester, 'dns-actions');
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(item);
  await tester.pump();
  await tester.tap(item);
  await tester.pump();
  await tester.pump();
}

Finder toolSurface() => find
    .ancestor(
      of: find.byKey(const PageStorageKey('dns-tool-scroll')),
      matching: find.byType(Material),
    )
    .first;

double formExtent(WidgetTester tester) => tester
    .widget<SizeTransition>(
      find
          .ancestor(
            of: keyed('dns-name'),
            matching: find.byType(SizeTransition),
          )
          .first,
    )
    .sizeFactor
    .value;

Future<void> openDnsNoticeDetails(WidgetTester tester) async {
  if (find.byType(AlertDialog).evaluate().isNotEmpty) return;
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  expect(find.byType(SnackBar), findsOneWidget);
  final action = find
      .descendant(of: find.byType(SnackBar), matching: find.byType(TextButton))
      .first;
  await tester.tap(action);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> showTechnical(WidgetTester tester) async {
  await openDnsNoticeDetails(tester);
  await tapKey(tester, 'dns-technical-details');
  await tester.pumpAndSettle();
}

InlineSpan _transparentLabel(InlineSpan span) => switch (span) {
  TextSpan() => TextSpan(
    text: span.text,
    style: (span.style ?? const TextStyle()).copyWith(
      color: Colors.transparent,
    ),
    children: span.children?.map(_transparentLabel).toList(),
  ),
  _ => span,
};

class _LabelPaintingContext extends PaintingContext {
  _LabelPaintingContext(super.layer, super.bounds);

  void finishRecording() => stopRecordingIfNeeded();
}

// 单独绘制标签字形，与隐藏标签前后的图像差值比较。
// ClipRect 裁掉的字形像素会在差值图中缺失，但标签仍可能存在于无障碍语义树中。
Future<void> expectNameLabelPainted(WidgetTester tester, String label) async {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: keyed('dns-name'), matching: find.text(label)).first,
  );
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    keyed('dns-paint-boundary'),
  );
  // 处理当前帧中需要重新布局和绘制的渲染对象，组件与标签动画保持当前状态。
  void flushPaint() => tester.binding.rootPipelineOwner
    ..flushLayout()
    ..flushCompositingBits()
    ..flushPaint();

  flushPaint();
  final captureTime = tester.binding.clock.now();
  final original = paragraph.text;
  final hidden = _transparentLabel(original);
  final size = paragraph.size;
  final layer = OffsetLayer();
  final painting = _LabelPaintingContext(layer, Offset.zero & boundary.size);
  painting.pushTransform(
    false,
    Offset.zero,
    paragraph.getTransformTo(boundary),
    (context, offset) => paragraph.paint(context, offset),
  );
  painting.finishRecording();
  // 每张图的捕获与像素读取在同一次异步操作中完成，三张图对应同一个动画帧。
  Future<ByteData?> pixels(Future<ui.Image> Function() render) =>
      tester.runAsync<ByteData?>(() async {
        final image = await render();
        try {
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });

  late final ByteData? referenceBytes;
  late final ByteData? actualBytes;
  late final ByteData? withoutBytes;
  try {
    referenceBytes = await pixels(
      () => layer.toImage(Offset.zero & boundary.size),
    );
    actualBytes = await pixels(() => boundary.toImage());
    expect(paragraph.text, same(original));
    paragraph.text = hidden;
    flushPaint();
    expect(paragraph.text, same(hidden));
    expect(paragraph.size, size);
    withoutBytes = await pixels(() => boundary.toImage());
    expect(paragraph.text, same(hidden));
    expect(tester.binding.clock.now(), captureTime);
  } finally {
    paragraph.text = original;
    flushPaint();
    layer.dispose();
  }
  var expected = 0;
  var visible = 0;
  for (var pixel = 0; pixel < referenceBytes!.lengthInBytes; pixel += 4) {
    if (referenceBytes.getUint8(pixel + 3) < 128) continue;
    expected++;
    var difference = 0;
    for (var channel = 0; channel < 3; channel++) {
      difference +=
          (actualBytes!.getUint8(pixel + channel) -
                  withoutBytes!.getUint8(pixel + channel))
              .abs();
    }
    if (difference > 3) visible++;
  }
  expect(expected, greaterThan(10));
  expect(
    visible / expected,
    greaterThan(.98),
    reason: 'floating label glyphs must paint, not merely remain in semantics',
  );
}

void main() {
  for (final language in ['en', 'zh']) {
    testWidgets('裸 DNS FD 的实际成功答案在界面显示，不打开读取错误弹窗 $language', (tester) async {
      final app = await runtimeDnsUiApp(tester);
      addTearDown(app.dispose);
      final native = app.native;
      final controller = await openTool(tester, app, language: language);
      await tester.enterText(keyed('dns-name'), 'example.com');
      await tapKey(tester, 'dns-query');
      final request = native
          .calls(ApplicationContract.coreOperationDnsQuery)
          .single;
      request.complete(nativeDnsResult);
      await tester.pump();
      expect(controller.queryBusy, isTrue);
      expect(controller.response, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      request.signalExit();
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
      expect(controller.status, DnsStatus.ready);
      expect(controller.response!.raw['dns'], nativeDnsResult);
      expect(selectable(strings.dnsRcode('NOERROR', 0)), findsOneWidget);
      expect(selectable('172.66.147.243'), findsOneWidget);
      expect(find.text(strings.dnsElapsed(48.4008)), findsOneWidget);
      expect(keyed('dns-edit'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      final scrollable = find
          .descendant(
            of: find.byKey(const PageStorageKey('dns-tool-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      final secondAnswer = selectable('104.20.23.154');
      await tester.scrollUntilVisible(
        secondAnswer,
        100,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(secondAnswer, findsOneWidget);
      expect(secondAnswer.hitTestable(), findsOneWidget);
      await tester.scrollUntilVisible(
        keyed('dns-raw-data'),
        -100,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, strings.rawData), findsOneWidget);
      expect(
        tester.widget<TextButton>(keyed('dns-raw-data')).onPressed,
        isNotNull,
      );
      await tapKey(tester, 'dns-raw-data');
      await tester.pumpAndSettle();
      final rawView = tester.widget<OriginalTextView>(
        find.byType(OriginalTextView),
      );
      expect(jsonDecode(rawView.text), controller.response!.raw);
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pumpAndSettle();
      await tapKey(tester, 'dns-edit');
      expect(keyed('dns-status'), findsNothing);
      expect(find.text(strings.runtimeConfigPreview), findsNothing);
      expect(native.calls(ApplicationContract.coreOperationDnsQuery), [
        request,
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  group(
    'DNS visual interaction and captured identity',
    dnsVisualInteractionTests,
  );
  testWidgets(
    'reduced size changes bypass AnimatedSize and normal phases retain the same keyed subtree',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1000);
      addTearDown(tester.view.reset);
      final presentation = ValueNotifier((1.0, false));
      addTearDown(presentation.dispose);
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(
        tester,
        app,
        presentation: presentation,
      );
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final input = find.byKey(const ValueKey('dns-name'), skipOffstage: false);
      final inputState = tester.state(input);
      final field = tester.widget<TextField>(input).controller!;
      field.value = field.value.copyWith(
        selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        composing: const TextRange(start: 1, end: 5),
      );
      final draft = field.value;
      final tool = tester.state(find.byType(DnsTool));
      final route = ModalRoute.of(tester.element(find.byType(DnsTool)));
      final scroll = find.byKey(const PageStorageKey('dns-tool-scroll'));
      final scrollable = find
          .descendant(of: scroll, matching: find.byType(Scrollable))
          .first;
      final scrollState = tester.state<ScrollableState>(scrollable);
      final scrollController = tester
          .widget<CustomScrollView>(scroll)
          .controller;
      final resize = find.ancestor(
        of: scroll,
        matching: find.byType(AnimatedSize),
      );
      final contentKey = tester.widget<AnimatedSize>(resize).child!.key!;
      final content = tester.element(find.byKey(contentKey));
      final initial = tester.getRect(toolSurface());
      void checkOwners({required bool resizeAnimated}) {
        expect(tester.state(find.byType(DnsTool)), same(tool));
        expect(
          ModalRoute.of(tester.element(find.byType(DnsTool))),
          same(route),
        );
        expect(tester.element(find.byKey(contentKey)), same(content));
        expect(tester.state(input), same(inputState));
        expect(tester.widget<TextField>(input).controller, same(field));
        expect(field.value, draft);
        expect(tester.state(scrollable), same(scrollState));
        expect(
          tester.widget<CustomScrollView>(scroll).controller,
          same(scrollController),
        );
        expect(controller.active, isTrue);
        expect(resize, resizeAnimated ? findsOneWidget : findsNothing);
        if (resizeAnimated) {
          expect(
            tester.widget<AnimatedSize>(resize).duration,
            const Duration(milliseconds: 180),
          );
        }
        expect(tester.takeException(), isNull);
      }

      checkOwners(resizeAnimated: true);
      presentation.value = (1, true);
      await tester.pump();
      checkOwners(resizeAnimated: false);
      await tapKey(tester, 'dns-query');
      bridge.replies.single.complete(
        dnsReply(
          answer: [
            dnsRecord(),
            dnsRecord(data: '192.0.2.2'),
          ],
        ),
      );
      await tester.pump();
      checkOwners(resizeAnimated: false);
      final result = tester.getRect(toolSurface());
      expect(result.height, greaterThan(initial.height));
      expect(keyed('dns-query').hitTestable(), findsNothing);
      await tapKey(tester, 'dns-edit');
      checkOwners(resizeAnimated: false);
      expect(tester.getRect(toolSurface()), initial);
      presentation.value = (1, false);
      await tester.pump();
      checkOwners(resizeAnimated: true);
      expect(tester.getRect(toolSurface()), initial);
      await tapKey(tester, 'dns-query');
      bridge.replies.last.complete(
        dnsReply(
          answer: [
            dnsRecord(),
            dnsRecord(data: '192.0.2.2'),
          ],
        ),
      );
      await tester.pump();
      checkOwners(resizeAnimated: false);
      await tester.pump(const Duration(milliseconds: 60));
      checkOwners(resizeAnimated: false);
      expect(
        tester.getRect(toolSurface()).height,
        inExclusiveRange(initial.height, result.height),
      );
      final outward = formExtent(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      checkOwners(resizeAnimated: false);
      expect(formExtent(tester), closeTo(outward, .001));
      await tester.pump(const Duration(milliseconds: 16));
      checkOwners(resizeAnimated: false);
      expect(formExtent(tester), inExclusiveRange(outward, 1));
      presentation.value = (1, true);
      await tester.pump();
      checkOwners(resizeAnimated: false);
      expect(tester.getRect(toolSurface()), initial);
      presentation.value = (1, false);
      await tester.pump();
      checkOwners(resizeAnimated: true);
      await tester.pump(const Duration(milliseconds: 200));
      checkOwners(resizeAnimated: true);
      expect(tester.getRect(toolSurface()), initial);
      expect(bridge.queries, hasLength(2));
      expect(bridge.cancellations, isEmpty);
      expect(controller.queryBusy, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'retired fake-IP confirmation callbacks cannot clear or pop DNS before repaint or during reverse',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final semantics = tester.ensureSemantics();
      try {
        final controller = await openTool(
          tester,
          app,
          disableAnimations: false,
        );
        await tester.enterText(keyed('dns-name'), 'controlled.example');
        final field = tester.widget<TextField>(keyed('dns-name')).controller!;
        final tool = tester.state(find.byType(DnsTool));
        final dnsRoute = ModalRoute.of(tester.element(find.byType(DnsTool)))!;
        final strings = AppLocalizations.of(
          tester.element(find.byType(DnsTool)),
        );
        await clear(tester, fakeIp: true);
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        final localRoute = ModalRoute.of(tester.element(dialog))!;
        final dialogFocus = FocusScope.of(tester.element(dialog));
        final confirm = find.widgetWithText(TextButton, strings.dnsClearFakeIp);
        final cancel = find.widgetWithText(TextButton, strings.cancel);
        final oldConfirm = tester.widget<TextButton>(confirm).onPressed!;
        final oldCancel = tester.widget<TextButton>(cancel).onPressed!;
        final draft = field.value;
        expect(controller.active, isTrue);
        oldCancel();
        expect(dnsRoute.isCurrent, isTrue);
        oldConfirm();
        oldCancel();
        expect(dnsRoute.isActive, isTrue);
        expect(bridge.clears, isEmpty);
        await tester.pump();
        expect(dialog, findsOneWidget);
        expect(confirm.hitTestable(), findsNothing);
        expect(cancel.hitTestable(), findsNothing);
        expect(dialogFocus.hasFocus, isFalse);
        expect(
          tester.semantics.simulatedAccessibilityTraversal().any(
            (node) => node.getSemanticsData().label.contains(
              strings.dnsFakeIpWarning,
            ),
          ),
          isFalse,
        );
        oldConfirm();
        oldCancel();
        await tester.pump(const Duration(milliseconds: 40));
        expect(localRoute.animation!.value, inExclusiveRange(0, 1));
        expect(bridge.clears, isEmpty);
        expect(controller.active, isTrue);
        expect(dnsRoute.isCurrent, isTrue);
        expect(tester.state(find.byType(DnsTool)), same(tool));
        expect(
          tester.widget<TextField>(keyed('dns-name')).controller,
          same(field),
        );
        expect(field.value, draft);
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(bridge.queries, isEmpty);
        expect(bridge.cancellations, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final mode in ['raw', 'error']) {
    testWidgets(
      'retired $mode close keeps DNS and a replacement route intact with its captured source',
      (tester) async {
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        final semantics = tester.ensureSemantics();
        try {
          final controller = await openTool(
            tester,
            app,
            disableAnimations: false,
          );
          await tester.enterText(keyed('dns-name'), 'controlled.example');
          final field = tester.widget<TextField>(keyed('dns-name')).controller!;
          final tool = tester.state(find.byType(DnsTool));
          final dnsRoute = ModalRoute.of(tester.element(find.byType(DnsTool)))!;
          final strings = AppLocalizations.of(
            tester.element(find.byType(DnsTool)),
          );
          Future<void> pumpPresentation() async {
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump();
          }

          await tapKey(tester, 'dns-query');
          final value = mode == 'raw' ? dnsReply() : dnsError('timeout');
          if (mode == 'error') app.publish(dnsBusy: true);
          bridge.replies.single.complete(value);
          await pumpPresentation();
          if (mode == 'raw') {
            await tapKey(tester, 'dns-raw-data');
            await pumpPresentation();
          } else {
            await openDnsNoticeDetails(tester);
          }
          final dialog = find.byType(AlertDialog);
          final localRoute = ModalRoute.of(tester.element(dialog))!;
          final navigator = Navigator.of(tester.element(dialog));
          final dialogFocus = FocusScope.of(tester.element(dialog));
          final close = find.descendant(
            of: dialog,
            matching: find.widgetWithText(TextButton, strings.close),
          );
          final oldClose = tester.widget<TextButton>(close).onPressed!;
          final draft = field.value;
          final response = controller.response;
          final errorDetail = controller.errorDetail;
          oldClose();
          expect(dnsRoute.isCurrent, isTrue);
          oldClose();
          expect(dnsRoute.isActive, isTrue);
          await tester.pump();
          expect(dialog, findsOneWidget);
          expect(close.hitTestable(), findsNothing);
          expect(dialogFocus.hasFocus, isFalse);
          expect(
            tester
                .widget<ExcludeSemantics>(
                  find
                      .ancestor(
                        of: dialog,
                        matching: find.byType(ExcludeSemantics),
                      )
                      .first,
                )
                .excluding,
            isTrue,
          );
          oldClose();
          await tester.pump(const Duration(milliseconds: 40));
          expect(localRoute.animation!.value, inExclusiveRange(0, 1));
          expect(controller.active, isTrue);
          expect(controller.queryBusy, mode == 'error');
          final replacement = MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Text('Controlled replacement route')),
          );
          unawaited(navigator.push<void>(replacement));
          app.publish(network: 2, dnsBusy: mode == 'error');
          oldClose();
          expect(replacement.isCurrent, isTrue);
          expect(replacement.isActive, isTrue);
          expect(dnsRoute.isActive, isTrue);
          await pumpPresentation();
          expect(find.text('Controlled replacement route'), findsOneWidget);
          navigator.pop();
          await pumpPresentation();
          expect(controller.active, isTrue);
          expect(tester.state(find.byType(DnsTool)), same(tool));
          expect(field.value, draft);
          expect(controller.response, same(response));
          expect(controller.errorDetail, errorDetail);
          if (mode == 'raw') {
            expect(controller.response!.raw, value);
            expect(controller.response!.networkEpoch, 1);
            expect(controller.stale, isTrue);
          } else {
            expect(jsonDecode(controller.errorDetail!), value);
            expect(controller.queryBusy, isTrue);
            app.publish(network: 2);
            expect(controller.queryBusy, isFalse);
          }
          expect(bridge.queries, hasLength(1));
          expect(bridge.clears, isEmpty);
          expect(bridge.cancellations, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'phase, rapid reversal, continuous resize and reduced motion keep the keyed input and scroll subtree',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1000);
      addTearDown(tester.view.reset);
      final presentation = ValueNotifier((1.0, false));
      addTearDown(presentation.dispose);
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(
        tester,
        app,
        presentation: presentation,
      );
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final field = tester.widget<TextField>(keyed('dns-name')).controller!;
      field.value = field.value.copyWith(
        selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        composing: const TextRange(start: 1, end: 5),
      );
      final draft = field.value;
      final toolState = tester.state(find.byType(DnsTool));
      final route = ModalRoute.of(tester.element(find.byType(DnsTool)));
      final scroll = find.byKey(const PageStorageKey('dns-tool-scroll'));
      final scrollable = find
          .descendant(of: scroll, matching: find.byType(Scrollable))
          .first;
      final scrollState = tester.state<ScrollableState>(scrollable);
      final scrollController = tester
          .widget<CustomScrollView>(scroll)
          .controller;
      final resize = find.ancestor(
        of: scroll,
        matching: find.byType(AnimatedSize),
      );
      expect(resize, findsOneWidget);
      final contentKey = tester.widget<AnimatedSize>(resize).child!.key!;
      final contentElement = tester.element(find.byKey(contentKey));
      final input = find.byKey(const ValueKey('dns-name'), skipOffstage: false);
      final inputState = tester.state(input);
      final initial = tester.getRect(toolSurface());
      void sameOwners() {
        expect(tester.state(find.byType(DnsTool)), same(toolState));
        expect(
          ModalRoute.of(tester.element(find.byType(DnsTool))),
          same(route),
        );
        expect(tester.element(find.byKey(contentKey)), same(contentElement));
        expect(tester.state(input), same(inputState));
        expect(tester.widget<TextField>(input).controller, same(field));
        expect(tester.state(scrollable), same(scrollState));
        expect(
          tester.widget<CustomScrollView>(scroll).controller,
          same(scrollController),
        );
        expect(field.value, draft);
        expect(controller.active, isTrue);
        expect(bridge.queries, hasLength(1));
        expect(bridge.cancellations, isEmpty);
        expect(tester.takeException(), isNull);
      }

      await tapKey(tester, 'dns-query');
      bridge.replies.single.complete(
        dnsReply(
          answer: [
            for (var index = 0; index < 80; index++)
              dnsRecord(data: 'RR-$index'),
          ],
        ),
      );
      await tester.pump();
      sameOwners();
      await tester.pump(const Duration(milliseconds: 48));
      expect(
        tester.getRect(toolSurface()).height,
        inExclusiveRange(initial.height, 720),
      );
      sameOwners();
      for (final size in [
        const Size(680, 820),
        const Size(560, 700),
        const Size(640, 760),
      ]) {
        tester.view.physicalSize = size;
        await tester.pump(const Duration(milliseconds: 16));
        sameOwners();
        expect(tester.getRect(toolSurface()).width, lessThanOrEqualTo(560));
        expect(
          tester.getRect(toolSurface()).bottom,
          lessThanOrEqualTo(size.height - 24),
        );
      }
      final outward = formExtent(tester);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(formExtent(tester), closeTo(outward, .001));
      await tester.pump(const Duration(milliseconds: 16));
      expect(formExtent(tester), inExclusiveRange(outward, 1));
      sameOwners();
      presentation.value = (1, true);
      await tester.pump();
      sameOwners();
      expect(formExtent(tester), 1);
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller,
        same(field),
      );
      expect(resize, findsNothing);
      presentation.value = (1, false);
      await tester.pump();
      sameOwners();
      expect(resize, findsOneWidget);
      expect(
        tester.widget<AnimatedSize>(resize).duration,
        const Duration(milliseconds: 180),
      );
      await tester.pump(const Duration(milliseconds: 16));
      sameOwners();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'captured commands cannot act on a replacement source before any widget frame',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(tester, app);
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final oldQuery = tester
          .widget<FilledButton>(keyed('dns-query'))
          .onPressed!;
      final oldRefresh = tester
          .widget<FilledButton>(keyed('dns-refresh'))
          .onPressed!;
      final oldMenu = tester.widget<ChoiceMenuButton<String>>(
        keyed('dns-actions'),
      );
      app.publish(network: 2);
      expect(controller.canQuery, isTrue);
      expect(controller.contextVersion, isNot(oldMenu.identity));
      oldQuery();
      oldRefresh();
      oldMenu.onSelected('clear');
      oldMenu.onSelected('fakeIp');
      expect(bridge.clears, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.clears, isEmpty);
      expect(bridge.queries, isEmpty);
      expect(app.refreshes, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'live route and phase revoke old command callbacks before repaint',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(tester, app);
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final oldQuery = tester
          .widget<FilledButton>(keyed('dns-query'))
          .onPressed!;
      final oldMenu = tester.widget<ChoiceMenuButton<String>>(
        keyed('dns-actions'),
      );
      final navigator = Navigator.of(tester.element(find.byType(DnsTool)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) =>
                const Scaffold(body: Text('Controlled covering route')),
          ),
        ),
      );
      // 此处尚未绘制新帧，控制器可见状态和旧组件仍对应 DNS 工具。
      expect(controller.active, isTrue);
      oldQuery();
      oldMenu.onSelected('clear');
      oldMenu.onSelected('fakeIp');
      expect(bridge.queries, isEmpty);
      expect(bridge.clears, isEmpty);
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(controller.active, isTrue);
      await tapKey(tester, 'dns-query');
      bridge.replies.single.complete(dnsReply());
      await tester.pumpAndSettle();
      oldQuery();
      expect(bridge.queries, hasLength(1));
      expect(keyed('dns-query').hitTestable(), findsNothing);
      expect(controller.response!.source.generation, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (width, height, language, scale, dark) in [
    (320.0, 900.0, 'en', 2.0, false),
    (700.0, 479.0, 'zh', 2.0, true),
    (1704.0, 1136.0, 'en', 1.0, true),
    (320.0, 900.0, 'zh', 1.0, false),
  ]) {
    testWidgets(
      'one bounded Dialog and complete themed title commands $language $width $scale dark=$dark',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, height);
        tester.view.padding = const FakeViewPadding(
          left: 12,
          top: 24,
          right: 20,
          bottom: 20,
        );
        addTearDown(tester.view.reset);
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        await openTool(
          tester,
          app,
          language: language,
          scale: scale,
          dark: dark,
        );
        final state = tester.state(find.byType(DnsTool));
        final strings = AppLocalizations.of(
          tester.element(find.byType(DnsTool)),
        );
        final colors = Theme.of(tester.element(find.byType(DnsTool)))
            .colorScheme;
        final inputRect = tester.getRect(toolSurface());
        expect(inputRect.width, lessThanOrEqualTo(560));
        expect(inputRect.left, greaterThanOrEqualTo(28));
        expect(inputRect.right, lessThanOrEqualTo(width - 36));
        expect(find.byType(BottomSheet), findsNothing);
        expect(
          find.ancestor(
            of: keyed('dns-actions'),
            matching: find.byKey(const ValueKey('dns-header')),
          ),
          findsOneWidget,
        );
        expect(
          find.ancestor(of: keyed('dns-actions'), matching: find.byType(Wrap)),
          findsNothing,
        );
        for (final key in ['dns-actions', 'dns-close']) {
          final rect = tester.getRect(keyed(key));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
        await tapKey(tester, 'dns-actions');
        await tester.pumpAndSettle();
        for (final (label, icon, color, iconColor) in [
          (
            strings.dnsClearCache,
            Icons.cleaning_services_outlined,
            colors.onSurface,
            colors.onSurfaceVariant,
          ),
          (strings.dnsClearFakeIp, Icons.link_off, colors.error, colors.error),
        ]) {
          final item = find.widgetWithText(MenuItemButton, label);
          expect(item, findsOneWidget);
          final button = tester.widget<MenuItemButton>(item);
          expect(button.trailingIcon, isNull);
          expect((button.leadingIcon! as Icon).icon, icon);
          expect((button.leadingIcon! as Icon).color, iconColor);
          final labelFinder = find.descendant(
            of: item,
            matching: find.text(label),
          );
          expect(tester.widget<Text>(labelFinder).style!.color, color);
          expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
          final paragraph = tester.renderObject<RenderParagraph>(labelFinder);
          expect(paragraph.didExceedMaxLines, isFalse);
          for (final word in RegExp(r'[A-Za-z]+').allMatches(label)) {
            expect(
              paragraph.getBoxesForSelection(
                TextSelection(baseOffset: word.start, extentOffset: word.end),
              ),
              hasLength(1),
              reason:
                  'A complete word must not be fragmented: ${word.group(0)}; '
                  'item=${tester.getRect(item)}, label=${paragraph.size}',
            );
          }
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        await tester.enterText(keyed('dns-name'), 'controlled.example');
        await tapKey(tester, 'dns-query');
        bridge.replies.single.complete(
          dnsReply(
            answer: [
              for (var index = 0; index < 80; index++)
                dnsRecord(data: '192.0.2.${index + 1}'),
            ],
          ),
        );
        await tester.pumpAndSettle();
        final resultRect = tester.getRect(toolSurface());
        expect(resultRect.width, closeTo(inputRect.width, .01));
        expect(resultRect.height, lessThanOrEqualTo(height - 92));
        expect(tester.state(find.byType(DnsTool)), same(state));
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(keyed('dns-actions'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'result structure transitions and reverses without delaying facts or rebuilding the draft',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1000);
      addTearDown(tester.view.reset);
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(tester, app, disableAnimations: false);
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final field = tester.widget<TextField>(keyed('dns-name')).controller!;
      field.value = field.value.copyWith(
        selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        composing: const TextRange(start: 1, end: 5),
      );
      final value = field.value;
      final state = tester.state(find.byType(DnsTool));
      final route = ModalRoute.of(tester.element(find.byType(DnsTool)))!;
      final initial = tester.getRect(toolSurface());
      await tapKey(tester, 'dns-query');
      bridge.replies.single.complete(
        dnsReply(
          answer: [
            for (var index = 0; index < 80; index++)
              dnsRecord(data: '192.0.2.${index + 1}'),
          ],
        ),
      );
      await tester.pump();
      expect(controller.response!.answer, hasLength(80));
      expect(keyed('dns-query').hitTestable(), findsNothing);
      expect(formExtent(tester), 1);
      await tester.pump(const Duration(milliseconds: 60));
      final outward = formExtent(tester);
      expect(outward, inExclusiveRange(0, 1));
      final middle = tester.getRect(toolSurface());
      expect(middle.height, greaterThan(initial.height));
      expect(middle.height, lessThan(720));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(formExtent(tester), closeTo(outward, .001));
      await tester.pump(const Duration(milliseconds: 1));
      expect(formExtent(tester), greaterThan(outward));
      expect(formExtent(tester), lessThan(1));
      tester.widget<FilledButton>(keyed('dns-query')).onPressed!();
      expect(bridge.queries, hasLength(2));
      bridge.replies.last.complete(dnsReply());
      await tester.pumpAndSettle();
      expect(controller.response!.answer, hasLength(1));
      expect(tester.state(find.byType(DnsTool)), same(state));
      expect(ModalRoute.of(tester.element(find.byType(DnsTool))), same(route));
      await tapKey(tester, 'dns-edit');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller,
        same(field),
      );
      expect(field.value, value);
      expect(tester.getRect(toolSurface()), initial);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('DNS phases finish immediately when reduced motion is enabled', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 1000);
    addTearDown(tester.view.reset);
    final presentation = ValueNotifier((1.0, false));
    addTearDown(presentation.dispose);
    final bridge = DnsTestBridge();
    final app = DnsTestApp(bridge);
    addTearDown(app.dispose);
    final controller = await openTool(tester, app, presentation: presentation);
    await tester.enterText(keyed('dns-name'), 'controlled.example');
    final fieldState = tester.state(keyed('dns-name'));
    final field = tester.widget<TextField>(keyed('dns-name')).controller!;
    final initial = tester.getRect(toolSurface());
    await tapKey(tester, 'dns-query');
    bridge.replies.single.complete(
      dnsReply(
        answer: [
          dnsRecord(),
          dnsRecord(data: '192.0.2.2'),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final middle = tester.getRect(toolSurface());
    presentation.value = (1, true);
    await tester.pump();
    final result = tester.getRect(toolSurface());
    expect(result.height, greaterThan(middle.height));
    expect(controller.response!.answer, hasLength(2));
    expect(keyed('dns-query').hitTestable(), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(toolSurface()), result);
    presentation.value = (1, false);
    await tester.pump();
    await tapKey(tester, 'dns-edit');
    await tester.pump(const Duration(milliseconds: 40));
    expect(
      tester.getRect(toolSurface()).height,
      inExclusiveRange(initial.height, result.height),
    );
    presentation.value = (1, true);
    await tester.pump();
    expect(tester.getRect(toolSurface()), initial);
    expect(keyed('dns-query').hitTestable(), findsOneWidget);
    expect(tester.state(keyed('dns-name')), same(fieldState));
    expect(tester.widget<TextField>(keyed('dns-name')).controller, same(field));
    expect(field.text, 'controlled.example');
    expect(controller.active, isTrue);
    expect(bridge.queries, hasLength(1));
    expect(bridge.cancellations, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final count in [2, 512]) {
    testWidgets(
      'DNS $count-record phase stays between natural heights without eager rows',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(700, 1000);
        addTearDown(tester.view.reset);
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        final controller = await openTool(
          tester,
          app,
          disableAnimations: false,
        );
        await tester.enterText(keyed('dns-name'), 'controlled.example');
        final state = tester.state(find.byType(DnsTool));
        final fieldState = tester.state(keyed('dns-name'));
        final field = tester.widget<TextField>(keyed('dns-name')).controller!;
        final initial = tester.getRect(toolSurface());
        await tapKey(tester, 'dns-query');
        bridge.replies.single.complete(
          dnsReply(
            answer: [
              for (var index = 0; index < count; index++)
                dnsRecord(
                  data: index == count - 1 ? 'last-phase-RR' : 'RR-$index',
                ),
            ],
          ),
        );
        await tester.pump();
        expect(controller.response!.answer, hasLength(count));
        final outward = [tester.getRect(toolSurface())];
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          outward.add(tester.getRect(toolSurface()));
          if (count == 512) expect(selectable('last-phase-RR'), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        final result = tester.getRect(toolSurface());
        expect(result.height, greaterThan(initial.height));
        expect(outward.first.height, closeTo(initial.height, .01));
        expect(
          outward[4].height,
          inExclusiveRange(initial.height, result.height),
        );
        for (var index = 0; index < outward.length; index++) {
          expect(
            outward[index].height,
            inInclusiveRange(initial.height - .01, result.height + .01),
            reason: 'outward frame $index must not overshoot the target',
          );
          if (index > 0) {
            expect(
              outward[index].height,
              greaterThanOrEqualTo(outward[index - 1].height - .01),
              reason: 'outward frame $index must not jump back',
            );
          }
        }
        await tapKey(tester, 'dns-edit');
        final inward = [tester.getRect(toolSurface())];
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          inward.add(tester.getRect(toolSurface()));
          if (count == 512) expect(selectable('last-phase-RR'), findsNothing);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        for (var index = 0; index < inward.length; index++) {
          expect(
            inward[index].height,
            inInclusiveRange(initial.height - .01, result.height + .01),
            reason: 'inward frame $index must not overshoot the target',
          );
          if (index > 0) {
            expect(
              inward[index].height,
              lessThanOrEqualTo(inward[index - 1].height + .01),
              reason: 'inward frame $index must not jump back',
            );
          }
        }
        expect(tester.getRect(toolSurface()), initial);
        expect(tester.state(find.byType(DnsTool)), same(state));
        expect(tester.state(keyed('dns-name')), same(fieldState));
        expect(
          tester.widget<TextField>(keyed('dns-name')).controller,
          same(field),
        );
        expect(field.text, 'controlled.example');
        expect(bridge.queries, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'live resize, text scale, keyboard and reduced motion keep the same route and composing input',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1704, 1136);
      addTearDown(tester.view.reset);
      final presentation = ValueNotifier((1.0, false));
      addTearDown(presentation.dispose);
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(
        tester,
        app,
        presentation: presentation,
      );
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final field = tester.widget<TextField>(keyed('dns-name')).controller!;
      field.value = field.value.copyWith(
        selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        composing: const TextRange(start: 1, end: 5),
      );
      final value = field.value;
      final state = tester.state(find.byType(DnsTool));
      final route = ModalRoute.of(tester.element(find.byType(DnsTool)));
      await tapKey(tester, 'dns-query');
      for (final (size, inset, scale, reduced) in [
        (const Size(700, 479), 150.0, 2.0, false),
        (const Size(320, 900), 300.0, 1.0, false),
        (const Size(1704, 1136), 0.0, 2.0, true),
        (const Size(700, 900), 250.0, 1.0, false),
      ]) {
        tester.view.physicalSize = size;
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        presentation.value = (scale, reduced);
        for (final ms in [0, 16, 40, 80, 200]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.state(find.byType(DnsTool)), same(state));
          expect(
            ModalRoute.of(tester.element(find.byType(DnsTool))),
            same(route),
          );
          expect(
            tester.widget<TextField>(keyed('dns-name')).controller,
            same(field),
          );
          expect(field.value, value);
          expect(controller.active, isTrue);
          expect(bridge.queries, hasLength(1));
          expect(bridge.cancellations, isEmpty);
          final rect = tester.getRect(toolSurface());
          expect(rect.width, lessThanOrEqualTo(560));
          expect(rect.bottom, lessThanOrEqualTo(size.height - 24));
          expect(tester.takeException(), isNull);
        }
      }
      presentation.value = (1, true);
      await tester.pump();
      bridge.replies.single.complete(dnsReply());
      await tester.pump();
      expect(keyed('dns-name'), findsNothing);
      expect(keyed('dns-edit'), findsOneWidget);
      expect(controller.response, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (width, language, inset) in [
    (320.0, 'en', 240.0),
    (700.0, 'zh', 250.0),
  ]) {
    testWidgets(
      'short DNS dialog keeps controls and complete RR reachable above the keyboard $width $language',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 479);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
        tester.view.padding = const FakeViewPadding(top: 24);
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        addTearDown(tester.view.reset);
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        final controller = await openTool(
          tester,
          app,
          language: language,
          scale: 2,
        );
        final tool = tester.state(find.byType(DnsTool));
        final route = ModalRoute.of(tester.element(find.byType(DnsTool)));
        final scrollable = find
            .descendant(
              of: find.byKey(const PageStorageKey('dns-tool-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        Future<void> reveal(Finder finder) async {
          await tester.pump();
          await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
          await tester.pumpAndSettle();
          expect(
            finder.hitTestable(),
            findsOneWidget,
            reason:
                'control=${tester.getRect(finder)} '
                'viewport=${tester.getRect(find.byKey(const PageStorageKey('dns-tool-scroll')))}',
          );
        }

        await reveal(keyed('dns-name'));
        await tester.enterText(keyed('dns-name'), 'controlled.example');
        final field = tester.widget<TextField>(keyed('dns-name')).controller!;
        await reveal(keyed('dns-type'));
        final type = tester
            .widget<ChoiceMenuButton<String>>(keyed('dns-type'))
            .options
            .keys
            .last;
        await tapKey(tester, 'dns-type');
        await tester.pumpAndSettle();
        final option = find.widgetWithText(MenuItemButton, type);
        await tester.ensureVisible(option);
        await tester.pump();
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(controller.type, type);
        await reveal(keyed('dns-refresh'));
        await tester.tap(keyed('dns-refresh'));
        await tester.pump();
        expect(app.refreshes, 1);
        expect(bridge.queries, isEmpty);
        await reveal(keyed('dns-query'));
        expect(
          tester.getSize(keyed('dns-query')).height,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(keyed('dns-query'));
        await tester.pump();
        final data =
            'RR-BEGIN\n${List.filled(32, 'complete RR 原文🙂').join('\n')}\nRR-END';
        bridge.replies.single.complete(
          dnsReply(
            type: type,
            answer: [
              dnsRecord(type: type, data: data),
              dnsRecord(data: 'LAST-RR-完整'),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(toolSurface()).bottom,
          lessThanOrEqualTo(479 - inset - 24),
        );
        expect(controller.response!.answer.first.data, data);
        final record = selectable(data);
        await tester.scrollUntilVisible(record, 100, scrollable: scrollable);
        await tester.pumpAndSettle();
        final editable = tester
            .state<EditableTextState>(
              find.descendant(of: record, matching: find.byType(EditableText)),
            )
            .renderEditable;
        final position = tester.state<ScrollableState>(scrollable).position;
        final viewport = tester.getRect(
          find.byKey(const PageStorageKey('dns-tool-scroll')),
        );
        for (final offset in [0, data.indexOf('RR-END')]) {
          final caret = editable.getLocalRectForCaret(
            TextPosition(offset: offset),
          );
          final y = editable.localToGlobal(caret.topLeft).dy;
          final before = (position.pixels, y, caret);
          position.jumpTo(
            (position.pixels + y - viewport.top - 12).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
          await tester.pumpAndSettle();
          final current = editable.getLocalRectForCaret(
            TextPosition(offset: offset),
          );
          final visible =
              editable.localToGlobal(current.topLeft) & current.size;
          expect(
            visible.top,
            greaterThanOrEqualTo(viewport.top),
            reason:
                'offset=$offset before=$before after=$position rect=$visible',
          );
          expect(visible.bottom, lessThanOrEqualTo(viewport.bottom));
          expect(
            tester
                .hitTestOnBinding(visible.center)
                .path
                .any((entry) => identical(entry.target, editable)),
            isTrue,
          );
        }
        final last = selectable('LAST-RR-完整');
        await tester.scrollUntilVisible(last, 100, scrollable: scrollable);
        await reveal(last);
        await tester.scrollUntilVisible(
          keyed('dns-raw-data'),
          -100,
          scrollable: scrollable,
        );
        await reveal(keyed('dns-raw-data'));
        await reveal(keyed('dns-actions'));
        await tapKey(tester, 'dns-actions');
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(2));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(controller.active, isTrue);
        await reveal(keyed('dns-edit'));
        await tapKey(tester, 'dns-edit');
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(keyed('dns-name')).controller,
          same(field),
        );
        expect(field.text, 'controlled.example');
        expect(tester.state(find.byType(DnsTool)), same(tool));
        expect(
          ModalRoute.of(tester.element(find.byType(DnsTool))),
          same(route),
        );
        expect(bridge.queries, hasLength(1));
        expect(bridge.cancellations, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'DNS affordances reverse visually while query facts and retired controls change immediately',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 900);
      addTearDown(tester.view.reset);
      final presentation = ValueNotifier((1.0, false));
      addTearDown(presentation.dispose);
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final semantics = tester.ensureSemantics();
      try {
        final controller = await openTool(
          tester,
          app,
          presentation: presentation,
        );
        final strings = AppLocalizations.of(
          tester.element(find.byType(DnsTool)),
        );
        final invalid = find.widgetWithIcon(IconButton, Icons.error_outline);
        final details = keyed('dns-query-details');
        double opacity(Finder finder) => tester
            .widget<Opacity>(
              find.ancestor(of: finder, matching: find.byType(Opacity)).first,
            )
            .opacity;
        final progress = find.descendant(
          of: keyed('dns-query'),
          matching: find.byType(CircularProgressIndicator),
        );
        double progressOpacity() => tester
            .widget<FadeTransition>(
              find
                  .ancestor(of: progress, matching: find.byType(FadeTransition))
                  .first,
            )
            .opacity
            .value;
        final state = tester.state(find.byType(DnsTool));
        final status = tester.getRect(keyed('dns-query'));
        final field = tester.widget<TextField>(keyed('dns-name')).controller!;
        expect(opacity(invalid), 0);
        expect(details, findsNothing);
        await tester.enterText(keyed('dns-name'), 'controlled.example');
        await tapKey(tester, 'dns-query');
        expect(bridge.queries, hasLength(1));
        expect(controller.queryBusy, isTrue);
        expect(progressOpacity(), 0);
        await tester.pump(const Duration(milliseconds: 40));
        expect(progressOpacity(), inExclusiveRange(0, 1));
        bridge.replies.single.complete(dnsError('invalidRequest'));
        await tester.pump();
        expect(controller.queryBusy, isFalse);
        expect(controller.errorCode, 'invalidRequest');
        expect(
          tester.widget<FilledButton>(keyed('dns-query')).onPressed,
          isNotNull,
        );
        expect(opacity(invalid), 0);
        expect(details, findsNothing);
        await tester.pump(const Duration(milliseconds: 40));
        final visible = opacity(invalid);
        expect(visible, inExclusiveRange(0, 1));
        expect(details, findsNothing);
        await tapKey(tester, 'dns-query');
        expect(bridge.queries, hasLength(2));
        expect(controller.queryBusy, isTrue);
        expect(opacity(invalid), closeTo(visible, .001));
        expect(invalid.hitTestable(), findsNothing);
        expect(details.hitTestable(), findsNothing);
        expect(
          tester.semantics.simulatedAccessibilityTraversal().any(
            (node) =>
                node.label == strings.dnsInvalidRequest ||
                node.label == strings.errorDetails,
          ),
          isFalse,
        );
        await tester.pump(const Duration(milliseconds: 10));
        final retiring = opacity(invalid);
        expect(retiring, inExclusiveRange(0, visible));
        bridge.replies.last.complete(dnsError('invalidRequest'));
        await tester.pump();
        expect(controller.queryBusy, isFalse);
        expect(opacity(invalid), closeTo(retiring, .001));
        await tester.pump(const Duration(milliseconds: 40));
        expect(opacity(invalid), inExclusiveRange(retiring, 1));
        presentation.value = (1, true);
        await tester.pump();
        expect(opacity(invalid), 1);
        expect(details, findsNothing);
        expect(progress, findsNothing);
        expect(invalid.hitTestable(), findsOneWidget);
        expect(details.hitTestable(), findsNothing);
        expect(tester.getRect(keyed('dns-query')), status);
        expect(tester.state(find.byType(DnsTool)), same(state));
        expect(
          tester.widget<TextField>(keyed('dns-name')).controller,
          same(field),
        );
        expect(bridge.cancellations, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final close in ['button', 'back', 'escape', 'barrier']) {
    testWidgets(
      '$close retires DNS before the first exit frame while real cancellation drains',
      (tester) async {
        final bridge = DnsTestBridge()..cancellationPending = Completer<void>();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        final semantics = tester.ensureSemantics();
        try {
          final controller = await openTool(
            tester,
            app,
            disableAnimations: false,
          );
          await tester.enterText(keyed('dns-name'), 'controlled.example');
          final oldQuery = tester
              .widget<FilledButton>(keyed('dns-query'))
              .onPressed!;
          await tapKey(tester, 'dns-query');
          final field = tester.widget<TextField>(keyed('dns-name')).controller!;
          final route = ModalRoute.of(tester.element(find.byType(DnsTool)))!;
          final owner = bridge.queries.single.queryOwner;
          switch (close) {
            case 'button':
              await tester.tap(keyed('dns-close'));
            case 'back':
              await tester.binding.handlePopRoute();
            case 'escape':
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            case 'barrier':
              await tester.tapAt(const Offset(4, 4));
          }
          expect(controller.active, isFalse);
          expect(controller.queryBusy, isTrue);
          expect(bridge.cancellations.single.queryOwner, owner);
          await tester.pump();
          expect(find.byType(DnsTool), findsOneWidget);
          expect(keyed('dns-close').hitTestable(), findsNothing);
          expect(keyed('dns-query').hitTestable(), findsNothing);
          expect(
            tester.semantics.simulatedAccessibilityTraversal().any((node) {
              final data = node.getSemanticsData();
              return data.label == 'Query' ||
                  data.value == 'controlled.example';
            }),
            isFalse,
          );
          expect(
            tester
                .widget<EditableText>(find.byType(EditableText))
                .focusNode
                .hasFocus,
            isFalse,
          );
          oldQuery();
          expect(bridge.queries, hasLength(1));
          await tester.pump(const Duration(milliseconds: 40));
          expect(route.animation!.value, inExclusiveRange(0, 1));
          app.publish(dnsBusy: true);
          bridge.replies.single.complete(dnsReply());
          await tester.pumpAndSettle();
          expect(find.byType(DnsTool), findsNothing);
          expect(controller.queryBusy, isTrue);
          bridge.cancellationPending!.complete();
          await tester.pump();
          expect(controller.queryBusy, isTrue);
          app.publish(dnsBusy: false);
          await tester.pumpAndSettle();
          expect(controller.queryBusy, isFalse);
          expect(find.byType(DnsTool), findsNothing);
          await reopenTool(tester);
          expect(
            tester.widget<TextField>(keyed('dns-name')).controller!.text,
            field.text,
          );
          expect(keyed('dns-edit'), findsNothing);
          expect(bridge.queries, hasLength(1));
          await tester.pumpWidget(const SizedBox());
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  testWidgets(
    'Back closes the title menu without editing results; stale results cannot clear a new source',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(tester, app);
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      await tapKey(tester, 'dns-query');
      bridge.replies.single.complete(dnsReply());
      await tester.pumpAndSettle();
      await tapKey(tester, 'dns-actions');
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(keyed('dns-name'), findsNothing);
      expect(keyed('dns-edit'), findsOneWidget);
      expect(controller.active, isTrue);
      app.publish(core: dnsCore(generation: 2), generation: 2);
      await tester.pumpAndSettle();
      expect(controller.stale, isTrue);
      expect(
        tester
            .widget<ChoiceMenuButton<String>>(keyed('dns-actions'))
            .disabledOptions,
        containsAll(['clear', 'fakeIp']),
      );
      expect(bridge.clears, isEmpty);
      expect(controller.response!.source.generation, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 700.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'settings DNS form keeps anchors through validation, waiting, failure and retry $language/$width/$scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1100);
            addTearDown(tester.view.reset);
            final app = await runtimeDnsUiApp(tester);
            final native = app.native;
            addTearDown(app.dispose);
            await openTool(tester, app, language: language, scale: scale);
            expect(find.byType(Dialog), findsOneWidget);
            expect(find.byType(SettingsPage), findsOneWidget);
            expect(
              find.descendant(
                of: find.byType(DnsTool),
                matching: find.byType(Scaffold),
              ),
              findsNothing,
            );
            await tester.enterText(keyed('dns-name'), '');
            await tester.pump();
            if (keyed('dns-query').hitTestable().evaluate().isEmpty) {
              await Scrollable.ensureVisible(
                tester.element(keyed('dns-query')),
                alignment: .5,
              );
              await tester.pump();
            }
            expect(keyed('dns-query').hitTestable(), findsOneWidget);
            final anchors = {
              for (final key in [
                'dns-name',
                'dns-type',
                'dns-query',
                'dns-actions',
              ])
                key: tester.getRect(keyed(key)),
            };
            void checkAnchors() {
              for (final entry in anchors.entries) {
                expect(
                  tester.getRect(keyed(entry.key)),
                  entry.value,
                  reason: entry.key,
                );
              }
              expect(tester.takeException(), isNull);
            }

            await tapKey(tester, 'dns-query');
            expect(
              native.calls(ApplicationContract.coreOperationDnsQuery),
              isEmpty,
            );
            checkAnchors();
            await tester.enterText(keyed('dns-name'), 'controlled.example');
            await tapKey(tester, 'dns-query');
            for (final ms in [0, 16, 100, 200]) {
              await tester.pump(Duration(milliseconds: ms));
              checkAnchors();
            }
            expect(
              tester.widget<FilledButton>(keyed('dns-query')).onPressed,
              isNull,
            );
            final request = native
                .calls(ApplicationContract.coreOperationDnsQuery)
                .single;
            request.complete(dnsError('timeout', core: native.core)['dns']);
            await tester.pump();
            expect(request.hasTerminal, isTrue);
            expect(request.actualExited, isFalse);
            expect(native.dns.busy, isTrue);
            expect(
              tester.widget<FilledButton>(keyed('dns-query')).onPressed,
              isNull,
            );
            checkAnchors();
            request.signalExit();
            await tester.pumpAndSettle();
            checkAnchors();
            final strings = AppLocalizations.of(
              tester.element(find.byType(DnsTool)),
            );
            expect(find.byType(AlertDialog), findsNothing);
            await openDnsNoticeDetails(tester);
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(selectable(strings.dnsTimeout), findsOneWidget);
            await tester.tap(find.widgetWithText(TextButton, strings.close));
            await tester.pumpAndSettle();
            checkAnchors();
            await tapKey(tester, 'dns-query');
            final retry = native
                .calls(ApplicationContract.coreOperationDnsQuery)
                .last;
            expect(retry.id, isNot(request.id));
            retry.complete(
              dnsReply(core: native.core, rcode: 3, answer: [])['dns'],
            );
            retry.signalExit();
            await tester.pumpAndSettle();
            expect(keyed('dns-name'), findsNothing);
            expect(selectable(strings.dnsRcode('NXDOMAIN', 3)), findsOneWidget);
            expect(keyed('dns-edit'), findsOneWidget);
            await tapKey(tester, 'dns-edit');
            await tester.pumpAndSettle();
            checkAnchors();
            expect(
              tester.widget<TextField>(keyed('dns-name')).controller!.text,
              'controlled.example',
            );
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'all twelve types use the anchored menu and presentation input reaches the bridge unchanged',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(tester, app);
      const name = r'例子\.service.example';
      await tester.enterText(keyed('dns-name'), name);
      final tool = tester.state(find.byType(DnsTool));
      final route = ModalRoute.of(tester.element(find.byType(DnsTool)));
      final input = keyed('dns-name');
      final inputState = tester.state(input);
      final field = tester.widget<TextField>(input).controller!;
      final draft = field.value;
      final trigger = keyed('dns-type');
      final triggerState = tester.state(trigger);
      final anchor = tester.getRect(trigger);
      await tapKey(tester, 'dns-type');
      await tester.pumpAndSettle();
      final firstType = find.widgetWithText(MenuItemButton, 'A');
      expect(firstType, findsOneWidget);
      final panelHost = find.ancestor(
        of: firstType,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is IntrinsicWidth &&
              widget.child is Material &&
              (widget.child as Material).type == MaterialType.canvas,
        ),
      );
      expect(panelHost, findsOneWidget);
      final surface = find.byWidget(
        tester.widget<IntrinsicWidth>(panelHost).child!,
      );
      expect(surface, findsOneWidget);
      final items = find.descendant(
        of: surface,
        matching: find.byType(MenuItemButton),
      );
      expect(
        tester
            .widgetList<MenuItemButton>(items)
            .map((w) => (w.key as ValueKey<String>).value),
        [
          'A',
          'AAAA',
          'CNAME',
          'MX',
          'TXT',
          'NS',
          'SOA',
          'PTR',
          'SRV',
          'HTTPS',
          'SVCB',
          'CAA',
        ],
      );
      final panel = tester.getRect(surface);
      expect(panel.right, closeTo(anchor.right, .01));
      expect(tester.getRect(trigger), anchor);
      expect(tester.state(trigger), same(triggerState));
      expect(tester.state(find.byType(DnsTool)), same(tool));
      expect(ModalRoute.of(tester.element(find.byType(DnsTool))), same(route));
      expect(
        tester.widget<DnsTool>(find.byType(DnsTool)).controller,
        same(controller),
      );
      expect(tester.state(input), same(inputState));
      expect(tester.widget<TextField>(input).controller, same(field));
      expect(field.value, draft);
      final overlay =
          Overlay.of(
                tester.element(trigger),
                rootOverlay: true,
              ).context.findRenderObject()!
              as RenderBox;
      final workspace = overlay.localToGlobal(Offset.zero) & overlay.size;
      final window = MediaQueryData.fromView(tester.view);
      final safe = (window.padding + window.viewInsets)
          .deflateRect(Offset.zero & window.size)
          .intersect(workspace);
      expect(panel.left, greaterThanOrEqualTo(safe.left));
      expect(panel.top, greaterThanOrEqualTo(safe.top));
      expect(panel.right, lessThanOrEqualTo(safe.right));
      expect(panel.bottom, lessThanOrEqualTo(safe.bottom));
      final firstItem = tester.getRect(firstType);
      expect(
        firstItem.right,
        lessThanOrEqualTo(tester.view.physicalSize.width),
      );
      expect(firstItem.top, greaterThanOrEqualTo(0));
      expect(
        firstItem.bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height),
      );
      await tester.scrollUntilVisible(
        find.widgetWithText(MenuItemButton, 'CAA'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.widgetWithText(MenuItemButton, 'CAA'));
      await tester.pumpAndSettle();
      await tapKey(tester, 'dns-query');
      expect(bridge.queries.single.name, name);
      expect(bridge.queries.single.type, 'CAA');
      bridge.replies.single.complete(dnsReply(type: 'CAA'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DnsTool), findsOneWidget);
      expect(tester.state(find.byType(DnsTool)), same(tool));
      expect(ModalRoute.of(tester.element(find.byType(DnsTool))), same(route));
      expect(
        tester.widget<DnsTool>(find.byType(DnsTool)).controller,
        same(controller),
      );
      expect(tester.state(input), same(inputState));
      expect(tester.widget<TextField>(input).controller, same(field));
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller!.text,
        name,
      );
      await tapKey(tester, 'dns-close');
      await tester.pumpAndSettle();
      await reopenTool(tester);
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller!.text,
        name,
      );
      expect(find.text('CAA'), findsOneWidget);
      expect(bridge.queries.length, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'window, safety and keyboard changes retain the same input and defer results until interactive',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1704, 1136);
      tester.view.padding = const FakeViewPadding(
        left: 8,
        right: 8,
        bottom: 20,
      );
      addTearDown(tester.view.reset);
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      await openTool(tester, app);
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final field = tester.widget<TextField>(keyed('dns-name')).controller!;
      field.value = field.value.copyWith(
        selection: const TextSelection(baseOffset: 1, extentOffset: 5),
        composing: const TextRange(start: 1, end: 5),
      );
      final value = field.value;
      final state = tester.state(find.byType(DnsTool));
      await tapKey(tester, 'dns-query');
      for (final size in [
        const Size(320, 900),
        const Size(700, 479),
        const Size(1704, 1136),
      ]) {
        tester.view.physicalSize = size;
        tester.view.viewInsets = FakeViewPadding(
          bottom: size.height < 500 ? 150 : 300,
        );
        await tester.pump(const Duration(milliseconds: 320));
        expect(tester.state(find.byType(DnsTool)), same(state));
        expect(
          tester.widget<TextField>(keyed('dns-name')).controller,
          same(field),
        );
        expect(field.value, value);
        expect(bridge.queries.length, 1);
        expect(tester.takeException(), isNull);
      }
      app.setInteractive(false);
      bridge.replies.single.complete(dnsReply());
      await tester.pumpAndSettle();
      expect(keyed('dns-edit'), findsNothing);
      app.setInteractive(true);
      await tester.pumpAndSettle();
      expect(keyed('dns-edit'), findsOneWidget);
      await tapKey(tester, 'dns-edit');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller,
        same(field),
      );
      expect(field.value, value);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final close in ['button', 'back', 'barrier']) {
    testWidgets(
      '$close close cancels its owner immediately; late results never reopen the tool',
      (tester) async {
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        final controller = await openTool(tester, app);
        await tester.enterText(keyed('dns-name'), 'controlled.example');
        await tapKey(tester, 'dns-query');
        final owner = bridge.queries.single.queryOwner;
        switch (close) {
          case 'button':
            await tapKey(tester, 'dns-close');
          case 'back':
            await tester.binding.handlePopRoute();
          case 'barrier':
            await tester.tapAt(const Offset(4, 4));
        }
        await tester.pump();
        expect(controller.active, isFalse);
        expect(
          bridge.cancellations.map((value) => value.queryOwner),
          contains(owner),
        );
        bridge.replies.single.complete(dnsReply());
        await tester.pumpAndSettle();
        expect(find.byType(DnsTool), findsNothing);
        await reopenTool(tester);
        expect(
          tester.widget<TextField>(keyed('dns-name')).controller!.text,
          'controlled.example',
        );
        expect(keyed('dns-edit'), findsNothing);
        expect(bridge.queries.length, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a covering route cancels the query and preserves the expired result and draft',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(tester, app);
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      await tapKey(tester, 'dns-query');
      bridge.replies.single.complete(dnsReply());
      await tester.pumpAndSettle();
      await tapKey(tester, 'dns-edit');
      await tapKey(tester, 'dns-query');
      final owner = bridge.queries.last.queryOwner;
      final navigator = Navigator.of(tester.element(find.byType(DnsTool)));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) =>
                const Scaffold(body: Text('Controlled covering route')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.active, isFalse);
      expect(bridge.cancellations.last.queryOwner, owner);
      bridge.replies.last.complete(
        dnsReply(answer: [dnsRecord(data: '192.0.2.99')]),
      );
      await tester.pump();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(controller.active, isTrue);
      expect(controller.response!.answer.single.data, '192.0.2.99');
      expect(controller.stale, isTrue);
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller!.text,
        'controlled.example',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final language in ['en', 'zh']) {
    testWidgets('DNS raw data can be read and copied whole: $language', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.reset);
      const original =
          'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture';
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
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(
        tester,
        app,
        language: language,
        scale: 2,
      );
      await tester.enterText(keyed('dns-name'), 'MiXeD.fixture.test');
      await tapKey(tester, 'dns-query');
      final value = dnsReply(
        type: 'TXT',
        answer: [dnsRecord(type: 'TXT', data: original)],
      )..['futureEnvelope'] = {'boolean': false, 'absent': null};
      final data = value['dns'] as Map;
      data['message'] = {
        'Id': 0xbeef,
        'AuthenticatedData': true,
        'future': [original, false, null],
      };
      (data['answer'] as List).single['futureRecord'] = original;
      bridge.replies.single.complete(value);
      await tester.pumpAndSettle();
      await tapKey(tester, 'dns-raw-data');
      await tester.pumpAndSettle();
      final raw = tester.widget<OriginalTextView>(
        find.byType(OriginalTextView),
      );
      expect(jsonDecode(raw.text), value);
      expect(controller.active, isTrue);
      expect(controller.stale, isFalse);
      await tapKey(tester, 'original-text-copy');
      expect(copied, raw.text);
      expect(jsonDecode(copied!), value);
      app.publish(network: 2);
      await tester.pump();
      expect(controller.stale, isTrue);
      expect(
        tester.widget<OriginalTextView>(find.byType(OriginalTextView)).text,
        raw.text,
      );
      final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pumpAndSettle();
      expect(controller.response!.raw, value);
      expect(keyed('dns-edit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('query failures keep their full feedback and can be reopened', (
    tester,
  ) async {
    const original =
        'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture';
    final bridge = DnsTestBridge();
    final app = DnsTestApp(bridge);
    addTearDown(app.dispose);
    await openTool(tester, app);
    await tester.enterText(keyed('dns-name'), 'MiXeD.fixture.test');
    await tapKey(tester, 'dns-query');
    final value = dnsError('future-error');
    (value['dns'] as Map)
      ..['detail'] = original
      ..['message'] = {
        'Id': 0xbeef,
        'future': [original, false, null],
      };
    bridge.replies.single.complete(value);
    await tester.pumpAndSettle();
    final raw = const JsonEncoder.withIndent('  ').convert(value);
    final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
    await openDnsNoticeDetails(tester);
    expect(selectable(strings.dnsQueryFailed), findsOneWidget);
    expect(selectable(raw), findsNothing);
    await showTechnical(tester);
    expect(selectable(raw), findsOneWidget);
    await closeTopDialog(tester, strings.close);
    expect(find.byType(AlertDialog), findsOneWidget);
    await openDnsNoticeDetails(tester);
    expect(selectable(strings.dnsQueryFailed), findsOneWidget);
    await closeTopDialog(tester, strings.close);
    expect(find.byType(AlertDialog), findsNothing);
    app.publish(network: 2);
    await tester.pump();
    await tapKey(tester, 'dns-query-details');
    await tester.pumpAndSettle();
    await showTechnical(tester);
    expect(selectable(raw), findsOneWidget);
    expect(jsonDecode(raw), value);
    expect(bridge.queries.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final fakeIp in [false, true]) {
    testWidgets(
      'cache details keep original fields after a source change: fakeIp=$fakeIp',
      (tester) async {
        const original =
            'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture';
        final value = dnsCacheReply(
          fakeIp: fakeIp,
          status: fakeIp ? 'partialOrFailed' : 'completed',
        );
        (value['cache'] as Map)
          ..['detail'] = original
          ..['future'] = [original, false, null];
        final bridge = DnsTestBridge()
          ..clearPending = Completer<Map<String, dynamic>>();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        await openTool(tester, app);
        await clear(tester, fakeIp: fakeIp);
        final strings = AppLocalizations.of(
          tester.element(find.byType(DnsTool)),
        );
        if (fakeIp) {
          await tester.tap(
            find.widgetWithText(TextButton, strings.dnsClearFakeIp),
          );
          await tester.pump();
        }
        app.publish(network: 2);
        bridge.clearPending!.complete(value);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        await tapKey(tester, 'dns-cache-details');
        await tester.pumpAndSettle();
        expect(
          find.text(strings.dnsResponseSource(strings.runtimeConfigLive)),
          findsOneWidget,
        );
        expect(
          find.text(strings.dnsResponseSource(strings.runtimeConfigPreview)),
          findsNothing,
        );
        final raw = const JsonEncoder.withIndent('  ').convert(value);
        expect(selectable(raw), findsNothing);
        await showTechnical(tester);
        expect(selectable(raw), findsOneWidget);
        expect(jsonDecode(raw), value);
        expect(bridge.clears, [fakeIp]);
        expect(bridge.queries, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'background cache failure remains available after return: fakeIp=$fakeIp',
      (tester) async {
        final failure = PlatformFailure(
          code: 'cache',
          message: 'https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture',
        );
        final bridge = DnsTestBridge()
          ..clearPending = Completer<Map<String, dynamic>>();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        await openTool(tester, app);
        await clear(tester, fakeIp: fakeIp);
        final strings = AppLocalizations.of(
          tester.element(find.byType(DnsTool)),
        );
        if (fakeIp) {
          await tester.tap(
            find.widgetWithText(TextButton, strings.dnsClearFakeIp),
          );
          await tester.pump();
        }
        app.setInteractive(false);
        app.publish(network: 2);
        bridge.clearPending!.completeError(failure);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        app.setInteractive(true);
        await tester.pumpAndSettle();
        await tapKey(tester, 'dns-cache-details');
        await tester.pumpAndSettle();
        expect(selectable(strings.dnsCacheFailed), findsOneWidget);
        expect(selectable(failure.toString()), findsNothing);
        await showTechnical(tester);
        expect(selectable(failure.toString()), findsOneWidget);
        expect(bridge.clears, [fakeIp]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final dark in [false, true]) {
    testWidgets(
      'bounded result keeps complete selectable records and its reading anchor $dark',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 700);
        addTearDown(tester.view.reset);
        final bridge = DnsTestBridge();
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        final controller = await openTool(tester, app, scale: 2, dark: dark);
        await tester.enterText(keyed('dns-name'), 'controlled.example');
        await tapKey(tester, 'dns-query');
        final text = 'controlled TXT ' * 60;
        final reply = dnsReply(
          type: 'TXT',
          truncated: true,
          answer: [dnsRecord(type: 'TXT', data: text)],
        );
        (reply['dns'] as Map)['authority'] = [
          dnsRecord(type: 'NS', data: 'ns.controlled.example.'),
        ];
        (reply['dns'] as Map)['additional'] = [
          dnsRecord(type: 'AAAA', data: '2001:db8::1'),
        ];
        bridge.replies.single.complete(reply);
        await tester.pumpAndSettle();
        final scroll = find.descendant(
          of: find.byType(DnsTool),
          matching: find.byType(CustomScrollView),
        );
        await tester.scrollUntilVisible(
          selectable(text),
          200,
          scrollable: find
              .descendant(of: scroll, matching: find.byType(Scrollable))
              .first,
        );
        await tester.pump();
        final before = tester.getRect(selectable(text));
        app.setForeground(false);
        await tester.pump();
        app.setForeground(true);
        await tester.pump();
        expect(tester.getRect(selectable(text)), before);
        expect(controller.stale, isTrue);
        final scrollable = find
            .descendant(of: scroll, matching: find.byType(Scrollable))
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        final pixels = position.pixels;
        expect(
          tester.getRect(selectable(text)).contains(tester.getCenter(scroll)),
          isTrue,
        );
        await tester.drag(scrollable, const Offset(0, -250));
        await tester.pump();
        expect(position.pixels, greaterThan(pixels));
        for (final data in ['ns.controlled.example.', '2001:db8::1']) {
          await tester.scrollUntilVisible(
            selectable(data),
            250,
            scrollable: scrollable,
          );
          expect(selectable(data), findsOneWidget);
        }
        expect(bridge.queries.length, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'separate cache menu clears DNS immediately and confirms fake-IP exactly once',
    (tester) async {
      final bridge = DnsTestBridge()
        ..clearPending = Completer<Map<String, dynamic>>();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      await openTool(tester, app);
      final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
      final anchor = tester.getRect(keyed('dns-actions'));
      await clear(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.clears, [false]);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(
                of: keyed('dns-actions'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      bridge.clearPending!.complete(dnsCacheReply());
      bridge.clearPending = null;
      await tester.pumpAndSettle();
      expect(find.text(strings.dnsCacheCompleted), findsOneWidget);
      expect(tester.getRect(keyed('dns-actions')), anchor);
      await clear(tester, fakeIp: true);
      await tester.pumpAndSettle();
      expect(find.text(strings.dnsFakeIpWarning), findsOneWidget);
      expect(bridge.clears, [false]);
      await tester.tap(find.widgetWithText(TextButton, strings.cancel));
      await tester.pumpAndSettle();
      await clear(tester, fakeIp: true);
      await tester.pumpAndSettle();
      bridge.clearValue = dnsCacheReply(fakeIp: true, status: 'empty');
      await tester.tap(find.widgetWithText(TextButton, strings.dnsClearFakeIp));
      await tester.pumpAndSettle();
      expect(bridge.clears, [false, true]);
      expect(find.text(strings.dnsFakeIpEmpty), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tapKey(tester, 'dns-cache-details');
      await tester.pumpAndSettle();
      expect(
        selectable(
          [
            strings.dnsFakeIpEmpty,
            'IPv4 · ${strings.dnsPoolInactive}',
            'IPv6 · ${strings.dnsPoolInactive}',
            strings.dnsPersistentPoolDisabled,
          ].join('\n'),
        ),
        findsOneWidget,
      );
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final language in ['en', 'zh']) {
    testWidgets(
      'mixed fake-IP family facts remain copyable and reopenable $language',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.reset);
        final value = dnsCacheReply(
          fakeIp: true,
          status: 'partialOrFailed',
          persistent: true,
        );
        (value['cache'] as Map)['ipv4'] = {
          'active': true,
          'outcome': 'cleared',
        };
        (value['cache'] as Map)['ipv6'] = {
          'active': true,
          'outcome': 'unconfirmed',
        };
        final bridge = DnsTestBridge()..clearValue = value;
        final app = DnsTestApp(bridge);
        addTearDown(app.dispose);
        await openTool(tester, app, language: language, scale: 2);
        final strings = AppLocalizations.of(
          tester.element(find.byType(DnsTool)),
        );
        await clear(tester, fakeIp: true);
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(TextButton, strings.dnsClearFakeIp),
        );
        await tester.pumpAndSettle();
        final expected = [
          strings.dnsCachePartialOrFailed,
          'IPv4 · ${strings.dnsPoolCleared}',
          'IPv6 · ${strings.dnsPoolUnconfirmed}',
          strings.dnsPersistentPoolEnabled,
        ].join('\n');
        await openDnsNoticeDetails(tester);
        expect(selectable(expected), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
        await tapKey(tester, 'dns-cache-details');
        await tester.pumpAndSettle();
        await openDnsNoticeDetails(tester);
        expect(selectable(expected), findsOneWidget);
        expect(bridge.clears, [true]);
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
        app.publish(network: 2);
        await tester.pump();
        expect(keyed('dns-cache-details'), findsNothing);
        expect(
          find.text(
            '${strings.dnsCachePartialOrFailed} · ${strings.dnsExpired}',
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final reason in ['background', 'network', 'cover']) {
    testWidgets('fake-IP confirmation cannot replay after $reason', (
      tester,
    ) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      await openTool(tester, app);
      final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
      await clear(tester, fakeIp: true);
      await tester.pumpAndSettle();
      switch (reason) {
        case 'background':
          app.setForeground(false);
          app.setForeground(true);
        case 'network':
          app.publish(network: 2);
        case 'cover':
          final navigator = Navigator.of(
            tester.element(find.byType(AlertDialog)),
          );
          unawaited(
            navigator.push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    const Scaffold(body: Text('Controlled covering route')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          navigator.pop();
          await tester.pumpAndSettle();
      }
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, strings.dnsClearFakeIp));
      await tester.pumpAndSettle();
      expect(bridge.clears, isEmpty);
      expect(app.commands, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

void dnsVisualInteractionTests() {
  for (final (language, scale, dark) in [
    ('en', 1.0, false),
    ('zh', 2.0, true),
  ]) {
    for (final reduced in [false, true]) {
      testWidgets(
        'name glyphs survive focus IME and result return $language/$scale/reduced=$reduced',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(700, 1000);
          addTearDown(tester.view.reset);
          final bridge = DnsTestBridge();
          final app = DnsTestApp(bridge);
          addTearDown(app.dispose);
          final controller = await openTool(
            tester,
            app,
            language: language,
            scale: scale,
            dark: dark,
            disableAnimations: reduced,
          );
          final strings = AppLocalizations.of(
            tester.element(find.byType(DnsTool)),
          );
          final input = tester.widget<TextField>(keyed('dns-name')).controller!;
          final state = tester.state(keyed('dns-name'));
          final tool = tester.state(find.byType(DnsTool));
          await expectNameLabelPainted(tester, strings.dnsName);
          await tester.tap(keyed('dns-name'));
          await tester.pump(const Duration(milliseconds: 80));
          await expectNameLabelPainted(tester, strings.dnsName);
          await tester.enterText(keyed('dns-name'), 'controlled.example');
          input.value = input.value.copyWith(
            selection: const TextSelection(baseOffset: 1, extentOffset: 5),
            composing: const TextRange(start: 1, end: 5),
          );
          final value = input.value;
          for (final inset in [300.0, 0.0]) {
            tester.view.viewInsets = FakeViewPadding(bottom: inset);
            await tester.pumpAndSettle();
            await tester.ensureVisible(keyed('dns-name'));
            await tester.pumpAndSettle();
            await expectNameLabelPainted(tester, strings.dnsName);
            expect(input.value, value);
          }
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          await expectNameLabelPainted(tester, strings.dnsName);
          final unfocusedValue = input.value;
          await tapKey(tester, 'dns-query');
          bridge.replies.single.complete(dnsReply());
          await tester.pumpAndSettle();
          await tapKey(tester, 'dns-edit');
          if (!reduced) {
            await tester.pump(const Duration(milliseconds: 100));
            expect(formExtent(tester), inExclusiveRange(0, 1));
            await expectNameLabelPainted(tester, strings.dnsName);
          }
          await tester.pumpAndSettle();
          await expectNameLabelPainted(tester, strings.dnsName);
          expect(tester.state(keyed('dns-name')), same(state));
          expect(
            tester.widget<TextField>(keyed('dns-name')).controller,
            same(input),
          );
          expect(input.value, unfocusedValue);
          expect(tester.state(find.byType(DnsTool)), same(tool));
          expect(controller.response, isNotNull);
          expect(bridge.queries, hasLength(1));
          expect(bridge.cancellations, isEmpty);
          await tester.enterText(keyed('dns-name'), '');
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump(const Duration(milliseconds: 80));
          await expectNameLabelPainted(tester, strings.dnsName);
          await tester.pumpAndSettle();
          await expectNameLabelPainted(tester, strings.dnsName);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final language in ['en', 'zh']) {
    for (final width in [320.0, 700.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'grouped query controls and summary action geometry $language/$width/$scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1200);
            addTearDown(tester.view.reset);
            final bridge = DnsTestBridge();
            final app = DnsTestApp(bridge);
            addTearDown(app.dispose);
            await openTool(tester, app, language: language, scale: scale);
            final strings = AppLocalizations.of(
              tester.element(find.byType(DnsTool)),
            );
            final query = tester.getRect(keyed('dns-query'));
            final refresh = tester.getRect(keyed('dns-refresh'));
            final type = tester.getRect(keyed('dns-type'));
            final actions = tester.getRect(keyed('dns-query-actions'));
            final controls = tester.getRect(keyed('dns-query-controls'));
            final name = tester.getRect(keyed('dns-name'));
            expect(name.left, controls.left);
            expect(name.right, controls.right);
            expect(query.height, refresh.height);
            for (final rect in [query, refresh, type]) {
              expect(rect.height, greaterThanOrEqualTo(48));
              expect(rect.width, greaterThanOrEqualTo(48));
              expect(rect.left, greaterThanOrEqualTo(controls.left));
              expect(rect.right, lessThanOrEqualTo(controls.right + .01));
            }
            if ((query.top - refresh.top).abs() < .01) {
              expect(refresh.left - query.right, closeTo(8, .01));
            } else {
              expect(refresh.top - query.bottom, closeTo(8, .01));
              expect(query.left, refresh.left);
              expect(query.width, refresh.width);
            }
            if ((type.center.dy - actions.center.dy).abs() > .01) {
              expect(actions.top, greaterThanOrEqualTo(type.bottom));
            }
            final visibleRefresh = find.descendant(
              of: keyed('dns-refresh'),
              matching: find.text(strings.dnsRefreshCoreStatus),
            );
            final paragraph = tester.renderObject<RenderParagraph>(
              visibleRefresh,
            );
            expect(paragraph.didExceedMaxLines, isFalse);
            await tapKey(tester, 'dns-refresh');
            expect(app.refreshes, 1);
            expect(bridge.queries, isEmpty);
            await tester.enterText(keyed('dns-name'), 'controlled.example');
            await tapKey(tester, 'dns-query');
            expect(tester.getRect(keyed('dns-query')), query);
            expect(tester.getRect(keyed('dns-refresh')), refresh);
            expect(
              tester.widget<FilledButton>(keyed('dns-refresh')).onPressed,
              isNull,
            );
            bridge.replies.single.complete(dnsReply());
            await tester.pumpAndSettle();
            final summary = tester.getRect(keyed('dns-result-summary'));
            final identity = tester.getRect(keyed('dns-result-identity'));
            final raw = tester.getRect(keyed('dns-raw-data'));
            expect(raw.right, closeTo(summary.right, .01));
            expect(raw.width, lessThanOrEqualTo(summary.width));
            if (width == 700 && scale == 1) {
              expect(raw.top, closeTo(summary.top, .01));
              expect(raw.left, greaterThan(identity.right));
            } else if (width == 320 && scale == 2) {
              expect(raw.top, greaterThanOrEqualTo(identity.bottom));
            }
            final rawLabel = tester.renderObject<RenderParagraph>(
              find.descendant(
                of: keyed('dns-raw-data'),
                matching: find.text(strings.rawData),
              ),
            );
            expect(rawLabel.didExceedMaxLines, isFalse);
            expect(
              find.descendant(
                of: find.byType(DnsTool),
                matching: find.byIcon(Icons.info_outline),
              ),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'visible result action returns to the same response, not JSON or another query',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      final controller = await openTool(tester, app);
      final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
      expect(keyed('dns-query-details').hitTestable(), findsNothing);
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      final input = tester.widget<TextField>(keyed('dns-name')).controller!;
      final state = tester.state(find.byType(DnsTool));
      final route = ModalRoute.of(tester.element(find.byType(DnsTool)));
      final scroll = tester
          .widget<CustomScrollView>(
            find.byKey(const PageStorageKey('dns-tool-scroll')),
          )
          .controller;
      await tapKey(tester, 'dns-query');
      bridge.replies.single.complete(dnsReply());
      await tester.pumpAndSettle();
      final response = controller.response;
      await tapKey(tester, 'dns-edit');
      await tester.pumpAndSettle();
      await tapKey(tester, 'dns-actions');
      await tester.pumpAndSettle();
      expect(
        find
            .widgetWithText(MenuItemButton, strings.dnsViewQueryResults)
            .hitTestable(),
        findsOneWidget,
      );
      await tapKey(tester, 'dns-query-details');
      await tester.pumpAndSettle();
      expect(keyed('dns-result-summary'), findsOneWidget);
      final identity = find
          .ancestor(
            of: selectable(
              strings.dnsQueryIdentity(
                controller.response!.name,
                controller.response!.type,
              ),
            ),
            matching: find.byType(Column),
          )
          .first;
      expect(tester.widget<Column>(identity).children, hasLength(2));
      expect(
        find.descendant(
          of: keyed('dns-result-summary'),
          matching: find.byWidgetPredicate(
            (widget) => widget is Visibility && widget.maintainSize,
          ),
        ),
        findsNothing,
      );
      expect(find.byType(OriginalTextView), findsNothing);
      expect(controller.response, same(response));
      expect(tester.state(find.byType(DnsTool)), same(state));
      expect(ModalRoute.of(tester.element(find.byType(DnsTool))), same(route));
      expect(
        tester
            .widget<CustomScrollView>(
              find.byKey(const PageStorageKey('dns-tool-scroll')),
            )
            .controller,
        same(scroll),
      );
      expect(bridge.queries, hasLength(1));
      await tapKey(tester, 'dns-edit');
      await tester.pumpAndSettle();
      await tester.enterText(keyed('dns-name'), 'new-draft.example');
      await tester.pump();
      await tapKey(tester, 'dns-actions');
      await tester.pumpAndSettle();
      expect(
        find
            .widgetWithText(MenuItemButton, strings.dnsViewPreviousQuery)
            .hitTestable(),
        findsOneWidget,
      );
      await tapKey(tester, 'dns-query-details');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: keyed('dns-result-summary'),
          matching: find.text(strings.dnsPreviousQuery),
        ),
        findsNothing,
      );
      await tapKey(tester, 'dns-raw-data');
      await tester.pumpAndSettle();
      expect(dialogText(strings.dnsQueryRawData), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      final reader = tester.widget<OriginalTextView>(
        find.byType(OriginalTextView),
      );
      expect(jsonDecode(reader.text), response!.raw);
      expect(
        find.descendant(
          of: find.byType(OriginalTextView),
          matching: selectable(
            strings.dnsQueryIdentity(response.name, response.type),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(OriginalTextView),
          matching: find.text(
            strings.dnsResponseSource(strings.runtimeConfigLive),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(OriginalTextView),
          matching: find.textContaining('new-draft.example'),
        ),
        findsNothing,
      );
      final readerState = tester.state(find.byType(OriginalTextView));
      app.publish(core: dnsCore(generation: 2), generation: 2, network: 2);
      await tester.pump();
      expect(tester.state(find.byType(OriginalTextView)), same(readerState));
      expect(
        tester.widget<OriginalTextView>(find.byType(OriginalTextView)).text,
        reader.text,
      );
      expect(
        find.descendant(
          of: find.byType(OriginalTextView),
          matching: find.text(strings.dnsPreviousQuery),
        ),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pumpAndSettle();
      await tapKey(tester, 'dns-edit');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller,
        same(input),
      );
      expect(input.text, 'new-draft.example');
      expect(bridge.queries, hasLength(1));
      expect(bridge.cancellations, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'error and cache labels lead to their own summary and complete copyable data',
    (tester) async {
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      await openTool(tester, app);
      final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      await tapKey(tester, 'dns-query');
      final failure = dnsError('unknown-wire-code');
      (failure['dns'] as Map)['detail'] =
          'original cause\nCaused by: resolver\nSuppressed: close';
      failure['unknown'] = [
        false,
        0,
        null,
        {'future': 'full'},
      ];
      bridge.replies.single.complete(failure);
      await tester.pumpAndSettle();
      await openDnsNoticeDetails(tester);
      expect(dialogText(strings.errorDetails), findsOneWidget);
      await openDnsNoticeDetails(tester);
      expect(selectable(strings.dnsQueryFailed), findsOneWidget);
      expect(find.byType(OriginalTextView), findsNothing);
      await showTechnical(tester);
      expect(dialogText(strings.technicalDetails), findsOneWidget);
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
      await tapKey(tester, 'original-text-copy');
      expect(jsonDecode(copied!), failure);
      await closeTopDialog(tester, strings.close);
      expect(find.byType(AlertDialog), findsOneWidget);
      await openDnsNoticeDetails(tester);
      expect(selectable(strings.dnsQueryFailed), findsOneWidget);
      await closeTopDialog(tester, strings.close);
      expect(find.byType(AlertDialog), findsNothing);
      await tapKey(tester, 'dns-actions');
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(MenuItemButton, strings.errorDetails).hitTestable(),
        findsOneWidget,
      );
      final value = dnsCacheReply(
        fakeIp: true,
        status: 'partialOrFailed',
        persistent: true,
      );
      (value['cache'] as Map)['unknown'] = [false, null, 0];
      bridge.clearValue = value;
      await clear(tester, fakeIp: true);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, strings.dnsClearFakeIp));
      await tester.pumpAndSettle();
      await openDnsNoticeDetails(tester);
      expect(dialogText(strings.dnsCacheOperationDetails), findsOneWidget);
      expect(dialogText(strings.dnsClearFakeIp), findsOneWidget);
      expect(find.byType(OriginalTextView), findsNothing);
      await showTechnical(tester);
      expect(dialogText(strings.dnsCacheRawData), findsOneWidget);
      expect(find.text(strings.dnsQueryRawData), findsNothing);
      await tapKey(tester, 'original-text-copy');
      expect(jsonDecode(copied!), value);
      expect(bridge.clears, [true]);
      expect(bridge.queries, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'real Tab order and responsive reflow preserve the focused query group',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1000);
      addTearDown(tester.view.reset);
      final bridge = DnsTestBridge();
      final app = DnsTestApp(bridge);
      addTearDown(app.dispose);
      await openTool(tester, app);
      final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
      await tester.enterText(keyed('dns-name'), 'controlled.example');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNWidgets(12));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(bridge.queries, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final queryLabel = find.descendant(
        of: keyed('dns-query'),
        matching: find.text(strings.dnsQuery),
      );
      final queryFocus = Focus.of(tester.element(queryLabel));
      expect(queryFocus.hasPrimaryFocus, isTrue);
      final queryState = tester.state(keyed('dns-query'));
      final refreshState = tester.state(keyed('dns-refresh'));
      for (final width in [320.0, 560.0, 700.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();
        expect(tester.state(keyed('dns-query')), same(queryState));
        expect(tester.state(keyed('dns-refresh')), same(refreshState));
        expect(Focus.of(tester.element(queryLabel)), same(queryFocus));
        expect(queryFocus.hasPrimaryFocus, isTrue);
        expect(bridge.queries, isEmpty);
        expect(app.refreshes, 0);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final refreshLabel = find.descendant(
        of: keyed('dns-refresh'),
        matching: find.text(strings.dnsRefreshCoreStatus),
      );
      expect(Focus.of(tester.element(refreshLabel)).hasPrimaryFocus, isTrue);
      expect(refreshLabel.hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(app.refreshes, 1);
      expect(bridge.queries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
