enum StrategyType {
  select('select', '手动选择'),
  urlTest('url-test', '自动测速'),
  fallback('fallback', '故障转移'),
  loadBalance('load-balance', '负载均衡');

  const StrategyType(this.value, this.label);
  final String value;
  final String label;

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
