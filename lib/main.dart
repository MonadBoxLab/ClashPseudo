import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/logic/background_entry.dart';
import 'src/app/app_legal.dart';

void main() {
  registerAppLicenses();
  runApp(const ClashPseudoApp());
}

@pragma('vm:entry-point')
void appBackgroundMain() => runBackground();
