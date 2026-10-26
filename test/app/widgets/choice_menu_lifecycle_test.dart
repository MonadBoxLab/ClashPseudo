import 'dart:async';

import 'package:clash_pseudo/src/app/widgets/choice_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('root menu registers Android Back before it can be invoked', (
    tester,
  ) async {
    final handlesBack = <bool>[];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          handlesBack.add(call.arguments as bool);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Root')),
          body: ChoiceMenuButton<int>(
            options: const {1: 'First'},
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(handlesBack.last, isFalse);
    for (final select in [false, true]) {
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      expect(handlesBack.last, isTrue);
      expect(find.byType(BackButton), findsNothing);
      if (select) {
        await tester.tap(find.byType(MenuItemButton));
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(find.text('Root'), findsOneWidget);
      expect(handlesBack.last, isFalse);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'system Back dismisses the menu without moving the AppBar or popping the page',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            appBar: AppBar(title: const Text('Page')),
            body: Align(
              alignment: Alignment.topRight,
              child: ChoiceMenuButton<int>(
                options: const {1: 'First'},
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      final title = tester.getRect(find.text('Page'));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsNothing);
      expect(tester.getRect(find.text('Page')), title);
      await tester.binding.handlePopRoute();
      for (final milliseconds in [0, 16, 100, 300]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(tester.getRect(find.text('Page')), title);
        expect(find.byType(BackButton), findsNothing);
      }
      expect(find.byType(MenuItemButton), findsNothing);
      expect(navigator.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a retired callback cannot borrow a newly opened menu identity', (
    tester,
  ) async {
    final epoch = ValueNotifier(1);
    addTearDown(epoch.dispose);
    final saved = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: epoch,
            builder: (context, identity, _) => Align(
              alignment: Alignment.topRight,
              child: ChoiceMenuButton<int>(
                identity: identity,
                options: const {1: 'First'},
                onSelected: (value) => saved.add((identity, value)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final retired = tester.widget<MenuItemButton>(find.byType(MenuItemButton));
    epoch.value = 2;
    await tester.pumpAndSettle();
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    retired.onPressed!();
    expect(saved, isEmpty);
    await tester.tap(find.byType(MenuItemButton));
    await tester.pumpAndSettle();
    expect(saved, [(2, 1)]);
    await tester.pumpWidget(const SizedBox());
  });

  for (final animations in [false, true]) {
    testWidgets(
      'cancelled selection cannot target a reopened same-identity menu animations=$animations',
      (tester) async {
        final selected = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: !animations),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: ChoiceMenuButton<int>(
                  identity: 'same-source',
                  options: const {1: 'First'},
                  onSelected: selected.add,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        final retired = tester
            .widget<MenuItemButton>(find.byType(MenuItemButton))
            .onPressed!;
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
        retired();
        expect(selected, isEmpty);
        await tester.tap(find.byType(IconButton));
        await tester.pumpAndSettle();
        retired();
        expect(selected, isEmpty);
        await tester.tap(find.byType(MenuItemButton));
        await tester.pumpAndSettle();
        expect(selected, [1]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'a covering route dismisses the menu and rejects its old callback',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: ChoiceMenuButton<int>(
                options: const {1: 'First'},
                onSelected: (_) => selected++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      final old = tester.widget<MenuItemButton>(find.byType(MenuItemButton));
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      old.onPressed!();
      expect(selected, 0);
      expect(find.byType(MenuItemButton), findsNothing);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(navigator.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('selecting retires Back history before the operation starts', (
    tester,
  ) async {
    final pending = Completer<void>();
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Operation page')),
                    body: ChoiceMenuButton<int>(
                      options: const {1: 'Start'},
                      onSelected: (_) async {
                        started = true;
                        await pending.future;
                      },
                    ),
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
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Start'));
    await tester.pump();
    expect(started, isTrue);
    final route = ModalRoute.of(tester.element(find.text('Operation page')))!;
    expect(route.willHandlePopInternally, isFalse);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Operation page'), findsNothing);
    pending.complete();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding retires an open menu before any resumed frame', (
    tester,
  ) async {
    final selected = <int>[];
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: ChoiceMenuButton<int>(
                identity: 'unchanged',
                options: const {1: 'First'},
                onSelected: selected.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      final old = tester
          .widget<MenuItemButton>(find.byType(MenuItemButton))
          .onPressed!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      old();
      expect(selected, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      old();
      expect(selected, isEmpty);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MenuItemButton));
      await tester.pumpAndSettle();
      expect(selected, [1]);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });

  testWidgets('temporary disable cannot revive a closing selection', (
    tester,
  ) async {
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: enabled,
            builder: (context, value, _) => ChoiceMenuButton<int>(
              identity: 'same-source',
              enabled: value,
              options: const {1: 'First'},
              onSelected: selected.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final old = tester
        .widget<MenuItemButton>(find.byType(MenuItemButton))
        .onPressed!;
    expect(find.semantics.byLabel('First'), findsOne);
    enabled.value = false;
    await tester.pump();
    expect(find.byType(MenuItemButton).hitTestable(), findsNothing);
    expect(find.semantics.byLabel('First'), findsNothing);
    enabled.value = true;
    await tester.pump();
    old();
    for (final item in tester.widgetList<MenuItemButton>(
      find.byType(MenuItemButton),
    )) {
      item.onPressed?.call();
    }
    expect(selected, isEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    old();
    expect(selected, isEmpty);
    await tester.tap(find.byType(MenuItemButton));
    await tester.pumpAndSettle();
    expect(selected, [1]);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  }, semanticsEnabled: true);

  testWidgets('returning to the opening size cannot revive a closing menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final selected = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: ChoiceMenuButton<int>(
              identity: 'same-source',
              options: const {1: 'First'},
              onSelected: selected.add,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final old = tester
        .widget<MenuItemButton>(find.byType(MenuItemButton))
        .onPressed!;
    tester.view.physicalSize = const Size(599, 900);
    await tester.pump();
    tester.view.physicalSize = const Size(700, 900);
    await tester.pump();
    old();
    expect(selected, isEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    old();
    expect(selected, isEmpty);
    await tester.tap(find.byType(MenuItemButton));
    await tester.pumpAndSettle();
    expect(selected, [1]);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disabled options stay disabled and availability changes retire the opening',
    (tester) async {
      final disabled = ValueNotifier<Set<int>>({2});
      addTearDown(disabled.dispose);
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: disabled,
              builder: (context, value, _) => ChoiceMenuButton<int>(
                identity: 'same-source',
                options: const {1: 'First', 2: 'Unavailable'},
                disabledOptions: value,
                onSelected: selected.add,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      final blocked = find.widgetWithText(MenuItemButton, 'Unavailable');
      expect(tester.widget<MenuItemButton>(blocked).onPressed, isNull);
      await tester.tap(blocked);
      await tester.pump();
      expect(selected, isEmpty);
      final old = tester
          .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'First'))
          .onPressed!;
      disabled.value = {};
      await tester.pump();
      disabled.value = {2};
      await tester.pump();
      old();
      expect(selected, isEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(tester.widget<MenuItemButton>(blocked).onPressed, isNull);
      await tester.tap(find.widgetWithText(MenuItemButton, 'First'));
      await tester.pumpAndSettle();
      expect(selected, [1]);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing during opening retires local history and focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChoiceMenuButton<int>(
            options: const {1: 'First'},
            onSelected: (_) => fail('Disposed menu selected'),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
