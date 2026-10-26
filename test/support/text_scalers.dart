import 'package:flutter/painting.dart';

/// 通用布局场景：小字号放大两倍，其余字号放大 1.7 倍。
class NonlinearTextScaler extends TextScaler {
  const NonlinearTextScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize <= 12 ? 2 : 1.7);

  @override
  double get textScaleFactor => 1.7;
}
