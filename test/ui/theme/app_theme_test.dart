import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  for (final brightness in Brightness.values) {
    final dark = brightness == Brightness.dark;
    final cinnabar = Color(dark ? 0xffedb09a : 0xffaa351f);
    final jade = Color(dark ? 0xff7ed4c7 : 0xff1a7a64);
    final cobalt = Color(dark ? 0xff9bc4ff : 0xff2858af);
    final roles = {
      BrandColor.cinnabar: [cinnabar, jade, cobalt],
      BrandColor.jade: [jade, cobalt, cinnabar],
      BrandColor.cobalt: [cobalt, cinnabar, jade],
    };
    for (final brand in BrandColor.values) {
      final theme = AppTheme.forBrightness(brightness, brand);
      final palette = theme.extension<HomePalette>()!;
      final scheme = theme.colorScheme;
      test('complete ordered brand rotation $brightness $brand', () {
        expect([
          scheme.primary,
          scheme.secondary,
          scheme.tertiary,
        ], roles[brand]);
        expect(palette.brand, brand);
        final baseline = AppTheme.forBrightness(brightness).colorScheme;
        expect(scheme.surface, baseline.surface);
        expect(scheme.surfaceContainer, baseline.surfaceContainer);
        expect(scheme.onSurface, baseline.onSurface);
        expect(scheme.error, baseline.error);
        expect(theme.iconTheme.color, scheme.onSurface);
        expect(theme.appBarTheme.iconTheme!.color, scheme.onSurface);
        expect(theme.popupMenuTheme.iconColor, scheme.onSurface);
        expect(theme.iconButtonTheme.style, isNull);
        expect(theme.menuButtonTheme.style, isNull);
      });
      test(
        'all foreground pairs meet normal-text contrast $brightness $brand',
        () {
          for (final (ink, background) in [
            (scheme.primary, scheme.surface),
            (scheme.secondary, scheme.surface),
            (scheme.tertiary, scheme.surface),
            (scheme.onPrimary, scheme.primary),
            (scheme.onSecondary, scheme.secondary),
            (scheme.onTertiary, scheme.tertiary),
            (scheme.onPrimaryContainer, scheme.primaryContainer),
            (scheme.onSecondaryContainer, scheme.secondaryContainer),
            (scheme.onTertiaryContainer, scheme.tertiaryContainer),
            (scheme.onPrimaryFixed, scheme.primaryFixed),
            (scheme.onPrimaryFixedVariant, scheme.primaryFixedDim),
            (scheme.onSecondaryFixed, scheme.secondaryFixed),
            (scheme.onSecondaryFixedVariant, scheme.secondaryFixedDim),
            (scheme.onTertiaryFixed, scheme.tertiaryFixed),
            (scheme.onTertiaryFixedVariant, scheme.tertiaryFixedDim),
            (scheme.onError, scheme.error),
            (scheme.onErrorContainer, scheme.errorContainer),
            (scheme.onInverseSurface, scheme.inverseSurface),
            (scheme.inversePrimary, scheme.inverseSurface),
          ]) {
            expect(
              contrast(ink, background),
              greaterThanOrEqualTo(4.5),
              reason: '$ink on $background',
            );
          }
          final baseline = HomePalette(dark);
          for (final pair in [
            (palette.syncAction, baseline.syncAction),
            (palette.editAction, baseline.editAction),
            (palette.moreAction, baseline.moreAction),
            (palette.remoteSource, baseline.remoteSource),
            (palette.localSource, baseline.localSource),
          ]) {
            expect(pair.$1, pair.$2);
            expect(
              contrast(pair.$1, scheme.surface),
              greaterThanOrEqualTo(4.5),
            );
          }
        },
      );
      testWidgets(
        'explicit actions and SDK disabled colors $brightness $brand',
        (tester) async {
          final actionStyle = ButtonStyle(
            iconColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? null
                  : palette.editAction,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Column(
                  children: [
                    IconButton(
                      onPressed: () {},
                      style: IconButton.styleFrom(
                        foregroundColor: palette.syncAction,
                      ),
                      icon: const Icon(Icons.sync),
                    ),
                    IconButton(
                      onPressed: null,
                      style: IconButton.styleFrom(
                        foregroundColor: palette.error,
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                    MenuItemButton(
                      style: actionStyle,
                      onPressed: () {},
                      leadingIcon: const Icon(Icons.edit),
                      child: const Text('Edit'),
                    ),
                    MenuItemButton(
                      style: actionStyle,
                      leadingIcon: const Icon(Icons.block),
                      child: const Text('Unavailable'),
                    ),
                    const TextField(
                      decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            IconTheme.of(tester.element(find.byIcon(Icons.sync))).color,
            palette.syncAction,
          );
          expect(
            IconTheme.of(tester.element(find.byIcon(Icons.edit))).color,
            palette.editAction,
          );
          for (final data in [Icons.delete_outline, Icons.block]) {
            expect(
              IconTheme.of(tester.element(find.byIcon(data))).color,
              scheme.onSurface.withAlpha(97),
            );
          }
          expect(
            IconTheme.of(tester.element(find.byIcon(Icons.search))).color,
            isNot(scheme.primary),
          );
          expect(
            DefaultTextStyle.of(tester.element(find.text('Edit'))).style.color,
            scheme.onSurface,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
    final theme = AppTheme.forBrightness(brightness);
    final palette = HomePalette(dark);
    test('neutral surfaces and stable semantic colors $brightness', () {
      final colors = theme.colorScheme;
      for (final surface in [
        colors.surface,
        colors.surfaceContainerLow,
        colors.surfaceContainer,
        colors.surfaceContainerHigh,
        colors.surfaceContainerHighest,
      ]) {
        expect([
          palette.background,
          palette.surface,
          palette.soft,
        ], contains(surface));
        for (final ink in [colors.onSurface, colors.onSurfaceVariant]) {
          expect(contrast(ink, surface), greaterThanOrEqualTo(4.5));
        }
      }
      for (final ink in [
        ModePalette(dark).rule,
        ModePalette(dark).global,
        ModePalette(dark).direct,
        ConnectionPalette(dark).active,
        ConnectionPalette(dark).warning,
        palette.error,
      ]) {
        expect(contrast(ink, palette.surface), greaterThanOrEqualTo(4.5));
      }
      for (final mark in [
        ConnectionPalette(dark).uploadPlot,
        ConnectionPalette(dark).downloadPlot,
      ]) {
        expect(contrast(mark, palette.surface), greaterThanOrEqualTo(3));
      }
      expect(colors.surfaceTint, Colors.transparent);
    });
    testWidgets('rendered menu and sheet retain neutral surfaces $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  PopupMenuButton<int>(
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 1, child: Text('条件')),
                    ],
                  ),
                  TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      builder: (_) =>
                          const SizedBox(height: 100, child: Text('模式')),
                    ),
                    child: const Text('展开'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<int>));
      await tester.pumpAndSettle();
      final menu = tester
          .widgetList<Material>(
            find.ancestor(of: find.text('条件'), matching: find.byType(Material)),
          )
          .first;
      expect(menu.color, palette.surface);
      expect(menu.surfaceTintColor, Colors.transparent);
      Navigator.of(tester.element(find.text('条件'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      final sheet = tester
          .widgetList<Material>(
            find.ancestor(of: find.text('模式'), matching: find.byType(Material)),
          )
          .first;
      expect(sheet.color, palette.surface);
      expect(sheet.surfaceTintColor, Colors.transparent);
      expect(tester.takeException(), isNull);
    });
  }
}
