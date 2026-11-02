enum TunnelMode {
  rule,
  global,
  direct;

  static TunnelMode parse(Object? value) => values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => throw const FormatException('Invalid tunnel mode'),
  );
}
