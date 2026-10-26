import '../../l10n/app_localizations.dart';

String strategyUnrestoredReason(String reason, AppLocalizations strings) =>
    switch (reason) {
      'group-missing' => strings.strategyGroupMissing,
      'type-changed' => strings.strategyTypeChanged,
      'not-selectable' => strings.strategyNotSelectable,
      'member-missing' => strings.strategyMemberMissing,
      _ => strings.resultUnconfirmed,
    };

enum StrategyType {
  select('select'),
  urlTest('url-test'),
  fallback('fallback'),
  loadBalance('load-balance');

  const StrategyType(this.value);
  final String value;

  String label(AppLocalizations strings) => switch (this) {
    StrategyType.select => strings.strategyChoiceSelect,
    StrategyType.urlTest => strings.strategyChoiceUrlTest,
    StrategyType.fallback => strings.strategyChoiceFallback,
    StrategyType.loadBalance => strings.strategyChoiceLoadBalance,
  };

  bool get automatic => this == urlTest || this == fallback;
  bool get selectable => this != loadBalance;

  static StrategyType parse(Object? value) => values.firstWhere(
    (type) => type.value == value,
    orElse: () => throw const FormatException('Invalid strategy type'),
  );
}

class StrategyChoice {
  const StrategyChoice({required this.type, required this.member});

  final StrategyType type;
  final String? member;

  Map<String, Object?> toJson() => {'type': type.value, 'member': member};

  factory StrategyChoice.fromJson(Map<String, dynamic> value) {
    final type = StrategyType.parse(value['type']);
    final member = value['member'];
    if (!type.selectable ||
        !value.containsKey('member') ||
        (member != null && (member is! String || member.isEmpty)) ||
        (member == null && !type.automatic)) {
      throw const FormatException('Invalid strategy choice');
    }
    return StrategyChoice(type: type, member: member as String?);
  }

  static Map<String, StrategyChoice> decode(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid strategy choices');
    }
    return Map.unmodifiable(
      value.map((name, choice) {
        if (name.isEmpty || choice is! Map<String, dynamic>) {
          throw const FormatException('Invalid strategy choice');
        }
        return MapEntry(name, StrategyChoice.fromJson(choice));
      }),
    );
  }
}
