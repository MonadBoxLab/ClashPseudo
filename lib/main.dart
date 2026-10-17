import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/background_entry.dart';
import 'app/app_legal.dart';

void main() {
  registerAppLicenses();
  runApp(const ClashPseudoApp());
}

@pragma('vm:entry-point')
void appBackgroundMain() => runBackground();
