import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../navigation/task_activity.dart';
import '../../theme/app_theme.dart';
import '../../components/feedback/operation_feedback.dart';
import '../../components/feedback/operation_notice.dart';
import '../../../l10n/app_localizations.dart';
import '../../../model/messages.dart';
import '../../components/feedback/confirm_action.dart';
import '../traffic_controller.dart';
import 'power_ripples.dart';
import 'session_uptime.dart';
import 'status_text.dart';
import '../../locale/message_text.dart';
import '../../locale/model_text.dart';

class StatusHero extends StatelessWidget {
  const StatusHero({
    super.key,
    required this.controller,
    required this.runningProgress,
    required this.visible,
    required this.onManage,
    required this.onImport,
    required this.onMode,
    this.traffic,
    this.compact = false,
    this.contentWidth,
    this.isCurrent,
    this.onRecovery,
    this.isCurrentWithPopup,
  });

  final AppController controller;
  final TrafficController? traffic;
  final double runningProgress;
  final bool visible;
  final VoidCallback onManage;
  final VoidCallback onImport;
  final VoidCallback onMode;
  final VoidCallback? onRecovery;
  final bool compact;
  final double? contentWidth;
  final bool Function()? isCurrent;
  final bool Function(ModalRoute<dynamic>)? isCurrentWithPopup;

