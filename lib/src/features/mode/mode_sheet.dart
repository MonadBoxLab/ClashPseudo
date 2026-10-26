import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/app_theme.dart';
import '../../app/widgets/operation_feedback.dart';
import '../../l10n/app_localizations.dart';
import '../../l10n/messages.dart';
import 'tunnel_mode.dart';

class ModeSheet extends StatefulWidget {
  const ModeSheet({super.key, required this.controller, this.storageEpoch});
  final AppController controller;
  final int? storageEpoch;

  @override
  State<ModeSheet> createState() => _ModeSheetState();
}

class _ModeSheetState extends State<ModeSheet> {
  TunnelMode? _target;
  String? _previousResult;
  bool _closing = false;
  late final int _storageEpoch;

  @override
  void initState() {
    super.initState();
    _storageEpoch = widget.storageEpoch ?? widget.controller.storageEpoch;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    final controller = widget.controller;
    final state = controller.state;
    final completed =
        state.resultId != null && state.resultId != _previousResult;
    if (_storageEpoch != controller.storageEpoch) _target = null;
    if (_target != null && !controller.busy) {
      if (controller.error != null || (completed && !state.resultSuccess)) {
        _target = null;
      } else if (completed &&
          _storageEpoch == controller.storageEpoch &&
          controller.configsCurrent &&
          controller.collection.mode == _target &&
          (state.phase == 'STOPPED' ||
              (state.running && state.mode == _target))) {
        if (!_closing) {
          _closing = true;
          final route = ModalRoute.of(context);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                route?.isCurrent == true &&
                _storageEpoch == controller.storageEpoch) {
              Navigator.of(context).pop();
            } else {
              _closing = false;
            }
          });
        }
      }
    }
    setState(() {});
  }

  Future<void> _choose(TunnelMode mode) async {
    final controller = widget.controller;
    if (!controller.canChangeMode || _target != null) return;
    if (_storageEpoch == controller.storageEpoch &&
        controller.collection.mode == mode &&
        (!controller.state.running || controller.state.mode == mode)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _target = mode;
      _previousResult = controller.state.resultId;
    });
    await controller.submit({
      'action': 'setMode',
      'mode': mode.name,
      'storageEpoch': _storageEpoch,
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final state = controller.state;
    final strings = AppLocalizations.of(context);
    final current = state.running
        ? state.mode
        : state.phase == 'STOPPED' && controller.configsCurrent
        ? controller.collection.mode
        : null;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = ModePalette(theme.brightness == Brightness.dark);
    final enabled = controller.canChangeMode && _target == null;
    final differs =
        state.running &&
        state.mode != null &&
        controller.configsCurrent &&
        controller.collection.mode != null &&
        state.mode != controller.collection.mode;
    final warning = state.modeError != null;
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
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.modeTitle,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: warning || differs
                        ? IconButton(
                            tooltip: state.modeError != null
                                ? strings.modeReadFailed
                                : strings.modeDiffers,
                            onPressed: () => showLocalizedOperationMessage(
                              context,
                              (strings) => [
                                if (controller.configsCurrent &&
                                    controller.collection.mode != null)
                                  strings.modeSaved(
                                    controller.collection.mode!.label(strings),
                                  ),
                                if (differs)
                                  strings.modeActualDiffers(
                                    state.mode!.label(strings),
                                  ),
                                if (state.modeErrorMessage case final message?)
                                  message.resolve(strings),
                              ].join('\n\n'),
                              title: (strings) => strings.modeTitle,
                              error: warning,
                            ),
                            icon: Icon(
                              warning
                                  ? Icons.error_outline
                                  : Icons.info_outline,
                              color: warning ? colors.error : colors.primary,
                            ),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.modeHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
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
                          ? colors.surfaceContainer
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
                                mode.label(strings),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                mode.description(strings),
                                style: descriptionStyle,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox.square(
                          dimension: 20,
                          child: current == mode
                              ? Icon(
                                  Icons.check,
                                  size: 20,
                                  color: colors.primary,
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
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
