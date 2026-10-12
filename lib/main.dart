import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/background_entry.dart';

void main() => runApp(const ClashPseudoApp());

@pragma('vm:entry-point')
void appBackgroundMain() => runBackground();
