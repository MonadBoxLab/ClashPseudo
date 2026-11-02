import 'package:clash_pseudo/src/model/platform_failure.dart';

import 'dart:async';

import 'package:clash_pseudo/src/ui/app/app_controller.dart';
import 'package:clash_pseudo/src/ui/navigation/task_activity.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_feedback.dart';
import 'package:clash_pseudo/src/ui/components/feedback/operation_notice.dart';
import 'package:clash_pseudo/src/ui/components/reading/original_text_view.dart';
import 'package:clash_pseudo/src/ui/diagnostics/resources/resources_page.dart';
import 'package:clash_pseudo/src/ui/settings/storage_data_page.dart';
import 'package:clash_pseudo/src/ui/settings/core_cleanup_action.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/channel/app_bridge.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/navigation/page_route.dart';
import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

class _CleanupBridge extends AppBridge {
  final commands = <Map<String, Object?>>[];
  Object? submitFailure;
  Object? candidatesFailure;
  int exits = 0;
  int resourceReads = 0;
  List<Map<String, dynamic>> rows = [];

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(command);
    if (submitFailure case final failure?) throw failure;
    return OperationAdmission(
      operationId: 'cleanup-${commands.length}',
      remaining: const Duration(seconds: 120),
    );
  }

  @override
  Future<Map<String, dynamic>> coreCleanupCandidates() async {
    if (candidatesFailure case final failure?) throw failure;
    final paths = <String>{
      'GeoSite.dat',
      'Country.mmdb',
      for (final row in rows)
        if (row['kind'] == 'geo')
          (row['path'] as String).replaceFirst('/fixture/mihomo/', ''),
    };
    return {
      'home': '/fixture/mihomo',
      'items': [
        {
          'kind': 'cache',
          'path': 'cache.db',
          'absolutePath': '/fixture/mihomo/cache.db',
        },
        for (final path in paths)
          {
            'kind': 'geo',
            'path': path,
            'absolutePath': '/fixture/mihomo/$path',
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> storageUsage() async => {
    'configurations': {'bytes': 19, 'path': '/fixture/configurations.json'},
    'overrides': {'bytes': 21, 'path': '/fixture/overrides.json'},
    'preferences': {'bytes': 23, 'path': '/fixture/preferences.json'},
    'core': {'bytes': 456, 'path': '/fixture/mihomo'},
  };

  @override
  Future<Map<String, dynamic>> resources(CoreSnapshot core) async {
    resourceReads++;
    return {
      'generation': core.generation,
      'composition': core.composition,
      'configId': core.configId,
      'revision': core.revision,
      'purpose': core.purpose,
      'resources': rows,
    };
  }
}

class _CleanupApp extends AppController {
  _CleanupApp(super.platform) {
    loading = false;
    state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 41);
    configErrorMessage = const AppMessage('configStoreUnreadable');
    overrideErrorMessage = const AppMessage('overridesUnreadable');
  }

  // 测试控制器从当前快照读取 storageEpoch；配置和插件读取错误仍使用构造时设置的值。
  @override
  int get storageEpoch => state.storageEpoch;

  ValueListenable<bool>? localFeedbackOwner;
  Future<AppSnapshot?>? submittedResult;

  @override
  Future<AppSnapshot?> submitAndWait(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) {
    localFeedbackOwner = feedbackOwner;
    return submittedResult = super.submitAndWait(
      command,
      feedbackOwner: feedbackOwner,
    );
  }

  void publish(AppSnapshot value) {
    state = value;
    notifyListeners();
  }

  @override
  Future<void> refresh() async => notifyListeners();

  void complete({
    bool success = true,
    AppMessage message = const AppMessage('coreCleanupCompleted'),
    CoreSnapshot? stableSource,
  }) => publish(
    AppSnapshot(
      phase: stableSource == null ? 'STOPPED' : state.phase,
      core: stableSource ?? const CoreSnapshot(),
      storageEpoch: state.storageEpoch,
      resultId: 'cleanup-${(platform as _CleanupBridge).commands.length}',
      resultSuccess: success,
      resultMessage: message,
      coreCleanup: {
        'ready': success,
        'status': success ? 'completed' : 'failed',
        'scope': 'files',
        'paths': (platform as _CleanupBridge).commands.last['paths'],
        'files': [
          for (final path
              in (platform as _CleanupBridge).commands.last['paths'] as List? ??
                  const [])
            {
              'path': path,
              'completed': success,
              if (!success) 'error': message.toMap(),
            },
        ],
        if (!success) 'error': message.toMap(),
      },
    ),
  );
}

class _ImmediateCleanupApp extends _CleanupApp {
  _ImmediateCleanupApp(super.platform) {
    state = const AppSnapshot(
      phase: 'RUNNING',
      storageEpoch: 41,
      core: CoreSnapshot(
        generation: 7,
        phase: 'READY',
        purpose: 'RUNNING',
        configId: 'main',
        revision: 1,
        composition: 'cleanup-source-7',
      ),
    );
  }

  @override
  Future<AppSnapshot?> submitAndWait(
    Map<String, Object?> command, {
    ValueListenable<bool>? feedbackOwner,
  }) async {
    (platform as _CleanupBridge).commands.add(command);
    final result = AppSnapshot(
      phase: state.phase,
      storageEpoch: state.storageEpoch,
      core: state.core,
      resultId: 'cleanup-${(platform as _CleanupBridge).commands.length}',
      resultSuccess: false,
      resultMessage: const AppMessage(
        'coreCleanupFailed',
        detail: 'immediate cleanup original',
      ),
      coreCleanup: const {
        'status': 'failed',
        'scope': 'files',
        'paths': ['cache.db'],
      },
    );
    publish(result);
    return result;
  }
}

Future<void> _pumpNoticeFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400, microseconds: 1));
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump();
  }
}

Future<void> _openNoticeDetails(
  WidgetTester tester, {
  bool animate = true,
}) async {
  expect(find.byType(AlertDialog), findsNothing);
  final context = tester.element(find.byType(SnackBar).last);
  final strings = AppLocalizations.of(context);
  final details = find
      .descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.errorDetails),
      )
      .hitTestable()
      .last;
  expect(details, findsOneWidget);
  expect(tester.getSize(details).shortestSide, greaterThanOrEqualTo(48));
  await tester.tap(details);
  if (animate) {
    await _pumpNoticeFrames(tester);
  } else {
    await tester.pump();
  }
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<void> _closeNotice(WidgetTester tester) async {
  final close = find
      .descendant(of: find.byType(SnackBar), matching: find.byIcon(Icons.close))
      .hitTestable()
      .last;
  expect(close, findsOneWidget);
  await tester.tap(close);
  await _pumpNoticeFrames(tester);
}

Future<String> _readFailure(WidgetTester tester) async {
  if (find.byType(AlertDialog).evaluate().isEmpty) {
    await _pumpNoticeFrames(tester);
    await _openNoticeDetails(tester);
  }
  final details = find.byKey(const ValueKey('operation-technical-details'));
  await tester.ensureVisible(details);
  await tester.tap(details);
  await tester.pumpAndSettle();
  expect(
    find.descendant(
      of: find.byType(CoreCleanupAction),
      matching: find.byType(CircularProgressIndicator),
    ),
    findsNothing,
  );
  final dialog = find.byType(AlertDialog).last;
  final summary = tester
      .widget<SelectableText>(
        find
            .descendant(
              of: dialog,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is SelectableText &&
                    widget.key != const ValueKey('operation-technical-text'),
              ),
            )
            .last,
      )
      .data!;
  final original = tester
      .widget<SelectableText>(
        find.byKey(const ValueKey('operation-technical-text')),
      )
      .data!;
  return '$summary\n$original';
}

