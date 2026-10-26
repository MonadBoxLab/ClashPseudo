import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

enum AppTask { overview, strategies, connections, configurations, settings }

class AppTaskScope extends InheritedWidget {
  const AppTaskScope({
    super.key,
    required this.open,
    required this.supported,
    required this.task,
    required this.owner,
    required super.child,
  });

  final ValueChanged<AppTask> open;
  final bool supported;
  final AppTask task;
  final Object owner;

  static AppTaskScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppTaskScope>();

  @override
  bool updateShouldNotify(AppTaskScope oldWidget) =>
      open != oldWidget.open ||
      supported != oldWidget.supported ||
      task != oldWidget.task ||
      !identical(owner, oldWidget.owner);
}

class FocusedPageRoute<T> extends MaterialPageRoute<T> {
  FocusedPageRoute({required super.builder, super.settings});
}

class WorkspaceLayout {
  const WorkspaceLayout({
    required this.tasks,
    required this.rail,
    required this.navigationWidth,
    required this.navigationHeight,
    required this.supported,
    this.destinationPadding = 0,
  });

  static const minimumContentWidth = 280.0;
  static const minimumContentHeight = 280.0;
  static const minimumBodyHeight = 160.0;

  final List<AppTask> tasks;
  final bool rail;
  final double navigationWidth;
  final double navigationHeight;
  final bool supported;
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

  factory WorkspaceLayout.of(BuildContext context, Size size) {
    return WorkspaceLayout.resolve(
      size: size,
      padding: MediaQuery.paddingOf(context),
      viewInsets: MediaQuery.viewInsetsOf(context),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      labelStyle: Theme.of(context).textTheme.labelMedium!,
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
    Size measure(String label, double maxWidth) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: textDirection,
        textScaler: textScaler,
      )..layout(maxWidth: maxWidth);
      final result = painter.size;
      painter.dispose();
      return result;
    }

    final lineHeight = measure('Ag', double.infinity).height;
    for (final rail in width >= 600 ? [true, false] : [false]) {
      for (final count in [5, 4, 3]) {
        final tasks = destinations(count);
        if (rail) {
          final labelSizes = [
            for (final task in tasks) measure(labels[task]!, double.infinity),
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
              supported: true,
            );
          }
        } else {
          final slotWidth = width / count;
          if (slotWidth < 64) continue;
          final labelSizes = [
            for (final task in tasks) measure(labels[task]!, slotWidth - 16),
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
              supported: true,
            );
          }
        }
      }
    }
    return const WorkspaceLayout(
      tasks: [AppTask.overview, AppTask.strategies, AppTask.settings],
      rail: false,
      navigationWidth: 0,
      navigationHeight: 0,
      supported: false,
    );
  }
}
