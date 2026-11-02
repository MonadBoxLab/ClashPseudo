import 'dart:convert';

import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/diagnostics/nodes/nodes_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/rules/rules_page.dart';
import 'package:clash_pseudo/src/ui/diagnostics/configuration/runtime_config_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:clash_pseudo/src/ui/settings/core_cleanup_action.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nodes/node_fakes.dart';
import 'resources/resources_test.dart'
    show ResourceApp, ResourceBridge, resourcePage;
import 'rules/rule_fakes.dart';
import 'configuration/runtime_fakes.dart';

Widget _host(
  Widget page, {
  bool reduced = false,
  ValueListenable<bool>? motion,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  navigatorObservers: [AppTaskNavigatorObserver()],
  builder: (context, child) => motion == null
      ? MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        )
      : ValueListenableBuilder<bool>(
          valueListenable: motion,
          child: child,
          builder: (context, reduced, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
        ),
  home: OperationNoticeHost(child: page),
);

Future<void> _refresh(WidgetTester tester, {required bool runtime}) async {
  final strings = lookupAppLocalizations(const Locale('en'));
  if (runtime) {
    await tester.tap(find.byTooltip(strings.moreActions));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, strings.refresh),
    );
  } else {
    await tester.tap(find.byTooltip(strings.refresh));
  }
  await tester.pump();
}

Future<void> _noticeDetails(WidgetTester tester) async {
  final strings = lookupAppLocalizations(const Locale('en'));
  final details = find.descendant(
    of: find.byType(SnackBar),
    matching: find.widgetWithText(TextButton, strings.errorDetails),
  );
  expect(details.hitTestable(), findsOneWidget);
  await tester.tap(details);
  await tester.pumpAndSettle();
}

class _CleanupBridge extends ResourceBridge {
  @override
  Future<Map<String, dynamic>> coreCleanupCandidates() async => {
    'home': '/fixture/mihomo',
    'items': [
      {
        'kind': 'cache',
        'path': 'cache.db',
        'absolutePath': '/fixture/mihomo/cache.db',
      },
      {
        'kind': 'geo',
        'path': 'Country.mmdb',
        'absolutePath': '/fixture/mihomo/Country.mmdb',
      },
    ],
  };
  int exits = 0;
}

class _CleanupApp extends ResourceApp {
  _CleanupApp(_CleanupBridge super.platform);
  int scheduled = 0;
  @override
  Future<AppSnapshot?> submitAndWait(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    scheduled++;
    final value = AppSnapshot(
      phase: 'RUNNING',
      core: core(1),
      resultSuccess: true,
      resultId: 'cleanup-result',
      resultMessage: messages.resourceUpdateSuccess,
      coreCleanup: const {
        'status': 'completed',
        'scope': 'files',
        'paths': ['Country.mmdb'],
      },
    );
    publish(value);
    return value;
  }
}

