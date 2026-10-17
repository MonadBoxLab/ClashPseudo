import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get light => _theme(Brightness.light);
  static ThemeData get dark => _theme(Brightness.dark);

  static ThemeData _theme(Brightness brightness) {
    final palette = HomePalette(brightness == Brightness.dark);
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xffbf4029),
          brightness: brightness,
        ).copyWith(
          primary: palette.accent,
          onPrimary: palette.startInk,
          primaryContainer: palette.accentSoft,
          onPrimaryContainer: palette.accent,
          surface: palette.surface,
          surfaceContainerHighest: palette.soft,
          onSurface: palette.ink,
          onSurfaceVariant: palette.muted,
          outlineVariant: palette.line,
          error: palette.error,
        );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: palette.background,
      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        foregroundColor: palette.ink,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        color: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: palette.soft,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? palette.accent
                : palette.muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: palette.ink,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
      dialogTheme: DialogThemeData(backgroundColor: palette.surface),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
  }
}

class ModePalette {
  const ModePalette(this.dark);
  final bool dark;

  Color get rule => Color(dark ? 0xff9bc4ff : 0xff3265a8);
  Color get global => Color(dark ? 0xffd2b8f5 : 0xff7952a3);
  Color get direct => Color(dark ? 0xff7ed4c7 : 0xff19796d);
}

class ConnectionPalette {
  const ConnectionPalette(this.dark);
  final bool dark;

  Color get active => Color(dark ? 0xff8bd5a5 : 0xff287847);
  Color get warning => Color(dark ? 0xffefc078 : 0xff8b5915);
  Color get upload => Color(dark ? 0xff9bc4ff : 0xff3265a8);
  Color get download => Color(dark ? 0xff7ed4c7 : 0xff19796d);
}

class HomePalette {
  const HomePalette(this.dark);
  final bool dark;

  Color get background => Color(dark ? 0xff191c1f : 0xfff8f6f1);
  Color get surface => Color(dark ? 0xff222629 : 0xfffffefa);
  Color get soft => Color(dark ? 0xff2d3338 : 0xfff1eee6);
  Color get ink => Color(dark ? 0xffe5e8e6 : 0xff2e302c);
  Color get muted => Color(dark ? 0xffadb4b9 : 0xff756f63);
  Color get line => Color(dark ? 0xff394046 : 0xffe9e3d8);
  Color get accent => Color(dark ? 0xffedb09a : 0xffaa351f);
  Color get accentSoft => Color(dark ? 0xff42302c : 0xfffff0e5);
  Color get error => Color(dark ? 0xfff1a9b7 : 0xffb63148);
  Color get hero => Color(dark ? 0xff281f1e : 0xffbf4029);
  Color get heroHighlight => Color(dark ? 0xff49302a : 0xffc24a2d);
  Color get heroInk => Color(dark ? 0xfff0dfd7 : 0xfffff9ef);
  Color get powerFace => Color(dark ? 0xff754635 : 0xfffff9f0);
  Color get powerInk => Color(dark ? 0xffffe1ce : 0xffbf4029);
  Color get powerEdge => Color(dark ? 0xffbd856d : 0x00ffffff);
  Color get startFace => Color(dark ? 0xffd69d83 : 0xffbf4029);
  Color get startInk => Color(dark ? 0xff2d1d17 : 0xffffffff);
  Color get ripple => Color(dark ? 0xffe3aa8f : 0xfffff4e6);
}
