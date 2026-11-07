import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../model/delay_result.dart';

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

  static TextStyle styleOf(BuildContext context) => Theme.of(context)
      .textTheme
      .bodySmall!
      .copyWith(
        height: 1.3,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static double width(BuildContext context, {TextStyle? textStyle}) =>
      _measure(context, textStyle ?? styleOf(context)).width;

  static double height(BuildContext context) =>
      _measure(context, styleOf(context)).height;

  static Size _measure(BuildContext context, TextStyle textStyle) {
    final resolved = DefaultTextStyle.of(context).style.merge(textStyle);
    final painter = TextPainter(
      text: TextSpan(text: '0', style: resolved),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final digitWidth = painter.width;
    final height = painter.height;
    painter.text = TextSpan(text: ' ms', style: resolved);
    painter.layout();
    // The value area fits five tabular digits and a unit; longer content scrolls
    // horizontally within it.
    final width = digitWidth * 5 + painter.width;
    painter.dispose();
    return Size(width.ceilToDouble(), height.ceilToDouble());
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
            DelayMemberStatus.failed || DelayMemberStatus.timeout => '',
            DelayMemberStatus.cancelled => strings.delayCancelled,
            DelayMemberStatus.expired || null => '',
          };
    final failed = rejected;
    return SizedBox(
      width: slotWidth,
      height: height(context),
      child: Tooltip(
        message: text.isEmpty
            ? ''
            : rejected
            ? text
            : strings.strategyCardDelayNotice(text),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Text(
              text,
              textAlign: TextAlign.end,
              maxLines: 1,
              softWrap: false,
              style: styleOf(context).copyWith(
                color: failed ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
