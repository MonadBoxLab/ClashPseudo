import 'package:flutter/painting.dart';

/// General layout scenario: small fonts scale by 2 and other fonts by 1.7.
class NonlinearTextScaler extends TextScaler {
  const NonlinearTextScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize <= 12 ? 2 : 1.7);

  @override
  double get textScaleFactor => 1.7;
}
