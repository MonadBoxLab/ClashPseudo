import '../../l10n/app_localizations.dart';

enum TunnelMode {
  rule,
  global,
  direct;

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

  static TunnelMode parse(Object? value) => values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => throw const FormatException('Invalid tunnel mode'),
  );
}
