import 'dart:io';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/app/widgets/reading_list.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';
import 'package:clash_pseudo/src/features/overrides/local_custom_actions.dart';
import 'package:clash_pseudo/src/features/overrides/local_custom_editor.dart';
import 'package:clash_pseudo/src/features/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/features/overrides/override_actions.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/features/overrides/rule_form.dart';
import 'package:clash_pseudo/src/features/overrides/strategy_group_form.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/local_definitions.dart';
import '../configs/action_fakes.dart';
import '../settings/preferences_fakes.dart';

class _Configs extends ConfigStore {
  _Configs() : super(Directory.systemTemp);
  @override
  Future<ConfigCollection> read() async => ConfigCollection(entries: []);
}

class _Overrides extends OverrideStore {
  _Overrides() : super(Directory.systemTemp);
  List<OverrideEntry> entries = [];
  bool unreadable = false;
  @override
  Future<List<OverrideEntry>> read() async {
    if (unreadable) throw ConfigFailure(messages.temporaryOverridesUnreadable);
    return List.unmodifiable(entries);
  }

  @override
  Future<void> save(List<OverrideEntry> entries) async =>
      this.entries = entries;
}

// Use the real YAML writer and AppController feedback ownership; control native
// receipt/result timing and apply outcome.
class _Bridge extends AppBridge {
  _Bridge(this.store) {
    actions = OverrideActions(
      store,
      DownloadFake(),
      platform,
      runInput: File(
        '${Directory.systemTemp.path}/unused-local-custom-input.json',
      ),
    );
  }
  final _Overrides store;
  final platform = PlatformFake();
  late final OverrideActions actions;
  AppSnapshot state = const AppSnapshot(phase: 'STOPPED');
  final commands = <Map<String, Object?>>[];
  @override
  Future<AppSnapshot> snapshot() async => state;
  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(Map.of(command));
    return OperationAdmission(
      operationId: 'local-${commands.length}',
      remaining: const Duration(seconds: 120),
    );
  }

  Future<void> finish({
    String status = 'saved',
    bool success = true,
    AppMessage? resultMessage,
  }) async {
    final command = Map<String, dynamic>.from(commands.last);
    AppMessage message;
    var outcome = status;
    try {
      if (status == 'notSaved') {
        throw ConfigFailure(messages.overrideChangedReopen);
      }
      message = command['action'] == 'saveOverride'
          ? await actions.execute(command)
          : await LocalCustomActions(actions).execute(command);
      if (status == 'applyFailed') {
        message = messages.overrideSavedReconnectIncomplete;
      }
    } on ConfigFailure catch (error) {
      message = error.message;
      outcome = 'notSaved';
      success = false;
    }
    state = AppSnapshot(
      phase: 'STOPPED',
      storageEpoch: state.storageEpoch,
      resultId: 'local-${commands.length}',
      resultMessage: resultMessage ?? message,
      resultSuccess: success,
      overrideStatus: outcome,
      targetId: outcome == 'notSaved'
          ? null
          : actions.result['targetId'] as String?,
      savedRevision: outcome == 'notSaved'
          ? null
          : actions.result['savedRevision'] as int?,
    );
  }
}

const _custom = OverrideEntry(
  id: 'custom',
  name: 'User-renamed local plugin',
  kind: ConfigKind.local,
  role: OverrideRole.localCustom,
  revision: 3,
  body: '# untouched\nunknown: true\n',
  enabled: false,
  mode: OverrideMode.replace,
);