  Future<void> _openVpnSettings(
    BuildContext context,
    bool Function() current,
    bool Function(ModalRoute<dynamic>) currentWithPopup,
  ) async {
    if (!current()) return;
    ModalRoute<dynamic>? popup;
    final confirmed = await confirmAction(
      context,
      onRoute: (route) => popup = route,
      isCurrent: () => popup == null ? current() : currentWithPopup(popup!),
      title: (strings) => strings.alwaysOnTitle,
      message: (strings) => strings.alwaysOnNotice,
      confirmLabel: (strings) => strings.openVpnSettings,
    );
    if (!confirmed || !context.mounted || !current()) return;
    if (controller.state.alwaysOn != true ||
        !(controller.state.running || controller.canStopBackground)) {
      return;
    }
    try {
      await controller.platform.openVpnSettings();
    } catch (error) {
      if (!context.mounted || !current()) return;
      showLocalizedOperationNotice(
        context,
        (strings) => strings.alwaysOnOpenFailed,
        technicalDetail: (_) => error.toString(),
        isCurrent: current,
        isCurrentWithPopup: currentWithPopup,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final strings = AppLocalizations.of(context);
    final palette = HomePalette.of(context);
    final selected = controller.collection.selected;
    final actual = controller.collection.find(state.configId);
    final running = state.running;
    final current = controller.configsCurrent;
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    final route = ModalRoute.of(context);
    final epoch = controller.storageEpoch;
    bool eligible({ModalRoute<dynamic>? ownedPopup}) =>
        context.mounted &&
        visible &&
        controller.foreground &&
        epoch == controller.storageEpoch &&
        AppTaskActivity.isActive(context, ownedPopup: ownedPopup) &&
        AppTaskActivity.routeIsActive(route, ownedPopup: ownedPopup) &&
        (ownedPopup == null
            ? (isCurrent?.call() ?? true)
            : (isCurrentWithPopup?.call(ownedPopup) ?? true));
    final issueSource = (state.generation, state.core.identity);
    final issueErrors = (
      controller.errorMessage,
      state.modeErrorMessage,
      state.errorMessage,
      state.resultMessageDescription,
      traffic?.errorMessage,
    );
    bool currentIssue({ModalRoute<dynamic>? ownedPopup}) =>
        eligible(ownedPopup: ownedPopup) &&
        issueSource ==
            (controller.state.generation, controller.state.core.identity) &&
        issueErrors ==
            (
              controller.errorMessage,
              controller.state.modeErrorMessage,
              controller.state.errorMessage,
              controller.state.resultMessageDescription,
              traffic?.errorMessage,
            );
    final title = controller.loading
        ? strings.statusLoading
        : controller.dispatching
        ? strings.statusSubmitting
        : state.operationMessage != null
        ? strings.statusProcessing
        : switch (state.phase) {
            'RUNNING' => strings.stateRunning,
            'STOPPED' => strings.stateStopped,
            'STARTING' => strings.stateStarting,
            'STOPPING' => strings.stateStopping,
            _ => strings.stateUnknown,
          };
    final issues =
        [
              controller.errorMessage,
              state.modeErrorMessage,
              state.errorMessage,
              if (!state.resultSuccess) state.resultMessageDescription,
              if (running && traffic?.active == true) traffic?.errorMessage,
            ]
            .whereType<AppMessage>()
            .where((message) => message.resolve(strings).trim().isNotEmpty)
            .toList();
    final subtitle = state.operationMessage != null
        ? switch (state.operationMessage!.id) {
            'stageStopping' => strings.stageStopping,
            'stageStartingTunnel' => strings.stageStartingTunnel,
            'stageWaitingVpnAuth' => strings.stageWaitingVpnAuth,
            'stageUpdatingConfig' => strings.stageUpdatingConfig,
            _ => strings.statusProcessing,
          }
        : (state.recoveryRequired || issues.isNotEmpty
              ? strings.statusIssue
              : controller.loading
              ? strings.statusPending
              : controller.platformError != null
              ? strings.statusAutoRetry
              : !state.confirmed
              ? state.phase == 'UNKNOWN'
                    ? strings.statusPlatformUnconfirmed
                    : strings.statusWaiting
              : !current
              ? controller.configError != null
                    ? strings.statusConfigFailed
                    : strings.statusConfigLoading
              : running
              ? ''
              : selected == null
              ? strings.statusImportPrompt
              : strings.statusReady);
    final configName = !current
        ? controller.configError != null
              ? strings.identityUnconfirmed
              : strings.identityLoading
        : running
        ? actual?.name ?? strings.identityUnconfirmed
        : selected?.name ?? strings.identityNoConfig;
    final identity = !current
        ? ''
        : running && state.configId != selected?.id
        ? strings.identitySelected(selected?.name ?? strings.identityNone)
        : running && actual != null && state.revision != actual.revision
        ? strings.identityRevisionDiff
        : !controller.loading && state.phase == 'UNKNOWN' && selected != null
        ? strings.identitySelectedUnconfirmed
        : '';
    final systemManagedStop =
        state.alwaysOn == true && (running || controller.canStopBackground);
    final label = systemManagedStop
        ? strings.openVpnSettings
        : controller.canStopBackground
        ? strings.actionStop
        : controller.loading || state.phase == 'UNKNOWN'
        ? strings.actionUnavailable
        : controller.dispatching || state.operationMessage != null
        ? strings.actionBusy
        : state.phase == 'STARTING'
        ? strings.actionStarting
        : state.phase == 'STOPPING'
        ? strings.actionStopping
        : running
        ? strings.actionStop
        : strings.actionStart;
    final control = palette.controlColors(running);
    final background = palette.controlBackground(runningProgress);
    final ink = palette.legibleInk(
      background,
      preferred: running ? palette.heroInk : palette.ink,
    );
    final face = control.face;
    final buttonInk = control.glyph;
    final enabled = systemManagedStop || controller.canToggle;
    final showImport = current && selected == null && !running;
    final emitting =
        running &&
        !(controller.dispatching &&
            controller.lastCommand?['action'] == 'stop');

    final readingWidth = math.max(
      1.0,
      (contentWidth ?? MediaQuery.sizeOf(context).width) -
          MediaQuery.paddingOf(context).horizontal -
          48,
    );
    double lineHeight(
      String text,
      double fontSize, {
      FontWeight? weight,
      bool wrap = false,
    }) {
      final style = DefaultTextStyle.of(context).style.merge(
        TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: wrap ? readingWidth : double.infinity);
      final height = painter.height;
      painter.dispose();
      return height;
    }

    const diameter = PowerRipples.buttonDiameter;
    final subtitleHeight = lineHeight(subtitle, 12);
    final statusContentHeight =
        lineHeight(title, 16, weight: FontWeight.w500) + 6 + subtitleHeight;
    final statusHeight = statusContentHeight
        .clamp(48.0, double.infinity)
        .toDouble();
    // Use the caption gap for the hit target and retain the power anchor.
    final captionGap = compact ? 12.0 : 22.0;
    final statusGap = (captionGap - (statusHeight - statusContentHeight))
        .clamp(0.0, captionGap)
        .toDouble();
    final detailsHeight = 10 + lineHeight(label, 12) + statusGap + statusHeight;
    return _HeroGeometry(
      detailsHeight: detailsHeight,
      revision: (title, subtitle, label, readingWidth),
      reduced: reduced,
      builder: (detailsHeight) => ClipRect(
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, compact ? 12 : 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.data_object_rounded, size: 20, color: ink),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Clash Pseudo',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: compact ? 8 : 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: showImport
                            ? (controller.canEdit ? onImport : null)
                            : onManage,
                        style: TextButton.styleFrom(
                          foregroundColor: ink,
                          padding: EdgeInsets.zero,
                          alignment: Alignment.centerLeft,
                          minimumSize: const Size(0, 48),
                        ).copyWith(animationDuration: Duration.zero),
                        child: Text(
                          showImport ? strings.importConfig : configName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ),
                    Flexible(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton(
                          onPressed: onManage,
                          style: TextButton.styleFrom(
                            foregroundColor: ink,
                            minimumSize: const Size(0, 48),
                          ).copyWith(animationDuration: Duration.zero),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  strings.configManage,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.chevron_right, size: 16),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                StatusText(
                  identity,
                  key: const ValueKey('config-identity'),
                  emptyText: strings.identitySelectedUnconfirmed,
                  style: TextStyle(color: ink, fontSize: 12),
                  textAlign: TextAlign.start,
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: compact ? 8 : 28),
                    // Preferred height supplies the sliver minimum; Flex distributes
                    // additional room around the LayoutBuilder.
                    child: SizedBox(
                      height: diameter + detailsHeight,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final radius = diameter / 2;
                          final lastCenter =
                              constraints.maxHeight - radius - detailsHeight;
                          final center = (constraints.maxHeight / 2).clamp(
                            radius,
                            lastCenter < radius ? radius : lastCenter,
                          );
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _HeroPosition(
                                left: (constraints.maxWidth - diameter) / 2,
                                top: center - radius,
                                width: diameter,
                                height: diameter,
                                child: TweenAnimationBuilder<Color?>(
                                  tween: ColorTween(
                                    end: running
                                        ? palette.heroInk
                                        : palette.accent,
                                  ),
                                  duration: reduced
                                      ? Duration.zero
                                      : const Duration(milliseconds: 320),
                                  builder: (context, color, child) =>
                                      PowerRipples(
                                        emitting: emitting,
                                        visible: visible,
                                        color: color!,
                                        child: child!,
                                      ),
                                  child: FilledButton(
                                    key: const ValueKey('power-button'),
                                    onPressed: enabled
                                        ? () {
                                            if (!eligible()) return;
                                            if (systemManagedStop) {
                                              _openVpnSettings(
                                                context,
                                                () => eligible(),
                                                (popup) =>
                                                    eligible(ownedPopup: popup),
                                              );
                                            } else if (controller.canToggle) {
                                              controller.submit({
                                                'action':
                                                    controller.state.running ||
                                                        controller
                                                            .canStopBackground
                                                    ? 'stop'
                                                    : 'start',
                                              });
                                            }
                                          }
                                        : null,
                                    style:
                                        FilledButton.styleFrom(
                                          fixedSize: const Size.square(
                                            diameter,
                                          ),
                                          shape: const CircleBorder(),
                                          padding: EdgeInsets.zero,
                                          backgroundColor: face,
                                          foregroundColor: buttonInk,
                                          disabledBackgroundColor: face,
                                          disabledForegroundColor: buttonInk,
                                        ).copyWith(
                                          animationDuration: Duration.zero,
                                        ),
                                    child: Semantics(
                                      label: label,
                                      child: ExcludeSemantics(
                                        child: controller.busy && !reduced
                                            ? SizedBox.square(
                                                dimension: 26,
                                                child:
                                                    CircularProgressIndicator(
                                                      color: buttonInk,
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.power_settings_new,
                                                size: 32,
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              _HeroPosition(
                                left: 0,
                                right: 0,
                                top: center + radius,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(height: 10),
                                    StatusText(
                                      label,
                                      style: TextStyle(
                                        color: ink,
                                        fontSize: 12,
                                      ),
                                    ),
                                    SizedBox(height: statusGap),
                                    SessionUptime(
                                      snapshot: state,
                                      active: visible && controller.foreground,
                                      showUptime:
                                          running &&
                                          !controller.loading &&
                                          !controller.dispatching &&
                                          state.operationMessage == null &&
                                          issues.isEmpty &&
                                          !state.recoveryRequired,
                                      title: title,
                                      subtitle: subtitle,
                                      color: ink,
                                      refresh: controller.refresh,
                                      onIssue:
                                          state.recoveryRequired &&
                                              onRecovery != null
                                          ? () {
                                              if (currentIssue() &&
                                                  controller
                                                      .state
                                                      .recoveryRequired) {
                                                onRecovery!();
                                              }
                                            }
                                          : issues.isEmpty
                                          ? null
                                          : () {
                                              if (!currentIssue()) return;
                                              showLocalizedOperationMessage(
                                                context,
                                                (strings) => issues
                                                    .map(
                                                      (message) => message
                                                          .summary(strings),
                                                    )
                                                    .where(
                                                      (text) => text
                                                          .trim()
                                                          .isNotEmpty,
                                                    )
                                                    .toSet()
                                                    .join('\n\n'),
                                                technicalDetail: (strings) {
                                                  final details = issues
                                                      .map(
                                                        (message) => message
                                                            .technicalDetail(
                                                              strings,
                                                            ),
                                                      )
                                                      .whereType<String>()
                                                      .where(
                                                        (text) =>
                                                            text.isNotEmpty,
                                                      )
                                                      .toSet();
                                                  return details.isEmpty
                                                      ? null
                                                      : details.join('\n\n');
                                                },
                                                title: (strings) =>
                                                    strings.tunnelStatus,
                                                isCurrent: () => currentIssue(),
                                                isCurrentWithPopup: (popup) =>
                                                    currentIssue(
                                                      ownedPopup: popup,
                                                    ),
                                              );
                                            },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    key: const ValueKey('mode-trigger'),
                    onPressed: controller.canChangeMode ? onMode : null,
                    style: TextButton.styleFrom(
                      foregroundColor: ink,
                      disabledForegroundColor: ink.withValues(alpha: .65),
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(48, 48),
                      alignment: Alignment.centerLeft,
                    ).copyWith(animationDuration: Duration.zero),
                    child: Row(
                      children: [
                        const Icon(Icons.expand_more, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: StatusText(
                            controller.loading || !state.confirmed
                                ? strings.modeUnconfirmed
                                : running
                                ? state.mode == null
                                      ? strings.modeRunningUnconfirmed
                                      : strings.modeRunning(
                                          state.mode!.label(strings),
                                        )
                                : current
                                ? controller.collection.mode == null
                                      ? strings.modeFollowConfigIdle
                                      : strings.modeSavedIdle(
                                          controller.collection.mode!.label(
                                            strings,
                                          ),
                                        )
                                : strings.modeSavedUnconfirmed,
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.start,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keep the outgoing prose's reading space until its text transition finishes.
class _HeroGeometry extends StatefulWidget {
  const _HeroGeometry({
    required this.detailsHeight,
    required this.revision,
    required this.reduced,
    required this.builder,
  });

  final double detailsHeight;
  final Object revision;
  final bool reduced;
  final Widget Function(double detailsHeight) builder;

  @override
  State<_HeroGeometry> createState() => _HeroGeometryState();
}

class _HeroGeometryState extends State<_HeroGeometry>
    with SingleTickerProviderStateMixin {
  late double _retainedHeight = widget.detailsHeight;
  late final _transition =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 280),
        value: 1,
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed &&
            _retainedHeight != widget.detailsHeight) {
          setState(() => _retainedHeight = widget.detailsHeight);
        }
      });

  @override
  void didUpdateWidget(_HeroGeometry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduced) {
      _transition.stop();
      _retainedHeight = widget.detailsHeight;
    } else if (oldWidget.revision != widget.revision ||
        oldWidget.detailsHeight != widget.detailsHeight) {
      _retainedHeight = math.max(_retainedHeight, widget.detailsHeight);
      if (_retainedHeight > widget.detailsHeight) {
        _transition.forward(from: 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(_retainedHeight);

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }
}

class _HeroPosition extends StatefulWidget {
  const _HeroPosition({
    this.left,
    this.right,
    required this.top,
    this.width,
    this.height,
    required this.child,
  });

  final double? left;
  final double? right;
  final double top;
  final double? width;
  final double? height;
  final Widget child;

  @override
  State<_HeroPosition> createState() => _HeroPositionState();
}

class _HeroPositionState extends State<_HeroPosition> {
  final _content = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _content, child: widget.child);
    // A duration-only update does not finish an implicit animation.
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      return Positioned(
        left: widget.left,
        right: widget.right,
        top: widget.top,
        width: widget.width,
        height: widget.height,
        child: child,
      );
    }
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      left: widget.left,
      right: widget.right,
      top: widget.top,
      width: widget.width,
      height: widget.height,
      child: child,
    );
  }
}
