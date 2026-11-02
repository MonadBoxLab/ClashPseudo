import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../model/app_message.dart';
import '../../../components/feedback/operation_notice.dart';
import 'form_body.dart';
import 'form_interaction.dart';

class DefinitionSaveBar extends StatelessWidget {
  const DefinitionSaveBar({
    super.key,
    required this.id,
    required this.saving,
    required this.onSave,
    this.compact = false,
    this.completed = false,
    this.saveKey,
  });
  final String id;
  final bool saving;
  final bool compact;
  final bool completed;
  final Key? saveKey;
  final VoidCallback onSave;

  static const _padding = EdgeInsets.fromLTRB(20, 8, 20, 12);
  static const _buttonPadding = EdgeInsets.symmetric(
    horizontal: 24,
    vertical: 12,
  );
  static double _height(
    BuildContext context,
    String text,
    TextStyle? style,
    double width,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: math.max(1, width));
    final height = painter.height;
    painter.dispose();
    return height;
  }

  static double heightOf(BuildContext context) =>
      _padding.vertical + buttonHeight(context);

  static double buttonHeight(BuildContext context) => math.max(
    kMinInteractiveDimension,
    _height(
          context,
          AppLocalizations.of(context).save,
          Theme.of(context).textTheme.labelLarge,
          double.infinity,
        ) +
        _buttonPadding.vertical,
  );

  static ButtonStyle buttonStyle(
    BuildContext context, {
    bool compact = false,
  }) => FilledButton.styleFrom(
    textStyle: Theme.of(context).textTheme.labelLarge,
    minimumSize: const Size(64, kMinInteractiveDimension),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.padded,
    padding: compact
        ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
        : _buttonPadding,
  );

  // Recheck the mounted widget, not the snapshot captured by a cached callback.
  DefinitionSaveBar? _current(BuildContext context) {
    if (!context.mounted || !DefinitionFormInteraction.canAct(context)) {
      return null;
    }
    final current = context.widget;
    return current is DefinitionSaveBar && current.id == id ? current : null;
  }

  Widget _save(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final progress = SizedBox.square(
      dimension: 16,
      child: saving && !completed
          ? const CircularProgressIndicator(strokeWidth: 2)
          : null,
    );
    final style = buttonStyle(context, compact: compact);
    final key = saveKey ?? ValueKey('definition-save:$id');
    return Tooltip(
      message: strings.save,
      excludeFromSemantics: true,
      child: FilledButton(
        key: key,
        style: style,
        onPressed: saving || completed
            ? null
            : () {
                final current = _current(context);
                if (current != null && !current.saving && !current.completed) {
                  current.onSave();
                }
              },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            progress,
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                strings.save,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!compact) const SizedBox(width: 24),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Align(
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: DefinitionFormBody.widthOf(context, wide: false),
      ),
      child: SafeArea(
        top: false,
        child: Padding(padding: _padding, child: _save(context)),
      ),
    ),
  );
}

Future<bool> showDefinitionSaveFailure(
  BuildContext context, {
  required AppMessage? failure,
  required String? detail,
  required bool Function() isCurrent,
  required Future<void> Function() onDetails,
  required Future<void> Function() onRetry,
  VoidCallback? onPresented,
}) => failure != null
    ? showAppNotice(
        context,
        failure,
        isCurrent: isCurrent,
        onDetails: onDetails,
        onRetry: onRetry,
        onPresented: onPresented,
      )
    : showLocalizedOperationNotice(
        context,
        (strings) => strings.proxySaveFailed,
        technicalDetail: (_) => detail,
        isCurrent: isCurrent,
        onDetails: onDetails,
        onRetry: onRetry,
        onPresented: onPresented,
      );
