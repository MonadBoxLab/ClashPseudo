import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/components/collections/collection_workspace.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
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

Future<void> _nextRead(WidgetTester tester, {bool afterFailure = false}) async {
  final strings = lookupAppLocalizations(const Locale('en'));
  expect(find.byTooltip(strings.refresh), findsNothing);
  await tester.pump(Duration(seconds: afterFailure ? 5 : 30));
  await tester.pump();
}

Future<void> _noticeDetails(WidgetTester tester) async {
  final strings = lookupAppLocalizations(const Locale('en'));
  final details = find.descendant(
    of: find.byType(SnackBar),
    matching: find.widgetWithText(TextButton, strings.errorDetails),
  );
  for (
    var frame = 0;
    frame < 30 && details.hitTestable().evaluate().isEmpty;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 16));
  }
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
    testWidgets(
      '${nodes ? 'nodes' : 'rules'} original error popup remains readable and cannot close a new page',
      (tester) async {
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
            await _nextRead(tester, afterFailure: true);
          }
          bridge.replies.last.complete(page());
        }
        if (bridge is RuleBridge) {
          if (bridge.replies.last.isCompleted) {
            await _nextRead(tester, afterFailure: true);
          }
          bridge.replies.last.complete(
            rulePage(kind: 'provider', name: 'set', total: 2),
          );
        }
        await tester.pumpAndSettle();
        await _nextRead(tester);
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
      },
    );
  }

  for (final boundary in ['close', 'dismiss', 'selection', 'source', 'page']) {
    testWidgets(
      'resource cleanup claims only the actual popup and rejects old callbacks after $boundary retirement',
      (tester) async {
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
        await tester.pumpWidget(
          _host(ResourcesPage(app: app, geoName: 'MMDB')),
        );
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
          confirmationRoute.transitionDuration +
              const Duration(microseconds: 1),
        );
        expect(confirmationRoute.isActive, isTrue);
        expect(confirmationRoute.isCurrent, isTrue);
        expect(confirmationAnimation.status, AnimationStatus.completed);
        expect(confirmationAnimation.value, 1);
        expect(confirm.hitTestable(), findsOneWidget);
        final admission = tester.widget<CoreCleanupAction>(
          find.byKey(
            const ValueKey('resource-delete-file'),
            skipOffstage: false,
          ),
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
          find.byKey(
            const ValueKey('resource-delete-file'),
            skipOffstage: false,
          ),
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
      },
    );
  }

  for (final category in ['nodes', 'rules', 'resources']) {
    testWidgets(
      '$category retains the pane from before geometry changes and retires old callbacks',
      (tester) async {
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
        final detail = find.byKey(selectedKey!);
        final close = tester
            .widget<BackButton>(
              find.descendant(of: detail, matching: find.byType(BackButton)),
            )
            .onPressed!;
        final reading = find
            .descendant(of: detail, matching: find.byType(SelectableText))
            .first;
        final readingElement = tester.element(reading);
        expect(
          find.byKey(
            ValueKey(switch (category) {
              'nodes' => 'node-raw-data',
              'rules' => 'rule-raw-data',
              _ => 'resource-raw-data',
            }),
          ),
          findsNothing,
        );
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
        expect(tester.element(reading), same(readingElement));
        expect(
          tester.widget<CollectionWorkspace>(workspaceFinder).detail!.key,
          selectedKey,
        );
        // Restore the original page layout before the first size animation finishes.
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
        close();
        await tester.pump();
        expect(
          tester.widget<CollectionWorkspace>(workspaceFinder).detail!.key,
          selectedKey,
        );

        tester.view.physicalSize = const Size(1100, 850);
        await tester.pumpAndSettle();
        expect(state.detailVisible, isTrue);
        expect(
          tester.widget<CollectionWorkspace>(workspaceFinder).detail!.key,
          selectedKey,
        );
        tester.widget<CollectionWorkspace>(workspaceFinder).onClose();
        close();
        await tester.pump();
        expect(
          tester.widget<CollectionWorkspace>(workspaceFinder).detail,
          isNull,
        );
        updateHost(() => active = false);
        await tester.pump();
        select();
        close();
        await tester.pump();
        expect(
          tester.widget<CollectionWorkspace>(workspaceFinder).detail,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'node capabilities and delay records retain business fields and actual failure time',
    (tester) async {
      final bridge = NodeBridge();
      final app = TestApp(bridge);
      addTearDown(app.dispose);
      await tester.pumpWidget(_host(NodesPage(app: app, provider: 'provider')));
      final value = page();
      final row =
          ((value['page'] as Map)['nodes'] as List).first
              as Map<String, dynamic>;
      row['udp'] = false;
      row['history'] = [
        {'time': 'original-time', 'delay': 0},
        {'time': 'successful-time', 'delay': 42},
      ];
      bridge.replies.last.complete(value);
      await tester.pumpAndSettle();
      await tester.tap(find.text('node-0'));
      await tester.pumpAndSettle();
      final strings = AppLocalizations.of(
        tester.element(find.byType(NodesPage)),
      );
      expect(find.text(strings.nodeDelayHistoryFailed), findsOneWidget);
      expect(find.byKey(const ValueKey('node-raw-data')), findsNothing);
      await _noticeDetails(tester);
      await tester.tap(
        find.byKey(const ValueKey('operation-technical-details')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('node-0 · original-time'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, strings.close));
      await tester.pumpAndSettle();
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
        find.text('successful-time'),
        200,
        scrollable: scrollable,
      );
      expect(find.text('successful-time'), findsOneWidget);
      expect(find.text('42 ms'), findsOneWidget);
      expect(find.text('original-time'), findsNothing);
      expect(find.text(strings.delayFailed), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final runtime in [true, false]) {
    testWidgets(
      '${runtime ? 'runtime' : 'resource'} retains reading state and scroll position after live animation preference changes',
      (tester) async {
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
        void completeSuccess() {
          switch (bridge) {
            case TestBridge():
              final value = response(core(1));
              value['configuration'] = 'interface-name: ${row['source']}\n';
              bridge.replies.last.complete(value);
            case ResourceBridge():
              bridge.replies.last.complete(resourcePage(core(1), rows: [row]));
          }
        }

        void failRead(String text) {
          switch (bridge) {
            case TestBridge():
              bridge.replies.last.completeError(StateError(text));
            case ResourceBridge():
              bridge.replies.last.completeError(StateError(text));
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
        completeSuccess();
        await tester.pumpAndSettle();
        if (!runtime) {
          await tester.tap(find.text('MMDB').first);
          await tester.pumpAndSettle();
        }
        final original = List.generate(
          40,
          (index) => 'motion original $index',
        ).join('\n');
        await _nextRead(tester);
        failRead(original);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        final motion = runtime
            ? find.byKey(const ValueKey('original-text-blocks'))
            : find.byKey(const ValueKey('resource-detail-status-motion'));
        expect(
          find.byKey(const ValueKey('runtime-read-error-motion')),
          findsNothing,
        );
        final scrollFinder = runtime
            ? find
                  .descendant(of: motion, matching: find.byType(Scrollable))
                  .first
            : find
                  .ancestor(of: motion, matching: find.byType(Scrollable))
                  .first;
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
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(IconButton),
          ),
        );
        await tester.pumpAndSettle();
        await _nextRead(tester, afterFailure: true);
        completeSuccess();
        await tester.pumpAndSettle();
        await _nextRead(tester);
        final expanded =
            '$original\n${List.generate(40, (index) => 'motion expanded $index').join('\n')}';
        failRead(expanded);
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
        final inlineOffset = scroll.position.pixels;
        expect(find.byKey(const ValueKey('resource-raw-data')), findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
        await _noticeDetails(tester);
        final dialog = find.byType(AlertDialog);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pumpAndSettle();
        final technical = find.byKey(
          const ValueKey('operation-technical-text'),
        );
        final technicalText = StateError(expanded).toString();
        final route = ModalRoute.of(tester.element(dialog));
        final technicalState = tester.state(technical);
        expect(tester.widget<SelectableText>(technical).data, technicalText);
        String? copied;
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(SystemChannels.platform, null),
        );
        final copy = find.byKey(const ValueKey('operation-technical-copy'));
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
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        final pending = switch (bridge) {
          TestBridge() => !bridge.replies.last.isCompleted,
          ResourceBridge() => !bridge.replies.last.isCompleted,
          _ => false,
        };
        if (pending) completeSuccess();
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(tester.state(reading), same(readingState));
        expect(tester.state(scrollFinder), same(scroll));
        expect(scroll.position.pixels, closeTo(inlineOffset, .5));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final reduced in [false, true]) {
    testWidgets(
      'runtime notice collapses from current progress while retaining content reduced=$reduced',
      (tester) async {
        final bridge = TestBridge();
        final app = TestApp(bridge);
        addTearDown(app.dispose);
        await tester.pumpWidget(
          _host(RuntimeConfigPage(app: app), reduced: reduced),
        );
        bridge.replies.last.complete(response(core(1)));
        await tester.pumpAndSettle();
        final input = tester
            .widget<TextField>(find.byType(TextField))
            .controller;
        final inputState = tester.state(find.byType(TextField));
        final body = find.byKey(const ValueKey('original-text-blocks'));
        final bodyElement = tester.element(body);
        final scrollFinder = find
            .descendant(of: body, matching: find.byType(Scrollable))
            .first;
        final scroll = tester.state<ScrollableState>(scrollFinder);
        final offset = scroll.position.pixels;
        final targets = [body, find.byType(TextField), find.byType(AppBar)];
        expect(find.byTooltip('More actions'), findsNothing);
        expect(find.byIcon(Icons.data_object), findsNothing);
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

        await _nextRead(tester);
        await tester.pump(const Duration(milliseconds: 40));
        expect(
          find.byKey(const ValueKey('runtime-refresh-pending')),
          findsNothing,
        );
        unchanged();
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
        await _nextRead(tester, afterFailure: true);
        bridge.replies.last.complete(response(core(1)));
        await tester.pumpAndSettle();
        unchanged();
        expect(notice, findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'resource read errors do not move the details pane reduced=$reduced',
      (tester) async {
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
        final targets = [motion, retained];
        expect(find.byKey(const ValueKey('resource-raw-data')), findsNothing);
        final cachedClose = tester
            .widget<BackButton>(
              find.descendant(
                of: find.byKey(selectedKey!),
                matching: find.byType(BackButton),
              ),
            )
            .onPressed!;
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
        await _nextRead(tester);
        bridge.replies.last.completeError(StateError(original));
        for (final milliseconds in [0, 16, 60, 100, 200]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          unchanged();
        }
        expect(find.textContaining(original), findsNothing);
        await _noticeDetails(tester);
        await tester.tap(
          find.byKey(const ValueKey('operation-technical-details')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining(original), findsOneWidget);
        final strings = lookupAppLocalizations(const Locale('en'));
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        if (!bridge.replies.last.isCompleted) {
          bridge.replies.last.complete(resourcePage(core(1), rows: [row]));
        }
        await tester.pumpAndSettle();
        unchanged();
        await _nextRead(tester);
        bridge.replies.last.complete(resourcePage(core(1), rows: [row]));
        for (final milliseconds in [0, 16, 60, 100, 200]) {
          await tester.pump(Duration(milliseconds: milliseconds));
          unchanged();
        }
        tester.widget<CollectionWorkspace>(workspace).onClose();
        await tester.pumpAndSettle();
        cachedClose();
        await tester.pumpAndSettle();
        expect(tester.widget<CollectionWorkspace>(workspace).detail, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
