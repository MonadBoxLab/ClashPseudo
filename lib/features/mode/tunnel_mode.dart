enum TunnelMode {
  rule('规则', '按配置中的规则选择连接去向。'),
  global('全局', '使用配置中的 GLOBAL 策略；不一定经过代理。'),
  direct('直连', '按直连模式处理连接，不会关闭 VPN 接管。');

  const TunnelMode(this.label, this.description);

  final String label;
  final String description;

  static TunnelMode parse(Object? value) => values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => throw const FormatException('Invalid tunnel mode'),
  );
}