void main() {
  late _CleanupBridge bridge;
  late _CleanupApp app;
  final locale = ValueNotifier(const Locale('en'));

  setUp(() {
    bridge = _CleanupBridge();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') bridge.exits++;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    app = _CleanupApp(bridge);
    locale.value = const Locale('en');
    addTearDown(app.dispose);
  });

  Future<void> show(
    WidgetTester tester, {
    Widget? home,
    String language = 'en',
    double scale = 1,
    bool disableAnimations = false,
    List<NavigatorObserver>? navigatorObservers,
  }) async {
    final observers = navigatorObservers ?? [AppTaskNavigatorObserver()];
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    locale.value = Locale(language);
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: locale,
        builder: (context, language, _) => MaterialApp(
          theme: AppTheme.light,
          navigatorObservers: observers,
          locale: language,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: disableAnimations,
            ),
            child: child!,
          ),
          home: OperationFeedback(
            controller: app,
            child: home ?? StorageDataPage(app: app),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (find.byType(SnackBar).evaluate().isNotEmpty) {
      await _closeNotice(tester);
    }
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scrollable = find.byType(Scrollable).first;
    for (var i = 0; i < 50 && target.evaluate().isEmpty; i++) {
      final bounds = tester.getRect(scrollable);
      await tester.dragFrom(
        Offset(bounds.left + 8, bounds.center.dy),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
    }
    expect(target, findsOneWidget);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Widget admissionPage({
    required bool Function() canStart,
    bool Function()? taskCurrent,
    bool Function()? selectionCurrent,
  }) => Scaffold(
    body: AppTaskActivity(
      active: true,
      isActiveNow: () => taskCurrent?.call() ?? true,
      isActiveWithPopup: (_) => taskCurrent?.call() ?? true,
      child: ListView(
        children: [
          CoreCleanupAction(
            key: const ValueKey('storage-cleanup-files'),
            app: app,
            request: const {'scope': 'cache'},
            canStart: canStart,
            isCurrent: () => selectionCurrent?.call() ?? true,
            isCurrentWithPopup: (_) => selectionCurrent?.call() ?? true,
            title: (strings) => strings.coreCleanupCache,
            description: (strings) => strings.coreCleanupCacheMessage,
            icon: Icons.delete_sweep_outlined,
          ),
        ],
      ),
    ),
  );

  Finder cacheAction() => find.byKey(const ValueKey('storage-cleanup-files'));

  Finder fileCandidate(String path) => find.byWidgetPredicate(
    (widget) =>
        widget is CheckboxListTile &&
        widget.key is ValueKey &&
        (widget.key! as ValueKey).value == ('cleanup-file', path),
  );

  Future<void> pumpPopupEntrance(
    WidgetTester tester,
    Finder button, {
    required Finder source,
    bool reduced = false,
    bool message = false,
  }) async {
    await tester.pump();
    expect(button, findsOneWidget);
    final route = ModalRoute.of(tester.element(button))!;
    expect(
      route,
      message || tester.widget(button) is TextButton
          ? isA<DialogRoute<void>>()
          : isA<DialogRoute<bool>>(),
    );
    expect(route.isActive, isTrue);
    expect(route.isCurrent, isTrue);
    expect(
      route.animation!.status,
      reduced ? AnimationStatus.completed : AnimationStatus.forward,
    );
    expect(route.animation!.value, reduced ? 1 : 0);
    expect(source, findsOneWidget);
    final sourceRoute = ModalRoute.of(tester.element(source))!;
    expect(sourceRoute, isNot(same(route)));
    expect(
      AppTaskActivity.routeIsActive(sourceRoute, ownedPopup: route),
      isTrue,
    );
    final dialog = find.ancestor(
      of: button,
      matching: find.byType(AlertDialog),
    );
    final size = tester.getSize(dialog);
    expect(size.isFinite, isTrue);
    expect(size.width, greaterThan(0));
    expect(size.height, greaterThan(0));
    final shield = find
        .ancestor(of: dialog, matching: find.byType(IgnorePointer))
        .first;
    expect(tester.widget<IgnorePointer>(shield).ignoring, isFalse);
    final started = tester.binding.clock.now();
    // SDK 插值在 duration 之后完成；spinner 不属于等待全部动画结束的条件。
    final elapsed = route.transitionDuration + const Duration(microseconds: 1);
    await tester.pump(elapsed);
    expect(tester.binding.clock.now().difference(started), elapsed);
    expect(route.isActive, isTrue);
    expect(route.isCurrent, isTrue);
    expect(route.animation!.status, AnimationStatus.completed);
    expect(route.animation!.value, 1);
    expect(tester.getSize(dialog), size);
    expect(tester.widget<IgnorePointer>(shield).ignoring, isFalse);
  }

  Future<void> pumpCacheResult(
    WidgetTester tester, {
    bool message = true,
  }) async {
    await _pumpNoticeFrames(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    if (app.state.resultSuccess &&
        bridge.submitFailure == null &&
        bridge.candidatesFailure == null) {
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.widgetWithText(
            TextButton,
            lookupAppLocalizations(locale.value).errorDetails,
          ),
        ),
        findsNothing,
      );
      return;
    }
    final details = find.descendant(
      of: find.byType(SnackBar),
      matching: find.widgetWithText(
        TextButton,
        lookupAppLocalizations(locale.value).errorDetails,
      ),
    );
    if (details.evaluate().isNotEmpty) {
      await _openNoticeDetails(tester, animate: false);
      await pumpPopupEntrance(
        tester,
        find.widgetWithText(
          TextButton,
          lookupAppLocalizations(locale.value).close,
        ),
        source: cacheAction().evaluate().isEmpty
            ? find.byType(StorageDataPage)
            : cacheAction(),
        message: message,
      );
    }
  }

  void failedResult() => app.complete(
    success: false,
    message: const AppMessage(
      'coreCleanupFailed',
      detail: 'cleanup-result-original',
    ),
  );

  Future<void> beginCache(WidgetTester tester) async {
    final target = cacheAction();
    await reveal(tester, target);
    await tester.tap(target);
    final confirm = find.widgetWithText(
      FilledButton,
      lookupAppLocalizations(locale.value).coreCleanupDeleteSelected,
    );
    await pumpPopupEntrance(tester, confirm, source: target);
    final cache = fileCandidate('cache.db');
    if (tester.widget<CheckboxListTile>(cache).value != true) {
      tester.widget<CheckboxListTile>(cache).onChanged!(true);
      await tester.pump();
    }
    await tester.tap(confirm);
    await tester.pump();
  }

  testWidgets('清理结果等待实际呈现才 acknowledge，恢复窗口后不重复反馈', (tester) async {
    await show(
      tester,
      home: OperationNoticeHost(child: admissionPage(canStart: () => true)),
    );
    await beginCache(tester);
    await tester.pump(const Duration(milliseconds: 250));
    final owner = app.localFeedbackOwner!;
    expect(owner.value, isTrue);
    var released = 0;
    owner.addListener(() {
      if (!owner.value) released++;
    });
    tester.view.physicalSize = const Size(360, 120);
    await tester.pump();
    failedResult();
    await _pumpNoticeFrames(tester);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.hasLocalFeedbackOwner, isTrue);
    expect(owner.value, isTrue);
    expect(released, 0);
    expect(
      tester
          .widget<ListTile>(
            find.descendant(of: cacheAction(), matching: find.byType(ListTile)),
          )
          .onTap,
      isNull,
    );
    tester.view.physicalSize = const Size(360, 900);
    await _pumpNoticeFrames(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.hasLocalFeedbackOwner, isFalse);
    expect(owner.value, isFalse);
    expect(released, 1);
    await _closeNotice(tester);
    await app.refresh();
    await _pumpNoticeFrames(tester);
    expect(find.byType(SnackBar), findsNothing);
    expect(bridge.commands, hasLength(1));
    expect(app.state.coreCleanup['files'], [
      {
        'path': 'cache.db',
        'completed': false,
        'error': const AppMessage(
          'coreCleanupFailed',
          detail: 'cleanup-result-original',
        ).toMap(),
      },
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清理提示与主动详情在 epoch 改变后退休，恢复旧值不启用旧action', (tester) async {
    await show(tester, home: admissionPage(canStart: () => true));
    await beginCache(tester);
    failedResult();
    await _pumpNoticeFrames(tester);
    expect(find.byType(AlertDialog), findsNothing);
    final strings = lookupAppLocalizations(locale.value);
    final oldDetails = tester
        .widget<TextButton>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.widgetWithText(TextButton, strings.errorDetails),
          ),
        )
        .onPressed!;
    final original = app.state;
    app.publish(const AppSnapshot(phase: 'STOPPED', storageEpoch: 42));
    app.publish(original);
    oldDetails();
    await _pumpNoticeFrames(tester);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.commands, hasLength(1));
    await beginCache(tester);
    failedResult();
    await pumpCacheResult(tester);
    final close = find.widgetWithText(TextButton, strings.close);
    final oldClose = tester.widget<TextButton>(close).onPressed!;
    final route = ModalRoute.of(tester.element(close))!;
    final second = app.state;
    app.publish(const AppSnapshot(phase: 'STOPPED', storageEpoch: 42));
    app.publish(second);
    oldClose();
    await tester.pump();
    expect(route.isActive, isFalse);
    expect(bridge.commands, hasLength(2));
    expect(app.hasLocalFeedbackOwner, isFalse);
    expect(bridge.exits, 0);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次受理读取实时 canStart，不重建也拒绝失效的 cached tap', (tester) async {
    var allowed = true;
    var reads = 0;
    await show(
      tester,
      home: admissionPage(
        canStart: () {
          reads++;
          return allowed;
        },
      ),
    );
    expect(reads, 0);
    final tile = find.descendant(
      of: find.byType(CoreCleanupAction),
      matching: find.byType(ListTile),
    );
    final tap = tester.widget<ListTile>(tile).onTap!;
    allowed = false;
    tap();
    await tester.idle();
    expect(reads, 1);
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('canStart 仅读取一次，弹窗期间变为 false 不阻止已受理结果和 Close', (tester) async {
    var allowed = true;
    var reads = 0;
    await show(
      tester,
      navigatorObservers: [AppTaskNavigatorObserver()],
      home: admissionPage(
        canStart: () {
          reads++;
          return allowed;
        },
      ),
    );
    final target = find.byKey(const ValueKey('storage-cleanup-files'));
    await tester.tap(target);
    await pumpPopupEntrance(
      tester,
      find.widgetWithText(
        FilledButton,
        lookupAppLocalizations(locale.value).coreCleanupDeleteSelected,
      ),
      source: target,
    );
    expect(reads, 1);
    final strings = lookupAppLocalizations(locale.value);
    final confirm = find.widgetWithText(
      FilledButton,
      strings.coreCleanupDeleteSelected,
    );
    allowed = false;
    tester.widget<FilledButton>(confirm).onPressed!();
    // 只完成 Route 的结果 Future，不等待重建或 reverse 动画的首帧。
    await tester.idle();
    expect(bridge.commands.single, {
      'paths': ['cache.db'],
      'restart': false,
      'action': 'scheduleCoreCleanup',
      'storageEpoch': 41,
    });
    expect(reads, 1);
    failedResult();
    await pumpCacheResult(tester);
    expect(find.text(strings.operationNotCompleted), findsOneWidget);
    expect(app.hasLocalFeedbackOwner, isFalse);
    expect(reads, 1);
    final exit = find.widgetWithText(TextButton, strings.close);
    tester.widget<TextButton>(exit).onPressed!();
    await tester.idle();
    expect(bridge.exits, 0);
    expect(reads, 1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final retired in ['task', 'route', 'selection']) {
    testWidgets('canStart 不能恢复因 $retired 退休的确认弹窗', (tester) async {
      var taskCurrent = true;
      var selectionCurrent = true;
      var reads = 0;
      await show(
        tester,
        navigatorObservers: [AppTaskNavigatorObserver()],
        home: const Scaffold(body: Text('cleanup launcher')),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final route = MaterialPageRoute<void>(
        builder: (_) => admissionPage(
          canStart: () {
            reads++;
            return true;
          },
          taskCurrent: () => taskCurrent,
          selectionCurrent: () => selectionCurrent,
        ),
      );
      unawaited(navigator.push(route));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storage-cleanup-files')));
      await pumpPopupEntrance(
        tester,
        find.widgetWithText(
          FilledButton,
          lookupAppLocalizations(locale.value).coreCleanupDeleteSelected,
        ),
        source: find.byKey(const ValueKey('storage-cleanup-files')),
      );
      final strings = lookupAppLocalizations(locale.value);
      final confirm = find.widgetWithText(
        FilledButton,
        strings.coreCleanupDeleteSelected,
      );
      final oldConfirm = tester.widget<FilledButton>(confirm).onPressed!;
      switch (retired) {
        case 'task':
          taskCurrent = false;
        case 'route':
          navigator.removeRoute(route);
        case 'selection':
          selectionCurrent = false;
      }
      oldConfirm();
      await tester.idle();
      expect(bridge.commands, isEmpty);
      // 先让 owner 检查退休原确认，再恢复状态；恢复不能受理旧确认。
      await app.refresh();
      await tester.pump();
      taskCurrent = true;
      selectionCurrent = true;
      oldConfirm();
      await tester.idle();
      expect(reads, 1);
      expect(bridge.commands, isEmpty);
      expect(bridge.exits, 0);
      expect(app.hasLocalFeedbackOwner, isFalse);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final boundary in [
    'close',
    'dismiss',
    'source',
    'task',
    'route',
    'page',
    'popup',
  ]) {
    testWidgets(
      '实际 popup 保留立即返回结果，迟到 Builder 与 $boundary 不改变 Route ownership',
      (tester) async {
        app = _ImmediateCleanupApp(bridge);
        addTearDown(app.dispose);
        final observer = AppTaskNavigatorObserver();
        var taskCurrent = true;
        final queriedPopups = <ModalRoute<dynamic>>[];
        final source = app.state.core;
        bool sourceCurrent() =>
            app.state.storageEpoch == 41 &&
            source.matchesIdentity(app.state.core);
        final strings = lookupAppLocalizations(locale.value);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale.value,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            navigatorObservers: [observer],
            home: const Scaffold(body: Text('cleanup phase launcher')),
          ),
        );
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        final sourceRoute = FocusedPageRoute<void>(
          builder: (context) {
            final route = ModalRoute.of(context)!;
            bool current({Route<dynamic>? popup}) =>
                taskCurrent &&
                AppTaskActivity.routeIsActive(route, ownedPopup: popup);
            return AppTaskActivity(
              active: true,
              isActiveNow: current,
              isActiveWithPopup: (popup) => current(popup: popup),
              child: Scaffold(
                body: CoreCleanupAction(
                  key: const ValueKey('cleanup-phase-action'),
                  app: app,
                  request: const {'scope': 'cache'},
                  canStart: () => current() && sourceCurrent(),
                  isCurrent: () => current() && sourceCurrent(),
                  isCurrentWithPopup: (popup) {
                    queriedPopups.add(popup);
                    return current(popup: popup) && sourceCurrent();
                  },
                  title: (strings) => strings.coreCleanupCache,
                  description: (strings) => strings.coreCleanupCacheMessage,
                  icon: Icons.delete_sweep_outlined,
                ),
              ),
            );
          },
        );
        unawaited(navigator.push(sourceRoute));
        await tester.pumpAndSettle();
        final action = find.byKey(const ValueKey('cleanup-phase-action'));
        final start = tester
            .widget<ListTile>(
              find.descendant(of: action, matching: find.byType(ListTile)),
            )
            .onTap!;
        start();
        await tester.pump();
        final confirmation = observer.stack.last as ModalRoute<dynamic>;
        Finder dialogFor(ModalRoute<dynamic> route) => find.byElementPredicate(
          (element) =>
              element.widget is AlertDialog &&
              identical(ModalRoute.of(element), route),
          skipOffstage: false,
        );
        void expectShield(ModalRoute<dynamic> route, {required bool active}) {
          final shield = find
              .ancestor(
                of: dialogFor(route),
                matching: find.byType(IgnorePointer, skipOffstage: false),
              )
              .first;
          expect(tester.widget<IgnorePointer>(shield).ignoring, !active);
        }

        final confirmationDialog = dialogFor(confirmation);
        expect(confirmationDialog, findsOneWidget);
        expect(confirmation, isA<DialogRoute<bool>>());
        expect(confirmation.isActive, isTrue);
        expect(confirmation.isCurrent, isTrue);
        expect(confirmation.animation!.status, AnimationStatus.forward);
        expect(confirmation.animation!.value, 0);
        expect(bridge.commands, isEmpty);
        expectShield(confirmation, active: true);
        final confirmationSize = tester.getSize(confirmationDialog);
        expect(confirmationSize.width, greaterThan(0));
        expect(confirmationSize.height, greaterThan(0));
        expect(confirmationSize.isFinite, isTrue);
        final spinner = find.descendant(
          of: action,
          matching: find.byType(CircularProgressIndicator, skipOffstage: false),
        );
        // 确认弹窗保留操作锁，但尚未开始业务 I/O。
        expect(spinner, findsNothing);
        expect(
          tester
              .widget<ListTile>(
                find.descendant(of: action, matching: find.byType(ListTile)),
              )
              .onTap,
          isNull,
        );
        // SDK isDone 要求 elapsed > duration；业务操作不等待该条件。
        final entranceStarted = tester.binding.clock.now();
        final entranceElapsed =
            confirmation.transitionDuration + const Duration(microseconds: 1);
        await tester.pump(entranceElapsed);
        expect(
          tester.binding.clock.now().difference(entranceStarted),
          entranceElapsed,
        );
        expect(confirmation.animation!.status, AnimationStatus.completed);
        expect(confirmation.animation!.value, 1);
        expect(tester.getSize(confirmationDialog), confirmationSize);
        final confirmationBuilder = find
            .ancestor(
              of: confirmationDialog,
              matching: find.byType(Builder, skipOffstage: false),
            )
            .first;
        final confirmationContext = tester.element(confirmationBuilder);
        final rebuildConfirmation = tester
            .widget<Builder>(confirmationBuilder)
            .builder;
        final oldConfirm = tester
            .widget<FilledButton>(
              find.descendant(
                of: confirmationDialog,
                matching: find.widgetWithText(
                  FilledButton,
                  strings.coreCleanupDeleteSelected,
                ),
              ),
            )
            .onPressed!;
        expect(confirmation.isActive, isTrue);
        expect(confirmation.isCurrent, isTrue);
        expect(
          tester.widget<CoreCleanupAction>(action).isCurrentWithPopup!(
            confirmation,
          ),
          isTrue,
        );
        expectShield(confirmation, active: true);
        oldConfirm();
        // 提交不等待确认退出动画；失败先显示 SnackBar，详情仅由用户打开。
        await tester.idle();
        expect(bridge.commands, hasLength(1));
        expect(confirmation.isActive, isFalse);
        expect(confirmation.animation!.status, AnimationStatus.reverse);
        expect(observer.stack.last, same(sourceRoute));
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 1));
        expect(observer.stack.last, same(sourceRoute));
        final detailAction = find.descendant(
          of: find.byType(SnackBar),
          matching: find.widgetWithText(TextButton, strings.errorDetails),
        );
        expect(detailAction, findsOneWidget);
        tester.widget<TextButton>(detailAction).onPressed!();
        await tester.idle();
        final result = observer.stack.last as ModalRoute<dynamic>;
        expect(result, isNot(same(confirmation)));
        expect(result.isCurrent, isTrue);
        await tester.pump();
        final resultDialog = dialogFor(result);
        expect(resultDialog, findsOneWidget);
        final resultBuilder = find
            .ancestor(
              of: resultDialog,
              matching: find.byType(Builder, skipOffstage: false),
            )
            .first;
        final resultContext = tester.element(resultBuilder);
        final rebuildResult = tester.widget<Builder>(resultBuilder).builder;
        final exit = tester
            .widget<TextButton>(
              find.descendant(
                of: resultDialog,
                matching: find.widgetWithText(TextButton, strings.close),
              ),
            )
            .onPressed!;
        expect(confirmationContext.mounted, isTrue);
        expect(confirmation.animation!.status, AnimationStatus.reverse);
        // 新弹窗安装后再次调用旧 SDK Builder；旧 Builder 不能重新认领 Route。
        expect(
          rebuildConfirmation(confirmationContext),
          isA<StatefulBuilder>(),
        );
        queriedPopups.clear();
        await app.refresh();
        await tester.pump(const Duration(milliseconds: 1));
        expect(queriedPopups, isNotEmpty);
        expect(
          queriedPopups.every((popup) => identical(popup, result)),
          isTrue,
        );
        expect(result.isActive, isTrue);
        expect(result.isCurrent, isTrue);
        expectShield(result, active: true);
        expect(app.state.resultSuccess, isFalse);
        expect(spinner, findsNothing);
        expect(
          tester
              .widget<ListTile>(
                find.descendant(of: action, matching: find.byType(ListTile)),
              )
              .onTap,
          isNotNull,
        );
        start();
        oldConfirm();
        await tester.idle();
        expect(bridge.commands, hasLength(1));
        expect(result.isCurrent, isTrue);
        final scheduled = app.state;
        switch (boundary) {
          case 'close':
            exit();
          case 'dismiss':
            navigator.pop();
          case 'source':
            app.publish(
              AppSnapshot(
                phase: 'RUNNING',
                storageEpoch: 41,
                core: const CoreSnapshot(
                  generation: 8,
                  phase: 'READY',
                  purpose: 'RUNNING',
                  configId: 'main',
                  revision: 1,
                  composition: 'cleanup-source-8',
                ),
                coreCleanup: scheduled.coreCleanup,
              ),
            );
            exit();
          case 'task':
            taskCurrent = false;
            exit();
          case 'route':
            navigator.removeRoute(sourceRoute);
            exit();
          case 'page':
            unawaited(
              navigator.push<void>(
                FocusedPageRoute(
                  builder: (_) =>
                      const Scaffold(body: Text('new cleanup page')),
                ),
              ),
            );
            exit();
          case 'popup':
            unawaited(
              navigator.push<void>(
                DialogRoute(
                  context: resultContext,
                  builder: (_) => const AlertDialog(title: Text('other popup')),
                ),
              ),
            );
            exit();
        }
        await tester.idle();
        expect(bridge.exits, 0);
        if (boundary == 'close' || boundary == 'dismiss') {
          expect(result.isCurrent, isFalse);
          expect(result.animation!.status, AnimationStatus.reverse);
          // reverse 期间两个旧 SDK Builder 尚未卸载，不能重新认领 Route 或操作新页面。
          final independent = FocusedPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('after cleanup result')),
          );
          unawaited(navigator.push(independent));
          expect(
            rebuildConfirmation(confirmationContext),
            isA<StatefulBuilder>(),
          );
          expect(rebuildResult(resultContext), isA<AnimatedBuilder>());
          oldConfirm();
          exit();
          await tester.idle();
          expect(independent.isCurrent, isTrue);
          expect(bridge.commands, hasLength(1));
          expect(bridge.exits, 0);
          navigator.pop();
          await tester.idle();
          start();
          await tester.pump();
          final nextConfirmation = observer.stack.last as ModalRoute<dynamic>;
          expect(nextConfirmation, isNot(same(confirmation)));
          expect(nextConfirmation, isNot(same(result)));
          expect(nextConfirmation.isCurrent, isTrue);
          expect(rebuildResult(resultContext), isA<AnimatedBuilder>());
          queriedPopups.clear();
          await app.refresh();
          await tester.pump();
          expect(queriedPopups, isNotEmpty);
          expect(
            queriedPopups.every((popup) => identical(popup, nextConfirmation)),
            isTrue,
          );
          expectShield(nextConfirmation, active: true);
          exit();
          await tester.idle();
          expect(nextConfirmation.isCurrent, isTrue);
          expect(bridge.commands, hasLength(1));
          expect(bridge.exits, 0);
          navigator.pop();
        } else {
          expect(result.isActive, isTrue);
          if (boundary != 'page' && boundary != 'popup') {
            expect(result.isCurrent, isTrue, reason: 'retirement cannot pop');
          }
          await app.refresh();
          await tester.pump();
          expectShield(result, active: false);
          expect(result.isActive, isFalse);
          expect(result.isCurrent, isFalse);
          if (boundary != 'page' && boundary != 'popup') {
            expect(result.animation!.status, AnimationStatus.reverse);
          }
          final independent = FocusedPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Text('retired result independent page')),
          );
          unawaited(navigator.push(independent));
          taskCurrent = true;
          app.publish(scheduled);
          oldConfirm();
          exit();
          await tester.idle();
          expect(bridge.exits, 0, reason: '恢复来源不能重新启用旧 Close');
          expect(bridge.commands, hasLength(1));
          expect(independent.isCurrent, isTrue);
          expect(result.isCurrent, isFalse);
          navigator.pop();
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final boundary in ['action', 'popup', 'host']) {
    testWidgets(
      '实际呈现释放 owner，主动详情退休后 cached Close 不访问已卸载页面，boundary=$boundary',
      (tester) async {
        var present = true;
        late StateSetter updateSource;
        await show(
          tester,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  FocusedPageRoute(
                    builder: (_) => StatefulBuilder(
                      builder: (context, setState) {
                        updateSource = setState;
                        return Scaffold(
                          body: ListView(
                            children: [
                              if (present)
                                CoreCleanupAction(
                                  key: const ValueKey('retiring-cleanup'),
                                  app: app,
                                  request: const {'scope': 'cache'},
                                  isCurrent: () => present,
                                  isCurrentWithPopup: (_) => present,
                                  title: (strings) => strings.coreCleanupCache,
                                  description: (strings) =>
                                      strings.coreCleanupCacheMessage,
                                  icon: Icons.delete_sweep_outlined,
                                ),
                              const Text('source page retained'),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
                child: const Text('open retiring cleanup'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open retiring cleanup'));
        await tester.pumpAndSettle();
        final action = find.byKey(const ValueKey('retiring-cleanup'));
        final sourceState = tester.state(action);
        final strings = lookupAppLocalizations(locale.value);
        await tester.tap(action);
        final confirm = find.widgetWithText(
          FilledButton,
          strings.coreCleanupDeleteSelected,
        );
        await pumpPopupEntrance(tester, confirm, source: action);
        tester.widget<FilledButton>(confirm).onPressed!();
        await tester.idle();
        expect(bridge.commands.single, {
          'paths': ['cache.db'],
          'restart': false,
          'action': 'scheduleCoreCleanup',
          'storageEpoch': 41,
        });
        expect(app.hasLocalFeedbackOwner, isTrue);
        final owner = app.localFeedbackOwner!;
        var synchronousRetirements = 0;
        owner.addListener(() {
          if (owner.value) return;
          synchronousRetirements++;
          expect(sourceState.mounted, isTrue);
          expect(app.hasLocalFeedbackOwner, isFalse);
        });
        failedResult();
        await _pumpNoticeFrames(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(owner.value, isFalse);
        expect(synchronousRetirements, 1);
        await _openNoticeDetails(tester, animate: false);
        final exitButton = find.widgetWithText(TextButton, strings.close);
        await pumpPopupEntrance(tester, exitButton, source: action);
        final popup = ModalRoute.of(tester.element(exitButton))!;
        final exit = tester.widget<TextButton>(exitButton).onPressed!;
        updateSource(() => present = false);
        if (boundary == 'popup') {
          scheduleMicrotask(() {
            if (popup.isActive) popup.navigator!.pop();
          });
        }
        exit();
        expect(bridge.exits, 0);
        expect(popup.isCurrent, isTrue);
        expect(owner.value, isFalse);
        expect(synchronousRetirements, 1);
        if (boundary == 'host') {
          await tester.pumpWidget(const SizedBox());
        } else {
          await tester.pump();
        }
        expect(synchronousRetirements, 1);
        expect(owner.value, isFalse);
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(sourceState.mounted, isFalse);
        expect(tester.takeException(), isNull);
        exit();
        await tester.idle();
        expect(bridge.exits, 0);
        expect(bridge.commands, hasLength(1));
        expect(app.state.resultSuccess, isFalse);
        expect(app.state.coreCleanup['status'], 'failed');
        if (boundary == 'action') {
          await tester.pump();
          expect(popup.isActive, isFalse);
          expect(popup.animation!.status, AnimationStatus.reverse);
          expect(exitButton.hitTestable(), findsNothing);
          final dialog = find.ancestor(
            of: exitButton,
            matching: find.byType(AlertDialog),
          );
          expect(
            tester
                .widget<IgnorePointer>(
                  find
                      .ancestor(
                        of: dialog,
                        matching: find.byType(IgnorePointer),
                      )
                      .first,
                )
                .ignoring,
            isTrue,
          );
          expect(
            tester
                .widget<ExcludeFocus>(
                  find
                      .ancestor(of: dialog, matching: find.byType(ExcludeFocus))
                      .first,
                )
                .excluding,
            isTrue,
          );
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
          await tester.pumpAndSettle();
        } else if (boundary == 'popup') {
          expect(popup.isActive, isFalse);
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox());
        await tester.idle();
        await tester.pump();
        exit();
        await tester.idle();
        expect(bridge.exits, 0);
        expect(synchronousRetirements, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('清理 spinner 只等待实际 submit Future，实际显示结果后释放操作锁', (tester) async {
    await show(tester, home: admissionPage(canStart: () => true));
    final target = cacheAction();
    final state = tester.state(target);
    final bounds = tester.getRect(target);
    ListTile tile() => tester.widget<ListTile>(
      find.descendant(of: target, matching: find.byType(ListTile)),
    );
    final start = tile().onTap!;
    final progress = find.descendant(
      of: target,
      matching: find.byType(CircularProgressIndicator),
    );
    final strings = lookupAppLocalizations(locale.value);
    await beginCache(tester);
    var submissionReturned = false;
    AppSnapshot? returnedResult;
    unawaited(
      app.submittedResult!.then((value) {
        returnedResult = value;
        submissionReturned = true;
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 181));
    expect(submissionReturned, isFalse);
    expect(app.state.resultId, isNull);
    expect(app.hasLocalFeedbackOwner, isTrue);
    expect(progress, findsOneWidget);
    expect(tester.widget<CircularProgressIndicator>(progress).value, isNull);
    expect(TickerMode.valuesOf(tester.element(progress)).enabled, isTrue);
    final fade = tester
        .widget<FadeTransition>(
          find
              .ancestor(of: progress, matching: find.byType(FadeTransition))
              .first,
        )
        .opacity;
    expect(fade.value, 1);
    expect(tile().onTap, isNull);
    expect(tester.getRect(target), bounds);
    start();
    await tester.idle();
    expect(bridge.commands, hasLength(1));
    expect(bridge.exits, 0);

    app.complete();
    await tester.idle();
    expect(submissionReturned, isTrue);
    expect(returnedResult, same(app.state));
    expect(app.state.resultSuccess, isTrue);
    expect(app.hasLocalFeedbackOwner, isTrue);
    await tester.pump();
    expect(
      tester
          .widget<AnimatedSwitcher>(
            find.descendant(
              of: target,
              matching: find.byType(AnimatedSwitcher),
            ),
          )
          .child,
      isA<Icon>(),
    );
    expect(fade.status, AnimationStatus.reverse);
    expect(fade.value, 1);
    expect(tile().onTap, isNull);
    await pumpCacheResult(tester);
    expect(app.hasLocalFeedbackOwner, isFalse);
    expect(progress, findsNothing);
    expect(tile().onTap, isNotNull);
    expect(tester.state(target), same(state));
    expect(tester.getRect(target), bounds);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(strings.coreCleanupCompleted),
      ),
      findsOneWidget,
    );
    final close = tester
        .widget<IconButton>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed!;
    close();
    await tester.idle();
    expect(app.hasLocalFeedbackOwner, isFalse);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    final independent = FocusedPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('cleanup independent page')),
    );
    unawaited(navigator.push(independent));
    close();
    await tester.idle();
    expect(independent.isCurrent, isTrue);
    expect(bridge.commands, hasLength(1));
    expect(bridge.exits, 0);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    expect(tile().onTap, isNotNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.state(target), same(state));
    expect(tester.getRect(target), bounds);
    expect(bridge.commands, hasLength(1));
    expect(bridge.exits, 0);
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [false, true]) {
    testWidgets('清理事实和 Close 不等待 DialogRoute 或 spinner 动画 reduced=$reduced', (
      tester,
    ) async {
      await show(
        tester,
        disableAnimations: reduced,
        home: Scaffold(
          body: ListView(
            children: [
              CoreCleanupAction(
                key: const ValueKey('cleanup-motion'),
                app: app,
                request: const {'scope': 'cache'},
                title: (strings) => strings.coreCleanupCache,
                description: (strings) => strings.coreCleanupCacheMessage,
                icon: Icons.delete_sweep_outlined,
                subject: 'cache.db',
              ),
              const Text('Following action'),
            ],
          ),
        ),
      );
      final target = find.byKey(const ValueKey('cleanup-motion'));
      final state = tester.state(target);
      final before = tester.getRect(target);
      final strings = lookupAppLocalizations(locale.value);
      await tester.tap(target);
      await tester.pump();
      final confirmation = ModalRoute.of(
        tester.element(find.byType(AlertDialog)),
      )!;
      final progress = find.descendant(
        of: target,
        matching: find.byType(CircularProgressIndicator),
      );
      expect(progress, findsNothing);
      expect(app.submittedResult, isNull);
      final shield = find
          .ancestor(
            of: find.byType(AlertDialog),
            matching: find.byType(IgnorePointer),
          )
          .first;
      expect(tester.widget<IgnorePointer>(shield).ignoring, isFalse);
      if (reduced) {
        expect(confirmation.animation!.value, 1);
        expect(confirmation.animation!.status, AnimationStatus.completed);
      } else {
        expect(confirmation.animation!.value, 0);
        await tester.pump(const Duration(milliseconds: 40));
        expect(confirmation.animation!.value, inExclusiveRange(0, 1));
        expect(progress, findsNothing);
        expect(app.submittedResult, isNull);
        final started = tester.binding.clock.now();
        final remainder =
            confirmation.transitionDuration -
            const Duration(milliseconds: 40) +
            const Duration(microseconds: 1);
        await tester.pump(remainder);
        expect(tester.binding.clock.now().difference(started), remainder);
        expect(confirmation.animation!.status, AnimationStatus.completed);
        expect(confirmation.animation!.value, 1);
      }
      tester
          .widget<FilledButton>(
            find.widgetWithText(
              FilledButton,
              strings.coreCleanupDeleteSelected,
            ),
          )
          .onPressed!();
      await tester.idle();
      expect(bridge.commands.single['action'], 'scheduleCoreCleanup');
      expect(bridge.commands.single['storageEpoch'], 41);
      expect(bridge.exits, 0);
      var submissionReturned = false;
      unawaited(
        app.submittedResult!.then((_) {
          submissionReturned = true;
        }),
      );
      await tester.idle();
      expect(submissionReturned, isFalse);
      await tester.pump();
      expect(progress, findsOneWidget);
      final fade = tester
          .widget<FadeTransition>(
            find
                .ancestor(of: progress, matching: find.byType(FadeTransition))
                .first,
          )
          .opacity;
      expect(fade.value, reduced ? 1 : 0);
      expect(tester.widget<CircularProgressIndicator>(progress).value, isNull);
      expect(TickerMode.valuesOf(tester.element(progress)).enabled, isTrue);
      expect(app.hasLocalFeedbackOwner, isTrue);
      await tester.pump(const Duration(milliseconds: 40));
      expect(fade.value, reduced ? 1 : inExclusiveRange(0, 1));
      expect(submissionReturned, isFalse);
      if (!reduced) {
        expect(confirmation.animation!.value, inExclusiveRange(0, 1));
      }
      failedResult();
      await tester.pump();
      await tester.pump();
      expect(submissionReturned, isTrue);
      expect(app.state.resultSuccess, isFalse);
      expect(app.hasLocalFeedbackOwner, isTrue);
      expect(
        tester
            .widget<ListTile>(
              find.descendant(of: target, matching: find.byType(ListTile)),
            )
            .onTap,
        isNull,
      );
      expect(bridge.exits, 0);
      await _pumpNoticeFrames(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.hasLocalFeedbackOwner, isFalse);
      final details = find.descendant(
        of: find.byType(SnackBar),
        matching: find.widgetWithText(TextButton, strings.errorDetails),
      );
      expect(details.hitTestable(), findsOneWidget);
      await tester.tap(details);
      await tester.pump();
      final result = find.ancestor(
        of: find.text(strings.operationNotCompleted),
        matching: find.byType(AlertDialog),
      );
      expect(result, findsOneWidget);
      final route = ModalRoute.of(tester.element(result))!;
      await tester.pump(const Duration(milliseconds: 40));
      expect(route.animation!.value, reduced ? 1 : inExclusiveRange(0, 1));
      expect(tester.getRect(target), before);
      await tester.tap(
        find.descendant(
          of: result,
          matching: find.widgetWithText(TextButton, strings.close),
        ),
      );
      await tester.pump();
      expect(bridge.exits, 0);
      if (!reduced) expect(route.animation!.value, inExclusiveRange(0, 1));
      expect(tester.state(target), same(state));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.hasLocalFeedbackOwner, isFalse);
      expect(bridge.commands, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      for (final multiple in [false, true]) {
        testWidgets(
          '候选清理逐项选择文件并保留 provider，language=$language scale=$scale multiple=$multiple',
          (tester) async {
            await show(tester, language: language, scale: scale);
            final strings = lookupAppLocalizations(Locale(language));
            final target = find.byKey(
              ValueKey(
                multiple ? 'storage-cleanup-files' : 'storage-cleanup-files',
              ),
            );
            await reveal(tester, target);
            await tester.tap(target);
            await pumpPopupEntrance(
              tester,
              find.widgetWithText(
                FilledButton,
                strings.coreCleanupDeleteSelected,
              ),
              source: target,
            );
            final dialog = find.byType(AlertDialog);
            expect(dialog, findsOneWidget);
            expect(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.text(strings.coreCleanupSelect),
              ),
              findsOneWidget,
            );
            expect(
              find.textContaining(strings.coreCleanupSelectionNotice),
              findsWidgets,
            );
            final files = find.byWidgetPredicate(
              (widget) => widget is CheckboxListTile && widget.key != null,
            );
            expect(files, findsNWidgets(3));
            for (final path in ['cache.db', 'GeoSite.dat', 'Country.mmdb']) {
              final candidate = fileCandidate(path);
              expect(candidate, findsOneWidget);
              expect(tester.widget<CheckboxListTile>(candidate).value, isFalse);
              expect(find.text(path), findsOneWidget);
              if (multiple || path == 'cache.db') {
                tester.widget<CheckboxListTile>(candidate).onChanged!(true);
                await tester.pump();
              }
            }
            expect(find.textContaining('providers/'), findsNothing);
            expect(find.textContaining('/fixture/mihomo'), findsNothing);
            final restart = find.widgetWithText(
              CheckboxListTile,
              strings.coreCleanupRestartLatest,
            );
            expect(tester.widget<CheckboxListTile>(restart).value, isFalse);
            if (multiple) {
              tester.widget<CheckboxListTile>(restart).onChanged!(true);
              await tester.pump();
            }
            expect(bridge.commands, isEmpty);
            expect(bridge.exits, 0);
            final confirm = find.widgetWithText(
              FilledButton,
              strings.coreCleanupDeleteSelected,
            );
            tester.widget<FilledButton>(confirm).onPressed!();
            await tester.idle();
            expect(bridge.commands.single, {
              'action': 'scheduleCoreCleanup',
              'paths': multiple
                  ? ['cache.db', 'GeoSite.dat', 'Country.mmdb']
                  : ['cache.db'],
              'restart': multiple,
              'storageEpoch': 41,
            });
            expect(app.hasLocalFeedbackOwner, isTrue);
            app.complete();
            await pumpCacheResult(tester);
            expect(find.byType(AlertDialog), findsNothing);
            expect(
              find.descendant(
                of: find.byType(SnackBar),
                matching: find.text(strings.coreCleanupCompleted),
              ),
              findsOneWidget,
            );
            expect(app.state.coreCleanup['files'], [
              for (final path
                  in multiple
                      ? ['cache.db', 'GeoSite.dat', 'Country.mmdb']
                      : ['cache.db'])
                {'path': path, 'completed': true},
            ]);
            expect(bridge.exits, 0);
            await _closeNotice(tester);
            expect(bridge.exits, 0);
            expect(app.hasLocalFeedbackOwner, isFalse);
            expect(find.byType(AlertDialog), findsNothing);
            expect(find.byType(SnackBar), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets('storageEpoch 改变后旧确认 callback 不提交也不恢复', (tester) async {
    await show(tester);
    final target = cacheAction();
    await reveal(tester, target);
    await tester.tap(target);
    final confirm = find.widgetWithText(
      FilledButton,
      lookupAppLocalizations(locale.value).coreCleanupDeleteSelected,
    );
    await pumpPopupEntrance(tester, confirm, source: target);
    tester.widget<CheckboxListTile>(fileCandidate('cache.db')).onChanged!(true);
    await tester.pump();
    final callback = tester.widget<FilledButton>(confirm).onPressed!;
    final route = ModalRoute.of(tester.element(confirm))!;
    app.publish(const AppSnapshot(phase: 'STOPPED', storageEpoch: 42));
    callback();
    await tester.idle();
    expect(bridge.commands, isEmpty);
    app.publish(const AppSnapshot(phase: 'STOPPED', storageEpoch: 41));
    callback();
    await tester.pumpAndSettle();
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
    expect(route.isActive, isFalse);
    expect(app.hasLocalFeedbackOwner, isFalse);
  });

  testWidgets('dismiss 结果后 cached Close 不执行第二次关闭或退出应用', (tester) async {
    await show(tester);
    await beginCache(tester);
    failedResult();
    await pumpCacheResult(tester);
    final button = find.widgetWithText(
      TextButton,
      lookupAppLocalizations(locale.value).close,
    );
    final oldExit = tester.widget<TextButton>(button).onPressed!;
    Navigator.of(tester.element(button)).pop();
    oldExit();
    await tester.pump();
    expect(bridge.exits, 0);
    expect(app.state.coreCleanup['status'], 'failed');
    expect(button.hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byType(StorageDataPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(bridge.commands, hasLength(1));
  });

  testWidgets('新文件请求不被旧结果的 Close callback 改写', (tester) async {
    await show(tester);
    await beginCache(tester);
    failedResult();
    await pumpCacheResult(tester);
    app.publish(
      const AppSnapshot(
        phase: 'STOPPED',
        storageEpoch: 41,
        coreCleanup: {
          'status': 'scheduled',
          'scope': 'files',
          'paths': ['GeoSite.dat'],
        },
      ),
    );
    await tester.pump();
    await tester.tap(
      find.widgetWithText(
        TextButton,
        lookupAppLocalizations(locale.value).close,
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.exits, 0);
    expect(app.state.coreCleanup['paths'], ['GeoSite.dat']);
    expect(bridge.commands, hasLength(1));
  });

  testWidgets('来源失效时不等待重建，直接拒绝 cached cleanup callback', (tester) async {
    var current = true;
    await show(
      tester,
      home: Scaffold(
        body: ListView(
          children: [
            CoreCleanupAction(
              key: const ValueKey('storage-cleanup-files'),
              app: app,
              request: const {'scope': 'cache'},
              isCurrent: () => current,
              title: (strings) => strings.coreCleanupCache,
              description: (strings) => strings.coreCleanupCacheMessage,
              icon: Icons.delete_sweep_outlined,
            ),
          ],
        ),
      ),
    );
    final tile = find.descendant(
      of: find.byType(CoreCleanupAction),
      matching: find.byType(ListTile),
    );
    final oldTap = tester.widget<ListTile>(tile).onTap!;
    current = false;
    oldTap();
    await tester.pumpAndSettle();
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final success in [false, true]) {
    testWidgets('FocusedPageRoute 仅认领实际确认和结果弹窗，success=$success', (
      tester,
    ) async {
      var popupChecks = 0;
      await show(
        tester,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                FocusedPageRoute(
                  builder: (_) => Scaffold(
                    body: Builder(
                      builder: (origin) => ListView(
                        children: [
                          CoreCleanupAction(
                            key: const ValueKey('storage-cleanup-files'),
                            app: app,
                            request: const {'scope': 'cache'},
                            isCurrent: () => AppTaskActivity.isActive(origin),
                            isCurrentWithPopup: (popup) {
                              popupChecks++;
                              return AppTaskActivity.isActive(
                                origin,
                                ownedPopup: popup,
                              );
                            },
                            title: (strings) => strings.coreCleanupCache,
                            description: (strings) =>
                                strings.coreCleanupCacheMessage,
                            icon: Icons.delete_sweep_outlined,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open cleanup'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open cleanup'));
      await tester.pumpAndSettle();
      await beginCache(tester);
      expect(bridge.commands, hasLength(1));
      const failure = AppMessage(
        'coreCleanupFailed',
        detail: 'schedule original\nCaused by: worker\nSuppressed: close 原文🙂',
      );
      app.complete(
        success: success,
        message: success ? const AppMessage('coreCleanupCompleted') : failure,
      );
      await pumpCacheResult(tester, message: true);
      final strings = lookupAppLocalizations(locale.value);
      expect(app.hasLocalFeedbackOwner, isFalse);
      expect(popupChecks, greaterThan(0));
      if (success) {
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.coreCleanupCompleted),
          ),
          findsOneWidget,
        );
        await _closeNotice(tester);
      } else {
        expect(find.text(strings.operationFinished), findsNothing);
        expect(await _readFailure(tester), failure.resolve(strings));
        await tester.tap(find.widgetWithText(TextButton, strings.close));
        await tester.pumpAndSettle();
      }
      expect(bridge.exits, 0);
      expect(app.hasLocalFeedbackOwner, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final configurations in [true, false]) {
    testWidgets('集合删除显示实际失败结果，不显示成功，configurations=$configurations', (
      tester,
    ) async {
      await show(tester);
      final clear = find.byKey(
        ValueKey(
          'storage-clear-${configurations ? 'configurations' : 'overrides'}',
        ),
      );
      await reveal(tester, clear);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(locale.value);
      await tester.tap(find.widgetWithText(FilledButton, strings.delete));
      await tester.pumpAndSettle();
      expect(
        bridge.commands.single['action'],
        configurations ? 'clearConfigurations' : 'clearOverrides',
      );
      expect(find.byType(AlertDialog), findsNothing);
      const failure = AppMessage(
        'operationNotCompletedRetry',
        detail: 'delete original\nCaused by: fsync\nSuppressed: close 原文🙂',
      );
      app.publish(
        const AppSnapshot(
          phase: 'STOPPED',
          storageEpoch: 41,
          resultId: 'cleanup-1',
          resultSuccess: false,
          resultMessage: failure,
        ),
      );
      await tester.pumpAndSettle();
      expect(await _readFailure(tester), failure.resolve(strings));
      expect(app.state.resultSuccess, isFalse);
      expect(bridge.exits, 0);
    });
  }

  testWidgets('取消文件清理确认不提交命令，也不退出应用', (tester) async {
    await show(tester);
    final target = find.byKey(const ValueKey('storage-cleanup-files'));
    await reveal(tester, target);
    await tester.tap(target);
    await pumpPopupEntrance(
      tester,
      find.widgetWithText(
        FilledButton,
        lookupAppLocalizations(locale.value).coreCleanupDeleteSelected,
      ),
      source: target,
    );
    await tester.tap(
      find.widgetWithText(
        TextButton,
        lookupAppLocalizations(locale.value).cancel,
      ),
    );
    await tester.pumpAndSettle();
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
    expect(app.hasLocalFeedbackOwner, isFalse);
  });

  testWidgets('清理失败保留 Stop 原错误，已打开的结果与技术详情随 locale 更新', (tester) async {
    await show(tester);
    await beginCache(tester);
    const original =
        'https://user:password@fixture.test/?token=完整🙂\nStop IOException 原文';
    app.complete(
      success: false,
      message: const AppMessage('coreCleanupFailed', detail: original),
    );
    await pumpCacheResult(tester);
    var strings = lookupAppLocalizations(locale.value);
    final summary = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(SelectableText),
        )
        .first;
    expect(
      tester.widget<SelectableText>(summary).data,
      strings.coreCleanupFailed,
    );
    expect(find.textContaining(original), findsNothing);
    await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('operation-technical-text')),
          )
          .data,
      original,
    );
    final resultRoute = ModalRoute.of(
      tester.element(find.text(strings.operationNotCompleted)),
    )!;
    locale.value = const Locale('zh');
    await tester.pump();
    strings = lookupAppLocalizations(locale.value);
    expect(
      ModalRoute.of(tester.element(find.text(strings.operationNotCompleted))),
      same(resultRoute),
    );
    expect(resultRoute.animation!.status, AnimationStatus.completed);
    expect(
      tester.widget<SelectableText>(summary).data,
      strings.coreCleanupFailed,
    );
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('operation-technical-text')),
          )
          .data,
      original,
    );
    expect(bridge.exits, 0);
    await tester.tap(find.widgetWithText(TextButton, strings.close));
    await tester.pumpAndSettle();
    expect(bridge.exits, 0);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('文件清理失败保留完整原错误，不退出应用', (tester) async {
    await show(tester);
    await beginCache(tester);
    const failure = AppMessage(
      'coreCleanupFailed',
      detail:
          'rename IOException https://user:password@fixture.test/?token=原文🙂',
    );
    app.complete(success: false, message: failure);
    await pumpCacheResult(tester, message: true);
    expect(
      await _readFailure(tester),
      failure.resolve(lookupAppLocalizations(locale.value)),
    );
    expect(bridge.exits, 0);
    expect(
      find.text(lookupAppLocalizations(locale.value).operationFinished),
      findsNothing,
    );
    await tester.tap(
      find.widgetWithText(
        TextButton,
        lookupAppLocalizations(locale.value).close,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(app.hasLocalFeedbackOwner, isFalse);
  });

  testWidgets('受理失败仅显示一次，并保留 typed error 和完整平台错误结构', (tester) async {
    const original = AppMessage(
      'coreCleanupFailed',
      detail: 'executor rejected 原文🙂',
    );
    bridge.submitFailure = PlatformFailure(
      code: 'coreCleanup',
      details: original.toMap(),
    );
    await show(tester);
    await beginCache(tester);
    await pumpCacheResult(tester, message: true);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      await _readFailure(tester),
      original
          .withDetail(bridge.submitFailure)
          .resolve(lookupAppLocalizations(locale.value)),
    );
    expect(bridge.exits, 0);
    await tester.tap(
      find.widgetWithText(
        TextButton,
        lookupAppLocalizations(locale.value).close,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('后台完成等待交互恢复才显示结果，不退出应用', (tester) async {
    await show(tester);
    await beginCache(tester);
    app.setForeground(false);
    app.complete();
    await tester.pump(const Duration(seconds: 1));
    expect(bridge.exits, 0);
    expect(find.byType(AlertDialog), findsNothing);
    app.setForeground(true);
    await pumpCacheResult(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(
          lookupAppLocalizations(locale.value).coreCleanupCompleted,
        ),
      ),
      findsOneWidget,
    );
    expect(bridge.commands, hasLength(1));
    await _closeNotice(tester);
    expect(bridge.exits, 0);
  });

  testWidgets('离开清理页面后交还实际全局反馈，不退出另一个页面', (tester) async {
    await show(
      tester,
      home: Navigator(
        observers: [AppTaskNavigatorObserver()],
        onGenerateRoute: (_) =>
            FocusedPageRoute<void>(builder: (_) => StorageDataPage(app: app)),
      ),
    );
    await beginCache(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('another page')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    app.complete();
    await tester.pumpAndSettle();
    expect(find.text('another page'), findsOneWidget);
    expect(bridge.exits, 0);
    expect(app.hasLocalFeedbackOwner, isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.text(lookupAppLocalizations(locale.value).coreCleanupCompleted),
      findsOneWidget,
    );
  });

  testWidgets('卸载执行中的清理组件不取消操作，也不退出应用', (tester) async {
    await show(tester);
    await beginCache(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(app.hasLocalFeedbackOwner, isFalse);
    app.complete();
    await tester.pump();
    expect(bridge.commands, hasLength(1));
    expect(bridge.exits, 0);
    expect(tester.takeException(), isNull);
  });

  for (final status in ['scheduled', 'failed', 'completed']) {
    testWidgets('存储页区分清理状态 $status，仍允许本地集合删除', (tester) async {
      const original =
          'delete IOException https://user:password@fixture.test/?token=原文🙂';
      app.publish(
        AppSnapshot(
          phase: 'STOPPED',
          storageEpoch: 41,
          coreCleanup: {
            'ready': status == 'completed',
            'status': status,
            'scope': 'files',
            'paths': ['cache.db'],
            'files': [
              {
                'path': 'cache.db',
                'completed': status == 'completed',
                if (status == 'failed')
                  'error': const AppMessage(
                    'coreCleanupFailed',
                    detail: original,
                  ).toMap(),
              },
            ],
            if (status == 'failed')
              'error': const AppMessage(
                'coreCleanupFailed',
                detail: original,
              ).toMap(),
          },
        ),
      );
      await show(tester);
      final state = find.byKey(const ValueKey('storage-core-cleanup-state'));
      await reveal(tester, state);
      final strings = lookupAppLocalizations(locale.value);
      final title = status == 'completed'
          ? strings.coreCleanupCompleted
          : status == 'failed'
          ? strings.coreCleanupFailed
          : strings.coreCleanupScheduled;
      expect((tester.widget<ListTile>(state).title! as Text).data, title);
      if (status == 'failed') {
        expect(find.textContaining(original), findsNothing);
        final details = find.byKey(
          const ValueKey('storage-core-cleanup-state-details'),
        );
        await reveal(tester, details);
        await tester.tap(details);
        await tester.pumpAndSettle();
        expect(
          await _readFailure(tester),
          const AppMessage(
            'coreCleanupFailed',
            detail: original,
          ).resolve(strings),
        );
        expect(find.textContaining(original), findsOneWidget);
        await tester.tap(
          find.widgetWithText(TextButton, strings.close).hitTestable(),
        );
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('storage-core-cleanup-exit')),
        findsNothing,
      );
      expect(bridge.exits, 0);
      expect(bridge.commands, isEmpty);
      final clear = find.byKey(const ValueKey('storage-clear-configurations'));
      await reveal(tester, clear);
      expect(tester.widget<ListTile>(clear).onTap, isNotNull);
    });
  }

  testWidgets('重选候选失败保留原错误与既有文件请求', (tester) async {
    final failure = StateError('exit worker IOException 原文🙂');
    bridge.candidatesFailure = failure;
    const original = {
      'ready': false,
      'status': 'failed',
      'scope': 'files',
      'paths': ['GeoSite.dat'],
    };
    app.publish(
      const AppSnapshot(
        phase: 'STOPPED',
        storageEpoch: 41,
        coreCleanup: original,
      ),
    );
    await show(tester);
    final target = cacheAction();
    await reveal(tester, target);
    await tester.tap(target);
    await pumpCacheResult(tester, message: true);
    expect(
      await _readFailure(tester),
      const AppMessage('coreCleanupFailed')
          .withDetail(failure)
          .resolve(lookupAppLocalizations(locale.value)),
    );
    expect(find.textContaining(failure.toString()), findsOneWidget);
    expect(app.state.coreCleanup, original);
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
  });

  for (final status in ['scheduled', 'failed']) {
    testWidgets('明确选择文件替换 $status 请求，取消时保留原请求', (tester) async {
      final original = {
        'ready': false,
        'status': status,
        'scope': 'files',
        'paths': ['GeoSite.dat'],
      };
      app.publish(
        AppSnapshot(phase: 'STOPPED', storageEpoch: 41, coreCleanup: original),
      );
      await show(tester);
      final strings = lookupAppLocalizations(locale.value);
      final target = find.byKey(const ValueKey('storage-cleanup-files'));
      await reveal(tester, target);
      await tester.tap(target);
      await pumpPopupEntrance(
        tester,
        find.widgetWithText(FilledButton, strings.coreCleanupDeleteSelected),
        source: target,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(strings.coreCleanupSelect),
        ),
        findsOneWidget,
      );
      expect(app.state.coreCleanup, original);
      await tester.tap(find.widgetWithText(TextButton, strings.cancel));
      await tester.pumpAndSettle();
      expect(app.state.coreCleanup, original);
      expect(bridge.commands, isEmpty);
      expect(bridge.exits, 0);
      await tester.tap(target);
      await pumpPopupEntrance(
        tester,
        find.widgetWithText(FilledButton, strings.coreCleanupDeleteSelected),
        source: target,
      );
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(strings.coreCleanupSelect),
        ),
        findsOneWidget,
      );
      expect(app.state.coreCleanup, original);
      tester.widget<CheckboxListTile>(fileCandidate('cache.db')).onChanged!(
        true,
      );
      await tester.pump();
      await tester.tap(
        find.widgetWithText(FilledButton, strings.coreCleanupDeleteSelected),
      );
      await tester.pump();
      expect(bridge.commands.single, {
        'action': 'scheduleCoreCleanup',
        'paths': ['cache.db'],
        'restart': false,
        'storageEpoch': 41,
      });
      app.complete();
      await pumpCacheResult(tester);
      expect(app.state.coreCleanup['status'], 'completed');
      expect(app.state.coreCleanup['paths'], ['cache.db']);
      await _closeNotice(tester);
      expect(bridge.exits, 0);
    });
  }

  testWidgets('内核身份改变后已受理资源确认保留原身份与路径', (tester) async {
    const source = CoreSnapshot(
      generation: 7,
      phase: 'READY',
      composition: '["loaded",7]',
      configId: 'loaded',
      revision: 2,
      purpose: 'RUNNING',
    );
    const path = '/fixture/mihomo/GeoSite.dat';
    bridge.rows = [
      {
        'kind': 'geo',
        'name': 'GeoSite',
        'vehicleType': 'HTTP',
        'source': 'https://fixture.test/original',
        'path': path,
        'updateSupported': true,
      },
    ];
    app.publish(
      const AppSnapshot(phase: 'RUNNING', core: source, storageEpoch: 41),
    );
    await show(tester, home: ResourcesPage(app: app));
    await tester.tap(find.widgetWithText(ListTile, 'GeoSite'));
    await tester.pumpAndSettle();
    final delete = find.byKey(const ValueKey('resource-delete-file'));
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    final strings = lookupAppLocalizations(locale.value);
    final confirm = find.widgetWithText(
      FilledButton,
      strings.coreCleanupDeleteSelected,
    );
    await pumpPopupEntrance(tester, confirm, source: delete);
    expect(find.text(path), findsOneWidget);
    tester.widget<FilledButton>(confirm).onPressed!();
    await tester.idle();
    expect(bridge.commands.single, {
      'action': 'scheduleCoreCleanup',
      'paths': [path.replaceFirst('/fixture/mihomo/', '')],
      'restart': false,
      'storageEpoch': 41,
    });
    app.publish(
      const AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 8,
          phase: 'READY',
          composition: '["replacement",8]',
          configId: 'replacement',
          revision: 3,
          purpose: 'RUNNING',
        ),
        storageEpoch: 42,
      ),
    );
    expect(bridge.commands, hasLength(1));
    const original = AppMessage(
      'coreCleanupFailed',
      detail: 'Resource context changed 原文🙂',
    );
    app.complete(success: false, message: original);
    await tester.pumpAndSettle();
    expect(await _readFailure(tester), original.resolve(strings));
    expect(bridge.exits, 0);
    expect(find.text(strings.operationFinished), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, strings.close));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('内核身份改变时立即拒绝尚未受理的旧资源路径和身份', (tester) async {
    const source = CoreSnapshot(
      generation: 7,
      phase: 'READY',
      composition: '["loaded",7]',
      configId: 'loaded',
      revision: 2,
      purpose: 'RUNNING',
    );
    const path = '/fixture/mihomo/GeoSite.dat';
    bridge.rows = [
      {'kind': 'geo', 'name': 'GeoSite', 'vehicleType': 'HTTP', 'path': path},
    ];
    const original = AppSnapshot(
      phase: 'RUNNING',
      core: source,
      storageEpoch: 41,
    );
    app.publish(original);
    await show(tester, home: ResourcesPage(app: app));
    await tester.tap(find.widgetWithText(ListTile, 'GeoSite'));
    await tester.pumpAndSettle();
    final delete = find.byKey(const ValueKey('resource-delete-file'));
    await tester.ensureVisible(delete);
    final sourceRoute = ModalRoute.of(tester.element(delete))!;
    expect(sourceRoute.isCurrent, isTrue);
    await tester.tap(delete);
    final strings = lookupAppLocalizations(locale.value);
    final confirm = find.widgetWithText(
      FilledButton,
      strings.coreCleanupDeleteSelected,
    );
    await pumpPopupEntrance(tester, confirm, source: delete);
    expect(find.text(path), findsOneWidget);
    final route = ModalRoute.of(tester.element(confirm))!;
    final oldConfirm = tester.widget<FilledButton>(confirm).onPressed!;
    app.publish(
      const AppSnapshot(
        phase: 'RUNNING',
        core: CoreSnapshot(
          generation: 8,
          phase: 'READY',
          composition: '["replacement",8]',
          configId: 'replacement',
          revision: 3,
          purpose: 'RUNNING',
        ),
        storageEpoch: 42,
      ),
    );
    oldConfirm();
    await tester.idle();
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
    expect(route, isNot(same(sourceRoute)));
    await tester.pump();
    expect(route.isActive, isFalse);
    expect(route.isCurrent, isFalse);
    expect(route.animation!.status, AnimationStatus.reverse);
    expect(sourceRoute.isActive, isTrue);
    expect(sourceRoute.isCurrent, isTrue);
    await tester.pump();
    expect(find.text(path), findsOneWidget);
    app.publish(original);
    oldConfirm();
    await tester.idle();
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
    expect(app.hasLocalFeedbackOwner, isFalse);
    expect(route.isActive, isFalse);
    expect(route.isCurrent, isFalse);
    expect(sourceRoute.isActive, isTrue);
    expect(sourceRoute.isCurrent, isTrue);
    await tester.pumpAndSettle();
    expect(
      ModalRoute.of(tester.element(find.byType(ResourcesPage))),
      same(sourceRoute),
    );
    expect(sourceRoute.isCurrent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('实际 Stop 结果退休同 generation 来源，并将 completed 事实交还全局', (
    tester,
  ) async {
    const source = CoreSnapshot(
      generation: 7,
      phase: 'READY',
      composition: '["loaded",7]',
      configId: 'loaded',
      revision: 2,
      purpose: 'RUNNING',
    );
    const path = '/fixture/mihomo/GeoSite.dat';
    bridge.rows = [
      {'kind': 'geo', 'name': 'GeoSite', 'vehicleType': 'HTTP', 'path': path},
    ];
    app.publish(
      const AppSnapshot(phase: 'RUNNING', core: source, storageEpoch: 41),
    );
    await show(tester, home: ResourcesPage(app: app));
    await tester.tap(find.widgetWithText(ListTile, 'GeoSite'));
    await tester.pumpAndSettle();
    final delete = find.byKey(const ValueKey('resource-delete-file'));
    await tester.ensureVisible(delete);
    final detailScaffold = Scaffold.of(tester.element(delete));
    final scaffolds = tester
        .stateList<ScaffoldState>(find.byType(Scaffold))
        .toList();
    expect(scaffolds, hasLength(2));
    final masterScaffold = scaffolds.singleWhere(
      (scaffold) => !identical(scaffold, detailScaffold),
    );
    final detailPane = find.byElementPredicate(
      (element) => identical(element, detailScaffold.context),
    );
    expect(delete.hitTestable(), findsOneWidget);
    await tester.tap(delete);
    final strings = lookupAppLocalizations(locale.value);
    final confirm = find.widgetWithText(
      FilledButton,
      strings.coreCleanupDeleteSelected,
    );
    await pumpPopupEntrance(tester, confirm, source: delete);
    expect(find.text(path), findsOneWidget);
    final oldConfirm = tester.widget<FilledButton>(confirm).onPressed!;
    oldConfirm();
    await tester.idle();
    expect(bridge.commands.single, {
      'action': 'scheduleCoreCleanup',
      'paths': [path.replaceFirst('/fixture/mihomo/', '')],
      'restart': false,
      'storageEpoch': 41,
    });
    // 发布 Stop 成功后的 STOPPED 快照：清空内核身份字段，保留 generation。
    // 直接提供最终 completed 结果，不先发布 RELEASING 快照。
    app.publish(
      const AppSnapshot(
        phase: 'STOPPED',
        storageEpoch: 41,
        core: CoreSnapshot(generation: 7),
        resultId: 'cleanup-1',
        resultSuccess: true,
        resultMessage: AppMessage('coreCleanupCompleted'),
        coreCleanup: {
          'ready': false,
          'status': 'completed',
          'scope': 'files',
          'paths': ['GeoSite.dat'],
        },
      ),
    );
    expect(app.state.core.generation, source.generation);
    expect(app.state.core.phase, 'EMPTY');
    expect(app.state.core.purpose, isNull);
    expect(app.state.core.configId, isNull);
    expect(app.state.core.revision, isNull);
    expect(app.state.core.composition, isNull);
    expect(app.state.core.logWindow, isNull);
    expect(source.matchesIdentity(app.state.core), isFalse);
    expect(app.state.storageEpoch, 41);
    expect(app.state.coreCleanup['status'], 'completed');
    oldConfirm();
    await tester.idle();
    expect(bridge.commands, hasLength(1));
    expect(bridge.exits, 0);
    expect(app.hasLocalFeedbackOwner, isFalse);
    await tester.pumpAndSettle();
    expect(app.state.resultSuccess, isTrue);
    expect(app.state.coreCleanup['status'], 'completed');
    expect(
      tester.stateList<ScaffoldState>(find.byType(Scaffold)),
      unorderedEquals([masterScaffold, detailScaffold]),
    );
    final snackBars = find.byType(SnackBar);
    expect(snackBars, findsNWidgets(2));
    final copies = tester.widgetList<SnackBar>(snackBars).toList();
    expect(copies.first, same(copies.last));
    expect(copies.first.key, isNotNull);
    expect(copies.first.key, same(copies.last.key));
    expect(
      snackBars.evaluate().map((element) => Scaffold.of(element)),
      unorderedEquals([masterScaffold, detailScaffold]),
    );
    final scheduledInDetail = find.descendant(
      of: detailPane,
      matching: find.text(strings.coreCleanupCompleted),
    );
    expect(scheduledInDetail, findsOneWidget);
    expect(scheduledInDetail.hitTestable(), findsOneWidget);
    expect(find.text(strings.operationFinished), findsNothing);
    expect(find.text(strings.coreCleanupScheduled), findsNothing);
    expect(find.widgetWithText(TextButton, strings.close), findsNothing);
    ScaffoldMessenger.of(detailScaffold.context).removeCurrentSnackBar();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text(strings.coreCleanupCompleted), findsNothing);
    expect(bridge.exits, 0);
    expect(tester.takeException(), isNull);
  });

  for (final (kind, vehicle, name, path) in const [
    (
      'proxyProvider',
      'HTTP',
      'remote',
      '/fixture/mihomo/providers/完整 名🙂.yaml',
    ),
    (
      'proxyProvider',
      'File',
      'remote',
      '/fixture/mihomo/providers/完整 名🙂.yaml',
    ),
    (
      'ruleProvider',
      'HTTP',
      'remote-rules',
      '/fixture/mihomo/rules/完整 名🙂.yaml',
    ),
    ('geo', 'File', 'GeoSite', '/fixture/mihomo/GeoSite.dat'),
  ]) {
    testWidgets('资源路径保持完整，provider 不提供文件删除，类型= $kind $vehicle', (tester) async {
      const source = CoreSnapshot(
        generation: 7,
        phase: 'READY',
        composition: '["loaded",7]',
        configId: 'loaded',
        revision: 2,
        purpose: 'RUNNING',
      );
      bridge.rows = [
        {
          'kind': kind,
          'name': name,
          'vehicleType': vehicle,
          'source': 'https://user:password@fixture.test/?token=完整🙂',
          'path': path,
          'updateSupported': true,
        },
      ];
      app.publish(
        const AppSnapshot(phase: 'RUNNING', core: source, storageEpoch: 41),
      );
      await show(tester, home: ResourcesPage(app: app));
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pumpAndSettle();
      final strings = lookupAppLocalizations(locale.value);
      expect(find.text(strings.resourceLocalFile(path)), findsOneWidget);
      final delete = find.byKey(const ValueKey('resource-delete-file'));
      if (kind != 'geo') {
        expect(delete, findsNothing);
        expect(bridge.commands, isEmpty);
        final raw = find.byKey(const ValueKey('resource-raw-data'));
        await tester.ensureVisible(raw);
        await tester.tap(raw);
        await tester.pumpAndSettle();
        final original = tester
            .widget<OriginalTextView>(find.byType(OriginalTextView))
            .text;
        expect(original, contains(path));
        expect(
          original,
          contains('https://user:password@fixture.test/?token=完整🙂'),
        );
        expect(original, contains(kind));
        expect(original, contains(vehicle));
        expect(bridge.commands, isEmpty);
        expect(bridge.exits, 0);
        Navigator.of(tester.element(find.byType(OriginalTextView))).pop();
        await tester.pumpAndSettle();
        expect(find.text(strings.resourceLocalFile(path)), findsOneWidget);
        expect(
          find.byKey(const ValueKey('resource-delete-file')),
          findsNothing,
        );
        return;
      }
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await pumpPopupEntrance(
        tester,
        find.widgetWithText(FilledButton, strings.coreCleanupDeleteSelected),
        source: delete,
      );
      expect(find.text(path), findsOneWidget);
      expect(
        find.textContaining(strings.coreCleanupResourceMessage),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(FilledButton, strings.coreCleanupDeleteSelected),
      );
      await tester.pump();
      expect(bridge.commands.single, {
        'action': 'scheduleCoreCleanup',
        'paths': [path.replaceFirst('/fixture/mihomo/', '')],
        'restart': false,
        'storageEpoch': 41,
      });
      // 保持资源身份；成功仅关闭提示，不关闭资源详情页。
      app.complete(stableSource: source);
      await _pumpNoticeFrames(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(app.state.coreCleanup['status'], 'completed');
      expect(
        find
            .descendant(
              of: find.byType(SnackBar),
              matching: find.textContaining(strings.coreCleanupCompleted),
            )
            .hitTestable(),
        findsWidgets,
      );
      expect(app.hasLocalFeedbackOwner, isFalse);
      expect(bridge.exits, 0);
      await _closeNotice(tester);
      expect(find.text(strings.resourceLocalFile(path)), findsOneWidget);
      expect(bridge.exits, 0);
    });
  }

  testWidgets('逐项结果保留成功文件、失败文件、完整路径与原错误', (tester) async {
    const original =
        'delete IOException https://user:password@fixture.test/?token=原文🙂';
    app.publish(
      const AppSnapshot(
        phase: 'STOPPED',
        storageEpoch: 41,
        coreCleanup: {
          'ready': false,
          'status': 'partial',
          'scope': 'files',
          'paths': ['cache.db', 'Geo/完整 名🙂.dat'],
          'files': [
            {'path': 'cache.db', 'completed': true},
            {
              'path': 'Geo/完整 名🙂.dat',
              'completed': false,
              'error': {
                'id': 'coreCleanupFailed',
                'args': <String, Object?>{},
                'detail': original,
              },
            },
          ],
        },
      ),
    );
    await show(tester);
    final state = find.byKey(const ValueKey('storage-core-cleanup-state'));
    await reveal(tester, state);
    final strings = lookupAppLocalizations(locale.value);
    expect(
      find.descendant(
        of: state,
        matching: find.text(strings.coreCleanupPartial),
      ),
      findsOneWidget,
    );
    for (final (path, complete) in [
      ('cache.db', true),
      ('Geo/完整 名🙂.dat', false),
    ]) {
      final row = find.ancestor(
        of: find.text(path),
        matching: find.byType(ListTile),
      );
      await reveal(tester, row);
      final leading = tester.widget<ListTile>(row).leading;
      expect(leading, isA<Icon>());
      expect(
        (leading! as Icon).icon,
        complete ? Icons.check_circle_outline : Icons.error_outline,
      );
    }
    expect(find.textContaining(original), findsNothing);
    final failed = find.ancestor(
      of: find.text('Geo/完整 名🙂.dat'),
      matching: find.byType(ListTile),
    );
    final details = find.descendant(
      of: failed,
      matching: find.widgetWithText(TextButton, strings.errorDetails),
    );
    await reveal(tester, details);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(
      await _readFailure(tester),
      const AppMessage('coreCleanupFailed', detail: original).resolve(strings),
    );
    await tester.tap(find.widgetWithText(TextButton, strings.close));
    await tester.pumpAndSettle();
    expect(app.state.coreCleanup['paths'], ['cache.db', 'Geo/完整 名🙂.dat']);
    expect(find.textContaining('providers/'), findsNothing);
    expect(bridge.commands, isEmpty);
    expect(bridge.exits, 0);
    expect(
      find.byKey(const ValueKey('storage-core-cleanup-exit')),
      findsNothing,
    );
  });

  test('快照保留逐项清理状态和原错误，不将全部存储标记为 busy', () {
    const original = 'https://user:password@fixture.test/?token=原文🙂';
    final raw = {
      'ready': false,
      'status': 'failed',
      'scope': 'files',
      'paths': ['完整🙂.dat'],
      'files': [
        {'path': '完整🙂.dat', 'completed': false},
      ],
      'error': const AppMessage('coreCleanupFailed', detail: original).toMap(),
      'unknown': 'preserved',
    };
    final snapshot = AppSnapshot.fromMap({
      'phase': 'STOPPED',
      'storageReady': true,
      'storageEpoch': 41,
      'coreCleanup': raw,
    });
    expect(snapshot.coreCleanup, raw);
    expect(snapshot.coreDataReady, isFalse);
    expect(snapshot.busy, isFalse);
    expect(AppMessage.fromMap(snapshot.coreCleanup['error']).detail, original);
    expect(snapshot.asStale().coreCleanup, same(snapshot.coreCleanup));
    raw['status'] = 'completed';
    expect(snapshot.coreCleanup['status'], 'failed');
    expect(
      () => snapshot.coreCleanup['status'] = 'completed',
      throwsUnsupportedError,
    );
  });
}
