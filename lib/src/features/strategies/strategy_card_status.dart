import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'delay_result.dart';

class StrategyCardStatus extends StatelessWidget {
  const StrategyCardStatus({
    super.key,
    required this.slotWidth,
    this.result,
    this.rejected = false,
  });

  final double slotWidth;
  final DelayMemberResult? result;
  final bool rejected;

  static const style = TextStyle(fontSize: 11, height: 1.3);

  static double width(BuildContext context) {
    final strings = AppLocalizations.of(context);
    var width = 0.0;
    for (final text in [
      '65535 ms',
      strings.strategyRejectStatus,
      strings.delayRunning,
      strings.delayFailed,
      strings.delayTimeout,
      strings.delayCancelled,
    ]) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width > width) width = painter.width;
      painter.dispose();
    }
    return width.ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final text = rejected
        ? strings.strategyRejectStatus
        : switch (result?.status) {
            DelayMemberStatus.success => '${result!.delay} ms',
            DelayMemberStatus.pending => '',
            DelayMemberStatus.running => strings.delayRunning,
            DelayMemberStatus.failed => strings.delayFailed,
            DelayMemberStatus.timeout => strings.delayTimeout,
            DelayMemberStatus.cancelled => strings.delayCancelled,
            DelayMemberStatus.expired || null => '',
          };
    final failed =
        rejected ||
        result?.status == DelayMemberStatus.failed ||
        result?.status == DelayMemberStatus.timeout;
    return SizedBox(
      width: slotWidth,
      height: MediaQuery.textScalerOf(context).scale(11) * 1.3,
      child: Tooltip(
        message: text.isEmpty
            ? ''
            : rejected
            ? text
            : strings.strategyCardDelayNotice(text),
        child: Text(
          text,
          textAlign: TextAlign.right,
          maxLines: 1,
          style: style.copyWith(
            color: failed ? colors.error : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
