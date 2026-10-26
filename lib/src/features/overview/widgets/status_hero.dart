import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../../../app/app_theme.dart';
import '../../../app/widgets/operation_feedback.dart';
import '../../../l10n/app_localizations.dart';
import '../../../l10n/messages.dart';
import '../../configs/widgets/confirm_action.dart';
import '../traffic_controller.dart';
import 'power_ripples.dart';
import 'session_uptime.dart';
import 'status_text.dart';

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
  });

  final AppController controller;
  final TrafficController? traffic;
  final double runningProgress;
  final bool visible;
  final VoidCallback onManage;
  final VoidCallback onImport;
  final VoidCallback onMode;

  Future<void> _openVpnSettings(BuildContext context) async {
    final confirmed = await confirmAction(
      context,
      title: (strings) => strings.alwaysOnTitle,
      message: (strings) => strings.alwaysOnNotice,
      confirmLabel: (strings) => strings.openVpnSettings,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await controller.platform.openVpnSettings();
    } catch (_) {
      if (!context.mounted) return;
      showLocalizedOperationMessage(
        context,
        (strings) => strings.alwaysOnOpenFailed,
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
    final reduced = MediaQuery.disableAnimationsOf(context);
    final title = controller.loading
        ? strings.statusLoading
        : controller.dispatching
        ? strings.statusSubmitting
        : state.operation != null
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
    final subtitle =
        state.operation ??
        (issues.isNotEmpty
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
        : controller.dispatching || state.operation != null
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
    final enabled = controller.canToggle;
    final showImport = current && selected == null && !running;
    final emitting =
        running &&
        !(controller.dispatching &&
            controller.lastCommand?['action'] == 'stop');

    double lineHeight(String text, double fontSize, {FontWeight? weight}) {
      final style = DefaultTextStyle.of(context).style
          .merge(TextStyle(fontSize: fontSize, fontWeight: weight));
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    const diameter = PowerRipples.buttonDiameter;
    final statusContentHeight =
        lineHeight(title, 16, weight: FontWeight.w500) +
        6 +
        lineHeight(subtitle.isEmpty ? strings.statusReady : subtitle, 12);
    final statusHeight = statusContentHeight
        .clamp(48.0, double.infinity)
        .toDouble();
    // Use the caption gap for the hit target and retain the power anchor.
    final statusGap = (22 - (statusHeight - statusContentHeight))
        .clamp(0.0, 22.0)
        .toDouble();
    final detailsHeight = 10 + lineHeight(label, 12) + statusGap + statusHeight;
    return ClipRect(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
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
              const SizedBox(height: 20),
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
                  padding: const EdgeInsets.symmetric(vertical: 28),
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
                            Positioned(
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
                                      ? systemManagedStop
                                            ? () => _openVpnSettings(context)
                                            : () => controller.submit({
                                                'action':
                                                    running ||
                                                        controller
                                                            .canStopBackground
                                                    ? 'stop'
                                                    : 'start',
                                              })
                                      : null,
                                  style: FilledButton.styleFrom(
                                    fixedSize: const Size.square(diameter),
                                    shape: const CircleBorder(),
                                    padding: EdgeInsets.zero,
                                    backgroundColor: face,
                                    foregroundColor: buttonInk,
                                    disabledBackgroundColor: face,
                                    disabledForegroundColor: buttonInk,
                                  ).copyWith(animationDuration: Duration.zero),
                                  child: Semantics(
                                    label: label,
                                    child: ExcludeSemantics(
                                      child: controller.busy && !reduced
                                          ? SizedBox.square(
                                              dimension: 26,
                                              child: CircularProgressIndicator(
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
                            Positioned(
                              left: 0,
                              right: 0,
                              top: center + radius,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 10),
                                  StatusText(
                                    label,
                                    style: TextStyle(color: ink, fontSize: 12),
                                  ),
                                  SizedBox(height: statusGap),
                                  SessionUptime(
                                    snapshot: state,
                                    active: visible && controller.foreground,
                                    showUptime:
                                        running &&
                                        !controller.loading &&
                                        !controller.dispatching &&
                                        state.operation == null &&
                                        issues.isEmpty,
                                    title: title,
                                    subtitle: subtitle,
                                    color: ink,
                                    refresh: controller.refresh,
                                    onIssue: issues.isEmpty
                                        ? null
                                        : () {
                                            showLocalizedOperationMessage(
                                              context,
                                              (strings) => issues
                                                  .map(
                                                    (message) => message
                                                        .resolve(strings),
                                                  )
                                                  .where(
                                                    (text) =>
                                                        text.trim().isNotEmpty,
                                                  )
                                                  .toSet()
                                                  .join('\n\n'),
                                              title: (strings) =>
                                                  strings.tunnelStatus,
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
    );
  }
}
