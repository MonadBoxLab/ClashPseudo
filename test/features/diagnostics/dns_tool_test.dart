import 'dart:async';

import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/features/diagnostics/dns_controller.dart';
import 'package:clash_pseudo/src/features/diagnostics/dns_tool.dart';
import 'package:clash_pseudo/src/features/settings/settings_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dns_fakes.dart';

Finder keyed(String value) => find.byKey(ValueKey(value));
Finder selectable(String value) =>
    find.byWidgetPredicate((w) => w is SelectableText && w.data == value);

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.pump();
  if (keyed(key).hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(keyed(key));
    await tester.pump();
  }
  await tester.tap(keyed(key));
  await tester.pump();
}

Future<DnsController> openTool(
  WidgetTester tester,
  DnsTestApp app, {
  String language = 'en',
  double scale = 1,
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(language),
      theme: dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
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
  await tapKey(tester, 'dns-actions');
  await tester.pumpAndSettle();
  final strings = AppLocalizations.of(tester.element(find.byType(DnsTool)));
  final item = find.widgetWithText(
    MenuItemButton,
    fakeIp ? strings.dnsClearFakeIp : strings.dnsClearCache,
  );
  await tester.ensureVisible(item);
  await tester.pump();
  await tester.tap(item);
  await tester.pump();
  await tester.pump();
}

void main() {
  for (final language in ['en', 'zh']) {
    for (final width in [280.0, 700.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'settings DNS form keeps anchors through validation, waiting, failure and retry $language/$width/$scale',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1100);
            addTearDown(tester.view.reset);
            final bridge = DnsTestBridge();
            final app = DnsTestApp(bridge);
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
            await tester.enterText(
              keyed('dns-name'),
              'https://controlled.example',
            );
            await tester.ensureVisible(keyed('dns-query'));
            await tester.pump();
            final anchors = {
              for (final key in [
                'dns-name',
                'dns-type',
                'dns-query',
                'dns-actions',
                'dns-status',
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
            expect(bridge.queries, isEmpty);
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
            bridge.replies.single.complete(dnsError('timeout'));
            await tester.pumpAndSettle();
            checkAnchors();
            final strings = AppLocalizations.of(
              tester.element(find.byType(DnsTool)),
            );
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(selectable(strings.dnsTimeout), findsOneWidget);
            await tester.tap(find.widgetWithText(TextButton, strings.close));
            await tester.pumpAndSettle();
            checkAnchors();
            await tapKey(tester, 'dns-query');
            bridge.replies.last.complete(dnsReply(rcode: 3, answer: []));
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
      await openTool(tester, app);
      const name = r'例子\.service.example';
      await tester.enterText(keyed('dns-name'), name);
      final anchor = tester.getRect(keyed('dns-type'));
      await tapKey(tester, 'dns-type');
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<MenuItemButton>(find.byType(MenuItemButton))
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
      final firstItem = tester.getRect(find.byType(MenuItemButton).first);
      expect(firstItem.right, closeTo(anchor.right, .01));
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
      expect(controller.response!.answer.single.data, '192.0.2.1');
      expect(controller.stale, isTrue);
      expect(
        tester.widget<TextField>(keyed('dns-name')).controller!.text,
        'controlled.example',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

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
        for (final data in ['ns.controlled.example.', '2001:db8::1']) {
          await tester.scrollUntilVisible(
            selectable(data),
            250,
            scrollable: find
                .descendant(of: scroll, matching: find.byType(Scrollable))
                .first,
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
        expect(selectable(expected), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
        await tapKey(tester, 'dns-cache-details');
        await tester.pumpAndSettle();
        expect(selectable(expected), findsOneWidget);
        expect(bridge.clears, [true]);
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
        app.publish(network: 2);
        await tester.pump();
        expect(keyed('dns-cache-details').hitTestable(), findsNothing);
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
