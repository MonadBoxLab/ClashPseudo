import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

class ResultPageBar extends StatelessWidget {
  const ResultPageBar({
    super.key,
    required this.label,
    this.onPrevious,
    this.onNext,
  });

  final String label;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final style = Theme.of(context).textTheme.bodyMedium!;
    final lineHeight =
        MediaQuery.textScalerOf(context).scale(style.fontSize!) *
        (style.height ?? 1.5);
    return SafeArea(
      top: false,
      child: Row(
        children: [
          IconButton(
            tooltip: strings.previousPage,
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: SizedBox(
              height: math.max(48, lineHeight * 2),
              child: Center(
                child: SingleChildScrollView(
                  child: Text(
                    label,
                    key: const ValueKey('result-page-range'),
                    textAlign: TextAlign.center,
                    style: style,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: strings.nextPage,
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
