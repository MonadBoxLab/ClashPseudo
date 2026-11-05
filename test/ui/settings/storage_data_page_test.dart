import 'dart:async';

import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:clash_pseudo/src/ui/components/reading/format_bytes.dart';
import 'package:clash_pseudo/src/ui/backup/backup_settings_actions.dart';
import 'package:clash_pseudo/src/ui/settings/settings_page.dart';
import 'package:clash_pseudo/src/ui/settings/storage_data_page.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/connection_fakes.dart';
import '../diagnostics/dns/dns_fakes.dart';

import 'package:clash_pseudo/src/ui/navigation/route_observer.dart';

class _StorageBridge extends ConnectionBridgeFake {
  int usageReads = 0;
  int exits = 0;
  Object? usageFailure;
  Completer<Map<String, dynamic>>? pendingUsage;
  Map<String, dynamic> usage = {
    'configurations': {
      'bytes': 134217729,
      'path': '/fixture/configurations.json',
    },
    'overrides': {'bytes': 123, 'path': '/fixture/overrides.json'},
    'preferences': {'bytes': 57, 'path': '/fixture/preferences.json'},
    'core': {'bytes': 456, 'path': '/fixture/mihomo'},
  };

  @override
  Future<Map<String, dynamic>> storageUsage() async {
    usageReads++;
    if (usageFailure case final failure?) throw failure;
    return pendingUsage == null ? Map.of(usage) : await pendingUsage!.future;
  }
}

