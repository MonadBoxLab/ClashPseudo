import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _OnDeactivate extends StatefulWidget {
  const _OnDeactivate({required this.onDeactivate});

  final VoidCallback onDeactivate;

  @override
  State<_OnDeactivate> createState() => _OnDeactivateState();
}

class _OnDeactivateState extends State<_OnDeactivate> {
  @override
  void deactivate() {
    super.deactivate();
    widget.onDeactivate();
  }

  @override
  Widget build(BuildContext context) => const Text('reader header');
}

void main() {
  testWidgets(
    'removed reader rejects cached copy while inactive on the same live route',
    (tester) async {
      final reply = Completer<Object?>();
      final copies = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copies.add(call.arguments['text'] as String);
            return reply.future;
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
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final readerKey = GlobalKey();
      const original = '﻿same\r\n原文';
      late VoidCallback cachedCopy;
      late ModalRoute<dynamic> route;
      var deactivations = 0;
      var newActions = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [AppTaskNavigatorObserver()],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: visible,
              builder: (_, shown, _) => shown
                  ? OriginalTextView(
                      key: readerKey,
                      text: original,
                      header: _OnDeactivate(
                        onDeactivate: () {
                          deactivations++;
                          final origin = readerKey.currentContext!;
                          expect(origin.mounted, isTrue);
                          expect((origin as Element).debugIsActive, isFalse);
                          expect(route.isActive, isTrue);
                          expect(route.isCurrent, isTrue);
                          cachedCopy();
                          reply.completeError(
                            PlatformFailure(
                              code: 'fixture',
                              message: 'late original cause',
                            ),
                          );
                        },
                      ),
                    )
                  : TextButton(
                      onPressed: () => newActions++,
                      child: const Text('new reader root'),
                    ),
            ),
          ),
        ),
      );
      route = ModalRoute.of(readerKey.currentContext!)!;
      cachedCopy = tester
          .widget<IconButton>(find.byKey(const ValueKey('original-text-copy')))
          .onPressed!;
      cachedCopy();
      await tester.pump();
      expect(copies, [original]);
      visible.value = false;
      await tester.pumpAndSettle();
      expect(deactivations, 1);
      expect(copies, [original]);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('new reader root'));
      expect(newActions, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('reattached reader captures live ownership and can copy again', (
    tester,
  ) async {
    var copies = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copies++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final moved = ValueNotifier(false);
    addTearDown(moved.dispose);
    final readerKey = GlobalKey();
    var armed = false;
    var deactivations = 0;
    late VoidCallback cachedCopy;
    final reader = OriginalTextView(
      key: readerKey,
      text: '﻿reattached\r\n原文',
      header: _OnDeactivate(
        onDeactivate: () {
          if (!armed) return;
          deactivations++;
          expect(readerKey.currentContext!.mounted, isTrue);
          expect((readerKey.currentContext! as Element).debugIsActive, isFalse);
          cachedCopy();
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: moved,
            builder: (_, right, _) => Row(
              children: [
                Expanded(child: right ? const SizedBox() : reader),
                Expanded(child: right ? reader : const SizedBox()),
              ],
            ),
          ),
        ),
      ),
    );
    final state = readerKey.currentState;
    cachedCopy = tester
        .widget<IconButton>(find.byKey(const ValueKey('original-text-copy')))
        .onPressed!;
    cachedCopy();
    await tester.pump();
    expect(copies, 1);
    armed = true;
    moved.value = true;
    await tester.pump();
    armed = false;
    expect(deactivations, 1);
    expect(readerKey.currentState, same(state));
    expect(copies, 1);
    cachedCopy();
    await tester.pump();
    expect(copies, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'captured task owner rejects copy and late failure before a frame',
    (tester) async {
      final reply = Completer<Object?>();
      var copies = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copies++;
            return reply.future;
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
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: active,
              child: const OriginalTextView(text: '﻿live task\r\n原文'),
              builder: (_, value, child) => AppTaskActivity(
                active: value,
                isActiveNow: () => active.value,
                child: child!,
              ),
            ),
          ),
        ),
      );
      final cachedCopy = tester
          .widget<IconButton>(find.byKey(const ValueKey('original-text-copy')))
          .onPressed!;
      cachedCopy();
      await tester.pump();
      expect(copies, 1);
      active.value = false;
      cachedCopy();
      reply.completeError(
        PlatformFailure(code: 'fixture', message: 'task late failure'),
      );
      await tester.pumpAndSettle();
      expect(copies, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final change in ['identity', 'text', 'eligibility']) {
    testWidgets(
      'late clipboard errors and cached copy cannot borrow new $change',
      (tester) async {
        final reply = Completer<Object?>();
        var copies = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copies++;
              return reply.future;
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
        final observer = AppTaskNavigatorObserver();
        var eligible = true;
        Widget host(String text, Object identity) => MaterialApp(
          navigatorObservers: [observer],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: OriginalTextView(
              text: text,
              identity: identity,
              isCurrent: () => eligible,
              isCurrentWithPopup: (_) => eligible,
            ),
          ),
        );
        await tester.pumpWidget(host('﻿same\r\n原文', 'source-a'));
        final copy = find.byKey(const ValueKey('original-text-copy'));
        final cachedCopy = tester.widget<IconButton>(copy).onPressed!;
        cachedCopy();
        await tester.pump();
        expect(copies, 1);
        switch (change) {
          case 'identity':
            await tester.pumpWidget(host('﻿same\r\n原文', 'source-b'));
          case 'text':
            await tester.pumpWidget(host('new original', 'source-a'));
          case 'eligibility':
            eligible = false;
        }
        cachedCopy();
        await tester.pump();
        expect(copies, 1);
        reply.completeError(
          PlatformFailure(code: 'fixture', message: 'late cause'),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test('render blocks preserve BOM, all newlines and surrogate pairs', () {
    for (final text in [
      '',
      '﻿first\r\nsecond\rthird\n',
      '${'x' * 8191}🌐${'y' * 8191}🌐\r\n尾部',
      '${'x' * 8191}\r\n${'y' * 20000}',
      ('日🌐\r\n\t"\\\u0000' * 10000),
    ]) {
      final ends = originalTextChunkEnds(text);
      var start = 0;
      final restored = StringBuffer();
      for (final end in ends) {
        final chunk = text.substring(start, end);
        expect(chunk.length, inInclusiveRange(1, 8192));
        expect(chunk.runes.contains(0xfffd), isFalse);
        if (end < text.length) {
          expect(text.substring(end - 1, end + 1), isNot('\r\n'));
        }
        restored.write(chunk);
        start = end;
      }
      expect(restored.toString(), text);
      expect(start, text.length);
    }
  });

  testWidgets('copy uses complete original text, not the visible blocks', (
    tester,
  ) async {
    final text = '﻿${'x' * 40000}🌐\r\nlast\rtail\n';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
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
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OriginalTextView(text: text)),
      ),
    );
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.text(text), findsNothing);
    expect(
      tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .every((widget) => widget.data!.length <= 8192),
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('original-text-copy')));
    await tester.pump();
    expect(copied, text);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dragging a long original block scrolls the reading page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.reset);
    final text = '${'original 原文🙂 ' * 1400}\r\ntail';
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OriginalTextView(text: text)),
      ),
    );
    final list = find.byKey(const ValueKey('original-text-blocks'));
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final block = find.byType(SelectableText).first;
    expect(tester.getRect(block).contains(tester.getCenter(list)), isTrue);
    final before = position.pixels;
    await tester.drag(scrollable, const Offset(0, -250));
    await tester.pump();
    expect(position.pixels, greaterThan(before));
    expect(
      tester.widget<OriginalTextView>(find.byType(OriginalTextView)).text,
      text,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scale in [1.0, 2.0]) {
    for (final change in ['identity', 'text']) {
      testWidgets(
        'copy failure preserves reading position and selection while invalidating old-source actions $scale/$change',
        (tester) async {
          final reply = Completer<void>();
          final failure = PlatformFailure(
            code: 'fixture',
            message: 'copy 原文\r\n',
          );
          final copies = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                copies.add((call.arguments as Map)['text'] as String);
                if (copies.length == 1) await reply.future;
                if (copies.length <= 2) throw failure;
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          final observer = AppTaskNavigatorObserver();
          Widget host(String text, String identity) => MaterialApp(
            navigatorObservers: [observer],
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: OriginalTextView(text: text, identity: identity),
            ),
          );
          const original = '﻿first 原文🙂\r\nsecond\rthird\n';
          await tester.pumpWidget(host(original, 'source-a'));
          final reader = find.byType(OriginalTextView);
          final body = find.byKey(const ValueKey('original-text-blocks'));
          final copy = find.byKey(const ValueKey('original-text-copy'));
          final block = find.byType(SelectableText).first;
          final editing = tester.widget<EditableText>(
            find.descendant(of: block, matching: find.byType(EditableText)),
          );
          final cachedCopy = tester.widget<IconButton>(copy).onPressed!;
          await tester.tap(copy);
          await tester.pump();
          editing.focusNode.requestFocus();
          editing.controller.selection = const TextSelection(
            baseOffset: 1,
            extentOffset: 7,
          );
          await tester.pump();
          final selection = editing.controller.selection;
          final readerState = tester.state(reader);
          final blockState = tester.state(block);
          final position = tester
              .state<ScrollableState>(
                find
                    .descendant(of: body, matching: find.byType(Scrollable))
                    .first,
              )
              .position;
          final offset = position.pixels;
          final targets = [reader, body, copy, block];
          final rectangles = targets.map(tester.getRect).toList();
          expect(editing.focusNode.hasFocus, isTrue);
          expect(tester.getSize(copy).height, greaterThanOrEqualTo(48));
          reply.complete();
          for (final milliseconds in [0, 16, 100, 200]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(targets.map(tester.getRect).toList(), rectangles);
            expect(tester.state(reader), same(readerState));
            expect(tester.state(block), same(blockState));
            expect(editing.controller.selection, selection);
            expect(editing.focusNode.hasFocus, isTrue);
            expect(position.pixels, offset);
            expect(find.byType(AlertDialog), findsNothing);
            expect(tester.takeException(), isNull);
          }
          await tester.pumpAndSettle();
          final notice = find.byType(SnackBar);
          expect(notice, findsOneWidget);
          final close = tester
              .widget<IconButton>(
                find.descendant(of: notice, matching: find.byType(IconButton)),
              )
              .onPressed!;
          final details = tester
              .widget<TextButton>(
                find.descendant(of: notice, matching: find.byType(TextButton)),
              )
              .onPressed!;
          close();
          for (final milliseconds in [0, 16, 100, 200]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(targets.map(tester.getRect).toList(), rectangles);
            expect(editing.controller.selection, selection);
            expect(editing.focusNode.hasFocus, isTrue);
            expect(position.pixels, offset);
          }
          await tester.pumpAndSettle();
          cachedCopy();
          await tester.pumpAndSettle();
          expect(notice, findsOneWidget);
          final current = tester.element(notice);
          for (final action in [close, details]) {
            action();
            await tester.pumpAndSettle();
            expect(tester.element(notice), same(current));
            expect(find.byType(AlertDialog), findsNothing);
            expect(editing.controller.selection, selection);
            expect(editing.focusNode.hasFocus, isTrue);
          }
          final oldActions = [
            tester
                .widget<IconButton>(
                  find.descendant(
                    of: notice,
                    matching: find.byType(IconButton),
                  ),
                )
                .onPressed!,
            tester
                .widget<TextButton>(
                  find.descendant(
                    of: notice,
                    matching: find.byType(TextButton),
                  ),
                )
                .onPressed!,
            cachedCopy,
          ];
          final nextText = change == 'text' ? '﻿next 原文\r\n' : original;
          await tester.pumpWidget(
            host(nextText, change == 'identity' ? 'source-b' : 'source-a'),
          );
          await tester.pumpAndSettle();
          for (final action in oldActions) {
            action();
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byType(SnackBar), findsNothing);
            expect(copies, [original, original]);
          }
          await tester.tap(copy);
          await tester.pumpAndSettle();
          expect(copies, [original, original, nextText]);
          expect(tester.state(reader), same(readerState));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'a new value releases old blocks and reports a clipboard failure',
    (tester) async {
      final failure = PlatformException(
        code: 'fixture',
        message: 'copy 原文 ?token=fixture',
      );
      final copies = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copies.add((call.arguments as Map)['text'] as String);
            if (copies.length == 1) throw failure;
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
      final observer = AppTaskNavigatorObserver();
      Widget host(String text) => MaterialApp(
        navigatorObservers: [observer],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OriginalTextView(text: text)),
      );
      await tester.pumpWidget(host('old' * 10000));
      await tester.pumpWidget(host('新原文'));
      expect(find.text('新原文'), findsOneWidget);
      expect(
        tester.widgetList<SelectableText>(find.byType(SelectableText)),
        hasLength(1),
      );
      final readerState = tester.state(find.byType(OriginalTextView));
      final viewport = find.descendant(
        of: find.byKey(const ValueKey('original-text-blocks')),
        matching: find.byType(Viewport),
      );
      expect(viewport, findsOneWidget);
      final scrollState = Scrollable.of(tester.element(viewport));
      final position = scrollState.position;
      final offset = position.pixels;
      final targets = [
        find.byKey(const ValueKey('original-text-copy')),
        viewport,
        find.byType(SelectableText).first,
      ];
      final rectangles = targets.map(tester.getRect).toList();
      await tester.tap(targets.first);
      for (final milliseconds in [0, 16, 100, 200]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(targets.map(tester.getRect).toList(), rectangles);
        expect(tester.state(find.byType(OriginalTextView)), same(readerState));
        expect(Scrollable.of(tester.element(viewport)), same(scrollState));
        expect(scrollState.position, same(position));
        expect(position.pixels, offset);
        expect(find.byType(AlertDialog), findsNothing);
      }
      await tester.pumpAndSettle();
      final notice = find.byType(SnackBar);
      expect(notice, findsOneWidget);
      expect(find.textContaining('copy 原文 ?token=fixture'), findsNothing);
      final strings = AppLocalizations.of(tester.element(notice));
      await tester.tap(
        find.descendant(of: notice, matching: find.text(strings.errorDetails)),
      );
      await tester.pumpAndSettle();
      final result = find.byType(AlertDialog);
      expect(result, findsOneWidget);
      final resultRoute = ModalRoute.of(tester.element(result))!;
      expect(find.textContaining('copy 原文 ?token=fixture'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('copy 原文 ?token=fixture'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('operation-technical-text')),
            )
            .data,
        failure.toString(),
      );
      await tester.tap(find.byKey(const ValueKey('operation-technical-copy')));
      await tester.pump();
      expect(copies, ['新原文', failure.toString()]);
      expect(ModalRoute.of(tester.element(result)), same(resultRoute));
      expect(resultRoute.isCurrent, isTrue);
      await tester.tap(find.text(strings.close));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(OriginalTextView)), same(readerState));
      expect(Scrollable.of(tester.element(viewport)), same(scrollState));
      expect(scrollState.position, same(position));
      expect(position.pixels, offset);
      expect(find.text('新原文'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
