import 'package:flutter/material.dart';

/// 根据等宽字体、字号和文字缩放限制技术文本的行宽，且不超过父组件允许的宽度。
class TechnicalReadingPane extends StatelessWidget {
  const TechnicalReadingPane({super.key, required this.child});

  final Widget child;

  static const maximumColumns = 120;
  static const horizontalPadding = 16.0;

  static TextStyle textStyleOf(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium!.copyWith(fontFamily: 'monospace');

  @override
  Widget build(BuildContext context) {
    final measure = TextPainter(
      text: TextSpan(text: 'M' * maximumColumns, style: textStyleOf(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final maximumWidth = measure.width + horizontalPadding * 2;
    measure.dispose();
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maximumWidth),
          child: child,
        ),
      ),
    );
  }
}
