import 'package:clash_pseudo/src/l10n/app_localizations.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/app_snapshot.dart';
import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/connection_snapshot.dart';
import 'package:clash_pseudo/src/model/core_snapshot.dart';
import 'package:clash_pseudo/src/model/messages.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/model/strategy_choice.dart';
import 'package:clash_pseudo/src/model/strategy_snapshot.dart';
import 'package:clash_pseudo/src/model/tunnel_mode.dart';
import 'package:clash_pseudo/src/ui/locale/message_text.dart';
import 'package:clash_pseudo/src/ui/locale/model_text.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final zh = lookupAppLocalizations(const Locale('zh'));
  tearDown(() => setMessageLanguage(AppLanguage.system));

  test('model extensions re-project the original descriptors and sources', () {
    final failure = messages.downloadFailed.withDetail('original native error');
    final local = ConfigEntry(
      id: 'local',
      name: 'Local',
      kind: ConfigKind.local,
      revision: 1,
      body: '{}',
      error: failure,
    );
    const remote = ConfigEntry(
      id: 'remote',
      name: 'Remote',
      source: 'https://fixture.invalid/raw-source',
      revision: 1,
      body: '{}',
    );
    final plugin = OverrideEntry(
      id: 'plugin',
      name: 'Plugin',
      kind: ConfigKind.local,
      revision: 1,
      body: '{}',
      error: failure,
    );
    final core = CoreSnapshot(error: failure);
    final snapshot = AppSnapshot(
      operation: messages.stageStartingTunnel,
      error: failure,
      resultMessage: messages.configSaved,
      modeError: messages.temporaryModeUnknown,
      core: core,
    );
    final original = [local.toJson(), plugin.toJson(), failure.toMap()];
    for (final strings in [en, zh, en]) {
      setMessageLanguage(
        strings.localeName == 'zh' ? AppLanguage.zh : AppLanguage.en,
      );
      expect(local.error, failure.resolve(strings));
      expect(local.displaySource, strings.localConfig);
      expect(remote.displaySource, remote.source);
      expect(plugin.error, failure.resolve(strings));
      expect(core.error, failure.resolve(strings));
      expect(snapshot.operation, strings.stageStartingTunnel);
      expect(snapshot.error, failure.resolve(strings));
      expect(snapshot.resultMessage, strings.configSaved);
      expect(snapshot.modeError, strings.temporaryModeUnknown);
      expect(snapshot.core, same(core));
      expect(local.errorMessage, same(failure));
      expect(plugin.errorMessage, same(failure));
      expect([local.toJson(), plugin.toJson(), failure.toMap()], original);
    }
  });

  test('mode and strategy labels keep raw unknown types intact', () {
    final unknown = StrategyGroup(
      name: 'Raw group',
      rawType: 'future-native-strategy',
      hidden: false,
      now: 'Raw member',
      fixed: '',
      members: const [],
    );
    for (final strings in [en, zh]) {
      expect(TunnelMode.rule.label(strings), strings.modeRule);
      expect(TunnelMode.global.label(strings), strings.modeGlobal);
      expect(TunnelMode.direct.label(strings), strings.modeDirect);
      expect(TunnelMode.rule.description(strings), strings.modeRuleDescription);
      expect(
        TunnelMode.global.description(strings),
        strings.modeGlobalDescription,
      );
      expect(
        TunnelMode.direct.description(strings),
        strings.modeDirectDescription,
      );
      expect(StrategyType.select.label(strings), strings.strategyChoiceSelect);
      expect(
        StrategyType.urlTest.label(strings),
        strings.strategyChoiceUrlTest,
      );
      expect(
        StrategyType.fallback.label(strings),
        strings.strategyChoiceFallback,
      );
      expect(
        StrategyType.loadBalance.label(strings),
        strings.strategyChoiceLoadBalance,
      );
      expect(unknown.typeLabel(strings), 'future-native-strategy');
      expect(
        strategyUnrestoredReason('group-missing', strings),
        strings.strategyGroupMissing,
      );
      expect(
        strategyUnrestoredReason('type-changed', strings),
        strings.strategyTypeChanged,
      );
      expect(
        strategyUnrestoredReason('not-selectable', strings),
        strings.strategyNotSelectable,
      );
      expect(
        strategyUnrestoredReason('member-missing', strings),
        strings.strategyMemberMissing,
      );
      expect(
        strategyUnrestoredReason('future-reason', strings),
        strings.resultUnconfirmed,
      );
    }
    expect(unknown.rawType, 'future-native-strategy');
  });

  test('connection display fallbacks stay in the UI extension', () {
    final empty = ConnectionRecord.fromMap({'id': 'empty'});
    final raw = ConnectionRecord.fromMap({
      'id': 'observed',
      'chains': ['DIRECT', 'Exit'],
      'rule': 'Domain',
      'rulePayload': 'fixture.invalid',
      'metadata': {'destinationIP': '2001:db8::1', 'destinationPort': '443'},
    });
    for (final strings in [en, zh]) {
      setMessageLanguage(
        strings.localeName == 'zh' ? AppLanguage.zh : AppLanguage.en,
      );
      expect(empty.target, strings.notProvided);
      expect(empty.path, strings.pathUnavailable);
      expect(empty.ruleLabel, strings.notProvided);
      expect(connectionEndpoint('', '443'), strings.notProvided);
      expect(connectionEndpoint('192.0.2.1', ''), '192.0.2.1');
      expect(connectionEndpoint('::1', '80'), '[::1]:80');
      expect(raw.target, '[2001:db8::1]:443');
      expect(raw.path, 'Exit → DIRECT');
      expect(raw.ruleLabel, 'Domain · fixture.invalid');
      expect(raw.ruleKey, ('Domain', 'fixture.invalid'));
    }
  });
}
