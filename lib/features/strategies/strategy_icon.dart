import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
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
    final (icon, color, badge) = switch (type) {
      'select' => (
        Icons.alt_route_rounded,
        palette.accent,
        Icons.touch_app_rounded,
      ),
      'url-test' => (Icons.speed_rounded, palette.jade, Icons.bolt_rounded),
      'fallback' => (
        Icons.swap_horiz_rounded,
        palette.cobalt,
        Icons.shield_outlined,
      ),
      'load-balance' => (
        Icons.account_tree_rounded,
        mode.global,
        Icons.balance_rounded,
      ),
      'Direct' => (Icons.arrow_forward_rounded, mode.direct, null),
      'Reject' => (Icons.block_rounded, palette.error, null),
      _ => (Icons.alt_route_rounded, palette.muted, null),
    };
    final fallback = Stack(
      fit: StackFit.expand,
      children: [
        Icon(icon, size: size * .9, color: color),
        if (badge != null)
          Positioned(
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: palette.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(
                badge,
                size: size * .38,
                color: type == 'select' ? palette.cobalt : palette.ink,
              ),
            ),
          ),
      ],
    );
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