void main() {
  late _StorageBridge bridge;
  late DnsTestApp app;

  Future<Object?> platformCall(MethodCall call) async {
    if (call.method == 'SystemNavigator.pop') bridge.exits++;
    return null;
  }

  setUp(() {
    bridge = _StorageBridge();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, platformCall);
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    app = DnsTestApp(bridge)
      ..state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 41)
      ..configsLoaded = false
      ..configErrorMessage = const AppMessage(
        'configStoreUnreadable',
        detail: '{broken 原文',
      )
      ..overridesLoaded = false
      ..overrideErrorMessage = const AppMessage('overridesUnreadable');
    addTearDown(app.dispose);
  });

  Future<void> show(
    WidgetTester tester, {
    String language = 'en',
    double scale = 1,
    bool settings = false,
    Size size = const Size(320, 900),
    bool dark = false,
    bool disableAnimations = false,
    ValueNotifier<(double, bool)>? presentation,
  }) async {
    final observer = AppTaskNavigatorObserver();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        theme: dark ? AppTheme.dark : AppTheme.light,
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          Widget media((double, bool) value) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(value.$1),
              disableAnimations: value.$2,
            ),
            child: child!,
          );
          return presentation == null
              ? media((scale, disableAnimations))
              : ValueListenableBuilder(
                  valueListenable: presentation,
                  builder: (_, value, _) => media(value),
                );
        },
        home: settings ? SettingsPage(app: app) : StorageDataPage(app: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reread(WidgetTester tester) async {
    app.setForeground(false);
    app.setForeground(true);
    await tester.pump();
  }

  Future<void> reveal(
    WidgetTester tester,
    Finder finder, {
    double delta = 180,
  }) async {
    final scrollable = find.byType(Scrollable).first;
    var direction = delta;
    for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
      final bounds = tester.getRect(scrollable);
      final position = tester.state<ScrollableState>(scrollable).position;
      final before = position.pixels;
      // 从列表边缘拖动，避免选中用量原文；到达边界后向另一侧查找。
      await tester.dragFrom(
        Offset(bounds.left + 8, bounds.center.dy),
        Offset(0, -direction),
      );
      await tester.pumpAndSettle();
      if ((position.pixels - before).abs() < .01) direction = -direction;
    }
    expect(finder, findsOneWidget);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<String> readOriginal(
    WidgetTester tester,
    Finder container,
    String original,
  ) async {
    final strings = AppLocalizations.of(
      tester.element(find.byType(StorageDataPage)),
    );
    final action = find.descendant(
      of: find.byType(SnackBar),
      matching: find.widgetWithText(TextButton, strings.errorDetails),
    );
    await tester.pumpAndSettle();
    expect(action, findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.widget<TextButton>(action).child, isNotNull);
    expect(tester.getRect(action).size.shortestSide, greaterThanOrEqualTo(48));
    final readers = find.descendant(
      of: container,
      matching: find.byType(EditableText),
    );
    final reader = readers.first;
    final readerState = readers.evaluate().isEmpty
        ? null
        : tester.state(reader);
    final page = tester.state(find.byType(StorageDataPage));
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    final pixels = scroll.pixels;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return platformCall(call);
      },
    );
    try {
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.textContaining(original), findsNothing);
      final technicalAction = find.byKey(
        const ValueKey('operation-technical-details'),
      );
      await tester.ensureVisible(technicalAction);
      await tester.pumpAndSettle();
      await tester.tap(technicalAction);
      await tester.pumpAndSettle();
      final technical = tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('operation-technical-text')),
          )
          .data!;
      expect(technical, contains(original));
      final copy = find.byKey(const ValueKey('operation-technical-copy'));
      await tester.ensureVisible(copy);
      await tester.tap(copy);
      await tester.pump();
      expect(copied, technical);
      await tester.tap(
        find.widgetWithText(TextButton, strings.close).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(StorageDataPage)), same(page));
      if (readerState != null) expect(tester.state(reader), same(readerState));
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable).first).position,
        same(scroll),
      );
      expect(scroll.pixels, closeTo(pixels, .01));
      return technical;
    } finally {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        platformCall,
      );
    }
  }

  testWidgets('存储旧epoch的错误详情callback立即失效', (tester) async {
    await show(tester);
    final strings = lookupAppLocalizations(const Locale('en'));
    final action = find.descendant(
      of: find.byType(SnackBar),
      matching: find.widgetWithText(TextButton, strings.errorDetails),
    );
    final oldDetails = tester.widget<TextButton>(action).onPressed!;
    app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 42);
    oldDetails();
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final language in ['zh', 'en']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('存储读取进度与失败保持正文几何 $language $scale', (tester) async {
        app.configErrorMessage = null;
        app.overrideErrorMessage = null;
        bridge.usage['configurations'] = {'bytes': 1048576};
        await show(
          tester,
          size: const Size(700, 1800),
          language: language,
          scale: scale,
        );
        final strings = lookupAppLocalizations(Locale(language));
        final row = find.byKey(const ValueKey('storage-usage-configurations'));
        final following = find.byKey(const ValueKey('storage-usage-overrides'));
        await reveal(tester, row);
        expect(find.byTooltip(strings.refresh), findsNothing);
        expect(find.byType(RefreshIndicator), findsNothing);
        final before = (tester.getRect(row), tester.getRect(following));
        final page = tester.state(find.byType(StorageDataPage));
        final scroll = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        final pixels = scroll.pixels;
        final pending = bridge.pendingUsage = Completer<Map<String, dynamic>>();
        await reread(tester);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect((tester.getRect(row), tester.getRect(following)), before);
        bridge.pendingUsage = null;
        pending.completeError(StateError('stat original cause'));
        await tester.pumpAndSettle();
        expect((tester.getRect(row), tester.getRect(following)), before);
        expect(scroll.pixels, pixels);
        expect(tester.state(find.byType(StorageDataPage)), same(page));
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text(strings.storageUsageFailed),
          ),
          findsOneWidget,
        );
        final text = tester
            .widget<SelectableText>(
              find.descendant(of: row, matching: find.byType(SelectableText)),
            )
            .data!;
        expect(text, contains(strings.storageFileBytes('1.00 MiB', '128 MiB')));
        expect(text, isNot(contains('stat original cause')));
        await tester.tap(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byIcon(Icons.close),
          ),
        );
        await tester.pumpAndSettle();
        await app.refresh();
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        expect(app.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('存储值与读取错误更新不改变行高或后续内容位置', (tester) async {
    app.configErrorMessage = null;
    app.overrideErrorMessage = null;
    bridge.usage['configurations'] = {'bytes': 1048576};
    final presentation = ValueNotifier((1.0, false));
    addTearDown(presentation.dispose);
    await show(tester, size: const Size(700, 1200), presentation: presentation);
    final row = find.byKey(const ValueKey('storage-usage-configurations'));
    final following = find.byKey(const ValueKey('storage-usage-overrides'));
    await reveal(tester, row);
    final page = tester.state(find.byType(StorageDataPage));
    final editor = find.descendant(
      of: row,
      matching: find.byType(EditableText),
    );
    final editorState = tester.state(editor);
    double extent() => tester
        .getSize(
          find.ancestor(of: row, matching: find.byType(AnimatedSize)).first,
        )
        .height;
    String text() => tester
        .widget<SelectableText>(
          find.descendant(of: row, matching: find.byType(SelectableText)),
        )
        .data!;
    final before = extent();
    final followingBefore = tester.getTopLeft(following).dy;
    final original = List.filled(8, 'original cause 原文🙂').join('\n');
    final native = {
      'bytes': 1572864,
      'path': '/fixture/configurations.json',
      'error': AppMessage('storageUsageFailed', detail: original).toMap(),
    };
    bridge.usage['configurations'] = native;
    await reread(tester);
    await tester.pump();
    expect(text(), contains('1.50 MiB / 128 MiB'));
    expect(
      text(),
      isNot(
        contains(lookupAppLocalizations(const Locale('en')).storageUsageFailed),
      ),
    );
    expect(text(), isNot(contains(original)));
    expect(bridge.usage['configurations'], same(native));
    expect(extent(), closeTo(before, .01));
    await tester.pump(const Duration(milliseconds: 60));
    final middle = extent();
    expect(middle, before);
    expect(tester.getSize(row).height, before);
    expect(tester.getTopLeft(following).dy, followingBefore);
    bridge.usage['configurations'] = {'bytes': 2097152};
    await reread(tester);
    await tester.pump();
    expect(text(), contains('2.00 MiB / 128 MiB'));
    expect(text(), isNot(contains(original)));
    expect(extent(), closeTo(middle, .01));
    await tester.pump(const Duration(milliseconds: 40));
    expect(extent(), middle);
    await tester.pumpAndSettle();
    expect(extent(), closeTo(before, .01));
    expect(tester.getTopLeft(following).dy, closeTo(followingBefore, .01));
    presentation.value = (2.0, true);
    await tester.pump();
    expect(
      find.ancestor(of: row, matching: find.byType(AnimatedSize)),
      findsNothing,
    );
    expect(tester.state(editor), same(editorState));
    bridge.usage['configurations'] = native;
    await reread(tester);
    await tester.pump();
    expect(
      text(),
      isNot(
        contains(lookupAppLocalizations(const Locale('en')).storageUsageFailed),
      ),
    );
    expect(text(), isNot(contains(original)));
    expect(
      tester.getTopLeft(following).dy,
      closeTo(tester.getBottomLeft(row).dy, .01),
    );
    expect(await readOriginal(tester, row, original), contains(original));
    expect(tester.state(find.byType(StorageDataPage)), same(page));
    expect(tester.state(editor), same(editorState));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('存储清理错误只由 SnackBar 展示，状态变化后旧详情失效', (tester) async {
    app.configErrorMessage = null;
    app.overrideErrorMessage = null;
    app.state = const AppSnapshot(
      phase: 'STOPPED',
      storageEpoch: 41,
      coreCleanup: {
        'status': 'failed',
        'scope': 'files',
        'files': [
          {'path': 'cache.db', 'completed': false},
        ],
        'error': {
          'id': 'coreCleanupFailed',
          'args': <String, Object?>{},
          'detail': 'cleanup original 原文🙂',
        },
      },
    );
    await show(tester, size: const Size(700, 1200));
    final strings = lookupAppLocalizations(const Locale('en'));
    final action = find.descendant(
      of: find.byType(SnackBar),
      matching: find.widgetWithText(TextButton, strings.errorDetails),
    );
    expect(action, findsOneWidget);
    expect(
      find.byKey(const ValueKey('storage-core-cleanup-state')),
      findsNothing,
    );
    expect(find.text('cache.db'), findsNothing);
    final oldDetails = tester.widget<TextButton>(action).onPressed!;
    app.state = const AppSnapshot(
      phase: 'STOPPED',
      storageEpoch: 41,
      coreCleanup: {'status': 'completed', 'scope': 'files'},
    );
    oldDetails();
    await app.refresh();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(strings.coreCleanupCompleted), findsOneWidget);
    expect(bridge.exits, 0);
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('部分清理结果在详情保留文件、状态和原因', (tester) async {
    app.configErrorMessage = null;
    app.overrideErrorMessage = null;
    app.state = const AppSnapshot(
      phase: 'STOPPED',
      storageEpoch: 41,
      coreCleanup: {
        'status': 'partial',
        'files': [
          {'path': 'cache.db', 'completed': true},
          {
            'path': 'geo/failed.dat',
            'completed': false,
            'error': {
              'id': 'coreCleanupFailed',
              'args': <String, Object?>{},
              'detail': 'permission denied original',
            },
          },
        ],
      },
    );
    await show(tester, size: const Size(700, 1200));
    final detail = await readOriginal(
      tester,
      find.byType(StorageDataPage),
      'permission denied original',
    );
    final strings = lookupAppLocalizations(const Locale('en'));
    expect(detail, contains('cache.db · ${strings.cleanupFileCompleted}'));
    expect(detail, contains('geo/failed.dat · ${strings.cleanupFileFailed}'));
    expect(app.commands, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('设置仅有一个存储入口，不重复显示 backup 操作', (tester) async {
    await show(tester, settings: true);
    expect(find.byType(BackupSettingsActions), findsNothing);
    final entry = find.byKey(const ValueKey('settings-storage-data'));
    await reveal(tester, entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(StorageDataPage), findsOneWidget);
    expect(find.byType(BackupSettingsActions), findsOneWidget);
    final import = find.byKey(const ValueKey('backup-import'));
    final export = find.byKey(const ValueKey('backup-export'));
    expect(
      tester.getTopLeft(import).dy,
      lessThan(tester.getTopLeft(export).dy),
    );
    expect(bridge.usageReads, 1);
    expect(app.commands, isEmpty);
  });

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('存储分组保留用量与损坏集合删除入口，$language $scale', (tester) async {
        await show(tester, language: language, scale: scale);
        final strings = lookupAppLocalizations(Locale(language));
        final originalRead = await readOriginal(
          tester,
          find.byType(StorageDataPage),
          '{broken 原文',
        );
        for (final heading in [
          strings.backupTitle,
          strings.storageUsage,
          strings.storageCleanup,
        ]) {
          await reveal(tester, find.text(heading));
          expect(find.text(heading), findsOneWidget);
        }
        final config = find.byKey(
          const ValueKey('storage-usage-configurations'),
        );
        // Scroll back up after reaching the cleanup group.
        await reveal(tester, config, delta: -180);
        final text = tester
            .widget<SelectableText>(
              find.descendant(
                of: config,
                matching: find.byType(SelectableText),
              ),
            )
            .data!;
        expect(
          text,
          contains(
            strings.storageFileBytes(
              '128 MiB',
              formatBytes(ApplicationContract.backupConfigurationsJsonBytes),
            ),
          ),
        );
        expect(text, contains(strings.storageLimitExceeded));
        expect(text, isNot(contains('/fixture/configurations.json')));
        expect(text, isNot(contains('134217729')));
        expect(bridge.usage['configurations'], {
          'bytes': 134217729,
          'path': '/fixture/configurations.json',
        });
        expect(text, isNot(contains(strings.configStoreUnreadable)));
        expect(text, isNot(contains('{broken 原文')));
        expect(originalRead, contains('{broken 原文'));
        expect(
          text,
          isNot(
            contains(
              strings.storageEntryCount(
                0,
                ApplicationContract.backupCollectionEntries,
              ),
            ),
          ),
        );
        final clear = find.byKey(
          const ValueKey('storage-clear-configurations'),
        );
        await reveal(tester, clear);
        expect(tester.widget<ListTile>(clear).onTap, isNotNull);
        expect(tester.takeException(), isNull);
        expect(app.commands, isEmpty);
      });
    }
  }

  for (final (bytes, label, exceeded) in const [
    (0, '0 B', false),
    (1023, '1023 B', false),
    (1024, '1.00 KiB', false),
    (1048576, '1.00 MiB', false),
    (134217727, '128 MiB', false),
    (134217728, '128 MiB', false),
    (134217729, '128 MiB', true),
    (1073741824, '1.00 GiB', true),
    (1099511627776, '1.00 TiB', true),
  ]) {
    testWidgets('存储格式化 $bytes 时保留配额精度', (tester) async {
      final raw = <String, dynamic>{
        'bytes': bytes,
        'path': '/fixture/configurations.json',
        'future': [null, false, 0, <String, dynamic>{}],
      };
      bridge.usage['configurations'] = raw;
      await show(tester);
      final strings = lookupAppLocalizations(const Locale('en'));
      final row = find.byKey(const ValueKey('storage-usage-configurations'));
      await reveal(tester, row);
      final text = tester
          .widget<SelectableText>(
            find.descendant(of: row, matching: find.byType(SelectableText)),
          )
          .data!;
      expect(text.split('\n').first, startsWith('$label / 128 MiB'));
      expect(text.contains(strings.storageLimitExceeded), exceeded);
      expect(text, isNot(contains('/fixture/')));
      expect(text, isNot(contains('$bytes bytes')));
      expect(bridge.usage['configurations'], same(raw));
      expect(raw, {
        'bytes': bytes,
        'path': '/fixture/configurations.json',
        'future': [null, false, 0, <String, dynamic>{}],
      });
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, language, scale, dark) in const [
    (Size(320, 900), 'en', 1.0, false),
    (Size(1704, 1136), 'zh', 2.0, true),
  ]) {
    testWidgets('存储各分组对齐行与 icon 基线，$size $language', (tester) async {
      await show(
        tester,
        size: size,
        language: language,
        scale: scale,
        dark: dark,
      );
      final strings = lookupAppLocalizations(Locale(language));
      final left = tester.getRect(find.byType(ListView)).left;
      for (final heading in [
        strings.backupTitle,
        strings.storageUsage,
        strings.storageCleanup,
      ]) {
        await reveal(tester, find.text(heading));
        expect(
          tester.getTopLeft(find.text(heading)).dx,
          closeTo(left + 16, .1),
        );
      }
      for (final (key, label, icon) in [
        ('backup-import', strings.backupImport, Icons.folder_open_outlined),
        (
          'storage-usage-configurations',
          strings.configurations,
          Icons.description_outlined,
        ),
        (
          'storage-clear-configurations',
          strings.clearConfigurations,
          Icons.delete_outline,
        ),
      ]) {
        final row = find.byKey(ValueKey(key));
        // Return to the beginning before finding a lazily built earlier row.
        await tester.dragFrom(
          Offset(left + 8, tester.getRect(find.byType(ListView)).center.dy),
          const Offset(0, 10000),
        );
        await tester.pumpAndSettle();
        await reveal(tester, row);
        expect(
          tester
              .getTopLeft(find.descendant(of: row, matching: find.byIcon(icon)))
              .dx,
          closeTo(left + 16, .1),
        );
        expect(
          tester
              .getTopLeft(find.descendant(of: row, matching: find.text(label)))
              .dx,
          closeTo(left + 56, .1),
        );
      }
      expect(find.byType(Card), findsNothing);
      expect(find.byType(ListView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('未知 core 用量不显示为零，文件原错误完整保留', (tester) async {
    const original =
        '/fixture/private/failed.json\nCaused by: original open\nSuppressed: original close';
    bridge.usage['core'] = {
      'bytes': -1,
      'path': '/fixture/mihomo',
      'error': const AppMessage('storageUsageFailed', detail: original).toMap(),
    };
    await show(tester);
    final row = find.byKey(const ValueKey('storage-usage-core'));
    await reveal(tester, row);
    final text = tester
        .widget<SelectableText>(
          find.descendant(of: row, matching: find.byType(SelectableText)),
        )
        .data!;
    expect(text.split('\n').first, '—');
    expect(text, isNot(contains(original)));
    expect(await readOriginal(tester, row, original), contains(original));
    expect(text, isNot(contains('/fixture/mihomo')));
    expect(text, isNot(contains('0 B')));
  });

  for (final configurations in [true, false]) {
    testWidgets(
      '集合删除仅显示一次范围确认，并保留原 native epoch，configurations=$configurations',
      (tester) async {
        await show(tester);
        final strings = lookupAppLocalizations(const Locale('en'));
        final clear = find.byKey(
          ValueKey(
            'storage-clear-${configurations ? 'configurations' : 'overrides'}',
          ),
        );
        await reveal(tester, clear);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(app.commands, isEmpty);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text(
            configurations
                ? strings.clearConfigurationsMessage
                : strings.clearOverridesMessage,
          ),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(TextButton, strings.cancel));
        await tester.pumpAndSettle();
        expect(app.commands, isEmpty);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 42);
        await app.refresh();
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, strings.delete));
        await tester.pumpAndSettle();
        expect(app.commands.single, {
          'action': configurations ? 'clearConfigurations' : 'clearOverrides',
          'storageEpoch': 41,
        });
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('结束记录清理调用同一 observer，不显示破坏性确认', (tester) async {
    await show(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    final clear = find.byKey(const ValueKey('storage-clear-connections'));
    await reveal(tester, clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(bridge.clears, 1);
    expect(app.commands, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.text(
        lookupAppLocalizations(const Locale('en')).inactiveConnectionsCleared,
      ),
      findsOneWidget,
    );
  });

  for (final language in ['en', 'zh']) {
    testWidgets('独立 backup 清理错误保持可读，不改变 commit 结果，$language', (tester) async {
      const original =
          'candidate cleanup https://user:pass@fixture.test/?token=原文🙂\nCaused by: directory fsync\nSuppressed: original close';
      final raw = <String, dynamic>{
        'busy': false,
        'draining': false,
        'errorCode': 'backupCleanupFailed',
        'errorDetail': const AppMessage(
          'backupFailed',
          detail: original,
        ).toMap(),
        'future': [false, 0, null, <String, dynamic>{}],
      };
      final snapshot = AppSnapshot.fromMap({
        'phase': 'STOPPED',
        'storageReady': true,
        'storageEpoch': 41,
        'backup': raw,
        'resultSuccess': false,
        'backupResult': {'status': 'restored', 'committed': true},
      });
      expect(snapshot.backup, raw);
      expect(snapshot.asStale().backup, same(snapshot.backup));
      raw['errorCode'] = 'changed after capture';
      expect(snapshot.backup['errorCode'], 'backupCleanupFailed');
      expect(snapshot.backupResult!['committed'], isTrue);
      expect(snapshot.resultSuccess, isFalse);
      app.state = snapshot;
      await show(tester, language: language);
      final error = find.byKey(const ValueKey('storage-usage-configurations'));
      await reveal(tester, error);
      expect(
        tester
            .widget<SelectableText>(
              find.descendant(of: error, matching: find.byType(SelectableText)),
            )
            .data,
        isNot(contains(original)),
      );
      expect(await readOriginal(tester, error, original), contains(original));
      final clear = find.byKey(const ValueKey('storage-clear-configurations'));
      await reveal(tester, clear);
      expect(tester.widget<ListTile>(clear).onTap, isNotNull);
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final ready in [false, true]) {
    testWidgets('启动文件错误保持可读，仍显示实际存储 ready=$ready', (tester) async {
      const original =
          'original file failure https://user:pass@fixture.test/?token=原文🙂\noriginal cleanup cause';
      final snapshot = AppSnapshot.fromMap({
        'phase': 'STOPPED',
        'storageReady': ready,
        'storageEpoch': 41,
        'storageError': AppMessage(
          ready ? 'storageCleanupFailed' : 'storageUnavailable',
          detail: original,
        ).toMap(),
      });
      expect(snapshot.storageReady, ready);
      expect(snapshot.asStale().storageError, snapshot.storageError);
      app.state = snapshot;
      await show(tester);
      final error = find.byKey(const ValueKey('storage-usage-configurations'));
      await reveal(tester, error);
      final text = tester
          .widget<SelectableText>(
            find.descendant(of: error, matching: find.byType(SelectableText)),
          )
          .data!;
      expect(text, isNot(contains(original)));
      expect(await readOriginal(tester, error, original), contains(original));
      final strings = lookupAppLocalizations(const Locale('en'));
      expect(
        text,
        isNot(
          contains(
            ready ? strings.storageCleanupFailed : strings.storageUnavailable,
          ),
        ),
      );
      expect(app.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('存储读取失败保留原错误，不禁用集合删除', (tester) async {
    const original =
        'https://user:password@fixture.test/path?token=原文#section\nAuthorization: Bearer 🙂';
    bridge.usageFailure = StateError(original);
    await show(tester);
    final error = find.byKey(const ValueKey('storage-usage-configurations'));
    await reveal(tester, error);
    expect(find.textContaining(StateError(original).toString()), findsNothing);
    expect(
      await readOriginal(tester, error, StateError(original).toString()),
      contains(StateError(original).toString()),
    );
    final clear = find.byKey(const ValueKey('storage-clear-overrides'));
    await reveal(tester, clear);
    expect(tester.widget<ListTile>(clear).onTap, isNotNull);
    expect(app.commands, isEmpty);
  });

  testWidgets('重新测量失败后保留上次用量和完整 cause', (tester) async {
    await show(tester);
    const original = 'stat original\nCaused by: open\nSuppressed: close 原文🙂';
    final readsBefore = bridge.usageReads;
    bridge.usageFailure = StateError(original);
    await reread(tester);
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('storage-usage-configurations'));
    await reveal(tester, row);
    final text = tester
        .widget<SelectableText>(
          find.descendant(of: row, matching: find.byType(SelectableText)),
        )
        .data!;
    expect(
      text.split('\n').first,
      '128 MiB / 128 MiB · ${lookupAppLocalizations(const Locale('en')).storageLimitExceeded}',
    );
    expect(bridge.usageReads, readsBefore + 1);
    await reveal(
      tester,
      find.byKey(const ValueKey('storage-usage-configurations')),
      delta: -180,
    );
    expect(find.textContaining(original), findsNothing);
    expect(
      await readOriginal(
        tester,
        find.byKey(const ValueKey('storage-usage-configurations')),
        original,
      ),
      contains(original),
    );
    expect(bridge.usageReads, readsBefore + 1);
    final clear = find.byKey(const ValueKey('storage-clear-configurations'));
    await reveal(tester, clear);
    expect(tester.widget<ListTile>(clear).onTap, isNotNull);
  });

  for (final rawBytes in <Object?>[null, -1, 0.5, '0', false]) {
    testWidgets('无效 byte 值 $rawBytes 显示为未知，而不是零', (tester) async {
      bridge.usage['configurations'] = {'bytes': rawBytes};
      await show(tester);
      final row = find.byKey(const ValueKey('storage-usage-configurations'));
      await reveal(tester, row);
      final text = tester
          .widget<SelectableText>(
            find.descendant(of: row, matching: find.byType(SelectableText)),
          )
          .data!;
      expect(text.split('\n').first, '— / 128 MiB');
      expect(text, isNot(contains('0 B')));
      expect(text, isNot(contains('0 /')));
    });
  }

  testWidgets('epoch 改变后不将旧读取的容量显示为当前值', (tester) async {
    await show(tester);
    final first = Completer<Map<String, dynamic>>();
    final second = Completer<Map<String, dynamic>>();
    bridge.pendingUsage = first;
    await reread(tester);
    app.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 42);
    await app.refresh();
    bridge.pendingUsage = second;
    first.complete({
      'configurations': {'bytes': 1},
    });
    await tester.pump();
    final row = find.byKey(const ValueKey('storage-usage-configurations'));
    await tester.ensureVisible(row);
    await tester.pump();
    String text() => tester
        .widget<SelectableText>(
          find.descendant(of: row, matching: find.byType(SelectableText)),
        )
        .data!;
    expect(text().split('\n').first, '— / 128 MiB');
    expect(text(), isNot(contains('1 B /')));
    second.complete({
      'configurations': {'bytes': 9},
    });
    await tester.pumpAndSettle();
    expect(text(), contains('9 B / 128 MiB'));
    expect(bridge.usageReads, 3);
  });

  testWidgets('关闭存储 Route 立即撤销 cached cleanup callback', (tester) async {
    await show(tester, settings: true);
    final entry = find.byKey(const ValueKey('settings-storage-data'));
    await reveal(tester, entry);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    final clear = find.byKey(const ValueKey('storage-clear-connections'));
    await reveal(tester, clear);
    final callback = tester.widget<ListTile>(clear).onTap!;
    expect(find.byType(RefreshIndicator), findsNothing);
    final reads = bridge.usageReads;
    Navigator.of(tester.element(clear)).pop();
    callback();
    expect(bridge.clears, 0);
    expect(bridge.usageReads, reads);
    await tester.pump();
    expect(find.byType(StorageDataPage), findsOneWidget);
    expect(clear.hitTestable(), findsNothing);
    expect(app.commands, isEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(StorageDataPage), findsNothing);
  });

  testWidgets('存储读取期间的来源变化合并为一次新读取', (tester) async {
    await show(tester);
    final pending = Completer<Map<String, dynamic>>();
    bridge.pendingUsage = pending;
    await reread(tester);
    expect(bridge.usageReads, 2);
    for (final epoch in [42, 43]) {
      app.state = AppSnapshot(phase: 'STOPPED', storageEpoch: epoch);
      await app.refresh();
    }
    expect(bridge.usageReads, 2);
    bridge.pendingUsage = null;
    bridge.usage = {
      ...bridge.usage,
      'configurations': {'bytes': 9, 'path': '/fixture/configurations.json'},
    };
    pending.complete({
      'configurations': {'bytes': 1, 'path': '/fixture/previous.json'},
    });
    await tester.pumpAndSettle();
    expect(bridge.usageReads, 3);
    final config = find.byKey(const ValueKey('storage-usage-configurations'));
    await reveal(tester, config);
    final text = tester
        .widget<SelectableText>(
          find.descendant(of: config, matching: find.byType(SelectableText)),
        )
        .data!;
    expect(text, isNot(contains('/fixture/')));
    expect(
      text,
      contains(
        lookupAppLocalizations(const Locale('en')).storageFileBytes(
          '9 B',
          formatBytes(ApplicationContract.backupConfigurationsJsonBytes),
        ),
      ),
    );
    expect(text, isNot(contains('1 B /')));
  });

  testWidgets('用量不可读时保留配额，不显示零用量', (tester) async {
    bridge.usageFailure = StateError('injected usage failure');
    await show(tester);
    final strings = lookupAppLocalizations(const Locale('en'));
    final config = find.byKey(const ValueKey('storage-usage-configurations'));
    await reveal(tester, config);
    final text = tester
        .widget<SelectableText>(
          find.descendant(of: config, matching: find.byType(SelectableText)),
        )
        .data!;
    expect(
      text,
      contains(
        strings.storageFileBytes(
          '—',
          formatBytes(ApplicationContract.backupConfigurationsJsonBytes),
        ),
      ),
    );
    expect(
      text,
      isNot(
        contains(
          strings.storageFileBytes(
            '0 B',
            formatBytes(ApplicationContract.backupConfigurationsJsonBytes),
          ),
        ),
      ),
    );
  });

  testWidgets('结束记录清理报告自身失败，并保留原错误', (tester) async {
    const original = 'https://user:password@fixture.test/?token=原文🙂';
    bridge.clearFailure = StateError(original);
    await show(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    final clear = find.byKey(const ValueKey('storage-clear-connections'));
    await reveal(tester, clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    final strings = lookupAppLocalizations(const Locale('en'));
    expect(find.text(strings.inactiveConnectionsClearFailed), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(strings.errorDetails),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('operation-technical-details')));
    await tester.pumpAndSettle();
    final summary = tester
        .widget<SelectableText>(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(SelectableText),
              )
              .first,
        )
        .data!;
    final technical = tester
        .widget<SelectableText>(
          find.byKey(const ValueKey('operation-technical-text')),
        )
        .data!;
    expect(
      '$summary\n$technical',
      '${strings.inactiveConnectionsClearFailed}\n${StateError(original)}',
    );
    expect(find.textContaining(strings.storageUsageFailed), findsNothing);
    expect(find.text(strings.inactiveConnectionsCleared), findsNothing);
    expect(app.commands, isEmpty);
  });

  testWidgets('存储页使用一个连续列表，不放置诊断导航', (tester) async {
    await show(tester);
    final strings = lookupAppLocalizations(const Locale('en'));
    expect(find.byType(ListView), findsOneWidget);
    final seen = <String>{};
    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    for (var i = 0; i < 50; i++) {
      seen.addAll(
        tester
            .widgetList<Text>(
              find.descendant(
                of: find.byType(StorageDataPage),
                matching: find.byType(Text),
              ),
            )
            .map((text) => text.data)
            .whereType<String>(),
      );
      if (position.extentAfter == 0) break;
      final bounds = tester.getRect(scrollable);
      await tester.dragFrom(
        Offset(bounds.left + 8, bounds.center.dy),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
    }
    expect(position.extentAfter, 0);
    expect(
      seen,
      containsAll([
        strings.backupTitle,
        strings.storageUsage,
        strings.storageCleanup,
        strings.backupImport,
        strings.backupExport,
        strings.clearConfigurations,
        strings.clearOverrides,
        strings.clearInactiveConnections,
        strings.coreCleanupSelect,
      ]),
    );
    for (final title in [
      strings.coreLogs,
      strings.dnsTools,
      strings.externalResources,
    ]) {
      expect(seen, isNot(contains(title)));
    }
    expect(app.commands, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
