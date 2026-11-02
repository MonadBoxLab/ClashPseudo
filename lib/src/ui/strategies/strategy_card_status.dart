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

  static const style = TextStyle(
    fontSize: 11,
    height: 1.3,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static double width(BuildContext context, {TextStyle textStyle = style}) =>
      _measure(context, textStyle).width;

  static double height(BuildContext context) => _measure(context, style).height;

  static Size _measure(BuildContext context, TextStyle textStyle) {
    final resolved = DefaultTextStyle.of(context).style.merge(textStyle);
    final painter = TextPainter(
      text: TextSpan(text: '0', style: resolved),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final digitWidth = painter.width;
    final height = painter.height;
    painter.text = TextSpan(text: ' ms', style: resolved);
    painter.layout();
    // 数值区域容纳五位 tabular 数字与单位，较长内容在同一区域水平阅读。
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
              style: style.copyWith(
                color: failed ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
