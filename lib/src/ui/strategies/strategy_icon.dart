import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'strategy_image.dart';

class StrategyIcon extends StatelessWidget {
  const StrategyIcon({
    super.key,
    required this.type,
    this.source = '',
    this.size = 30,
  });
  final String type;
  final String source;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final palette = HomePalette(dark);
    final mode = ModePalette(dark);
    final (icon, color) = switch (type) {
      'select' => (Icons.alt_route_rounded, palette.accent),
      'url-test' => (Icons.speed_rounded, palette.jade),
      'fallback' => (Icons.swap_horiz_rounded, palette.cobalt),
      'load-balance' => (Icons.account_tree_rounded, mode.global),
      'Direct' => (Icons.arrow_forward_rounded, mode.direct),
      'Reject' => (Icons.block_rounded, palette.error),
      _ => (Icons.alt_route_rounded, palette.cobalt),
    };
    final fallback = Icon(icon, size: size * .9, color: color);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: source.isEmpty
            ? fallback
            : StrategyImage(source: source, fallback: fallback),
      ),
    );
  }
}
