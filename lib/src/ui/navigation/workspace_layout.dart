import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'task_activity.dart';

class WorkspaceLayout {
  const WorkspaceLayout({
    required this.tasks,
    required this.rail,
    required this.navigationWidth,
    required this.navigationHeight,
    this.compact = false,
    this.destinationPadding = 0,
  });

  static const minimumContentWidth = 280.0;
  static const minimumContentHeight = 280.0;
  static const minimumBodyHeight = 160.0;

  final List<AppTask> tasks;
  final bool rail;
  final double navigationWidth;
  final double navigationHeight;
  final bool compact;
  final double destinationPadding;

  static List<AppTask> destinations(int count) => [
    AppTask.overview,
    AppTask.strategies,
    if (count >= 4) AppTask.connections,
    if (count >= 5) AppTask.configurations,
    AppTask.settings,
  ];

  static Map<AppTask, String> navigationLabels(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return {
      AppTask.overview: strings.overview,
      AppTask.strategies: strings.strategies,
      AppTask.connections: strings.connectionsNavigation,
      AppTask.configurations: strings.configurationsNavigation,
      AppTask.settings: strings.settings,
    };
  }

  static TextStyle navigationLabelStyle(
    BuildContext context, {
    required bool rail,
    required bool selected,
  }) {
    final theme = Theme.of(context);
    final override = rail
        ? (selected
              ? theme.navigationRailTheme.selectedLabelTextStyle
              : theme.navigationRailTheme.unselectedLabelTextStyle)
        : theme.navigationBarTheme.labelTextStyle?.resolve(
            selected ? {WidgetState.selected} : {},
          );
    return theme.textTheme.labelMedium!.merge(override);
  }

  factory WorkspaceLayout.of(BuildContext context, Size size) {
    return WorkspaceLayout.resolve(
      size: size,
      padding: MediaQuery.paddingOf(context),
      viewInsets: MediaQuery.viewInsetsOf(context),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      labelStyle: Theme.of(context).textTheme.labelMedium!,
      railLabelStyles: [
        for (final selected in [false, true])
          navigationLabelStyle(context, rail: true, selected: selected),
      ],
      barLabelStyles: [
        for (final selected in [false, true])
          navigationLabelStyle(context, rail: false, selected: selected),
      ],
      labels: navigationLabels(context),
    );
  }

  factory WorkspaceLayout.resolve({
    required Size size,
    required EdgeInsets padding,
    EdgeInsets viewInsets = EdgeInsets.zero,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required TextStyle labelStyle,
    List<TextStyle>? railLabelStyles,
    List<TextStyle>? barLabelStyles,
    required Map<AppTask, String> labels,
  }) {
    final width = math.max(
      0.0,
      size.width - padding.horizontal - viewInsets.horizontal,
    );
    final height = math.max(
      0.0,
      size.height - padding.vertical - viewInsets.vertical,
    );
    Size measure(String label, double maxWidth, List<TextStyle>? styles) {
      var width = 0.0;
      var height = 0.0;
      for (final style in styles ?? [labelStyle]) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: textDirection,
          textScaler: textScaler,
        )..layout(maxWidth: maxWidth);
        width = math.max(width, painter.width);
        height = math.max(height, painter.height);
        painter.dispose();
      }
      return Size(width, height);
    }

    final lineHeight = measure('Ag', double.infinity, barLabelStyles).height;
    for (final rail in width >= 600 ? [true, false] : [false]) {
      for (final count in [5, 4, 3]) {
        final tasks = destinations(count);
        if (rail) {
          final labelSizes = [
            for (final task in tasks)
              measure(labels[task]!, double.infinity, railLabelStyles),
          ];
          final railWidth = math.max(
            80.0,
            labelSizes.map((s) => s.width + 32).reduce(math.max),
          );
          final railHeight = labelSizes.fold<double>(
            16,
            (total, label) => total + math.max(64, 32 + 4 + label.height + 12),
          );
          if (width - railWidth >= minimumContentWidth &&
              height >= railHeight &&
              height >= minimumContentHeight) {
            return WorkspaceLayout(
              tasks: tasks,
              rail: true,
              navigationWidth: railWidth,
              navigationHeight: height,
              destinationPadding: ((height - railHeight) / (count * 4)).clamp(
                0.0,
                20.0,
              ),
            );
          }
        } else {
          final slotWidth = width / count;
          if (slotWidth < 64) continue;
          final labelSizes = [
            for (final task in tasks)
              measure(labels[task]!, slotWidth - 16, barLabelStyles),
          ];
          final labelHeight = labelSizes.map((s) => s.height).reduce(math.max);
          final barHeight = math.max(80.0, 32 + 4 + labelHeight + 24);
          if (width >= minimumContentWidth &&
              height >= minimumContentHeight &&
              height - barHeight >= minimumBodyHeight &&
              (count == 3 ||
                  labelSizes.every((s) => s.height <= lineHeight + .01))) {
            return WorkspaceLayout(
              tasks: tasks,
              rail: false,
              navigationWidth: width,
              navigationHeight: barHeight,
            );
          }
        }
      }
    }
    return WorkspaceLayout(
      tasks: const [AppTask.overview, AppTask.strategies, AppTask.settings],
      rail: false,
      navigationWidth: math.max(width, 192),
      navigationHeight: 64,
      compact: true,
    );
  }
}
