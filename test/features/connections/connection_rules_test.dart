import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:clash_pseudo/src/app/app_controller.dart';
import 'package:clash_pseudo/src/app/app_theme.dart';
import 'package:clash_pseudo/src/app/widgets/operation_feedback.dart';
import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/configs/config_store.dart';
import 'package:clash_pseudo/src/features/connections/connection_controller.dart';
import 'package:clash_pseudo/src/features/connections/connection_snapshot.dart';
import 'package:clash_pseudo/src/features/connections/connections_page.dart';
import 'package:clash_pseudo/src/features/overrides/definition_form_fields.dart';
import 'package:clash_pseudo/src/features/overrides/local_custom_actions.dart';
import 'package:clash_pseudo/src/features/overrides/local_yaml_edit.dart';
import 'package:clash_pseudo/src/features/overrides/override_actions.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';
import 'package:clash_pseudo/src/features/overrides/rule_form.dart';
import 'package:clash_pseudo/src/features/strategies/strategy_snapshot.dart';
import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/operation_admission.dart';
import 'package:clash_pseudo/src/platform/app_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../configs/action_fakes.dart';
import '../settings/preferences_fakes.dart';

const _id = '00000000-0000-4000-8000-000000000001';
const _otherId = '00000000-0000-4000-8000-000000000002';
const _core = CoreSnapshot(
  generation: 7,
  phase: 'READY',
  purpose: 'VPN',
  configId: 'one',
  revision: 1,
  composition: 'controlled-composition',
);

Map<String, dynamic> _suggestions({
  String id = _id,
  String? host = 'a.private.github.io',
  String? boundary = 'private.github.io',
  String? ip = '192.0.2.1/32',
}) => {
  'connectionId': id,
  'host': host,
  'suffixBoundary': boundary,
  'ipCidr': ip,
};

Map<String, dynamic> _row({
  String id = _id,
  bool active = true,
  String displayHost = 'display-is-not-authoritative.example',
}) => {
  'id': id,
  'start': '2026-10-19T10:00:00Z',
  'active': active,
  'upload': 12,
  'download': 34,
  'chains': ['DIRECT'],
  'rule': 'Match',
  'fieldsTruncated': true,
  'metadata': {
    'host': displayHost,
    'destinationIP': '198.18.0.99',
    'destinationPort': '443',
    'sourceIP': '192.0.2.2',
    'sourcePort': '1234',
    'network': 'tcp',
    'type': 'Tun',
  },
};

Map<String, dynamic> _sample({
  CoreSnapshot source = _core,
  Object? suggestions,
  bool active = true,
  String id = _id,
  int session = 1,
  int age = 0,
}) => {
  'generation': source.generation,
  'composition': source.composition,
  'configId': source.configId,
  'revision': source.revision,
  'purpose': source.purpose,
  'phase': 'RUNNING',
  'sessionGeneration': session,
  'fresh': true,
  'sampleAgeMs': age,
  'connections': [
    {..._row(id: id, active: active), 'ruleSuggestions': suggestions},
  ],
};

StrategySnapshot _targets(CoreSnapshot core) => StrategySnapshot(
  generation: core.generation,
  configId: core.configId!,
  revision: core.revision!,
  purpose: core.purpose!,
  composition: core.composition,
  globalReferenced: false,
  groups: [
    for (final entry in [
      ('Hidden group', true),
      ('GLOBAL', false),
      ('Visible group', false),
    ])
      StrategyGroup(
        name: entry.$1,
        rawType: 'Selector',
        hidden: entry.$2,
        now: 'DIRECT',
        fixed: '',
        members: const [],
        icon: '',
      ),
  ],
  unrestored: const {},
);

class _RuleBridge extends AppBridge {
  CoreSnapshot source = _core;
  int session = 1;
  String trackerId = _id;
  int reads = 0;
  int targetReads = 0;
  int submits = 0;
  int age = 0;
  bool sampleFails = false;
  bool targetFails = false;
  bool trackerActive = true;
  Map<String, dynamic>? suggestions = _suggestions();
  StrategySnapshot? targetValue;
  Completer<StrategySnapshot>? targetPending;
  Completer<ConnectionSnapshot>? samplePending;
  final detailRequests = <Map<String, Object?>?>[];

