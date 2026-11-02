import 'dart:async';

import 'package:clash_pseudo/src/ui/overrides/forms/proxy/proxy_form_type_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const rawTypes = [
  'http',
  'socks5',
  'ssh',
  'masque',
  'ss',
  'ssr',
  'vmess',
  'vless',
  'snell',
  'trojan',
  'hysteria',
  'hysteria2',
  'tuic',
  'shadowquic',
  'gost-relay',
  'mieru',
  'anytls',
  'sudoku',
  'trusttunnel',
  'wireguard',
  'openvpn',
  'zerotier',
  'easytier',
  'tailscale',
  'direct',
  'dns',
  'reject',
  'rematch',
];

void main() {
  final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
  setUpAll(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDownAll(
    () => WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy,
  );
  test('exactly 28 original parser types in four fixed categories', () {
    expect(ProxyFormType.values.map((type) => type.raw), rawTypes);
    expect(ProxyFormType.values.map((type) => type.raw).toSet().length, 28);
    expect(
      [
        for (final category in ProxyFormCategory.values)
          ProxyFormType.values
              .where((type) => type.category == category)
              .length,
      ],
      [4, 15, 5, 4],
    );
    expect(() => ProxyFormType.fromRaw('https'), throwsArgumentError);
    expect(() => ProxyFormType.fromRaw('socks5-tls'), throwsArgumentError);
  });

  testWidgets(
    'each actual row returns its exact raw type, not a friendly preset',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const ProxyFormTypePage(selectedType: 'http'),
                    ),
                  );
                },
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      );
      for (final raw in rawTypes.take(24)) {
        await tester.tap(find.text('Choose'));
        await tester.pumpAndSettle();
        final row = find.byKey(ValueKey('proxy-type:$raw'));
        await tester.scrollUntilVisible(
          row,
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(result, raw);
        expect(find.byType(ProxyFormTypePage), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'covered and exiting choice routes reject retained row callbacks',
    (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const ProxyFormTypePage(selectedType: 'http'),
                    ),
                  );
                },
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      final choose = tester
          .widget<ListTile>(find.byKey(const ValueKey('proxy-type:socks5')))
          .onTap!;
      final navigator = Navigator.of(
        tester.element(find.byType(ProxyFormTypePage)),
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      choose();
      await tester.pump();
      expect(find.text('cover'), findsOneWidget);
      expect(result, isNull);
      navigator.pop();
      await tester.pumpAndSettle();
      choose();
      await tester.pump();
      expect(result, 'socks5');
      choose();
      await tester.pumpAndSettle();
      expect(find.text('Choose'), findsOneWidget);
      expect(result, 'socks5');
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in [const Locale('en'), const Locale('zh')]) {
    testWidgets(
      '${locale.languageCode} narrow large-font selection preserves row positions and full labels',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final selected = ValueNotifier<String>('http');
        addTearDown(selected.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: ValueListenableBuilder<String>(
              valueListenable: selected,
              builder: (_, value, _) => ProxyFormTypePage(selectedType: value),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final http = find.byKey(const ValueKey('proxy-type:http'));
        final socks = find.byKey(const ValueKey('proxy-type:socks5'));
        final httpBefore = tester.getRect(http);
        final socksBefore = tester.getRect(socks);
        selected.value = 'socks5';
        await tester.pump();
        expect(tester.getRect(http), httpBefore);
        expect(tester.getRect(socks), socksBefore);
        expect(find.byType(SegmentedButton), findsNothing);
        final lastProtocol = find.byKey(const ValueKey('proxy-type:tailscale'));
        await tester.scrollUntilVisible(
          lastProtocol,
          300,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        expect(find.text('Tailscale'), findsOneWidget);
        for (final raw in ['direct', 'dns', 'reject', 'rematch']) {
          expect(find.byKey(ValueKey('proxy-type:$raw')), findsNothing);
          expect(
            ProxyFormType.fromRaw(raw).category,
            ProxyFormCategory.builtin,
          );
        }
        final strings = AppLocalizations.of(
          tester.element(find.byType(ProxyFormTypePage)),
        );
        expect(find.text(strings.proxyCategoryBuiltin), findsNothing);
        expect(find.text(strings.proxyBuiltinDescription), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
