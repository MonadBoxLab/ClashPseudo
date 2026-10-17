import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../../../app/app_theme.dart';
import '../../../app/widgets/operation_feedback.dart';
import 'power_ripples.dart';
import 'status_text.dart';

class StatusHero extends StatelessWidget {
  const StatusHero({
    super.key,
    required this.controller,
    required this.visible,
    required this.onManage,
    required this.onImport,
    required this.onMode,
  });

  final AppController controller;
  final bool visible;
  final VoidCallback onManage;
  final VoidCallback onImport;
  final VoidCallback onMode;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final palette = HomePalette(
      Theme.of(context).brightness == Brightness.dark,
    );
    final selected = controller.collection.selected;
    final actual = controller.collection.find(state.configId);
    final running = state.running;
    final current = controller.configsCurrent;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final title = controller.loading
        ? '正在获取状态'
        : controller.dispatching
        ? '正在提交请求'
        : state.operation != null
        ? '正在处理'
        : switch (state.phase) {
            'RUNNING' => '接管运行中',
            'STOPPED' => '接管已关闭',
            'STARTING' => '正在启动',
            'STOPPING' => '正在停止',
            _ => '状态未确认',
          };
    final subtitle =
        state.operation ??
        (controller.loading
            ? '状态确认前，暂不可启停'
            : controller.platformError != null
            ? '暂时无法获取状态，正在自动尝试'
            : !state.confirmed
            ? state.phase == 'UNKNOWN'
                  ? '平台尚未确认资源状态，暂不可启停'
                  : '正在等待接管结果'
            : !current
            ? controller.configError != null
                  ? '配置读取失败，仍可查看管理页面'
                  : '正在读取已保存配置'
            : running
            ? ''
            : selected == null
            ? '导入完整配置后，即可启动'
            : selected.body == null
            ? '当前配置需要重新导入更新'
            : '准备好，即可开始');
    final configName = !current
        ? controller.configError != null
              ? '配置身份未确认'
              : '正在读取配置'
        : running
        ? actual?.name ?? '配置身份未确认'
        : selected?.name ?? '尚未导入配置';
    final identity = !current
        ? ''
        : running && state.configId != selected?.id
        ? '当前选择：${selected?.name ?? '无'}'
        : running && actual != null && state.revision != actual.revision
        ? '运行中版本与已保存版本不同'
        : !controller.loading && state.phase == 'UNKNOWN' && selected != null
        ? '已选配置 · 未确认实际使用'
        : '';
    final label = controller.loading || state.phase == 'UNKNOWN'
        ? '暂不可用'
        : controller.dispatching || state.operation != null
        ? '处理中…'
        : state.phase == 'STARTING'
        ? '启动中…'
        : state.phase == 'STOPPING'
        ? '停止中…'
        : running
        ? '停止接管'
        : '启动接管';
    final ink = running ? palette.heroInk : palette.ink;
    final enabled = controller.canToggle;
    final showImport = current && selected == null && !running;
    final emitting =
        running &&
        !(controller.dispatching &&
            controller.lastCommand?['action'] == 'stop');

    return AnimatedContainer(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 320),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(.9, -1),
          radius: 1.6,
          colors: [
            palette.heroHighlight.withValues(alpha: running ? 1 : 0),
            palette.heroHighlight.withValues(alpha: 0),
          ],
        ),
      ),
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
              TextButton(
                onPressed: onManage,
                style: TextButton.styleFrom(
                  foregroundColor: ink,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 48),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        configName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text('配置管理', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 16),
                  ],
                ),
              ),
              StatusText(
                identity,
                key: const ValueKey('config-identity'),
                style: TextStyle(color: ink, fontSize: 12),
                textAlign: TextAlign.start,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TweenAnimationBuilder<Color?>(
                        tween: ColorTween(
                          end: running ? palette.ripple : palette.accent,
                        ),
                        duration: reduced
                            ? Duration.zero
                            : const Duration(milliseconds: 320),
                        builder: (context, color, child) => PowerRipples(
                          emitting: emitting,
                          visible: visible,
                          color: color!,
                          child: child!,
                        ),
                        child: SizedBox.square(
                          dimension: 88,
                          child: FilledButton(
                            key: const ValueKey('power-button'),
                            onPressed: enabled
                                ? () => controller.submit({
                                    'action': running ? 'stop' : 'start',
                                  })
                                : null,
                            style: FilledButton.styleFrom(
                              shape: CircleBorder(
                                side: BorderSide(
                                  color: running
                                      ? palette.powerEdge
                                      : palette.line,
                                ),
                              ),
                              padding: EdgeInsets.zero,
                              backgroundColor: running
                                  ? palette.powerFace
                                  : palette.startFace,
                              foregroundColor: running
                                  ? palette.powerInk
                                  : palette.startInk,
                              disabledBackgroundColor: palette.soft,
                              disabledForegroundColor: palette.muted,
                            ),
                            child: Semantics(
                              label: label,
                              child: ExcludeSemantics(
                                child: controller.busy && !reduced
                                    ? const SizedBox.square(
                                        dimension: 26,
                                        child: CircularProgressIndicator(
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
                      const SizedBox(height: 10),
                      StatusText(
                        label,
                        style: TextStyle(color: ink, fontSize: 12),
                      ),
                      const SizedBox(height: 22),
                      StatusText(
                        title,
                        style: TextStyle(
                          color: ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 6),
                      StatusText(
                        subtitle,
                        style: TextStyle(color: ink, fontSize: 12),
                      ),
                      TextButton.icon(
                        key: const ValueKey('mode-trigger'),
                        onPressed: controller.canChangeMode ? onMode : null,
                        style: TextButton.styleFrom(
                          foregroundColor: ink,
                          disabledForegroundColor: ink.withValues(alpha: .65),
                        ),
                        icon: const Icon(Icons.expand_more, size: 16),
                        label: StatusText(
                          controller.loading || !state.confirmed
                              ? '运行模式 · 未确认'
                              : running
                              ? state.mode == null
                                    ? '运行模式未确认'
                                    : '${state.mode!.label}模式'
                              : current
                              ? '${controller.collection.mode.label}模式 · 未运行'
                              : '保存模式未确认',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (state.modeError != null)
                        Text(
                          state.modeError!,
                          style: TextStyle(color: ink, fontSize: 12),
                        ),
                      if (showImport) ...[
                        const SizedBox(height: 14),
                        TextButton.icon(
                          onPressed: controller.canEdit ? onImport : null,
                          icon: const Icon(Icons.add_link, size: 18),
                          label: const Text('导入配置'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              OperationFeedback(
                controller: controller,
                showOperation: false,
                hideToggleSuccess: true,
                hideModeSuccess: true,
                foregroundColor: ink,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
