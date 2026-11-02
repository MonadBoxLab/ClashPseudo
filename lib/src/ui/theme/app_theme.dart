import 'package:flutter/material.dart';

import '../../model/app_preferences.dart';

class AppTheme {
  static ThemeData get light => forBrightness(Brightness.light);
  static ThemeData get dark => forBrightness(Brightness.dark);

  static ThemeData forBrightness(
    Brightness brightness, [
    BrandColor brand = BrandColor.cinnabar,
  ]) {
    final palette = HomePalette(brightness == Brightness.dark, brand: brand);
    final (secondaryBrand, tertiaryBrand) = switch (brand) {
      BrandColor.cinnabar => (BrandColor.jade, BrandColor.cobalt),
      BrandColor.jade => (BrandColor.cobalt, BrandColor.cinnabar),
      BrandColor.cobalt => (BrandColor.cinnabar, BrandColor.jade),
    };
    final secondary = palette.withBrand(secondaryBrand);
    final tertiary = palette.withBrand(tertiaryBrand);
    final fixed = HomePalette(false, brand: brand);
    final fixedSecondary = fixed.withBrand(secondaryBrand);
    final fixedTertiary = fixed.withBrand(tertiaryBrand);
    final inverse = HomePalette(!palette.dark, brand: brand);
    final colors =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: brightness,
        ).copyWith(
          primary: palette.accent,
          onPrimary: palette.startInk,
          primaryContainer: palette.accentSoft,
          onPrimaryContainer: palette.accent,
          secondary: secondary.accent,
          onSecondary: secondary.startInk,
          secondaryContainer: secondary.accentSoft,
          onSecondaryContainer: secondary.accent,
          tertiary: tertiary.accent,
          onTertiary: tertiary.startInk,
          tertiaryContainer: tertiary.accentSoft,
          onTertiaryContainer: tertiary.accent,
          primaryFixed: fixed.accentSoft,
          primaryFixedDim: Color.lerp(fixed.accentSoft, fixed.accent, .12),
          onPrimaryFixed: fixed.ink,
          onPrimaryFixedVariant: fixed.ink,
          secondaryFixed: fixedSecondary.accentSoft,
          secondaryFixedDim: Color.lerp(
            fixedSecondary.accentSoft,
            fixedSecondary.accent,
            .12,
          ),
          onSecondaryFixed: fixed.ink,
          onSecondaryFixedVariant: fixed.ink,
          tertiaryFixed: fixedTertiary.accentSoft,
          tertiaryFixedDim: Color.lerp(
            fixedTertiary.accentSoft,
            fixedTertiary.accent,
            .12,
          ),
          onTertiaryFixed: fixed.ink,
          onTertiaryFixedVariant: fixed.ink,
          surface: palette.surface,
          surfaceDim: palette.background,
          surfaceBright: palette.surface,
          surfaceContainerLowest: palette.background,
          surfaceContainerLow: palette.surface,
          surfaceContainer: palette.soft,
          surfaceContainerHigh: palette.soft,
          surfaceContainerHighest: palette.soft,
          surfaceTint: Colors.transparent,
          onSurface: palette.ink,
          onSurfaceVariant: palette.muted,
          outline: palette.muted,
          outlineVariant: palette.line,
          inverseSurface: inverse.surface,
          onInverseSurface: inverse.ink,
          inversePrimary: inverse.accent,
          error: palette.error,
          onError: palette.dark ? const Color(0xff3e0718) : Colors.white,
          errorContainer: Color(palette.dark ? 0xff381d26 : 0xffffe8ed),
          onErrorContainer: palette.error,
        );
    return ThemeData(
      useMaterial3: true,
      extensions: [palette],
      colorScheme: colors,
      scaffoldBackgroundColor: palette.background,
      iconTheme: IconThemeData(color: palette.ink),
      listTileTheme: ListTileThemeData(
        iconColor: palette.ink,
        selectedColor: colors.primary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        foregroundColor: palette.ink,
        iconTheme: IconThemeData(color: palette.ink),
        actionsIconTheme: IconThemeData(color: palette.ink),
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
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: palette.surface,
        elevation: 0,
        indicatorColor: palette.soft,
        selectedLabelTextStyle: TextStyle(
          color: palette.ink,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: palette.ink, fontSize: 12),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: palette.ink,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
        contentTextStyle: TextStyle(
          color: palette.ink,
          fontSize: 14,
          height: 1.5,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: TextStyle(color: palette.ink, fontSize: 14),
        iconColor: palette.ink,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(palette.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(3),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    );
  }
}

class SettingsPalette {
  const SettingsPalette(this.dark);
  final bool dark;

  Color get appearance => Color(dark ? 0xffe7c086 : 0xff8b651a);
  Color get language => Color(dark ? 0xffefb5d8 : 0xff984570);
  Color get configuration => Color(dark ? 0xff9bc4ff : 0xff3265a8);
  Color get network => Color(dark ? 0xff7ed4c7 : 0xff19796d);
  Color get extension => Color(dark ? 0xffd2b8f5 : 0xff7952a3);
  Color get diagnostics => Color(dark ? 0xffdec39f : 0xff865b31);
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
  Color get uploadPlot => Color(dark ? 0xff4b91e0 : 0xff2858af);
  Color get downloadPlot => Color(dark ? 0xff27a48d : 0xff087958);
}

class HomePalette extends ThemeExtension<HomePalette> {
  const HomePalette(this.dark, {this.brand = BrandColor.cinnabar});
  final bool dark;
  final BrandColor brand;

  static HomePalette of(BuildContext context) =>
      Theme.of(context).extension<HomePalette>() ??
      HomePalette(Theme.of(context).brightness == Brightness.dark);

  HomePalette withBrand(BrandColor value) => HomePalette(dark, brand: value);

  @override
  HomePalette copyWith({bool? dark, BrandColor? brand}) =>
      HomePalette(dark ?? this.dark, brand: brand ?? this.brand);

  @override
  HomePalette lerp(covariant HomePalette? other, double t) =>
      other == null || t < 0.5 ? this : other;

  Color legibleInk(Color background, {Color? preferred}) {
    final backdrop = background.computeLuminance();
    return [
      ?preferred,
      ink,
      copyWith(dark: !dark).ink,
      Colors.black,
      Colors.white,
    ].firstWhere((color) {
      final foreground = color.computeLuminance();
      return (foreground > backdrop
              ? (foreground + .05) / (backdrop + .05)
              : (backdrop + .05) / (foreground + .05)) >=
          4.5;
    });
  }

  Color get background => Color(dark ? 0xff191c1f : 0xfff8f6f1);
  Color get surface => Color(dark ? 0xff222629 : 0xfffffefa);
  Color get soft => Color(dark ? 0xff2d3338 : 0xfff1eee6);
  Color get ink => Color(dark ? 0xffe5e8e6 : 0xff2e302c);
  Color get muted => Color(dark ? 0xffadb4b9 : 0xff706a5f);
  Color get line => Color(dark ? 0xff394046 : 0xffe9e3d8);
  Color get accent => switch (brand) {
    BrandColor.cinnabar => Color(dark ? 0xffedb09a : 0xffaa351f),
    BrandColor.jade => jade,
    BrandColor.cobalt => cobalt,
  };
  Color get accentSoft => switch (brand) {
    BrandColor.cinnabar => Color(dark ? 0xff42302c : 0xfffff0e5),
    BrandColor.jade => jadeSoft,
    BrandColor.cobalt => cobaltSoft,
  };
  Color get jade => Color(dark ? 0xff7ed4c7 : 0xff1a7a64);
  Color get jadeSoft => Color(dark ? 0xff183c35 : 0xffe6f2ec);
  Color get cobalt => Color(dark ? 0xff9bc4ff : 0xff2858af);
  Color get cobaltSoft => Color(dark ? 0xff24364e : 0xffeaf0fa);
  Color get error => Color(dark ? 0xfff1a9b7 : 0xffb63148);
  Color get syncAction => Color(dark ? 0xff81c9db : 0xff157386);
  Color get editAction => Color(dark ? 0xffe7c086 : 0xff8b651a);
  Color get moreAction => Color(dark ? 0xffd2b8f5 : 0xff7952a3);
  Color get remoteSource => Color(dark ? 0xff9bc4ff : 0xff3265a8);
  Color get localSource => Color(dark ? 0xff8bd5a5 : 0xff287847);
  Color get success => Color(dark ? 0xff8bd5a5 : 0xff287847);
  Color get warning => Color(dark ? 0xffefc078 : 0xff8b5915);
  Color get hero => dark ? Color.lerp(startFace, background, .78)! : startFace;

  Color get startFace => switch (brand) {
    BrandColor.cinnabar => const Color(0xffbf4029),
    BrandColor.jade => const Color(0xff1a7a64),
    BrandColor.cobalt => const Color(0xff2858af),
  };

  ({Color background, Color face, Color glyph}) controlColors(bool running) {
    final neutral = dark ? ink : surface;
    final filled = dark ? accent : startFace;
    return (
      background: running ? hero : background,
      face: running ? neutral : filled,
      glyph: running
          ? legibleInk(neutral, preferred: copyWith(dark: false).accent)
          : legibleInk(filled, preferred: startInk),
    );
  }

  Color controlBackground(double progress) => Color.lerp(
    controlColors(false).background,
    controlColors(true).background,
    progress,
  )!;

  Color get heroHighlight => brand == BrandColor.cinnabar
      ? Color(dark ? 0xff49302a : 0xffc24a2d)
      : Color.lerp(hero, accent, dark ? 0.18 : 0.12)!;
  Color get heroInk => legibleInk(hero);
  Color get startInk => legibleInk(accent);
  Color get ripple => brand == BrandColor.cinnabar
      ? Color(dark ? 0xffe3aa8f : 0xfffff4e6)
      : dark
      ? accent
      : const Color(0xfffff4e6);
}
