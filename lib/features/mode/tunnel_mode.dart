enum TunnelMode {
  rule('规则', '按配置规则选择连接去向。'),
  global('全局', '按全局策略选择连接去向。'),
  direct('直连', '直接连接目标并保持接管。');

  const TunnelMode(this.label, this.description);

  final String label;
  final String description;

  static TunnelMode parse(Object? value) => values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => throw const FormatException('Invalid tunnel mode'),
  );
}