Finder _field(String id) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is DefinitionTextField && widget.id == id,
  ),
  matching: find.byType(TextField),
);
const _saveKey = ValueKey('definition-save:rule');
const _detailsKey = ValueKey('definition-details:rule');

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late _Overrides store;
  late _Bridge bridge;
  late AppController app;
  late GlobalKey<NavigatorState> navigator;

  setUp(() {
    store = _Overrides();
    bridge = _Bridge(store);
    app = AppController(
      bridge,
      store: _Configs(),
      overrideStore: store,
      preferencesStore: MemoryPreferencesStore(),
    );
    navigator = GlobalKey<NavigatorState>();
  });
  tearDown(() => app.dispose());

  Future<void> host(
    WidgetTester tester, {
    bool definitions = false,
    LocalYamlSection section = LocalYamlSection.rules,
    String? editGroup,
    Set<LocalYamlSection>? sections,
    bool Function()? isContextCurrent,
    String language = 'en',
    double scale = 1,
  }) async {
    await app.refresh();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: language == 'zh' ? ThemeMode.dark : ThemeMode.light,
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: OperationFeedback(
          controller: app,
          child: Builder(
            builder: (context) {
              final epoch = app.storageEpoch;
              return Scaffold(
                body: TextButton(
                  onPressed: () {
                    if (editGroup != null) {
                      showLocalCustomGroupEditor(
                        context,
                        app: app,
                        storageEpoch: epoch,
                        name: editGroup,
                      );
                    } else if (definitions) {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text('Category')),
                            body: LocalDefinitions(
                              app: app,
                              sections:
                                  sections ?? LocalYamlSection.values.toSet(),
                              builder: (context, rows) => ReadingList(
                                identity: app.storageEpoch,
                                header: const SizedBox.shrink(),
                                items: rows,
                              ),
                            ),
                          ),
                        ),
                      );
                    } else {
                      showLocalCustomForm(
                        context,
                        app: app,
                        section: section,
                        storageEpoch: epoch,
                        targets: const ['DIRECT', 'REJECT'],
                        initialValue: 'example.test',
                        initialTarget: 'DIRECT',
                        isContextCurrent: isContextCurrent,
                      );
                    }
                  },
                  child: const Text('Open'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await settleLocalDefinitions(tester);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(_saveKey));
    await tester.pump();
  }

  Future<void> finish(
    WidgetTester tester, {
    String status = 'saved',
    bool success = true,
  }) async {
    await bridge.finish(status: status, success: success);
    await app.refresh();
    await settleLocalDefinitions(tester);
  }

  Future<void> confirmDelete(WidgetTester tester) async {
    await settleLocalDefinitions(tester);
    expect(find.text(en.localCustomDeleteConfirm), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, en.delete));
    await settleLocalDefinitions(tester);
  }

  Future<void> groupType(WidgetTester tester, String type) async {
    final menu = find.byKey(const ValueKey('definition-menu:group/type'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await settleLocalDefinitions(tester);
    await tester.tap(
      find.byWidgetPredicate(
        (widget) => widget is MenuItemButton && widget.key == ValueKey(type),
      ),
    );
    await settleLocalDefinitions(tester);
  }

  Future<void> groupSave(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('definition-save:group')));
    await tester.pump();
    await finish(tester);
    expect(find.byType(StrategyGroupFormPage), findsNothing);
  }

  for (final type in ['select', 'url-test', 'fallback', 'load-balance']) {
    testWidgets(
      '$type creates, leaves, reopens, changes and reopens saved GUI',
      (tester) async {
        store.entries = [_custom];
        await host(tester, section: LocalYamlSection.strategyGroups);
        await tester.ensureVisible(_field('group/name'));
        await tester.enterText(_field('group/name'), 'created-$type');
        await groupType(tester, type);
        await groupSave(tester);
        final created = store.entries.single;
        expect(created.id, _custom.id);
        expect(created.enabled, isFalse);
        expect(created.mode, OverrideMode.replace);
        expect(created.revision, _custom.revision + 1);
        expect(created.body, startsWith('# untouched\n'));
        expect(created.body, endsWith('unknown: true\n'));
        expect(bridge.commands.single['action'], 'saveLocalDefinition');
        expect(bridge.commands.single['replacement'], isNull);

        await host(tester, editGroup: 'created-$type');
        expect(
          tester
              .widget<StrategyGroupFormPage>(find.byType(StrategyGroupFormPage))
              .initialDefinition,
          {'type': type, 'name': 'created-$type'},
        );
        await tester.ensureVisible(_field('group/name'));
        await tester.enterText(_field('group/name'), 'renamed-$type');
        final next = type == 'fallback' ? 'url-test' : 'fallback';
        await groupType(tester, next);
        await groupSave(tester);
        expect(bridge.commands.last['id'], created.id);
        expect(bridge.commands.last['revision'], created.revision);
        expect(bridge.commands.last['replacement'], {
          'path': ['proxy-groups', 0],
          'value': 'created-$type',
          'inPlace': true,
        });
        final changed = store.entries.single;
        expect(changed.enabled, isFalse);
        expect(changed.mode, OverrideMode.replace);
        expect(changed.revision, created.revision + 1);
        final editor = LocalYamlEdit(changed.body);
        final groups = editor.definitions(LocalYamlSection.strategyGroups);
        expect(groups, hasLength(1));
        expect(editor.definitionValue(groups.single), {
          'type': next,
          'name': 'renamed-$type',
        });
        await host(tester, editGroup: 'renamed-$type');
        expect(
          tester
              .widget<StrategyGroupFormPage>(find.byType(StrategyGroupFormPage))
              .initialDefinition,
          {'type': next, 'name': 'renamed-$type'},
        );
        await tester.tap(find.byType(BackButton));
        await settleLocalDefinitions(tester);
        expect(bridge.commands, hasLength(2));
        expect(app.state.phase, 'STOPPED');
      },
    );
  }

  testWidgets(
    'local group editing preserves untouched bytes and inline comments',
    (tester) async {
      final body =
          '\u{feff}${'''# document header
proxy-groups:
  - {name: before, type: select, proxies: [DIRECT]} # before inline
  # target comment
  - name: target # name note
    type: url-test # type note
    proxies: [DIRECT] # members note
    tolerance: 27 # old-only
    url: "" # explicit empty
    interval: 0 # explicit zero
    lazy: false # explicit false
    use: null # explicit null
    unknown: # retain nested formatting and text
      value: '原文🧭' # nested note
      list: [false, 0, "", null]
  - {name: after, type: fallback, proxies: [DIRECT]} # after inline
rules: [MATCH,DIRECT] # unrelated
'''.replaceAll('\n', '\r\n')}';
      store.entries = [_custom.withContent(body)];
      await host(tester, editGroup: 'target');
      await tester.ensureVisible(_field('group/name'));
      await tester.enterText(_field('group/name'), 'renamed');
      await groupSave(tester);
      final renamed = body.replaceFirst('name: target', 'name: renamed');
      expect(store.entries.single.body, renamed);

      await host(tester, editGroup: 'renamed');
      await groupType(tester, 'fallback');
      await groupSave(tester);
      final changed = renamed
          .replaceFirst('type: url-test', 'type: fallback')
          .replaceFirst('    tolerance: 27 # old-only\r\n', '');
      expect(store.entries.single.body, changed);
      await host(tester, editGroup: 'renamed');
      final form = tester.widget<StrategyGroupFormPage>(
        find.byType(StrategyGroupFormPage),
      );
      expect(form.initialDefinition!['type'], 'fallback');
      expect(form.initialDefinition!.containsKey('tolerance'), isFalse);
      expect(form.initialDefinition!.containsKey('use'), isTrue);
      expect(form.initialDefinition!['use'], isNull);
      final revision = store.entries.single.revision;
      await groupSave(tester);
      expect(store.entries.single.body, changed);
      expect(store.entries.single.revision, revision);
      expect(store.entries.single.enabled, isFalse);
      expect(store.entries.single.mode, OverrideMode.replace);
    },
  );

  testWidgets(
    'first GUI save creates the unique role without selecting or starting a config',
    (tester) async {
      await host(tester);
      await save(tester);
      expect(bridge.commands.single['action'], 'saveLocalDefinition');
      expect(bridge.commands.single['id'], isNull);
      expect(bridge.commands.single['storageEpoch'], 0);
      await finish(tester);
      expect(store.entries.single.role, OverrideRole.localCustom);
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules)
            .single
            .value,
        'DOMAIN,example.test,DIRECT',
      );
      expect(bridge.platform.events, isEmpty);
      expect(find.byType(RuleFormPage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'partial save adopts identity and same draft retries exact saved body once',
    (tester) async {
      await host(tester);
      await save(tester);
      await finish(tester, status: 'applyFailed', success: false);
      final saved = store.entries.single;
      expect(find.byType(RuleFormPage), findsOneWidget);
      expect(app.hasLocalFeedbackOwner, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(_detailsKey));
      await settleLocalDefinitions(tester);
      expect(find.text(en.overrideSavedReconnectIncomplete), findsOneWidget);
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsNothing);
      await save(tester);
      expect(bridge.commands.last['action'], 'saveOverride');
      expect(bridge.commands.last['id'], saved.id);
      expect(bridge.commands.last['revision'], saved.revision);
      expect(bridge.commands.last['body'], saved.body);
      await finish(tester);
      expect(store.entries.single.revision, saved.revision);
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules),
        hasLength(1),
      );
      expect(find.byType(RuleFormPage), findsNothing);
    },
  );

  testWidgets(
    'editing the partially saved draft replaces only its original direct definition',
    (tester) async {
      store.entries = [_custom];
      await host(tester);
      expect(find.text(en.localCustomDisabled), findsOneWidget);
      await save(tester);
      await finish(tester, status: 'applyFailed', success: false);
      final saved = store.entries.single;
      await tester.ensureVisible(_field('rule/value'));
      await tester.enterText(_field('rule/value'), 'changed.test');
      await settleLocalDefinitions(tester);
      await save(tester);
      expect(bridge.commands.last['action'], 'saveLocalDefinition');
      expect(bridge.commands.last['id'], saved.id);
      expect(bridge.commands.last['revision'], saved.revision);
      expect(bridge.commands.last['replacement'], {
        'path': ['rules', 0],
        'value': 'DOMAIN,example.test,DIRECT',
      });
      await finish(tester);
      expect(store.entries.single.enabled, isFalse);
      expect(store.entries.single.mode, OverrideMode.replace);
      expect(store.entries.single.name, _custom.name);
      expect(store.entries.single.body, contains('unknown: true\n'));
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules)
            .single
            .value,
        'DOMAIN,changed.test,DIRECT',
      );
    },
  );

  testWidgets(
    'concurrent text or role replacement rejects the old form and keeps its input',
    (tester) async {
      store.entries = [_custom];
      await host(tester);
      store.entries = [_custom.withContent('rules: [MATCH,DIRECT]\n')];
      await app.refresh();
      await save(tester);
      await settleLocalDefinitions(tester);
      expect(bridge.commands, isEmpty);
      expect(find.byType(RuleFormPage), findsOneWidget);
      expect(
        tester.widget<TextField>(_field('rule/value')).controller!.text,
        'example.test',
      );
      await tester.tap(find.byKey(_detailsKey));
      await settleLocalDefinitions(tester);
      expect(find.text(en.overrideChangedReopen), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets(
    'timeout never re-adds and releases unknown late feedback to the global reader',
    (tester) async {
      await host(tester);
      await save(tester);
      await tester.pump(const Duration(seconds: 126));
      await settleLocalDefinitions(tester);
      expect(app.hasLocalFeedbackOwner, isFalse);
      await save(tester);
      await settleLocalDefinitions(tester);
      expect(bridge.commands, hasLength(1));
      expect(find.byType(RuleFormPage), findsOneWidget);
      await finish(tester, status: 'notSaved', success: false);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(en.overrideChangedReopen), findsOneWidget);
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'departure during save returns a late failure globally without popping another route',
    (tester) async {
      await host(tester);
      await save(tester);
      final route = ModalRoute.of(tester.element(find.byType(RuleFormPage)))!;
      navigator.currentState!.removeRoute(route);
      await settleLocalDefinitions(tester);
      expect(app.hasLocalFeedbackOwner, isFalse);
      await finish(tester, status: 'applyFailed', success: false);
      expect(find.byType(RuleFormPage), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(en.overrideSavedReconnectIncomplete), findsOneWidget);
    },
  );

  testWidgets(
    'own successful apply may expire the source context without losing its real result',
    (tester) async {
      var current = true;
      await host(tester, isContextCurrent: () => current);
      await save(tester);
      current = false;
      await finish(tester);
      expect(store.entries, hasLength(1));
      expect(find.byType(RuleFormPage), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'saved deletion preserves its real result if rereading the body fails',
    (tester) async {
      store.entries = [
        _custom.withContent(
          'rules: ["DOMAIN,first.test,DIRECT", "MATCH,DIRECT"]\n',
        ),
      ];
      await host(tester, definitions: true, sections: {LocalYamlSection.rules});
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await confirmDelete(tester);
      await bridge.finish();
      store.unreadable = true;
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining(en.overrideSavedApplyLater), findsOneWidget);
      expect(
        find.textContaining(messages.temporaryOverridesUnreadable.resolve(en)),
        findsOneWidget,
      );
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      store.unreadable = false;
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.delete_outline).first,
            )
            .onPressed,
        isNull,
      );
      expect(bridge.commands, hasLength(1));
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules)
            .single
            .value,
        'MATCH,DIRECT',
      );
      await tester.tap(find.byTooltip(en.viewConfigError));
      await settleLocalDefinitions(tester);
      expect(find.textContaining(en.overrideSavedApplyLater), findsOneWidget);
      expect(
        find.textContaining(messages.temporaryOverridesUnreadable.resolve(en)),
        findsOneWidget,
      );
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      await tester.pageBack();
      await settleLocalDefinitions(tester);
      await host(tester, definitions: true, sections: {LocalYamlSection.rules});
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.delete_outline).first,
            )
            .onPressed,
        isNotNull,
      );
      expect(bridge.commands, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final outcome in [
    (status: 'saved', success: true, message: messages.overrideSavedApplyLater),
    (
      status: 'applyFailed',
      success: false,
      message: messages.overrideSavedReconnectIncomplete,
    ),
    (
      status: 'saved',
      success: false,
      message: messages.storageSyncWarning(messages.overrideSavedApplyLater),
    ),
  ]) {
    for (final language in ['en', 'zh']) {
      testWidgets(
        'saved result survives unreadable body and blocked retry ${outcome.message.id} $language',
        (tester) async {
          tester.view.physicalSize = const Size(320, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await host(tester, language: language, scale: 2);
          final strings = lookupAppLocalizations(Locale(language));
          await tester.ensureVisible(_field('rule/target'));
          await settleLocalDefinitions(tester);
          final targetRect = tester.getRect(_field('rule/target'));
          final saveRect = tester.getRect(find.byKey(_saveKey));
          await save(tester);
          await bridge.finish(
            status: outcome.status,
            success: outcome.success,
            resultMessage: outcome.message,
          );
          final saved = store.entries.single;
          store.unreadable = true;
          await app.refresh();
          for (final milliseconds in [0, 16, 100]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(tester.getRect(_field('rule/target')), targetRect);
            expect(tester.getRect(find.byKey(_saveKey)), saveRect);
          }
          expect(find.byType(RuleFormPage), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(app.hasLocalFeedbackOwner, isFalse);
          await tester.tap(find.byKey(_detailsKey));
          await settleLocalDefinitions(tester);
          expect(
            find.textContaining(outcome.message.resolve(strings)),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              messages.temporaryOverridesUnreadable.resolve(strings),
            ),
            findsOneWidget,
          );
          expect(
            find.text(
              messages
                  .localCustomSavedVerificationFailed(
                    result: outcome.message,
                    reason: messages.temporaryOverridesUnreadable,
                  )
                  .resolve(strings),
            ),
            findsOneWidget,
          );
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.tap(find.text(strings.close));
          await settleLocalDefinitions(tester);
          store.unreadable = false;
          await app.refresh();
          await settleLocalDefinitions(tester);
          expect(find.byType(AlertDialog), findsNothing);
          await tester.ensureVisible(_field('rule/value'));
          await tester.enterText(_field('rule/value'), 'not-resubmitted.test');
          await settleLocalDefinitions(tester);
          await save(tester);
          await settleLocalDefinitions(tester);
          expect(bridge.commands, hasLength(1));
          expect(store.entries.single.id, saved.id);
          expect(store.entries.single.revision, saved.revision);
          expect(
            LocalYamlEdit(store.entries.single.body)
                .definitions(LocalYamlSection.rules)
                .single
                .value,
            'DOMAIN,example.test,DIRECT',
          );
          expect(
            tester.widget<TextField>(_field('rule/value')).controller!.text,
            'not-resubmitted.test',
          );
          await tester.tap(find.byKey(_detailsKey));
          await settleLocalDefinitions(tester);
          expect(
            find.textContaining(outcome.message.resolve(strings)),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              messages.overrideChangedReopen.resolve(strings),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'local list excludes same-name ordinary definitions and provider-expanded members',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.entries = [
        OverrideEntry.fromJson({
          ..._custom.toJson(),
          'id': 'ordinary',
          'role': null,
          'body': 'proxies: [{name: not-local, type: direct}]\n',
        }),
        _custom.withContent('''proxies: [{name: own, type: direct}]
proxy-groups: [{name: group, type: select, proxies: [DIRECT]}]
proxy-providers: {feed: {type: inline, payload: [{name: downloaded, type: direct}]}}
rule-providers: {set: {type: inline, payload: [DOMAIN,feed.test]}}
rules: ["MATCH,DIRECT"]
'''),
      ];
      await host(tester, definitions: true);
      expect(find.text('own'), findsOneWidget);
      expect(find.text('group'), findsOneWidget);
      expect(find.text('feed'), findsOneWidget);
      expect(find.text('set'), findsOneWidget);
      expect(find.text('MATCH,DIRECT'), findsOneWidget);
      expect(find.text('not-local'), findsNothing);
      expect(find.text('downloaded'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(5));
      expect(find.text(en.localCustomDisabled), findsOneWidget);
    },
  );

  testWidgets(
    'duplicate rule deletion uses the original path and partial apply retry does not delete again',
    (tester) async {
      store.entries = [
        _custom.withContent('''rules:
  - DOMAIN,same.test,DIRECT
  - DOMAIN,same.test,DIRECT
  - MATCH,DIRECT
'''),
      ];
      await host(tester, definitions: true, sections: {LocalYamlSection.rules});
      await tester.tap(find.byIcon(Icons.delete_outline).at(1));
      await confirmDelete(tester);
      expect(bridge.commands.single['path'], ['rules', 1]);
      expect(bridge.commands.single['revision'], store.entries.single.revision);
      await finish(tester, status: 'applyFailed', success: false);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      expect(find.text('DOMAIN,same.test,DIRECT'), findsOneWidget);
      final saved = store.entries.single;
      await tester.tap(find.byTooltip(en.retry));
      await tester.pump();
      expect(bridge.commands.last['action'], 'saveOverride');
      expect(bridge.commands.last['body'], saved.body);
      expect(bridge.commands.last['revision'], saved.revision);
      await finish(tester);
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules),
        hasLength(2),
      );
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'a restored epoch retires uncertain deletion but only newly rendered rows can write',
    (tester) async {
      store.entries = [
        _custom.withContent(
          'rules: ["DOMAIN,old.test,DIRECT", "MATCH,DIRECT"]\n',
        ),
      ];
      await host(tester, definitions: true, sections: {LocalYamlSection.rules});
      final old = tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.delete_outline).first,
              matching: find.byType(IconButton),
            ),
          )
          .onPressed!;
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await confirmDelete(tester);
      await bridge.finish();
      store.unreadable = true;
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      store.unreadable = false;
      await app.refresh();
      await settleLocalDefinitions(tester);
      final delete = find.ancestor(
        of: find.byIcon(Icons.delete_outline).first,
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(delete).onPressed, isNull);
      final saved = store.entries.single;
      store.entries = [
        OverrideEntry.fromJson({
          ...saved.toJson(),
          'body': 'rules: ["DOMAIN,restored.test,DIRECT", "MATCH,DIRECT"]\n',
        }),
      ];
      bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.text('DOMAIN,restored.test,DIRECT'), findsOneWidget);
      expect(tester.widget<IconButton>(delete).onPressed, isNotNull);
      old();
      await settleLocalDefinitions(tester);
      expect(bridge.commands, hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await confirmDelete(tester);
      expect(bridge.commands.last['storageEpoch'], 1);
      expect(bridge.commands.last['revision'], saved.revision);
      await finish(tester);
      expect(bridge.commands, hasLength(2));
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules)
            .single
            .value,
        'MATCH,DIRECT',
      );
      expect(store.entries.single.enabled, isFalse);
    },
  );

  testWidgets(
    'old list delete callback cannot retarget a duplicate after another deletion',
    (tester) async {
      store.entries = [
        _custom.withContent('''rules:
  - DOMAIN,same.test,DIRECT
  - DOMAIN,same.test,DIRECT
  - DOMAIN,same.test,DIRECT
  - MATCH,DIRECT
'''),
      ];
      await host(tester, definitions: true, sections: {LocalYamlSection.rules});
      final old = tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.delete_outline).at(1),
          )
          .onPressed!;
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await confirmDelete(tester);
      await finish(tester);
      old();
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.commands, hasLength(1));
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules),
        hasLength(3),
      );
    },
  );

  testWidgets('a mismatched saved target cannot retarget the existing draft', (
    tester,
  ) async {
    store.entries = [_custom];
    await host(tester);
    await save(tester);
    await bridge.finish(status: 'applyFailed', success: false);
    final saved = store.entries.single;
    store.entries = [
      OverrideEntry.fromJson({...saved.toJson(), 'id': 'other-role'}),
    ];
    bridge.state = AppSnapshot(
      phase: 'STOPPED',
      resultId: 'local-1',
      resultSuccess: false,
      overrideStatus: 'applyFailed',
      targetId: 'other-role',
      savedRevision: saved.revision,
      resultMessage: messages.overrideSavedReconnectIncomplete,
    );
    await app.refresh();
    await settleLocalDefinitions(tester);
    await save(tester);
    await settleLocalDefinitions(tester);
    expect(bridge.commands, hasLength(1));
    expect(store.entries.single.id, 'other-role');
    expect(find.byType(RuleFormPage), findsOneWidget);
  });

  testWidgets(
    'empty native rule is visibly identified and deletes only its original value',
    (tester) async {
      store.entries = [_custom.withContent('rules: ["", "MATCH,DIRECT"]\n')];
      await host(tester, definitions: true, sections: {LocalYamlSection.rules});
      expect(find.text('""'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await settleLocalDefinitions(tester);
      expect(find.widgetWithText(SelectableText, '""'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, en.delete));
      await settleLocalDefinitions(tester);
      expect(bridge.commands.single['path'], ['rules', 0]);
      expect(bridge.commands.single['value'], '');
      await finish(tester);
      expect(
        LocalYamlEdit(store.entries.single.body)
            .definitions(LocalYamlSection.rules)
            .single
            .value,
        'MATCH,DIRECT',
      );
    },
  );

  testWidgets(
    'covered form releases the result without claiming a later local ack',
    (tester) async {
      await host(tester);
      await save(tester);
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('Cover route')),
        ),
      );
      await settleLocalDefinitions(tester);
      expect(app.hasLocalFeedbackOwner, isFalse);
      await finish(tester, status: 'applyFailed', success: false);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(en.overrideSavedReconnectIncomplete), findsOneWidget);
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      expect(find.text('Cover route'), findsOneWidget);
      navigator.currentState!.pop();
      await settleLocalDefinitions(tester);
      expect(find.byType(RuleFormPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await save(tester);
      expect(bridge.commands.last['action'], 'saveOverride');
      await finish(tester);
      expect(store.entries, hasLength(1));
    },
  );

  testWidgets(
    'background releases the reader and resume presents the late failure once',
    (tester) async {
      await host(tester);
      await save(tester);
      app.setForeground(false);
      expect(app.hasLocalFeedbackOwner, isFalse);
      await bridge.finish(status: 'notSaved', success: false);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      app.setForeground(true);
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(en.overrideChangedReopen), findsOneWidget);
      await tester.tap(find.text(en.close));
      await settleLocalDefinitions(tester);
      await app.refresh();
      await settleLocalDefinitions(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(RuleFormPage), findsOneWidget);
      expect(bridge.commands, hasLength(1));
    },
  );

  for (final language in ['en', 'zh']) {
    testWidgets(
      'waiting partial-save and retry frames keep draft anchors $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        store.entries = [_custom];
        await host(tester, language: language, scale: 2);
        await tester.ensureVisible(_field('rule/target'));
        await settleLocalDefinitions(tester);
        final target = tester.getRect(_field('rule/target'));
        final saveRect = tester.getRect(find.byKey(_saveKey));
        Future<void> frames() async {
          for (final milliseconds in [0, 16, 100]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(tester.getRect(_field('rule/target')), target);
            expect(tester.getRect(find.byKey(_saveKey)), saveRect);
            expect(tester.takeException(), isNull);
          }
        }

        await save(tester);
        await frames();
        await bridge.finish(status: 'applyFailed', success: false);
        await app.refresh();
        await frames();
        expect(find.byType(AlertDialog), findsNothing);
        await save(tester);
        expect(bridge.commands.last['action'], 'saveOverride');
        await frames();
        await finish(tester);
        expect(find.byType(RuleFormPage), findsNothing);
        expect(store.entries.single.enabled, isFalse);
      },
    );

    testWidgets(
      'local delete waiting rejection and retry keep list anchors $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        store.entries = [_custom.withContent('rules: ["MATCH,DIRECT"]\n')];
        await host(
          tester,
          definitions: true,
          sections: {LocalYamlSection.rules},
          language: language,
          scale: 2,
        );
        final strings = lookupAppLocalizations(Locale(language));
        final row = find.widgetWithText(ListTile, 'MATCH,DIRECT');
        await tester.scrollUntilVisible(
          row,
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(row);
        await settleLocalDefinitions(tester);
        final rowRect = tester.getRect(row);
        final header = find.byKey(const ValueKey('local-definitions-header'));
        final readerRect = tester.getRect(header);
        Future<void> frames() async {
          for (final milliseconds in [0, 16, 100]) {
            await tester.pump(Duration(milliseconds: milliseconds));
            expect(tester.getRect(row), rowRect);
            expect(tester.getRect(header), readerRect);
            expect(tester.takeException(), isNull);
          }
        }

        await tester.tap(find.byIcon(Icons.delete_outline));
        await settleLocalDefinitions(tester);
        await tester.tap(find.widgetWithText(TextButton, strings.delete));
        await settleLocalDefinitions(tester);
        await frames();
        await bridge.finish(status: 'notSaved', success: false);
        await app.refresh();
        await frames();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text(strings.close));
        await settleLocalDefinitions(tester);
        await frames();
        expect(store.entries.single.revision, _custom.revision + 1);
        await tester.tap(find.byIcon(Icons.delete_outline));
        await settleLocalDefinitions(tester);
        await tester.tap(find.widgetWithText(TextButton, strings.delete));
        await settleLocalDefinitions(tester);
        await frames();
        expect(bridge.commands, hasLength(2));
        await finish(tester);
        expect(
          LocalYamlEdit(store.entries.single.body)
              .definitions(LocalYamlSection.rules),
          isEmpty,
        );
      },
    );

    testWidgets('restoration keeps draft anchors at narrow 2x text $language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.entries = [_custom];
      await host(tester, language: language, scale: 2);
      await tester.ensureVisible(_field('rule/target'));
      await settleLocalDefinitions(tester);
      final target = tester.getRect(_field('rule/target'));
      final saveRect = tester.getRect(find.byKey(_saveKey));
      bridge.state = const AppSnapshot(phase: 'STOPPED', storageEpoch: 1);
      await app.refresh();
      for (final milliseconds in [0, 16, 100]) {
        await tester.pump(Duration(milliseconds: milliseconds));
        expect(tester.getRect(_field('rule/target')), target);
        expect(tester.getRect(find.byKey(_saveKey)), saveRect);
        expect(tester.takeException(), isNull);
      }
      await save(tester);
      await settleLocalDefinitions(tester);
      expect(bridge.commands, isEmpty);
      expect(find.byType(RuleFormPage), findsOneWidget);
      expect(tester.getRect(find.byKey(_saveKey)), saveRect);
    });
  }
}
