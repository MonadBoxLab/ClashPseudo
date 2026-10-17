import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/operation_feedback.dart';
import 'tunnel_mode.dart';

class ModeSheet extends StatefulWidget {
  const ModeSheet({super.key, required this.controller});
  final AppController controller;

  @override
  State<ModeSheet> createState() => _ModeSheetState();
}

class _ModeSheetState extends State<ModeSheet> {
  TunnelMode? _target;
  String? _previousResult;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    final controller = widget.controller;
    final state = controller.state;
    final completed =
        state.resultId != null && state.resultId != _previousResult;
    if (_target != null && !controller.busy) {
      if (controller.error != null || (completed && !state.resultSuccess)) {
        _target = null;
      } else if (completed &&
          controller.configsCurrent &&
          controller.collection.mode == _target &&
          (state.phase == 'STOPPED' ||
              (state.running && state.mode == _target))) {
        if (!_closing) {
          _closing = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop();
          });
        }
      }
    }
    setState(() {});
  }

  Future<void> _choose(TunnelMode mode) async {
    final controller = widget.controller;
    if (!controller.canChangeMode || _target != null) return;
    if (controller.collection.mode == mode &&
        (!controller.state.running || controller.state.mode == mode)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _target = mode;
      _previousResult = controller.state.resultId;
    });
    await controller.submit({'action': 'setMode', 'mode': mode.name});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final state = controller.state;
    final current = state.running
        ? state.mode
        : state.phase == 'STOPPED' && controller.configsCurrent
        ? controller.collection.mode
        : null;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = ModePalette(theme.brightness == Brightness.dark);
    final enabled = controller.canChangeMode && _target == null;
    Color categoryColor(TunnelMode mode) => switch (mode) {
      TunnelMode.rule => palette.rule,
      TunnelMode.global => palette.global,
      TunnelMode.direct => palette.direct,
    };
    final descriptionStyle = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.45,
    );
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '运行模式',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.running
                  ? '切换不主动断开已有连接，新连接按所选模式处理。'
                  : '仅保存选择，下次启动生效，不会自动启动接管。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            if (state.running &&
                controller.configsCurrent &&
                state.mode != controller.collection.mode) ...[
              const SizedBox(height: 8),
              Text('已保存：${controller.collection.mode.label}；供下次启动使用。'),
            ],
            const SizedBox(height: 20),
            for (final mode in TunnelMode.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Semantics(
                  selected: current == mode,
                  child: OutlinedButton(
                    key: ValueKey('mode-${mode.name}'),
                    onPressed: enabled ? () => _choose(mode) : null,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      backgroundColor: current == mode
                          ? Color.alphaBlend(
                              colors.primary.withValues(alpha: .04),
                              colors.surface,
                            )
                          : colors.surface,
                      foregroundColor: colors.onSurface,
                      disabledForegroundColor: colors.onSurface.withValues(
                        alpha: .65,
                      ),
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: categoryColor(mode)
                                .withValues(alpha: enabled ? .10 : .04),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            switch (mode) {
                              TunnelMode.rule => Icons.alt_route_rounded,
                              TunnelMode.global => Icons.public_outlined,
                              TunnelMode.direct => Icons.arrow_forward_rounded,
                            },
                            size: 22,
                            color: categoryColor(mode)
                                .withValues(alpha: enabled ? 1 : .38),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                mode.label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(mode.description, style: descriptionStyle),
                            ],
                          ),
                        ),
                        if (current == mode) ...[
                          const SizedBox(width: 12),
                          Icon(Icons.check, size: 20, color: colors.primary),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            if (_target != null)
              Semantics(
                liveRegion: true,
                child: Text('正在确认${_target!.label}模式…'),
              ),
            if (state.modeError != null) Text(state.modeError!),
            if (_target == null)
              OperationFeedback(
                controller: controller,
                hideModeSuccess: true,
                hideToggleSuccess: true,
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }
}
