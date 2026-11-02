import 'package:flutter/material.dart';

import 'src/platform/app_bootstrap.dart';
import 'src/ui/app/app.dart';
import 'src/ui/legal/app_legal.dart';

void main() {
  registerAppLicenses();
  runApp(const ClashPseudoApp());
}

@pragma('vm:entry-point')
void appBackgroundMain() => runBackground();