void main() {
  for (final nodes in [true, false]) {
    testWidgets('${nodes ? 'nodes' : 'rules'} 原错误弹窗保持可读，不能关闭新页面', (
      tester,
    ) async {
      final AppBridge bridge = nodes ? NodeBridge() : RuleBridge();
      final app = TestApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        _host(
          nodes
              ? NodesPage(app: app, provider: 'provider')
              : RulesPage(app: app, provider: 'set'),
        ),
      );
      final failure = StateError('exact original error, false 0 null');
      if (bridge is NodeBridge) bridge.replies.last.completeError(failure);
      if (bridge is RuleBridge) bridge.replies.last.completeError(failure);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey(nodes ? 'node-read-error' : 'rule-read-error')),
        findsNothing,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await _noticeDetails(tester);
      final popup = ModalRoute.of(tester.element(find.byType(AlertDialog)));
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(
        ModalRoute.of(tester.element(find.byType(AlertDialog))),
        same(popup),
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const ValueKey('operation-technical-text')),
            )
            .data,
        failure.toString(),
      );
      expect(
        find.textContaining('exact original error, false 0 null'),
        findsWidgets,
      );
      final strings = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      if (bridge is NodeBridge) {
        if (bridge.replies.last.isCompleted) {
          await _refresh(tester, runtime: false);
        }
        bridge.replies.last.complete(page());
      }
      if (bridge is RuleBridge) {
        if (bridge.replies.last.isCompleted) {
          await _refresh(tester, runtime: false);
        }
        bridge.replies.last.complete(
          rulePage(kind: 'provider', name: 'set', total: 2),
        );
      }
      await tester.pumpAndSettle();
      await _refresh(tester, runtime: false);
      if (bridge is NodeBridge) bridge.replies.last.completeError(failure);
      if (bridge is RuleBridge) bridge.replies.last.completeError(failure);
      await tester.pumpAndSettle();
      await _noticeDetails(tester);
      final closeFinder = find.widgetWithText(TextButton, strings.close);
      final close = tester.widget<TextButton>(closeFinder).onPressed!;
      Navigator.of(tester.element(closeFinder)).push<void>(
        FocusedPageRoute(
          builder: (_) => const Scaffold(body: Text('new independent page')),
        ),
      );
      await tester.pump();
      close();
      await tester.pumpAndSettle();
      expect(find.text('new independent page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final boundary in ['close', 'dismiss', 'selection', 'source', 'page']) {
    testWidgets('资源清理仅认领实际 popup，$boundary 退休后拒绝旧 callback', (tester) async {
      tester.view.physicalSize = const Size(1100, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = _CleanupBridge();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') bridge.exits++;
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      final app = _CleanupApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(ResourcesPage(app: app, geoName: 'MMDB')));
      bridge.replies.last.complete(
        resourcePage(
          core(1),
          rows: [
            {
              'kind': 'geo',
              'name': 'MMDB',
              'source': '',
              'path': 'Country.mmdb',
              'updateSupported': false,
            },
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('MMDB').first);
      await tester.pumpAndSettle();
      final cleanup = find.byKey(const ValueKey('resource-delete-file'));
      await tester.ensureVisible(cleanup);
      await tester.tap(cleanup);
      await tester.pump();
      final strings = lookupAppLocalizations(const Locale('en'));
      final confirm = find.widgetWithText(
        FilledButton,
        strings.coreCleanupDeleteSelected,
      );
      final confirmation = ModalRoute.of(tester.element(confirm))!;
      expect(confirmation, isA<DialogRoute<bool>>());
      final confirmationRoute = confirmation as DialogRoute<bool>;
      final confirmationAnimation = confirmationRoute.animation!;
      expect(confirmationRoute.isActive, isTrue);
      expect(confirmationRoute.isCurrent, isTrue);
      expect(confirmationAnimation.status, AnimationStatus.forward);
      expect(confirmationAnimation.value, 0);
      expect(
        AppTaskActivity.routeIsActive(
          ModalRoute.of(tester.element(cleanup)),
          ownedPopup: confirmationRoute,
        ),
        isTrue,
      );
      await tester.pump(
        confirmationRoute.transitionDuration + const Duration(microseconds: 1),
      );
      expect(confirmationRoute.isActive, isTrue);
      expect(confirmationRoute.isCurrent, isTrue);
      expect(confirmationAnimation.status, AnimationStatus.completed);
      expect(confirmationAnimation.value, 1);
      expect(confirm.hitTestable(), findsOneWidget);
      final admission = tester.widget<CoreCleanupAction>(
        find.byKey(const ValueKey('resource-delete-file'), skipOffstage: false),
      );
      expect(admission.canStart!(), isFalse);
      expect(admission.isCurrentWithPopup!(confirmation), isTrue);
      final cachedConfirm = tester.widget<FilledButton>(confirm).onPressed!;
      await tester.tap(confirm);
      expect(confirmationAnimation.status, AnimationStatus.reverse);
      await tester.pump();
      expect(app.scheduled, 1);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      if (!bridge.replies.last.isCompleted) {
        bridge.replies.last.complete(
          resourcePage(
            core(1),
            rows: [
              {
                'kind': 'geo',
                'name': 'MMDB',
                'source': '',
                'path': 'Country.mmdb',
                'updateSupported': false,
              },
            ],
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(confirmationAnimation.status, AnimationStatus.dismissed);
      expect(find.byType(AlertDialog), findsNothing);
      final notice = find.byType(SnackBar);
      expect(notice, findsOneWidget);
      expect(
        tester.widget<SnackBar>(notice).behavior,
        SnackBarBehavior.floating,
      );
      expect(
        find.descendant(of: notice, matching: find.byType(TextButton)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: notice,
          matching: find.text(
            'Country.mmdb\n${messages.resourceUpdateSuccess.summary(strings)}',
          ),
        ),
        findsOneWidget,
      );
      final owner = tester.widget<CoreCleanupAction>(
        find.byKey(const ValueKey('resource-delete-file'), skipOffstage: false),
      );
      expect(owner.isCurrentWithPopup!(confirmationRoute), isFalse);
      final exitButton = find.descendant(
        of: notice,
        matching: find.byType(IconButton),
      );
      final exit = tester.widget<IconButton>(exitButton).onPressed!;
      final sourceContext = tester.element(cleanup);
      final sourceRoute = ModalRoute.of(sourceContext)!;
      cachedConfirm();
      expect(app.scheduled, 1);
      switch (boundary) {
        case 'close':
          await tester.tap(exitButton);
        case 'dismiss':
          ScaffoldMessenger.of(tester.element(exitButton))
              .hideCurrentSnackBar();
        case 'selection':
          tester
              .widget<CollectionWorkspace>(
                find.byType(CollectionWorkspace, skipOffstage: false),
              )
              .onClose();
          exit();
        case 'source':
          app.publish(AppSnapshot(phase: 'RUNNING', core: core(2)));
          exit();
          await tester.pump();
          if (!bridge.replies.last.isCompleted) {
            bridge.replies.last.complete(
              resourcePage(
                core(2),
                rows: [
                  {
                    'kind': 'geo',
                    'name': 'MMDB',
                    'source': '',
                    'path': 'Country.mmdb',
                    'updateSupported': false,
                  },
                ],
              ),
            );
          }
        case 'page':
          Navigator.of(sourceContext).push<void>(
            FocusedPageRoute(
              builder: (_) => const Scaffold(body: Text('unrelated page')),
            ),
          );
          await tester.pump();
          exit();
      }
      await tester.pumpAndSettle();
      exit();
      cachedConfirm();
      await tester.pumpAndSettle();
      expect(app.scheduled, 1);
      expect(sourceRoute.isActive, isTrue);
      expect(bridge.exits, 0);
      if (boundary == 'page') {
        expect(find.text('unrelated page'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final category in ['nodes', 'rules', 'resources']) {
    testWidgets('$category 保留 geometry 改变前的面板，退休旧 callback', (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final AppBridge bridge = switch (category) {
        'nodes' => NodeBridge(),
        'rules' => RuleBridge(),
        _ => ResourceBridge(),
      };
      final app = TestApp(bridge);
      addTearDown(app.dispose);
      final pageWidget = switch (category) {
        'nodes' => NodesPage(
          app: app,
          provider: 'provider',
          expectedSource: core(1),
        ),
        'rules' => RulesPage(
          app: app,
          provider: 'set',
          expectedSource: core(1),
        ),
        _ => ResourcesPage(app: app, geoName: 'MMDB'),
      };
      late StateSetter updateHost;
      var active = true;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return AppTaskActivity(active: active, child: _host(pageWidget));
          },
        ),
      );
      switch (bridge) {
        case NodeBridge():
          bridge.replies.last.complete(page());
        case RuleBridge():
          bridge.replies.last.complete(
            rulePage(kind: 'provider', name: 'set', total: 2),
          );
        case ResourceBridge():
          bridge.replies.last.complete(
            resourcePage(
              core(1),
              rows: [
                {
                  'kind': 'geo',
                  'name': 'MMDB',
                  'source': '',
                  'updateSupported': true,
                },
              ],
            ),
          );
      }
      await tester.pumpAndSettle();
      final workspaceFinder = find.byType(CollectionWorkspace);
      final state = tester.state<CollectionWorkspaceState>(workspaceFinder);
      final tile = find
          .descendant(
            of: workspaceFinder,
            matching: find.byWidgetPredicate(
              (widget) => widget is ListTile && widget.onTap != null,
            ),
          )
          .first;
      final select = tester.widget<ListTile>(tile).onTap!;
      final update = category == 'resources'
          ? tester
                .widget<TextButton>(
                  find.widgetWithText(
                    TextButton,
                    lookupAppLocalizations(const Locale('en')).resourceUpdate,
                  ),
                )
                .onPressed
          : null;
      await tester.tap(tile);
      await tester.pumpAndSettle();
      final selectedWidget = tester.widget<CollectionWorkspace>(
        workspaceFinder,
      );
      final selectedKey = selectedWidget.detail!.key;
      final rawKey = ValueKey(switch (category) {
        'nodes' => 'node-raw-data',
        'rules' => 'rule-raw-data',
        _ => 'resource-raw-data',
      });
      final raw = tester.widget<TextButton>(find.byKey(rawKey)).onPressed!;
      final readingElement = tester.element(find.byKey(rawKey));
      final masterWidth = tester
          .getSize(find.byWidget(selectedWidget.master))
          .width;
      expect(state.detailVisible, isTrue);

      tester.view.physicalSize = const Size(560, 850);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final during = tester
          .getSize(
            find.byWidget(
              tester.widget<CollectionWorkspace>(workspaceFinder).master,
            ),
          )
          .width;
      expect(during, greaterThan(masterWidth));
      expect(during, lessThan(560));
      expect(tester.element(find.byKey(rawKey)), same(readingElement));
      expect(
        tester.widget<CollectionWorkspace>(workspaceFinder).detail!.key,
        selectedKey,
      );
      // 第一次尺寸动画尚未结束时，将页面布局切回原来的状态。
      tester.view.physicalSize = const Size(1000, 850);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tester.widget<CollectionWorkspace>(workspaceFinder).detail!.key,
        selectedKey,
      );
      tester.view.physicalSize = const Size(560, 850);
      await tester.pumpAndSettle();
      update?.call();
      expect(
        app.commands,
        isEmpty,
        reason: 'hidden master cannot update a resource',
      );
      state.showMaster();
      await tester.pump(const Duration(milliseconds: 1));
      expect(state.detailVisible, isFalse);
      raw();
      await tester.pump();
      expect(find.byKey(const ValueKey('original-text-copy')), findsNothing);

      tester.view.physicalSize = const Size(1100, 850);
      await tester.pumpAndSettle();
      expect(state.detailVisible, isTrue);
      expect(
        tester.widget<CollectionWorkspace>(workspaceFinder).detail!.key,
        selectedKey,
      );
      tester.widget<CollectionWorkspace>(workspaceFinder).onClose();
      raw();
      await tester.pump();
      expect(find.byKey(const ValueKey('original-text-copy')), findsNothing);
      expect(
        tester.widget<CollectionWorkspace>(workspaceFinder).detail,
        isNull,
      );
      updateHost(() => active = false);
      await tester.pump();
      select();
      raw();
      await tester.pump();
      expect(
        tester.widget<CollectionWorkspace>(workspaceFinder).detail,
        isNull,
      );
      expect(find.byKey(const ValueKey('original-text-copy')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('节点原始能力字段和完整 map 在读取及复制后保持不变', (tester) async {
    final bridge = NodeBridge();
    final app = TestApp(bridge);
    addTearDown(app.dispose);
    await tester.pumpWidget(_host(NodesPage(app: app, provider: 'provider')));
    final value = page();
    final row =
        ((value['page'] as Map)['nodes'] as List).first as Map<String, dynamic>;
    row['raw'] = {
      'udp': false,
      'history': [
        {'time': 'original-time', 'delay': 0},
      ],
      'tests': [],
      'future': [false, 0, null, <Object?>[], <String, Object?>{}],
    };
    bridge.replies.last.complete(value);
    await tester.pumpAndSettle();
    await tester.tap(find.text('node-0'));
    await tester.pumpAndSettle();
    final strings = AppLocalizations.of(tester.element(find.byType(NodesPage)));
    final detailScroll = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final scrollable = find.byElementPredicate(
      (element) => identical(element, detailScroll.context),
    );
    await tester.scrollUntilVisible(
      find.text(strings.proxyFalse),
      200,
      scrollable: scrollable,
    );
    expect(find.text(strings.proxyFalse), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('original-time'),
      200,
      scrollable: scrollable,
    );
    expect(find.text('original-time'), findsOneWidget);
    expect(find.text(strings.delayFailed), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('node-raw-data')),
      -200,
      scrollable: scrollable,
    );
    await tester.tap(find.byKey(const ValueKey('node-raw-data')));
    await tester.pumpAndSettle();
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
    await tester.tap(find.byKey(const ValueKey('original-text-copy')));
    await tester.pump();
    expect(jsonDecode(copied!), row);
    expect((jsonDecode(copied!) as Map)['raw']['future'], [
      false,
      0,
      null,
      [],
      {},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  for (final runtime in [true, false]) {
    testWidgets('${runtime ? 'runtime' : 'resource'} 实时动画偏好改变后保留读取状态与滚动位置', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final AppBridge bridge = runtime ? TestBridge() : ResourceBridge();
      final TestApp app = runtime
          ? TestApp(bridge)
          : ResourceApp(bridge as ResourceBridge);
      final reduced = ValueNotifier(false);
      addTearDown(app.dispose);
      addTearDown(reduced.dispose);
      final row = {
        'kind': 'geo',
        'name': 'MMDB',
        'source': List.generate(
          40,
          (index) => 'retained source $index',
        ).join('\n'),
        'updateSupported': false,
      };
      void completeRead(String text) {
        switch (bridge) {
          case TestBridge():
            bridge.replies.last.completeError(StateError(text));
          case ResourceBridge():
            bridge.replies.last.complete(
              resourcePage(
                core(1),
                rows: [
                  {...row, 'lastError': text},
                ],
              ),
            );
        }
      }

      await tester.pumpWidget(
        _host(
          runtime
              ? RuntimeConfigPage(app: app)
              : ResourcesPage(app: app, geoName: 'MMDB'),
          motion: reduced,
        ),
      );
      final strings = lookupAppLocalizations(const Locale('en'));
      if (bridge is TestBridge) {
        final value = response(core(1));
        (value['configuration'] as Map)['retained'] = List.generate(
          60,
          (index) => 'retained configuration $index',
        );
        bridge.replies.last.complete(value);
        await tester.pumpAndSettle();
        await _refresh(tester, runtime: runtime);
        await tester.pump();
      }
      final original = List.generate(
        40,
        (index) => 'motion original $index',
      ).join('\n');
      completeRead(original);
      await tester.pumpAndSettle();
      if (!runtime) {
        await tester.tap(find.text('MMDB').first);
        await tester.pumpAndSettle();
      }
      final motion = runtime
          ? find.byType(CustomScrollView)
          : find.byKey(const ValueKey('resource-detail-status-motion'));
      expect(
        find.byKey(const ValueKey('runtime-read-error-motion')),
        findsNothing,
      );
      final scrollFinder = runtime
          ? find.descendant(of: motion, matching: find.byType(Scrollable)).first
          : find.ancestor(of: motion, matching: find.byType(Scrollable)).first;
      final scroll = tester.state<ScrollableState>(scrollFinder);
      final scrollable = find.byElementPredicate(
        (element) => identical(element, scroll.context),
      );
      await tester.drag(scrollable, Offset(0, runtime ? -64 : -160));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(0));
      final reading = runtime
          ? find.byType(SelectableText).first
          : find.widgetWithText(SelectableText, row['source']! as String);
      expect(reading, findsOneWidget);
      final readingState = tester.state(reading);
      final retainedText = tester.widget<SelectableText>(reading).data;
      final summary = runtime
          ? messages.operationFailed.summary(strings)
          : strings.resourceUpdateFailed;
      expect(find.widgetWithText(SelectableText, summary), findsNothing);
      expect(find.textContaining('motion original 0'), findsNothing);
      final offset = scroll.position.pixels;
      final input = runtime
          ? tester.widget<TextField>(find.byType(TextField)).controller
          : null;
      final selectedKey = runtime
          ? null
          : tester
                .widget<CollectionWorkspace>(find.byType(CollectionWorkspace))
                .detail!
                .key;
      for (final value in [true, false]) {
        reduced.value = value;
        await tester.pump();
        expect(tester.state(reading), same(readingState));
        expect(tester.state(scrollFinder), same(scroll));
        expect(scroll.position.pixels, closeTo(offset, .5));
        expect(tester.takeException(), isNull);
      }
      await _refresh(tester, runtime: runtime);
      await tester.pump();
      final expanded =
          '$original\n${List.generate(40, (index) => 'motion expanded $index').join('\n')}';
      completeRead(expanded);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final middle = tester.getSize(motion).height;
      final movingOffset = scroll.position.pixels;
      reduced.value = true;
      await tester.pump();
      expect(
        tester.getSize(motion).height,
        middle,
        reason: 'longer technical errors do not expand the task summary',
      );
      expect(tester.state(reading), same(readingState));
      expect(tester.state(scrollFinder), same(scroll));
      expect(scroll.position.pixels, closeTo(movingOffset, .5));
      reduced.value = false;
      await tester.pump();
      expect(tester.state(reading), same(readingState));
      expect(tester.state(scrollFinder), same(scroll));
      expect(scroll.position.pixels, closeTo(movingOffset, .5));
      if (runtime) {
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(input),
        );
      } else {
        expect(
          tester
              .widget<CollectionWorkspace>(find.byType(CollectionWorkspace))
              .detail!
              .key,
          selectedKey,
        );
      }
      expect(tester.widget<SelectableText>(reading).data, retainedText);
      expect(find.textContaining('motion expanded 0'), findsNothing);
      var inlineOffset = scroll.position.pixels;
      final Finder technical;
      final Finder dialog;
      final String technicalText;
      if (runtime) {
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(find.byTooltip(strings.moreActions));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(PopupMenuItem<String>, strings.errorDetails),
        );
        await tester.pumpAndSettle();
        dialog = find.byType(AlertDialog);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pumpAndSettle();
        technical = find.byKey(const ValueKey('operation-technical-text'));
        technicalText = StateError(expanded).toString();
      } else {
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.widgetWithText(SelectableText, summary), findsNothing);
        final raw = find.byKey(const ValueKey('resource-raw-data'));
        await tester.scrollUntilVisible(raw, 200, scrollable: scrollable);
        await tester.pumpAndSettle();
        inlineOffset = scroll.position.pixels;
        await tester.tap(raw);
        await tester.pumpAndSettle();
        dialog = find.byType(OriginalTextView);
        technical = find
            .descendant(of: dialog, matching: find.byType(SelectableText))
            .first;
        technicalText = const JsonEncoder.withIndent('  ')
            .convert({...row, 'lastError': expanded});
      }
      final route = ModalRoute.of(tester.element(dialog));
      final technicalState = tester.state(technical);
      expect(tester.widget<SelectableText>(technical).data, technicalText);
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final copy = find.byKey(
        ValueKey(runtime ? 'operation-technical-copy' : 'original-text-copy'),
      );
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pump();
      expect(copied, technicalText);
      final technicalScrollFinder = find
          .ancestor(of: technical, matching: find.byType(Scrollable))
          .first;
      final technicalScroll = tester.state<ScrollableState>(
        technicalScrollFinder,
      );
      await tester.drag(
        find.byElementPredicate(
          (element) => identical(element, technicalScroll.context),
        ),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      expect(technicalScroll.position.pixels, greaterThan(0));
      final technicalOffset = technicalScroll.position.pixels;
      for (final value in [true, false]) {
        reduced.value = value;
        await tester.pump();
        expect(tester.state(technical), same(technicalState));
        expect(tester.state(technicalScrollFinder), same(technicalScroll));
        expect(technicalScroll.position.pixels, closeTo(technicalOffset, .5));
        expect(ModalRoute.of(tester.element(dialog)), same(route));
        expect(tester.takeException(), isNull);
      }
      final readsBeforeClose = bridge is TestBridge
          ? bridge.replies.length
          : null;
      if (runtime) {
        await tester.tap(find.widgetWithText(TextButton, strings.close));
      } else {
        await tester.pageBack();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      if (bridge is TestBridge) {
        expect(bridge.replies.length, readsBeforeClose! + 1);
        expect(bridge.replies.last.isCompleted, isFalse);
        completeRead(expanded);
      } else if (bridge is ResourceBridge && !bridge.replies.last.isCompleted) {
        completeRead(expanded);
      }
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(tester.state(reading), same(readingState));
      expect(tester.state(scrollFinder), same(scroll));
      expect(scroll.position.pixels, closeTo(inlineOffset, .5));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final reduced in [false, true]) {
    testWidgets('runtime 提示从当前进度收起且保留正文，reduced=$reduced', (tester) async {
      final bridge = TestBridge();
      final app = TestApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        _host(RuntimeConfigPage(app: app), reduced: reduced),
      );
      bridge.replies.last.complete(response(core(1)));
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(find.byType(TextField)).controller;
      final inputState = tester.state(find.byType(TextField));
      final body = find.byType(CustomScrollView);
      final bodyElement = tester.element(body);
      final scrollFinder = find
          .descendant(of: body, matching: find.byType(Scrollable))
          .first;
      final scroll = tester.state<ScrollableState>(scrollFinder);
      final offset = scroll.position.pixels;
      final targets = [
        body,
        find.byType(TextField),
        find.byTooltip('More actions'),
        find.byIcon(Icons.data_object),
      ];
      final rectangles = targets.map(tester.getRect).toList();
      void unchanged() {
        expect(targets.map(tester.getRect).toList(), rectangles);
        expect(tester.element(body), same(bodyElement));
        expect(tester.state(find.byType(TextField)), same(inputState));
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller,
          same(input),
        );
        expect(tester.state(scrollFinder), same(scroll));
        expect(scroll.position.pixels, closeTo(offset, .01));
        expect(
          find.byKey(const ValueKey('runtime-read-error-motion')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }

      await _refresh(tester, runtime: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final pendingIcon = find.byKey(const ValueKey('runtime-refresh-pending'));
      expect(pendingIcon, findsOneWidget);
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(of: pendingIcon, matching: find.byType(FadeTransition))
            .first,
      );
      expect(fade.opacity.value, greaterThan(0));
      if (!reduced) expect(fade.opacity.value, lessThan(1));
      unchanged();
      for (
        var frame = 0;
        frame < 30 && find.byType(PopupMenuItem<String>).evaluate().isNotEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
        unchanged();
      }
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      bridge.replies.last.completeError(
        StateError('actual original error\nsecond line\nthird line'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      unchanged();
      final notice = find.byType(SnackBar);
      for (var frame = 0; frame < 30 && notice.evaluate().isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        unchanged();
      }
      expect(notice, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 16));
      final animation = tester.widget<SnackBar>(notice).animation!;
      final close = find.descendant(
        of: notice,
        matching: find.byType(IconButton),
      );
      for (
        var frame = 0;
        frame < 15 && close.hitTestable().evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
        unchanged();
      }
      expect(close.hitTestable(), findsOneWidget);
      final middle = animation.value;
      expect(middle, greaterThan(0));
      if (!reduced) expect(middle, lessThan(1));
      await tester.tap(close);
      await tester.pump();
      if (!reduced) expect(animation.value, closeTo(middle, .01));
      for (final milliseconds in [16, 60, 100, 200]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        unchanged();
      }
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
      await _refresh(tester, runtime: true);
      bridge.replies.last.complete(response(core(1)));
      await tester.pumpAndSettle();
      unchanged();
      expect(notice, findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('资源错误元数据不移动原文面板，reduced=$reduced', (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = ResourceBridge();
      final app = ResourceApp(bridge);
      addTearDown(app.dispose);
      const row = {
        'kind': 'geo',
        'name': 'MMDB',
        'source': '',
        'updateSupported': false,
      };
      await tester.pumpWidget(
        _host(
          ResourcesPage(app: app, geoName: 'MMDB'),
          reduced: reduced,
        ),
      );
      bridge.replies.last.complete(resourcePage(core(1), rows: [row]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('MMDB').first);
      await tester.pumpAndSettle();
      final workspace = find.byType(CollectionWorkspace);
      final selectedKey = tester
          .widget<CollectionWorkspace>(workspace)
          .detail!
          .key;
      final motion = find.byKey(
        const ValueKey('resource-detail-status-motion'),
      );
      final retained = find.descendant(
        of: motion,
        matching: find.widgetWithText(SelectableText, 'MMDB'),
      );
      final retainedState = tester.state(retained);
      final scrollFinder = find
          .ancestor(of: motion, matching: find.byType(Scrollable))
          .first;
      final scroll = tester.state<ScrollableState>(scrollFinder);
      final offset = scroll.position.pixels;
      final targets = [
        motion,
        retained,
        find.byKey(const ValueKey('resource-raw-data')),
      ];
      final rectangles = targets.map(tester.getRect).toList();
      void unchanged() {
        expect(targets.map(tester.getRect).toList(), rectangles);
        expect(tester.state(retained), same(retainedState));
        expect(tester.state(scrollFinder), same(scroll));
        expect(scroll.position.pixels, closeTo(offset, .01));
        expect(
          tester.widget<CollectionWorkspace>(workspace).detail!.key,
          selectedKey,
        );
        expect(tester.takeException(), isNull);
      }

      const original =
          'actual original failure\nline two\nline three\nline four';
      await _refresh(tester, runtime: false);
      bridge.replies.last.complete(
        resourcePage(
          core(1),
          rows: [
            {...row, 'lastError': original},
          ],
        ),
      );
      for (final milliseconds in [0, 16, 60, 100, 200]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        unchanged();
      }
      expect(find.textContaining(original), findsNothing);
      final raw = find.byKey(const ValueKey('resource-raw-data'));
      final cachedRaw = tester.widget<TextButton>(raw).onPressed!;
      await tester.tap(raw);
      await tester.pumpAndSettle();
      final rawView = tester.widget<OriginalTextView>(
        find.byType(OriginalTextView),
      );
      expect(jsonDecode(rawView.text), {...row, 'lastError': original});
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      if (!bridge.replies.last.isCompleted) {
        bridge.replies.last.complete(
          resourcePage(
            core(1),
            rows: [
              {...row, 'lastError': original},
            ],
          ),
        );
      }
      await tester.pumpAndSettle();
      unchanged();
      await _refresh(tester, runtime: false);
      bridge.replies.last.complete(resourcePage(core(1), rows: [row]));
      for (final milliseconds in [0, 16, 60, 100, 200]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        unchanged();
      }
      tester.widget<CollectionWorkspace>(workspace).onClose();
      await tester.pumpAndSettle();
      cachedRaw();
      await tester.pumpAndSettle();
      expect(find.byType(OriginalTextView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