  @override
  Future<ConnectionSnapshot> recentConnections({Map<String, Object?>? detail}) {
    reads++;
    detailRequests.add(detail);
    if (sampleFails) return Future.error(StateError('controlled read failure'));
    return samplePending?.future ??
        Future.value(
          ConnectionSnapshot.fromMap(
            _sample(
              source: source,
              session: session,
              id: trackerId,
              active: trackerActive,
              age: age,
              suggestions: suggestions,
            ),
          ),
        );
  }

  @override
  Future<StrategySnapshot> strategies(int generation) {
    targetReads++;
    if (targetFails) {
      return Future.error(StateError('controlled target failure'));
    }
    return targetPending?.future ??
        Future.value(targetValue ?? _targets(source));
  }

  @override
  Future<void> releaseConnectionDetail() async {}

  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    submits++;
    return OperationAdmission(
      operationId: 'unexpected-$submits',
      remaining: const Duration(seconds: 120),
    );
  }
}

class _RuleApp extends AppController {
  _RuleApp(super.platform) {
    loading = false;
    configsLoaded = true;
    overridesLoaded = true;
    state = const AppSnapshot(phase: 'RUNNING', generation: 1, core: _core);
  }
  @override
  Future<void> refresh() async {}
  void publish({
    CoreSnapshot source = _core,
    int epoch = 0,
    String phase = 'RUNNING',
    int session = 1,
  }) {
    state = AppSnapshot(
      phase: phase,
      generation: session,
      core: source,
      storageEpoch: epoch,
    );
    notifyListeners();
  }
}

class _Clock implements Stopwatch {
  @override
  int elapsedMilliseconds = 0;
  @override
  void start() {}
  @override
  void stop() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Configs extends ConfigStore {
  _Configs() : super(Directory.systemTemp);
  static const main = ConfigEntry(
    id: 'one',
    name: 'Controlled main',
    kind: ConfigKind.local,
    revision: 1,
    body: 'proxy-groups:\n  - {name: Hidden group, type: select, hidden: true, proxies: [DIRECT]}\nrules: [MATCH,DIRECT]\n',
  );
  @override
  Future<ConfigCollection> read() async =>
      ConfigCollection(entries: const [main], selectedId: main.id);
}

class _Overrides extends OverrideStore {
  _Overrides(super.directory);
  List<OverrideEntry> entries = [];
  @override
  Future<List<OverrideEntry>> read() async => List.unmodifiable(entries);
  @override
  Future<void> save(List<OverrideEntry> entries) async =>
      this.entries = List.unmodifiable(entries);
}

/// Uses the real local YAML writer and AppController feedback owner. Only the
/// native observations, command receipt timing and VPN boundary are controlled.
class _BusinessBridge extends _RuleBridge {
  _BusinessBridge(this.store, File input) {
    native.input = input;
    native.load(_Configs.main);
    nativeState = native.state;
    source = nativeState.core;
    session = nativeState.generation;
    actions = OverrideActions(store, DownloadFake(), native, runInput: input);
  }
  final _Overrides store;
  final native = PlatformFake();
  late final OverrideActions actions;
  late AppSnapshot nativeState;
  final commands = <Map<String, Object?>>[];

  @override
  Future<AppSnapshot> snapshot() async => nativeState;
  @override
  Future<OperationAdmission?> submit(Map<String, Object?> command) async {
    commands.add(Map.of(command));
    return OperationAdmission(
      operationId: 'rule-${commands.length}',
      remaining: const Duration(seconds: 120),
    );
  }

  Future<void> finish() async {
    final command = Map<String, dynamic>.from(commands.last);
    final message = command['action'] == 'saveOverride'
        ? await actions.execute(command)
        : await LocalCustomActions(actions).execute(command);
    final state = native.state;
    final result = actions.result;
    nativeState = AppSnapshot(
      phase: state.phase,
      generation: state.generation,
      core: state.core,
      configId: state.configId,
      revision: state.revision,
      mode: state.mode,
      resultId: 'rule-${commands.length}',
      resultMessage: message,
      resultSuccess: result['overrideStatus'] != 'applyFailed',
      overrideStatus: result['overrideStatus'] as String?,
      targetId: result['targetId'] as String?,
      savedRevision: result['savedRevision'] as int?,
    );
    if (state.core.ready) source = state.core;
    session = state.generation;
    if (session > 1) trackerId = _otherId;
    suggestions = null;
  }
}

Finder _field(String id) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is DefinitionTextField && widget.id == id,
  ),
  matching: find.byType(TextField),
);

