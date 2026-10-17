import 'package:clash_pseudo/app/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  for (final dark in [false, true]) {
    final theme = dark ? AppTheme.dark : AppTheme.light;
    final palette = HomePalette(dark);
    test('neutral surfaces and readable semantic colors dark=$dark', () {
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
        palette.accent,
        palette.jade,
        palette.cobalt,
        ModePalette(dark).rule,
        ModePalette(dark).global,
        ModePalette(dark).direct,
        ConnectionPalette(dark).active,
        ConnectionPalette(dark).warning,
        palette.error,
      ]) {
        expect(contrast(ink, palette.surface), greaterThanOrEqualTo(4.5));
      }
      expect(colors.surfaceTint, Colors.transparent);
    });

    testWidgets('rendered menu and sheet use neutral surfaces dark=$dark', (
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
      final menuMaterial = tester
          .widgetList<Material>(
            find.ancestor(of: find.text('条件'), matching: find.byType(Material)),
          )
          .first;
      expect(menuMaterial.color, palette.surface);
      expect(menuMaterial.surfaceTintColor, Colors.transparent);
      Navigator.of(tester.element(find.text('条件'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      final sheetMaterial = tester
          .widgetList<Material>(
            find.ancestor(of: find.text('模式'), matching: find.byType(Material)),
          )
          .first;
      expect(sheetMaterial.color, palette.surface);
      expect(sheetMaterial.surfaceTintColor, Colors.transparent);
      expect(tester.takeException(), isNull);
    });
  }
}
