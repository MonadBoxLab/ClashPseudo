import '../../l10n/app_localizations.dart';
import '../../model/app_snapshot.dart';
import '../../model/config_entry.dart';
import '../../model/connection_snapshot.dart';
import '../../model/core_snapshot.dart';
import '../../model/override_entry.dart';
import '../../model/strategy_choice.dart';
import '../../model/strategy_snapshot.dart';
import '../../model/tunnel_mode.dart';
import 'message_text.dart';

extension ConfigEntryText on ConfigEntry {
  String? get error => errorMessage?.text;
  String get displaySource => remote ? source! : localizedMessages.localConfig;
}

extension OverrideEntryText on OverrideEntry {
  String? get error => errorMessage?.text;
}

extension AppSnapshotText on AppSnapshot {
  String? get operation => operationMessage?.text;
  String? get error => errorMessage?.text;
  String? get resultMessage => resultMessageDescription?.text;
  String? get modeError => modeErrorMessage?.text;
}

extension CoreSnapshotText on CoreSnapshot {
  String? get error => errorMessage?.text;
}

extension TunnelModeText on TunnelMode {
  String label(AppLocalizations strings) => switch (this) {
    TunnelMode.rule => strings.modeRule,
    TunnelMode.global => strings.modeGlobal,
    TunnelMode.direct => strings.modeDirect,
  };

  String description(AppLocalizations strings) => switch (this) {
    TunnelMode.rule => strings.modeRuleDescription,
    TunnelMode.global => strings.modeGlobalDescription,
    TunnelMode.direct => strings.modeDirectDescription,
  };
}

extension StrategyTypeText on StrategyType {
  String label(AppLocalizations strings) => switch (this) {
    StrategyType.select => strings.strategyChoiceSelect,
    StrategyType.urlTest => strings.strategyChoiceUrlTest,
    StrategyType.fallback => strings.strategyChoiceFallback,
    StrategyType.loadBalance => strings.strategyChoiceLoadBalance,
  };
}

extension StrategyGroupText on StrategyGroup {
  String typeLabel(AppLocalizations strings) => type?.label(strings) ?? rawType;
}

String strategyUnrestoredReason(String reason, AppLocalizations strings) =>
    switch (reason) {
      'group-missing' => strings.strategyGroupMissing,
      'type-changed' => strings.strategyTypeChanged,
      'not-selectable' => strings.strategyNotSelectable,
      'member-missing' => strings.strategyMemberMissing,
      _ => strings.resultUnconfirmed,
    };

extension ConnectionRecordText on ConnectionRecord {
  String get target => host.isNotEmpty
      ? host
      : connectionEndpoint(destinationIP, destinationPort);
  String get path => chains.isEmpty
      ? localizedMessages.pathUnavailable
      : chains.reversed.join(' → ');
  String get ruleLabel => rule.isEmpty
      ? localizedMessages.notProvided
      : [rule, if (rulePayload.isNotEmpty) rulePayload].join(' · ');
}

String connectionEndpoint(String address, String port) {
  if (address.isEmpty) return localizedMessages.notProvided;
  final host = address.contains(':') ? '[$address]' : address;
  return port.isEmpty ? host : '$host:$port';
}