Future<void> _host(
  WidgetTester tester,
  AppController app, {
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
      home: OperationFeedback(
        controller: app,
        child: ConnectionsPage(app: app),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('display-is-not-authoritative.example'));
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

Future<void> _tapRule(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('connection-add-rule'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

Future<void> _chooseTarget(WidgetTester tester, String target) async {
  final menu = find.byKey(const ValueKey('definition-suggestions:rule/target'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(target).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    for (final entry in const {
      'Roboto': String.fromEnvironment('D7_TEST_FONT'),
      'Ahem': String.fromEnvironment('D7_TEST_FONT'),
      'MaterialIcons': String.fromEnvironment('D7_ICON_FONT'),
    }.entries) {
      if (entry.value.isEmpty) continue;
      final loader = FontLoader(entry.key)
        ..addFont(
          Future.value(
            ByteData.sublistView(await File(entry.value).readAsBytes()),
          ),
        );
      await loader.load();
    }
  });

  test('compact boundary expands every suffix and serialization preserves the observed source', () {
    final host = List.filled(127, 'a').join('.');
    expect(host.length, 253);
    final record = ConnectionSnapshot.fromMap(
      _sample(
        suggestions: _suggestions(host: host, boundary: 'a.a', ip: null),
      ),
    ).records.single;
    final rules = record.ruleMetadata!;
    expect(rules.host, host);
    expect(rules.suffixes, hasLength(126));
    expect(rules.suffixes.first, host);
    expect(rules.suffixes[1], host.substring(2));
    expect(rules.suffixes.last, 'a.a');
    expect(rules.candidates, hasLength(127));
    const replacement = CoreSnapshot(
      generation: 8,
      phase: 'READY',
      purpose: 'VPN',
      configId: 'one',
      revision: 1,
      composition: 'replacement',
    );
    final restored = ConnectionSnapshot.fromMap({
      ..._sample(source: replacement),
      'connections': [record.observed(active: false).toMap()],
    }).records.single;
    expect(restored.active, isFalse);
    expect(restored.ruleMetadata!.source.identity, _core.identity);
    expect(restored.ruleMetadata!.candidates, rules.candidates);
    expect(restored.ruleMetadata!.matches(replacement), isFalse);
  });

  test('trusted helper controls candidates, never cropped display host or displayed IP', () {
    final result = ConnectionSnapshot.fromMap(
      _sample(suggestions: _suggestions()),
    );
    expect(result.records.single.host, 'display-is-not-authoritative.example');
    expect(result.records.single.destinationIP, '198.18.0.99');
    expect(result.records.single.ruleMetadata!.candidates, [
      (type: 'DOMAIN', value: 'a.private.github.io'),
      (type: 'DOMAIN-SUFFIX', value: 'a.private.github.io'),
      (type: 'DOMAIN-SUFFIX', value: 'private.github.io'),
      (type: 'IP-CIDR', value: '192.0.2.1/32'),
    ]);
    expect(result.records.single.ruleMetadata!.matches(_core), isTrue);
    expect(
      ConnectionSnapshot.fromMap(_sample()).records.single.ruleMetadata,
      isNull,
    );
  });

  test('exact-only internal/public suffix names and IP-only results are not invented', () {
    for (final host in ['localhost', 'co.uk']) {
      final value = ConnectionRuleSuggestions.fromValue(
        _suggestions(host: host, boundary: null, ip: null),
        _core,
      )!;
      expect(value.candidates, [(type: 'DOMAIN', value: host)]);
    }
    for (final ip in ['192.0.2.1/32', '2001:db8::1/128']) {
      final value = ConnectionRuleSuggestions.fromValue(
        _suggestions(host: null, boundary: null, ip: ip),
        _core,
      )!;
      expect(value.host, isNull);
      expect(value.candidates.single.value, ip);
      expect(
        value.candidates.single.type,
        ip.contains(':') ? 'IP-CIDR6' : 'IP-CIDR',
      );
    }
  });

  test('malformed identity, suffix scope and non-single-address IP cannot create candidates', () {
    for (final invalid in [
      _suggestions(id: 'not-a-tracker'),
      _suggestions(host: 'cropped…'),
      _suggestions(host: 'bad.example.'),
      _suggestions(host: 'https://example.test'),
      _suggestions(host: null),
      _suggestions(boundary: 'unrelated.example'),
      _suggestions(boundary: 'cropped…'),
      {
        ..._suggestions(),
        'suffixBoundary': ['private.github.io'],
      },
      _suggestions(ip: '192.0.2.0/24'),
      _suggestions(ip: '::/128'),
      _suggestions(ip: '0.0.0.0/32'),
      _suggestions(ip: 'fe80::1%wlan0/128'),
    ]) {
      expect(
        () => ConnectionRuleSuggestions.fromValue(invalid, _core),
        throwsFormatException,
      );
    }
    for (final source in [
      const CoreSnapshot(),
      const CoreSnapshot(
        generation: 7,
        configId: 'one',
        revision: 1,
        purpose: 'VPN',
      ),
    ]) {
      expect(
        () => ConnectionRuleSuggestions.fromValue(_suggestions(), source),
        throwsFormatException,
      );
    }
    expect(
      () => ConnectionSnapshot.fromMap(
        _sample(suggestions: _suggestions(id: _otherId)),
      ),
      throwsFormatException,
    );
    final inactive = ConnectionSnapshot.fromMap(
      _sample(suggestions: _suggestions(), active: false),
    ).records.single;
    expect(inactive.active, isFalse);
    expect(inactive.ruleMetadata!.matches(_core), isTrue);
  });

  testWidgets(
    'detail samples carry full source and target read is explicit, single-flight and unfiltered',
    (tester) async {
      final bridge = _RuleBridge();
      final app = _RuleApp(bridge);
      final controller = ConnectionController(app)..setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      expect(controller.canCreateRule, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.targetReads, 0);
      expect(bridge.detailRequests.last, {
        'generation': 7,
        'configId': 'one',
        'revision': 1,
        'composition': 'controlled-composition',
        'purpose': 'VPN',
        'id': _id,
      });
      final source = controller.ruleSuggestions!;
      expect(controller.canCreateRule, isTrue);
      bridge.targetPending = Completer<StrategySnapshot>();
      final pending = controller.loadRuleTargets(
        source,
        0,
        source.candidates.first,
      );
      expect(controller.ruleLoading, isTrue);
      await expectLater(
        controller.loadRuleTargets(source, 0, source.candidates.first),
        throwsA(isA<ConfigFailure>()),
      );
      expect(bridge.targetReads, 1);
      bridge.targetPending!.complete(_targets(_core));
      final targets = await pending;
      expect(targets.groups.map((group) => group.name), [
        'Hidden group',
        'GLOBAL',
        'Visible group',
      ]);
      expect(controller.ruleLoading, isFalse);
      controller.dispose();
      app.dispose();
    },
  );

  for (final reason in [
    'closed',
    'stale',
    'epoch',
    'composition',
    'session',
    'network-read-failure',
    'stop',
  ]) {
    testWidgets(
      'rule source retention follows $reason and its original identity',
      (tester) async {
        final bridge = _RuleBridge();
        final app = _RuleApp(bridge);
        final clock = _Clock();
        final controller = ConnectionController(app, clock: clock)
          ..setVisible(true);
        await tester.pump();
        controller.openDetail(controller.data!.records.single);
        await tester.pump(const Duration(seconds: 1));
        final source = controller.ruleSuggestions!;
        switch (reason) {
          case 'closed':
            bridge.trackerActive = false;
            bridge.suggestions = null;
            await tester.pump(const Duration(seconds: 1));
          case 'stale':
            bridge.samplePending = Completer<ConnectionSnapshot>();
            clock.elapsedMilliseconds = 5001;
            await tester.pump(const Duration(milliseconds: 5001));
          case 'epoch':
            app.publish(epoch: 1);
          case 'composition':
            app.publish(
              source: const CoreSnapshot(
                generation: 7,
                phase: 'READY',
                purpose: 'VPN',
                configId: 'one',
                revision: 1,
                composition: 'new-composition',
              ),
            );
          case 'session':
            bridge.session = 2;
            app.publish(session: 2);
            await tester.pump(const Duration(seconds: 1));
          case 'network-read-failure':
            bridge.sampleFails = true;
            await tester.pump(const Duration(seconds: 1));
          case 'stop':
            app.publish(phase: 'STOPPED', source: const CoreSnapshot());
        }
        final reusable = const [
          'closed',
          'stale',
          'network-read-failure',
        ].contains(reason);
        expect(controller.canCreateRule, reusable);
        expect(
          controller.isRuleSourceCurrent(
            source,
            0,
            candidate: source.candidates.first,
          ),
          reusable,
        );
        if (reusable) expect(controller.canClose, isFalse);
        expect(controller.detail, isNotNull);
        expect(bridge.targetReads, 0);
        controller.dispose();
        bridge.samplePending?.complete(ConnectionSnapshot.fromMap(_sample()));
        await tester.pump();
        app.dispose();
      },
    );
  }

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'rule actions occupy the label row or move together below full-width content $language/$scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(700, 1000);
          addTearDown(tester.view.reset);
          final bridge = _RuleBridge();
          final app = _RuleApp(bridge);
          try {
            await _host(tester, app, language: language, scale: scale);
            final scope = find.byKey(const ValueKey('connection-rule-scope'));
            final scopeState = tester.state(scope);
            final strings = AppLocalizations.of(tester.element(scope));
            for (final width in [1000.0, 280.0, 1000.0]) {
              tester.view.physicalSize = Size(width, 1000);
              await tester.pump();
              final label = tester.getRect(find.text(strings.matchedRule));
              final actions = tester.getRect(
                find.byKey(const ValueKey('connection-rule-actions')),
              );
              final body = tester.getRect(
                find
                    .ancestor(
                      of: find.byWidgetPredicate(
                        (widget) =>
                            widget is SelectableText && widget.data == 'Match',
                      ),
                      matching: find.byType(LayoutBuilder),
                    )
                    .first,
              );
              if (width == 1000) {
                expect(actions.center.dy, closeTo(label.center.dy, .01));
                expect(actions.left, greaterThan(label.left));
                expect(body.top, greaterThanOrEqualTo(actions.bottom));
              } else {
                expect(actions.top, greaterThan(body.bottom));
                expect(actions.left, closeTo(label.left, .01));
              }
              expect(body.left, closeTo(label.left, .01));
              expect(body.right, closeTo(width - 32, .01));
              expect(tester.state(scope), same(scopeState));
              expect(tester.takeException(), isNull);
            }
          } finally {
            await tester.pumpWidget(const SizedBox());
            app.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'late targets from another composition cannot open a valid form context',
    (tester) async {
      final bridge = _RuleBridge();
      final app = _RuleApp(bridge);
      final controller = ConnectionController(app)..setVisible(true);
      await tester.pump();
      controller.openDetail(controller.data!.records.single);
      await tester.pump(const Duration(seconds: 1));
      final source = controller.ruleSuggestions!;
      bridge.targetPending = Completer<StrategySnapshot>();
      final pending = controller.loadRuleTargets(
        source,
        0,
        source.candidates.first,
      );
      final expectation = expectLater(pending, throwsA(isA<ConfigFailure>()));
      app.publish(
        source: const CoreSnapshot(
          generation: 8,
          phase: 'READY',
          purpose: 'VPN',
          configId: 'one',
          revision: 1,
          composition: 'next',
        ),
      );
      bridge.targetPending!.complete(_targets(_core));
      await expectation;
      expect(controller.ruleLoading, isFalse);
      controller.dispose();
      app.dispose();
    },
  );

  for (final reason in ['epoch', 'composition', 'background']) {
    testWidgets(
      'opened form retains input and rejects expired $reason before submitting',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        final bridge = _RuleBridge();
        final app = _RuleApp(bridge);
        await _host(tester, app, scale: 2);
        await _tapRule(tester);
        await tester.pumpAndSettle();
        await _chooseTarget(tester, 'DIRECT');
        await tester.ensureVisible(_field('rule/value'));
        await tester.enterText(_field('rule/value'), 'kept-controlled.example');
        await tester.pumpAndSettle();
        final valueRect = tester.getRect(_field('rule/value'));
        final saveRect = tester.getRect(
          find.byKey(const ValueKey('definition-save:rule')),
        );
        switch (reason) {
          case 'epoch':
            app.publish(epoch: 1);
          case 'composition':
            app.publish(
              source: const CoreSnapshot(
                generation: 7,
                phase: 'READY',
                purpose: 'VPN',
                configId: 'one',
                revision: 1,
                composition: 'changed',
              ),
            );
          case 'background':
            app.setForeground(false);
        }
        for (final ms in [0, 16, 100, 200]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(tester.getRect(_field('rule/value')), valueRect);
          expect(
            tester.getRect(find.byKey(const ValueKey('definition-save:rule'))),
            saveRect,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byKey(const ValueKey('definition-save:rule')));
        await tester.pumpAndSettle();
        expect(bridge.submits, 0);
        expect(find.byType(RuleFormPage), findsOneWidget);
        expect(
          tester.widget<TextField>(_field('rule/value')).controller!.text,
          'kept-controlled.example',
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('definition-save:rule'))),
          saveRect,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
  }

  testWidgets(
    'long complete host stays uncut in scope choices and the actual form at large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(280, 800);
      addTearDown(tester.view.reset);
      final host = ['a' * 63, 'b' * 63, 'c' * 63, 'd' * 61].join('.');
      expect(host.length, 253);
      final bridge = _RuleBridge()
        ..suggestions = _suggestions(
          host: host,
          boundary: host.substring(64),
          ip: null,
        );
      final app = _RuleApp(bridge);
      await _host(tester, app, scale: 2);
      final menu = find.byKey(const ValueKey('connection-rule-scope'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text(host), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text(host).first)).pop();
      await tester.pumpAndSettle();
      await _tapRule(tester);
      await tester.pumpAndSettle();
      expect(
        tester.widget<RuleFormPage>(find.byType(RuleFormPage)).initialValue,
        host,
      );
      expect(
        tester.widget<TextField>(_field('rule/value')).controller!.text,
        host,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );

  testWidgets(
    'restricted shared form rejects an initial target outside the current complete snapshot',
    (tester) async {
      final saved = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: RuleFormPage(
            onSave: (value) async {
              saved.add(value);
            },
            targets: const ['Hidden group', 'GLOBAL', 'DIRECT', 'REJECT'],
            initialValue: 'controlled.example',
            initialTarget: 'not-a-current-target',
            restrictTargets: true,
          ),
        ),
      );
      final targetRect = tester.getRect(_field('rule/target'));
      final saveRect = tester.getRect(
        find.byKey(const ValueKey('definition-save:rule')),
      );
      await tester.tap(find.byKey(const ValueKey('definition-save:rule')));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.byType(RuleFormPage), findsOneWidget);
      expect(
        tester.widget<TextField>(_field('rule/target')).controller!.text,
        'not-a-current-target',
      );
      expect(tester.getRect(_field('rule/target')), targetRect);
      expect(
        tester.getRect(find.byKey(const ValueKey('definition-save:rule'))),
        saveRect,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'IP-only native suggestion uses IPv6 single-address rule, not displayed metadata',
    (tester) async {
      final bridge = _RuleBridge()
        ..suggestions = _suggestions(
          host: null,
          boundary: null,
          ip: '2001:db8::2/128',
        );
      final app = _RuleApp(bridge);
      await _host(tester, app);
      await _tapRule(tester);
      await tester.pumpAndSettle();
      final form = tester.widget<RuleFormPage>(find.byType(RuleFormPage));
      expect(form.initialType, 'IP-CIDR6');
      expect(form.initialValue, '2001:db8::2/128');
      expect(form.initialValue, isNot('198.18.0.99/32'));
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );

  for (final language in ['en', 'zh']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'real rule entry, loading, failure and retry anchors $language $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 800);
          addTearDown(tester.view.reset);
          final bridge = _RuleBridge()
            ..targetPending = Completer<StrategySnapshot>();
          final app = _RuleApp(bridge);
          await _host(
            tester,
            app,
            language: language,
            scale: scale,
            dark: language == 'zh',
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('connection-rule-actions')),
          );
          await tester.pump();
          final action = tester.getRect(
            find.byKey(const ValueKey('connection-rule-actions')),
          );
          final button = tester.getRect(
            find.byKey(const ValueKey('connection-add-rule')),
          );
          await tester.tap(find.byKey(const ValueKey('connection-add-rule')));
          for (final ms in [0, 16, 100, 200]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(
              tester.getRect(
                find.byKey(const ValueKey('connection-rule-actions')),
              ),
              action,
            );
            expect(
              tester.getRect(find.byKey(const ValueKey('connection-add-rule'))),
              button,
            );
            expect(tester.takeException(), isNull);
          }
          bridge.targetPending!.completeError(StateError('controlled failure'));
          bridge.targetPending = null;
          await tester.pumpAndSettle();
          final strings = AppLocalizations.of(
            tester.element(find.byKey(const ValueKey('connection-add-rule'))),
          );
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(
            find.text(strings.connectionRuleTargetsFailed),
            findsOneWidget,
          );
          expect(find.byType(RuleFormPage), findsNothing);
          await tester.tap(find.widgetWithText(TextButton, strings.close));
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 1));
          await _tapRule(tester);
          await tester.pumpAndSettle();
          expect(find.byType(RuleFormPage), findsOneWidget);
          final form = tester.widget<RuleFormPage>(find.byType(RuleFormPage));
          expect(form.initialType, 'DOMAIN');
          expect(form.initialValue, 'a.private.github.io');
          expect(form.targets, [
            'Hidden group',
            'GLOBAL',
            'Visible group',
            'DIRECT',
            'REJECT',
          ]);
          expect(form.restrictTargets, isTrue);
          expect(
            tester.widget<TextField>(_field('rule/target')).readOnly,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          app.dispose();
        },
      );
    }
  }

  testWidgets('scope menu retires across background without preparing a rule', (
    tester,
  ) async {
    final bridge = _RuleBridge();
    final app = _RuleApp(bridge);
    try {
      await _host(tester, app);
      final trigger = find.byKey(const ValueKey('connection-rule-scope'));
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      final item = find.widgetWithText(MenuItemButton, 'private.github.io');
      expect(item.hitTestable(), findsOneWidget);
      final old = tester.widget<MenuItemButton>(item).onPressed!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(tester.binding.framesEnabled, isFalse);
      old();
      expect(bridge.targetReads, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(item.hitTestable(), findsNothing);
      await tester.pumpAndSettle();
      old();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(find.byType(RuleFormPage), findsNothing);
      expect(bridge.targetReads, 0);
      expect(tester.takeException(), isNull);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    }
  });

  testWidgets(
    'suffix scope retires on source expiry and its old callback cannot adopt a new source',
    (tester) async {
      final bridge = _RuleBridge();
      final app = _RuleApp(bridge);
      await _host(tester, app);
      final menu = find.byKey(const ValueKey('connection-rule-scope'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final item = find.widgetWithText(MenuItemButton, 'private.github.io');
      final before = tester.getRect(menu);
      final old = tester.widget<MenuItemButton>(item).onPressed!;
      app.publish(
        source: const CoreSnapshot(
          generation: 8,
          phase: 'READY',
          purpose: 'VPN',
          configId: 'one',
          revision: 1,
          composition: 'next',
        ),
      );
      for (final ms in [0, 16, 100, 200]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(tester.getRect(menu), before);
        expect(item.hitTestable(), findsNothing);
        old();
        expect(bridge.targetReads, 0);
        expect(tester.takeException(), isNull);
      }
      expect(find.byType(MenuItemButton), findsNothing);
      expect(find.byType(RuleFormPage), findsNothing);
      expect(bridge.targetReads, 0);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );

  for (final choice in [
    (type: 'DOMAIN-SUFFIX', value: 'private.github.io'),
    (type: 'IP-CIDR', value: '192.0.2.1/32'),
  ]) {
    testWidgets(
      'native scope ${choice.type} opens the shared actual form unchanged',
      (tester) async {
        final bridge = _RuleBridge();
        final app = _RuleApp(bridge);
        await _host(tester, app);
        final menu = find.byKey(const ValueKey('connection-rule-scope'));
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        final item = find.widgetWithText(MenuItemButton, choice.value).last;
        await tester.ensureVisible(item);
        await tester.tap(item);
        await tester.pumpAndSettle();
        final form = tester.widget<RuleFormPage>(find.byType(RuleFormPage));
        expect(form.initialType, choice.type);
        expect(form.initialValue, choice.value);
        expect(
          tester.widget<TextField>(_field('rule/value')).controller!.text,
          choice.value,
        );
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
  }

  for (final departed in [false, true]) {
    testWidgets(
      'real saved apply failure is not duplicated or attached to a departed route $departed',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'controlled-connection-rule-failure-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final store = _Overrides(directory);
        final bridge = _BusinessBridge(
          store,
          File('${directory.path}/run.json'),
        );
        final app = AppController(
          bridge,
          store: _Configs(),
          overrideStore: store,
          preferencesStore: MemoryPreferencesStore(),
        );
        await app.refresh();
        await _host(tester, app);
        await _tapRule(tester);
        await tester.pumpAndSettle();
        await _chooseTarget(tester, 'DIRECT');
        final keptValue = tester
            .widget<TextField>(_field('rule/value'))
            .controller!
            .text;
        final saveRect = tester.getRect(
          find.byKey(const ValueKey('definition-save:rule')),
        );
        await tester.tap(find.byKey(const ValueKey('definition-save:rule')));
        await tester.pump();
        expect(bridge.commands, hasLength(1));
        if (departed) {
          final context = tester.element(find.byType(RuleFormPage));
          final navigator = Navigator.of(context);
          navigator.removeRoute(ModalRoute.of(context)!);
          await tester.pumpAndSettle();
          unawaited(
            navigator.push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    const Scaffold(body: Text('Controlled successor route')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(app.hasLocalFeedbackOwner, isFalse);
        }
        bridge.native.failStart = true;
        await tester.runAsync(() async {
          await bridge.finish();
          await app.refresh();
        });
        await tester.pumpAndSettle();
        expect(store.entries, hasLength(1));
        expect(store.entries.single.role, OverrideRole.localCustom);
        expect(
          LocalYamlEdit(store.entries.single.body)
              .definitions(LocalYamlSection.rules),
          hasLength(1),
        );
        expect(bridge.nativeState.overrideStatus, 'applyFailed');
        expect(app.hasLocalFeedbackOwner, isFalse);
        if (departed) {
          expect(find.byType(RuleFormPage), findsNothing);
          expect(find.text('Controlled successor route'), findsOneWidget);
          expect(find.byType(AlertDialog), findsOneWidget);
        } else {
          expect(find.byType(RuleFormPage), findsOneWidget);
          expect(
            tester.widget<TextField>(_field('rule/value')).controller!.text,
            keptValue,
          );
          for (final ms in [0, 16, 100, 200]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(
              tester.getRect(
                find.byKey(const ValueKey('definition-save:rule')),
              ),
              saveRect,
            );
            expect(tester.takeException(), isNull);
          }
          await tester.tap(find.byKey(const ValueKey('definition-save:rule')));
          await tester.pumpAndSettle();
          expect(bridge.commands, hasLength(1));
          expect(
            tester.widget<TextField>(_field('rule/value')).controller!.text,
            keptValue,
          );
        }
        expect(bridge.commands, hasLength(1));
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
  }

  for (final endedBeforeDetail in [true, false]) {
    testWidgets(
      'inactive rule saves through the unique writer, ended before detail: $endedBeforeDetail',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'controlled-connection-rule-',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final store = _Overrides(directory);
        final bridge = _BusinessBridge(
          store,
          File('${directory.path}/run.json'),
        )..trackerActive = !endedBeforeDetail;
        final app = AppController(
          bridge,
          store: _Configs(),
          overrideStore: store,
          preferencesStore: MemoryPreferencesStore(),
        );
        await app.refresh();
        await _host(tester, app);
        await _tapRule(tester);
        await tester.pumpAndSettle();
        if (!endedBeforeDetail) {
          bridge.trackerActive = false;
          bridge.suggestions = null;
          await tester.pump(const Duration(seconds: 1));
        }
        final target = tester
            .widget<RuleFormPage>(find.byType(RuleFormPage))
            .targets
            .first;
        // A native group, including hidden, is chosen through the real read-only field.
        await tester.ensureVisible(_field('rule/target'));
        await tester.tap(
          find.byKey(const ValueKey('definition-suggestions:rule/target')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(target).last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('definition-save:rule')));
        await tester.pump();
        expect(bridge.commands, hasLength(1));
        expect(bridge.commands.single['action'], 'saveLocalDefinition');
        expect(bridge.commands.single['section'], 'rules');
        expect(
          bridge.commands.single['rule'],
          'DOMAIN,a.private.github.io,Hidden group',
        );
        expect(bridge.commands.single['storageEpoch'], 0);
        final original = bridge.source;
        await tester.runAsync(() async {
          await bridge.finish();
          await app.refresh();
        });
        await tester.pumpAndSettle();
        expect(store.entries, hasLength(1));
        expect(store.entries.single.role, OverrideRole.localCustom);
        expect(
          LocalYamlEdit(store.entries.single.body)
              .definitions(LocalYamlSection.rules)
              .single
              .value,
          'DOMAIN,a.private.github.io,Hidden group',
        );
        expect(bridge.native.events, contains('stop'));
        expect(
          bridge.native.events.where((event) => event.startsWith('start:')),
          hasLength(1),
        );
        expect(bridge.source.matchesIdentity(original), isFalse);
        expect(find.byType(RuleFormPage), findsNothing);
        expect(app.hasLocalFeedbackOwner, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
  }
}
